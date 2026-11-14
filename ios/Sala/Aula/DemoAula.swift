#if DEBUG
import Foundation

/// Demo mode (debug builds): a fake Aula answering from `ios/DemoAula/`, so the app runs in the
/// simulator with no login. Launch with `-demo YES`. Every route, mapping and view runs as with real
/// Aula; only the transport is fake. Writes answer success and change nothing (no state is kept).
///
/// Fixtures: one `<method>.json` per Aula `?method=`, a list of `{"when": {param: value}, "answer": <Aula's
/// whole answer>}`. The case whose `when` params all equal the request's and has the most of them wins;
/// repeated params (`ids[]`) are joined with commas. Dates are written as if today were `anchor`, and
/// every `YYYY-MM-DD` is shifted to the real today when a fixture is read.
/// `-demoOpenPhoto YES` (with `-demo YES`) starts in the photo viewer, for checking it by hand and for
/// SalaUITests. Cleared once the viewer opens, so going back stays back.
@MainActor enum DemoLaunch {
    static var openPhoto = DemoTransport.enabled && UserDefaults.standard.bool(forKey: "demoOpenPhoto")
}

final class DemoTransport: AulaTransport, @unchecked Sendable {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "demo") }
    static let anchor = Day(2026, 11, 13)!
    static let tokens = Aula.Tokens(access_token: "demo", refresh_token: nil, expires_in: nil, expiresAt: nil)

    let dir: URL
    private let lock = NSLock()
    private var _missing: [String] = []
    /// Requests no fixture answered, for the coverage test.
    var missing: [String] { lock.withLock { _missing } }

    init(dir: URL = Bundle.main.url(forResource: "DemoAula", withExtension: nil)!) { self.dir = dir }

    func cookie(named: String) -> String? { nil }
    func clearCookies() {}

    func send(_ request: URLRequest, redirectsAllowed: (@Sendable (URL?) -> Bool)?) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let reply = { (status: Int, data: Data) in (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!) }
        guard url.host == "www.aula.dk", url.path.hasPrefix("/api/") else {
            // Files (attachments, pictures): one placeholder per kind.
            if request.httpMethod ?? "GET" == "GET", Aula.fileURLAllowed(url) {
                let ext = ["pdf", "mp4"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "png"
                return reply(200, try Data(contentsOf: dir.appending(path: "_files/placeholder.\(ext)")))
            }
            lock.withLock { _missing.append("\(request.httpMethod ?? "GET") \(url)") }
            return reply(599, Data())
        }
        var params: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] where item.name != "access_token" {
            params[item.name] = params[item.name].map { "\($0),\(item.value ?? "")" } ?? item.value ?? ""
        }
        let method = params.removeValue(forKey: "method") ?? ""
        if let answer = try answer(method, params) { return reply(200, answer) }
        let line = "\(request.httpMethod ?? "GET") \(method) \(params.sorted { $0.key < $1.key })"
        lock.withLock { _missing.append(line) }
        let body = ["status": ["code": 599, "message": "no demo fixture for \(line) in ios/DemoAula/"], "data": NSNull()] as [String: Any]
        return reply(599, try JSONSerialization.data(withJSONObject: body))
    }

    private func answer(_ method: String, _ params: [String: String]) throws -> Data? {
        let file = dir.appending(path: "\(method).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let text = Self.shiftDates(try String(contentsOf: file, encoding: .utf8), by: AulaTime.today().ordinal - Self.anchor.ordinal)
        let cases = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [[String: Any]]
        let best = cases
            .filter { ($0["when"] as? [String: String] ?? [:]).allSatisfy { params[$0.key] == $0.value } }
            .max { ($0["when"] as? [String: String] ?? [:]).count < ($1["when"] as? [String: String] ?? [:]).count }
        return try best.map { try JSONSerialization.data(withJSONObject: $0["answer"] as Any) }
    }

    // ponytail: shifts the date and keeps the UTC offset, so a winter time shown in summer is an hour off.
    static func shiftDates(_ text: String, by days: Int) -> String {
        guard days != 0 else { return text }
        let regex = try! NSRegularExpression(pattern: #"(?<!\d)\d{4}-\d{2}-\d{2}(?!\d)"#)
        let out = NSMutableString(string: text)
        for m in regex.matches(in: text, range: NSRange(location: 0, length: out.length)) {
            if let day = Day.parse(out.substring(with: m.range)) { out.replaceCharacters(in: m.range, with: day.adding(days).iso) }
        }
        return out as String
    }
}
#endif
