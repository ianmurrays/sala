import Foundation
import XCTest

// Demo mode's fixtures (ios/DemoAula/, read by Sala/Aula/DemoAula.swift) must keep up with the code:
// every Aula method the app calls has one, and every screen's route works on them.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private let fixtures = repo.appending(path: "DemoAula")

final class DemoTests: XCTestCase {
    /// `"area.name"` literals in the Aula code that aren't Aula methods (JSON key paths, defaults keys).
    private let notMethods: Set<String> = ["a", "aula", "child", "content", "data", "file", "institution", "message", "sender", "text"]

    func testEveryAulaMethodHasAFixture() throws {
        let aulaDir = repo.appending(path: "Sala/Aula")
        let regex = try NSRegularExpression(pattern: #""([a-z]+)\.([a-z][A-Za-z]*)""#)
        var called: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(atPath: aulaDir.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: aulaDir.appending(path: file), encoding: .utf8)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let area = String(text[Range(m.range(at: 1), in: text)!])
                if !notMethods.contains(area) { called.insert(String(text[Range(m.range, in: text)!]).trimmingCharacters(in: ["\""])) }
            }
        }
        let have = Set(try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
        XCTAssertEqual(called.subtracting(have).sorted(), [], "Aula methods with no fixture in ios/DemoAula/ (or add the area to notMethods if it isn't a method)")
        XCTAssertEqual(have.subtracting(called).sorted(), [], "fixtures for methods the app no longer calls: delete them")
    }

    func testDateShift() {
        XCTAssertEqual(DemoTransport.shiftDates(#"{"a":"2026-11-13T08:00:00+01:00","b":"2026-12-31"}"#, by: 1),
                       #"{"a":"2026-11-14T08:00:00+01:00","b":"2027-01-01"}"#)
    }

    /// Every screen's reads to the end of every list, then every thread, album, contact group and holiday
    /// request they link to, then every write the goldens make, at hours a parent uses the app, months
    /// after the fixtures' anchor day so stale dates show up.
    func testEveryScreenWorksOnTheFixtures() async throws {
        // Writes only on Fridays like the anchor day: the goldens' write bodies name weekdays, and a shift
        // that isn't whole weeks would move them onto a weekend.
        for (instant, writes) in [("2027-03-20T10:00:00+01:00", false), ("2027-03-19T06:30:00+01:00", true), ("2027-03-19T22:30:00+01:00", true)] {
            try await walk(ISO8601DateFormatter().date(from: instant)!, writes: writes)
        }
    }

    private func walk(_ now: Date, writes: Bool) async throws {
        let transport = DemoTransport(dir: fixtures)
        let aula = Aula(transport: transport, tokens: DemoTransport.tokens)
        defer { XCTAssertEqual(transport.missing, [], "\(now): Aula requests with no matching fixture case in ios/DemoAula/") }
        let shift = Aula.$clock.withValue(now) { AulaTime.today().ordinal } - DemoTransport.anchor.ordinal
        func send(_ verb: String, _ path: String, _ body: Data? = nil) async throws -> Any {
            let data = try await Aula.$clock.withValue(now) { try await aula.handle(verb, path, body: body) }
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
        /// Page 1 (or 0) must have items; later pages until an empty one, at most 10.
        func pages(_ path: String, first: Int = 1, key: String? = nil) async throws -> [[String: Any]] {
            var all: [[String: Any]] = []
            for page in first..<first + 10 {
                let answer = try await send("GET", "\(path)\(path.contains("?") ? "&" : "?")page=\(page)")
                let items = (key.map { (answer as? [String: Any])?[$0] } ?? answer) as? [[String: Any]] ?? []
                if items.isEmpty { break }
                all += items
            }
            XCTAssertFalse(all.isEmpty, "\(now) \(path): empty")
            return all
        }

        let today = try await send("GET", "/today") as? [String: Any] ?? [:]
        let children = today["children"] as? [[String: Any]] ?? []
        XCTAssertFalse(children.isEmpty, "/today: no children")
        for child in children {
            let pickup = try await send("GET", "/children/\(child["id"]!)/pickup") as? [String: Any] ?? [:]
            // An empty pickup list leaves the sheet's Save disabled.
            XCTAssertFalse((pickup["people"] as? [Any] ?? []).isEmpty, "\(now) \(child["name"]!): no pickup people")
        }
        for item in today["attention"] as? [[String: Any]] ?? [] where item["kind"] as? String == "holiday_request" {
            _ = try await send("GET", "/holiday-requests/\(item["id"]!)")
        }
        for request in try await send("GET", "/holiday-requests") as? [[String: Any]] ?? [] {
            _ = try await send("GET", "/holiday-requests/\(request["id"]!)")
        }
        let absences = try await send("GET", "/absences") as? [Any] ?? []
        XCTAssertFalse(absences.isEmpty, "\(now) /absences: empty")
        _ = try await pages("/posts")
        _ = try await send("GET", "/calendar?month=\(Day(ordinal: DemoTransport.anchor.ordinal + shift).iso.prefix(7))")
        _ = try await send("GET", "/folders")
        for thread in try await pages("/threads", first: 0) { _ = try await send("GET", "/threads/\(thread["id"]!)") }
        for album in try await pages("/albums") { _ = try await pages("/albums/\(album["id"]!)/photos") }
        for group in try await send("GET", "/contacts/groups") as? [[String: Any]] ?? [] {
            _ = try await send("GET", "/contacts/groups/\(group["id"]!)")
        }
        for type in ["messages", "posts", "photos"] { _ = try await pages("/search?q=jul&type=\(type)", key: type) }

        // Writes: the goldens' successful ones, dates moved like the fixtures'.
        guard writes else { return }
        for name in ["pickup", "sick", "absences", "manage_absences", "holiday", "save", "reply", "patch_thread", "folders"] {
            let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appending(path: "SalaTests/Goldens/\(name).json"))) as! [String: Any]
            for step in golden["steps"] as! [[String: Any]] where step["verb"] as? String != "GET" && step["status"] as? Int == 200 {
                // ponytail: creating a folder re-reads the folders to find it, which a fake that keeps no state can't show.
                if step["verb"] as? String == "POST", step["path"] as? String == "/folders" { continue }
                // ponytail: the demo's absence 7001 hasn't started, so a past start is refused there.
                if step["note"] as? String == "shorten a started absence" { continue }
                // ponytail: the demo's Oskar is checked in, so a drop-off change is refused there.
                if step["note"] as? String == "drop-off changed before arrival" { continue }
                let body = (step["body"].flatMap { $0 is NSNull ? nil : $0 })
                    .map { DemoTransport.shiftDates(String(decoding: try! JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]), as: UTF8.self), by: shift) }
                _ = try await send(step["verb"] as! String, step["path"] as! String, body.map { Data($0.utf8) })
            }
        }
    }
}
