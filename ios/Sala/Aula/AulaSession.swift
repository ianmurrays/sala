import CryptoKit
import Foundation

/// The phone's own Aula session: OAuth tokens in the Keychain, Aula's session cookies in memory, and
/// every Aula API call. Port of the aula library's auth_flow + api_client plumbing and Sala's
/// SessionManager (server/sala/aula_session.py), so the rules carry over:
///
/// - MitID only ever starts from the login screen (`LoginWebView`), never from here, and never retries.
/// - A session is opened by calling Aula with `access_token` (profiles.getProfilesByLogin, then
///   getProfileContext as guardian), which sets the cookies; later calls use the cookies only.
/// - On HTTP 401 or sub-code 9/23 the refresh token is used once (single flight), the session is
///   opened again and the call retried.
/// - Any other refusal (401/403 after that) gets one profile probe. Only a refused probe means the
///   session is gone (-> `.authRequired`); a refused call with a working probe (step-up for a
///   sensitive thread, say) is just that call failing.
///
/// Raw Aula JSON (`[String: Any]`) never leaves this actor: mapping code lives in extensions of it
/// and hands out `Data` in API.md's shapes.
actor Aula {
    #if DEBUG
    static let shared = DemoTransport.enabled ? Aula(transport: DemoTransport(), tokens: DemoTransport.tokens) : Aula()
    #else
    static let shared = Aula()
    #endif

    // OAuth (aula/const.py)
    static let authBase = "https://login.aula.dk/simplesaml/module.php/oidc"
    static let clientID = "_99949a54b8b65423862aac1bf629599ed64231607a"
    static let redirectHost = "app-private.aula.dk"
    static let redirectURI = "https://app-private.aula.dk"
    static let apiPrefix = "https://www.aula.dk/api/v"
    private static let tokensKey = "aula.tokens"

    struct Tokens: Codable, Sendable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double?
        /// When `access_token` stops working (with a minute's margin, like the library).
        var expiresAt: Date?
    }

    enum Failure: Error {
        /// No usable session: show the login screen.
        case authRequired
        /// Aula answered, but not with success. `status` is the HTTP status.
        case rejected(status: Int, code: Int?, subCode: Int?, method: String?)
        case transport(String)
    }

    let transport: AulaTransport
    private(set) var apiVersion = 25
    private var tokens: Tokens?
    /// True once the cookies are set for the current tokens.
    private var open = false
    private var csrf: String?
    /// The two raw answers that open the session, kept for the profile (mapping reads them).
    private(set) var profilesByLogin: [String: Any]?
    private(set) var profileContext: [String: Any]?
    private var refreshTask: Task<Bool, Never>?
    private var openTask: Task<Void, Error>?
    /// Bumped each time a new session is opened; a call that saw an older one just retries.
    /// Readable so the routes can key their per-session profile on it.
    private(set) var generation = 0
    /// The routes' state (AulaMapping.swift): attachment ids, listed thread rows, the profile.
    var local = AulaLocalState()

    init(transport: AulaTransport = URLSessionTransport(), tokens: Tokens? = Aula.storedTokens) {
        self.transport = transport
        self.tokens = tokens
    }

    var apiURL: String { "\(Self.apiPrefix)\(apiVersion)/" }
    var hasTokens: Bool { tokens != nil }

    static var storedTokens: Tokens? {
        Keychain.data(tokensKey).flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
    }

    // MARK: Login (the web view hands over the redirect)

    static func randomURLSafe() -> String {
        b64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    }

    static func authorizeURL(verifier: String, state: String) -> URL {
        var c = URLComponents(string: "\(authBase)/authorize.php")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "scope", value: "aula-sensitive"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: b64url(Data(SHA256.hash(data: Data(verifier.utf8))))),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        return c.url!
    }

    /// Step 7 of the library's flow: the redirect's code for tokens, then a fresh session.
    func completeLogin(redirect: URL, verifier: String, state: String) async throws {
        let q = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = q.first(where: { $0.name == "code" })?.value else {
            throw Failure.transport(q.first(where: { $0.name == "error_description" })?.value ?? "Aula sent no login code")
        }
        guard q.first(where: { $0.name == "state" })?.value == state else { throw Failure.transport("Login state mismatch") }
        let t = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI, "code_verifier": verifier,
        ])
        save(t)
        try await openSession()
    }

    func logout() {
        #if DEBUG
        if transport is DemoTransport { tokens = DemoTransport.tokens; open = false; return }  // never touch the real login
        #endif
        tokens = nil
        open = false
        csrf = nil
        profilesByLogin = nil
        profileContext = nil
        // The attachment register holds the old account's signed file URLs; pictures are its people.
        local = AulaLocalState()
        local.attachmentsLoaded = true
        for dir in ["aula-attachments.json", "pictures"] { try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: dir)) }
        Keychain.delete(Self.tokensKey)
        transport.clearCookies()
        #if DEBUG
        TrafficLog.clear()
        #endif
    }

    private func save(_ t: Tokens?) {
        #if DEBUG
        if transport is DemoTransport { tokens = DemoTransport.tokens; open = false; return }  // never touch the real login
        #endif
        tokens = t
        open = false
        if let t, let d = try? JSONEncoder().encode(t) { Keychain.write(d, Self.tokensKey) }
        if t == nil { Keychain.delete(Self.tokensKey) }
    }

    #if DEBUG
    /// Makes the next call go through the refresh grant and open a new session, as a cold launch
    /// more than an hour after login does.
    func debugExpireSession() {
        tokens?.expiresAt = .distantPast
        open = false
    }
    #endif

    private func tokenRequest(_ form: [String: String]) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "\(Self.authBase)/token.php")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Self.formEncode(form.sorted { $0.key < $1.key }).data(using: .utf8)
        let (data, resp) = try await transport.send(req)
        guard resp.statusCode == 200 else { throw Failure.rejected(status: resp.statusCode, code: nil, subCode: nil, method: "token") }
        var t = try JSONDecoder().decode(Tokens.self, from: data)
        if t.refresh_token == nil { t.refresh_token = tokens?.refresh_token }
        t.expiresAt = t.expires_in.map { Date() + $0 - 60 }
        return t
    }

    /// The refresh grant, once for all callers waiting on it. False: the tokens are gone.
    private func refresh() async -> Bool {
        if let refreshTask { return await refreshTask.value }
        let task = Task<Bool, Never> {
            guard let rt = tokens?.refresh_token else { return false }
            do {
                save(try await tokenRequest(["grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": rt]))
                return true
            } catch let Failure.rejected(status, _, _, _) where (400..<500).contains(status) {
                return false  // Aula refused the refresh token: the session is over
            } catch {
                return true  // offline, 5xx, odd answer: keep the tokens, the next call tries again
            }
        }
        refreshTask = task
        let ok = await task.value
        refreshTask = nil
        return ok
    }

    /// api_client.init: opens the cookie session with the access token.
    private func openSession() async throws {
        guard var t = tokens else { throw Failure.authRequired }
        if let exp = t.expiresAt, exp < Date() {
            guard await refresh(), let fresh = tokens else { save(nil); throw Failure.authRequired }
            t = fresh
        }
        let token = [("access_token", t.access_token)]
        transport.clearCookies()
        profilesByLogin = try await raw("GET", "profiles.getProfilesByLogin", token, retry: false)
        profileContext = try await raw(
            "GET", "profiles.getProfileContext", [("portalrole", "guardian"), ("deviceId", "sala-ios")] + token, retry: false)
        csrf = transport.cookie(named: "Csrfp-Token")
        open = true
        generation += 1
    }

    // MARK: API calls

    /// GET `?method=<method>&params…`; the whole answer (status + data), after Aula's envelope is checked.
    func get(_ method: String, _ params: [(String, String)] = []) async throws -> [String: Any] {
        try await call("GET", method, params, body: nil)
    }

    /// POST `?method=<method>` with a JSON body.
    func post(_ method: String, _ body: Any, _ params: [(String, String)] = []) async throws -> [String: Any] {
        try await call("POST", method, params, body: try JSONSerialization.data(withJSONObject: body))
    }

    private func call(_ verb: String, _ method: String, _ params: [(String, String)], body: Data?) async throws -> [String: Any] {
        if !open { try await openOrLose() }
        let seen = generation
        do {
            return try await raw(verb, method, params, body: body, retry: true)
        } catch Failure.authRequired {
            throw Failure.authRequired
        } catch let Failure.rejected(status, code, sub, m) where status == 401 || status == 403 {
            // Refused after the refresh: is the session itself gone? (aula_session.py probe rule)
            if seen != generation { return try await raw(verb, method, params, body: body, retry: false) }
            do {
                _ = try await raw("GET", "profiles.getProfilesByLogin", [], retry: false)
            } catch let Failure.rejected(s, _, _, _) where s == 401 || s == 403 {
                save(nil)
                throw Failure.authRequired
            }
            throw Failure.rejected(status: status, code: code, subCode: sub, method: m)
        }
    }

    /// Opens the session if it isn't open, so `profilesByLogin` / `profileContext` are current.
    func ensureOpen() async throws {
        if !open { try await openOrLose() }
    }

    /// One open at a time: a second caller waits for the first instead of clearing its cookies.
    private func openOrLose() async throws {
        if let openTask { return try await openTask.value }
        let task = Task { try await openOrLoseOnce() }
        openTask = task
        defer { openTask = nil }
        try await task.value
    }

    private func openOrLoseOnce() async throws {
        do { try await openSession() } catch let Failure.rejected(s, _, _, _) where s == 401 || s == 403 {
            // The access token was refused while opening: one refresh, then give up.
            guard await refresh() else { save(nil); throw Failure.authRequired }
            do { try await openSession() } catch let Failure.rejected(s, _, _, _) where s == 401 || s == 403 {
                save(nil)
                throw Failure.authRequired
            }
        }
    }

    private func raw(_ verb: String, _ method: String, _ params: [(String, String)], body: Data? = nil, retry: Bool) async throws -> [String: Any] {
        for _ in 0..<5 {  // 410 Gone: the API version moved on (api_client._do_request)
            var c = URLComponents(string: apiURL)!
            c.percentEncodedQuery = Self.formEncode([("method", method)] + params)
            var req = URLRequest(url: c.url!)
            req.httpMethod = verb
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let csrf = transport.cookie(named: "Csrfp-Token") ?? csrf { req.setValue(csrf, forHTTPHeaderField: "csrfp-token") }
            }
            let (data, resp) = try await transport.send(req)
            #if DEBUG
            TrafficLog.record(verb, method, params, body: body, status: resp.statusCode, response: data)
            #endif
            if resp.statusCode == 410 { apiVersion += 1; continue }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let status = json?["status"] as? [String: Any]
            let code = (status?["code"] as? NSNumber)?.intValue
            let sub = (status?["subCode"] as? NSNumber)?.intValue
            if retry, resp.statusCode == 401 || sub == 9 || sub == 23 {
                let seen = generation
                if await refresh() {
                    if seen == generation { try await openOrLose() }
                    return try await raw(verb, method, params, body: body, retry: false)
                }
                save(nil)
                throw Failure.authRequired
            }
            if sub == 9 || sub == 23 { throw Failure.rejected(status: 401, code: code, subCode: sub, method: method) }
            if sub == 7 || sub == 8 { throw Failure.rejected(status: 403, code: code, subCode: sub, method: method) }
            guard (200..<300).contains(resp.statusCode), let json else {
                throw Failure.rejected(status: resp.statusCode, code: code, subCode: sub, method: method)
            }
            if let code, code != 0 { throw Failure.rejected(status: resp.statusCode, code: code, subCode: sub, method: method) }
            return json
        }
        throw Failure.rejected(status: 410, code: nil, subCode: nil, method: method)
    }

    /// An Aula file (attachment or picture), with the session cookies. Only https on `*.aula.dk`,
    /// and every redirect hop is checked too (mapping.download_attachment).
    func download(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        guard Self.fileURLAllowed(url) else { throw Failure.transport("attachment is not on an Aula file host") }
        if !open { try await openOrLose() }
        let (data, resp) = try await transport.send(URLRequest(url: url), redirectsAllowed: Self.fileURLAllowed)
        guard (200..<300).contains(resp.statusCode) else { throw Failure.rejected(status: resp.statusCode, code: nil, subCode: nil, method: nil) }
        return (data, resp)
    }

    // MARK: helpers

    static func fileURLAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "aula.dk" || host.hasSuffix(".aula.dk")
    }

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// `application/x-www-form-urlencoded`, with `+`, `&`, `=` and the rest escaped (URLComponents leaves `+`).
    static func formEncode(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
    }
}

/// How Aula is reached: the network, or recorded answers in tests.
protocol AulaTransport: Sendable {
    func send(_ request: URLRequest, redirectsAllowed: (@Sendable (URL?) -> Bool)?) async throws -> (Data, HTTPURLResponse)
    func cookie(named: String) -> String?
    func clearCookies()
}

extension AulaTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await send(request, redirectsAllowed: nil) }
}

final class URLSessionTransport: AulaTransport, @unchecked Sendable {
    private let session: URLSession
    private let cookies: HTTPCookieStorage

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpCookieAcceptPolicy = .always
        cookies = config.httpCookieStorage ?? HTTPCookieStorage()
        session = URLSession(configuration: config)
    }

    func send(_ request: URLRequest, redirectsAllowed: (@Sendable (URL?) -> Bool)?) async throws -> (Data, HTTPURLResponse) {
        var retried = false
        while true {
            do {
                let (data, resp) = try await session.data(for: request, delegate: redirectsAllowed.map(RedirectGuard.init))
                guard let http = resp as? HTTPURLResponse else { throw Aula.Failure.transport("No HTTP response") }
                return (data, http)
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch let e as URLError {
                // Returning to the foreground, the network is often not back yet: one retry a second later.
                guard !retried, Self.shouldRetry(e.code, method: request.httpMethod) else {
                    throw Aula.Failure.transport(e.localizedDescription)
                }
                retried = true
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Whether a request that failed with `code` is worth one more try. Never `.timedOut` (another 30 s).
    /// Writes only when the request can't have reached Aula, so a sick report or token refresh never runs twice.
    static func shouldRetry(_ code: URLError.Code, method: String?) -> Bool {
        switch code {
        case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost: true
        case .networkConnectionLost: (method ?? "GET") == "GET"
        default: false
        }
    }

    func cookie(named name: String) -> String? {
        cookies.cookies?.first { $0.name == name && $0.domain.hasSuffix("aula.dk") }?.value
    }

    func clearCookies() { cookies.cookies?.forEach(cookies.deleteCookie) }
}

/// Follows a redirect only when `allowed` says so; otherwise the request fails.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let allowed: @Sendable (URL?) -> Bool
    init(_ allowed: @escaping @Sendable (URL?) -> Bool) { self.allowed = allowed }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        // nil: the 3xx itself comes back as the answer, which the caller treats as a failure.
        allowed(request.url) ? request : nil
    }
}

#if DEBUG
/// Settings → Debug → "Capture Aula traffic": every Aula API call and its answer, one JSON line each,
/// in `Caches/aula-traffic.jsonl`. `scripts/pull-aula-traffic.sh` copies it to the Mac. It holds
/// real children's data, so it never goes into git; `docs/aula-shapes/` keeps only their structure and types.
/// The access token is left out (cookies and the CSRF header are never part of a line).
enum TrafficLog {
    static let file = URL.cachesDirectory.appending(path: "aula-traffic.jsonl")
    private static let key = "aula.captureTraffic"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func clear() { try? FileManager.default.removeItem(at: file) }

    static func record(_ verb: String, _ method: String, _ params: [(String, String)], body: Data?, status: Int, response: Data) {
        guard enabled else { return }
        var line: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "verb": verb,
            "method": method,
            "params": params.filter { $0.0 != "access_token" }.map { [$0.0, $0.1] },
            "status": status,
        ]
        line["body"] = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        line["response"] = (try? JSONSerialization.jsonObject(with: response)) ?? String(decoding: response.prefix(2000), as: UTF8.self)
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}
#endif
