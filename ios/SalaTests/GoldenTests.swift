import Foundation
import XCTest

// The Swift port of the old server's routes against recordings of the server itself, made on its
// fake Aula before it was removed (git history: server/tests/export_goldens.py). Each step's Aula
// traffic is replayed by `GoldenTransport`, and the Swift answer, error and writes must equal the
// recorded ones. The goldens are frozen: a deliberate route change means editing its golden by hand.

private let goldensDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens")
private let profileMethods: Set<String> = ["profiles.getProfilesByLogin", "profiles.getProfileContext"]

private func loadGolden(_ name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: goldensDir.appendingPathComponent("\(name).json"))
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

// MARK: strict JSON comparison (bools are not numbers, null is not missing)

private func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

/// nil when equal, else where they first differ.
func jsonDiff(_ a: Any?, _ b: Any?, _ path: String = "$") -> String? {
    let a = a is NSNull ? nil : a, b = b is NSNull ? nil : b
    switch (a, b) {
    case (nil, nil): return nil
    case let (x as [String: Any], y as [String: Any]):
        for key in Set(x.keys).union(y.keys).sorted() {
            guard x[key] != nil, y[key] != nil else { return "\(path).\(key): only on one side (swift \(x[key].map { "\($0)" } ?? "missing"), server \(y[key].map { "\($0)" } ?? "missing"))" }
            if let d = jsonDiff(x[key], y[key], "\(path).\(key)") { return d }
        }
        return nil
    case let (x as [Any], y as [Any]):
        if x.count != y.count { return "\(path): \(x.count) items vs \(y.count)" }
        for (i, (p, q)) in zip(x, y).enumerated() { if let d = jsonDiff(p, q, "\(path)[\(i)]") { return d } }
        return nil
    case let (x as String, y as String): return x == y ? nil : "\(path): \(x.debugDescription) vs \(y.debugDescription)"
    case let (x as NSNumber, y as NSNumber):
        return isBool(x) == isBool(y) && x == y ? nil : "\(path): \(x) vs \(y)"
    default: return "\(path): \(a.map { "\($0)" } ?? "null") vs \(b.map { "\($0)" } ?? "null")"
    }
}

// MARK: the replaying transport

final class GoldenTransport: AulaTransport, @unchecked Sendable {
    struct Exchange {
        var verb: String
        var query: [[String]]
        var body: Any?
        var status: Int
        var answer: Any?
        var consumed = false
        var method: String { query.first { $0[0] == "method" }?[1] ?? "" }
    }

    private let lock = NSLock()
    private let profile: [String: Any]
    private let files: [String: Data]
    private let forbidAll: Bool
    private var pending: [Exchange] = []
    private(set) var unmatched: [String] = []
    private(set) var posts: [[String: Any]] = []

    init(_ golden: [String: Any]) {
        profile = golden["profile"] as? [String: Any] ?? [:]
        files = (golden["files"] as? [String: String] ?? [:]).compactMapValues { Data(base64Encoded: $0) }
        forbidAll = (golden["forbidden"] as? [String] ?? []).contains("*")
    }

    func begin(_ exchanges: [[String: Any]]) {
        lock.withLock {
            pending = exchanges.map {
                Exchange(verb: $0["verb"] as! String, query: ($0["query"] as! [[String]]).sorted { $0.lexicographicallyPrecedes($1) },
                         body: $0["body"], status: $0["status"] as! Int, answer: $0["answer"])
            }
            unmatched = []
            posts = []
        }
    }

    /// Recorded exchanges (other than the profile reads, which the Swift session makes on opening)
    /// the Swift code never asked for.
    var leftovers: [String] {
        lock.withLock { pending.filter { !$0.consumed && !profileMethods.contains($0.method) }.map { "\($0.verb) \($0.query)" } }
    }

    func cookie(named: String) -> String? { nil }
    func clearCookies() {}

    func send(_ request: URLRequest, redirectsAllowed: (@Sendable (URL?) -> Bool)?) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let reply = { (status: Int, body: Any?) -> (Data, HTTPURLResponse) in
            let data = body.map { try! JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) } ?? Data()
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
        guard url.host == "www.aula.dk", url.path.hasPrefix("/api/") else {
            if url.host == "login.aula.dk" { return reply(400, ["error": "invalid_grant"]) }  // no refresh in tests
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            c.query = nil
            if let data = files[c.string!] {
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
            }
            return reply(404, nil)
        }
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
            .split(separator: "&").map { part -> [String] in
                let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).removingPercentEncoding! }
                return [kv[0], kv.count > 1 ? kv[1] : ""]
            }
            .filter { $0[0] != "access_token" }
        let method = query.first { $0[0] == "method" }?[1] ?? ""
        let verb = request.httpMethod ?? "GET"
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        let forbidden: (Data, HTTPURLResponse) = reply(403, ["status": ["code": 403, "message": "Forbidden"], "data": NSNull()])
        if forbidAll { return forbidden }
        if profileMethods.contains(method) { return reply(200, profile[method]) }

        let sorted = query.sorted { $0.lexicographicallyPrecedes($1) }
        return lock.withLock {
            if verb == "POST" { posts.append(["method": method, "payload": body ?? NSNull()]) }
            guard let i = pending.firstIndex(where: {
                !$0.consumed && $0.verb == verb && $0.query == sorted && (verb != "POST" || jsonDiff(body, $0.body) == nil)
            }) else {
                let bodyText = body.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
                    .map { String(decoding: $0, as: UTF8.self) } ?? ""
                unmatched.append("\(verb) \(sorted) \(bodyText)")
                return reply(599, ["status": ["code": 599, "message": "not in the recording"], "data": NSNull()])
            }
            pending[i].consumed = true
            return reply(pending[i].status, pending[i].answer)
        }
    }
}

// MARK: tests

final class GoldenTests: XCTestCase {
    private func run(_ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let golden = try loadGolden(name)
        let transport = GoldenTransport(golden)
        let aula = Aula(transport: transport, tokens: Aula.Tokens(access_token: "golden", refresh_token: nil, expires_in: nil, expiresAt: nil))
        let now = ISO8601DateFormatter().date(from: golden["now"] as! String)!
        for (n, step) in (golden["steps"] as! [[String: Any]]).enumerated() {
            let verb = step["verb"] as! String, path = step["path"] as! String
            let label = "\(name) step \(n): \(verb) \(path)" + ((step["note"] as? String).map { $0.isEmpty ? "" : " (\($0))" } ?? "")
            let status = step["status"] as! Int
            let expected = step["response"] as Any?
            transport.begin(step["aula"] as! [[String: Any]])

            if path.hasPrefix("/attachments/") {
                let id = String(path.dropFirst("/attachments/".count))
                let result = await Aula.$clock.withValue(now) { () -> Result<(Data, name: String, contentType: String), Error> in
                    do { return .success(try await aula.attachment(id)) } catch { return .failure(error) }
                }
                let att = step["attachment"] as! [String: Any]
                switch result {
                case let .success((data, fileName, type)):
                    XCTAssertEqual(status, 200, label, file: file, line: line)
                    XCTAssertEqual(data.base64EncodedString(), att["bytes"] as? String, label, file: file, line: line)
                    XCTAssertEqual(fileName, att["name"] as? String, label, file: file, line: line)
                    XCTAssertEqual(type, att["contentType"] as? String, label, file: file, line: line)
                case let .failure(error):
                    check(error, status: status, expected: expected, label, file: file, line: line)
                }
            } else {
                let body = J.isNone(step["body"]) ? nil : try JSONSerialization.data(withJSONObject: step["body"]!, options: [.fragmentsAllowed])
                let result = await Aula.$clock.withValue(now) { () -> Result<Data, Error> in
                    do { return .success(try await aula.handle(verb, path, body: body)) } catch { return .failure(error) }
                }
                switch result {
                case let .success(data):
                    XCTAssertEqual(status, 200, "\(label): Swift answered, the server said \(status) \(expected ?? "")", file: file, line: line)
                    if status == 200 {
                        let got = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                        if let d = jsonDiff(got, expected) { XCTFail("\(label): \(d)", file: file, line: line) }
                    }
                case let .failure(error):
                    check(error, status: status, expected: expected, label, file: file, line: line)
                }
            }

            XCTAssertEqual(transport.unmatched, [], "\(label): requests the server never made", file: file, line: line)
            XCTAssertEqual(transport.leftovers, [], "\(label): requests the server made and Swift didn't", file: file, line: line)
            let writes = step["writes"] as! [Any]
            if let d = jsonDiff(transport.posts, writes) { XCTFail("\(label): writes differ: \(d)", file: file, line: line) }
        }
    }

    private func check(_ error: Error, status: Int, expected: Any?, _ label: String, file: StaticString, line: UInt) {
        let message = (expected as? [String: Any])?["message"] as? String
        let ok: Bool
        switch (error as? APIError, status) {
        case let (.http(400, m)?, 400): ok = m == message
        case let (.http(405, _)?, 405): ok = true
        case (.notFound?, 404): ok = true
        case let (.conflict(m)?, 409): ok = m == message
        case (.upstream?, 502): ok = true
        case (.authRequired?, 503): ok = true
        default: ok = false
        }
        XCTAssertTrue(ok, "\(label): Swift threw \(error), the server said \(status) \(expected ?? "")", file: file, line: line)
    }

    func testToday() async throws { try await run("today") }
    func testTodayPartial() async throws { try await run("today_partial") }
    func testSessionGone() async throws { try await run("session_gone") }
    func testPickup() async throws { try await run("pickup") }
    func testPickupAbsent() async throws { try await run("pickup_absent") }
    func testSick() async throws { try await run("sick") }
    func testHoliday() async throws { try await run("holiday") }
    func testAbsences() async throws { try await run("absences") }
    func testAbsenceDenied() async throws { try await run("absence_denied") }
    func testPosts() async throws { try await run("posts") }
    func testSave() async throws { try await run("save") }
    func testGallery() async throws { try await run("gallery") }
    func testCalendar() async throws { try await run("calendar") }
    func testContacts() async throws { try await run("contacts") }
    func testThreads() async throws { try await run("threads") }
    func testPatchThread() async throws { try await run("patch_thread") }
    func testThreadDetail() async throws { try await run("thread_detail") }
    func testReply() async throws { try await run("reply") }
    func testFolders() async throws { try await run("folders") }
    func testAttachments() async throws { try await run("attachments") }
    func testGuards() async throws { try await run("guards") }

    /// Every recorded scenario has a test above.
    func testAllScenariosCovered() throws {
        let tested: Set<String> = [
            "today", "today_partial", "session_gone", "pickup", "pickup_absent", "sick", "holiday", "absences", "absence_denied",
            "posts", "gallery", "calendar", "contacts", "save", "threads", "patch_thread", "thread_detail", "reply", "folders", "attachments", "guards",
        ]
        let files = try FileManager.default.contentsOfDirectory(atPath: goldensDir.path)
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix("_") }.map { String($0.dropLast(5)) }
        XCTAssertEqual(Set(files), tested)
    }
}

/// The pure helpers the routes lean on, against the server's own outputs.
final class HelperTests: XCTestCase {
    private var h: [String: Any] = [:]

    override func setUpWithError() throws { h = try loadGolden("_helpers") }

    private func rows(_ key: String) -> [[Any]] { h[key] as! [[Any]] }
    private func opt(_ v: Any) -> String? { v as? String }

    func testPlain() {
        for r in rows("plain") { XCTAssertEqual(Aula.plain(r[0] as! String), r[1] as? String, "plain(\((r[0] as! String).debugDescription))") }
    }

    func testTextToHTML() {
        for r in rows("textToHtml") { XCTAssertEqual(Aula.textToHTML(r[0] as! String), r[1] as? String) }
    }

    func testISO() {
        for r in rows("iso") { XCTAssertEqual(AulaTime.iso(J.val(r[0])), opt(r[1]), "iso(\(r[0]))") }
        for r in rows("localDate") { XCTAssertEqual(Aula.localDate(J.val(r[0]))?.iso, opt(r[1]), "local_date(\(r[0]))") }
    }

    func testTimes() {
        for r in rows("hhmm") { XCTAssertEqual(Aula.hhmm(J.val(r[0]) as? String), opt(r[1]), "hhmm(\(r[0]))") }
        for r in rows("validHHmm") { XCTAssertEqual(Aula.validHHmm(r[0] as? String), r[1] as? Bool, "valid_hhmm(\(r[0]))") }
        for r in rows("pickupTimes") {
            let at = Aula.minutes(r[3] as! String)!
            XCTAssertEqual(try Aula.pickupTimes(current: opt(r[0]), opensAt: opt(r[1]), closesAt: opt(r[2]), nowMinutes: at), r[4] as? [String], "\(r)")
        }
    }

    func testDates() {
        for r in rows("dateRange") {
            XCTAssertEqual(Aula.dateRangeLabel(Day.parse(r[0] as! String)!, opt(r[1]).flatMap(Day.parse)), r[2] as? String)
        }
        for r in rows("validateVacation") {
            let err = Aula.validateVacation(start: Day.parse(r[0] as! String)!, end: Day.parse(r[1] as! String)!, comment: r[2] as! String,
                                            today: Day.parse(r[3] as! String)!)
            XCTAssertEqual(err, opt(r[4]), "\(r[0]) \(r[1])")
        }
    }

    /// Offline fails /today instead of blanking its optional parts (which Store would then save).
    func testOfflineIsNotOptional() async {
        do {
            _ = try await Aula.optional("x") { () async throws -> Int in throw Aula.Failure.transport("offline") }
            XCTFail("transport error was swallowed")
        } catch {}
    }
}
