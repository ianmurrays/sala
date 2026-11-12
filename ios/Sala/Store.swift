import Foundation
import Observation
import Security

enum AppTab: Hashable { case today, messages }

@MainActor @Observable
final class Store {
    enum Phase: Equatable {
        case loading
        case ready
        /// The server needs a MitID login (503 auth_required).
        case needsLogin
        /// 401: the bearer token is wrong or missing.
        case unauthorized
        /// No data and the last load failed (connection refused, 502, …).
        case failed(String)
    }

    // Config
    private(set) var serverURL: String
    private(set) var token: String

    // State
    var phase: Phase = .loading
    var today: Today?
    /// Transient, non-fatal error shown as a banner on Today (failed save, sick report, …).
    var banner: String?
    var isRefreshing = false
    var showSettings = false

    // Auth
    var auth: AuthStatus?
    var authError: String?

    // Messages
    var threads: [ThreadSummary]?
    /// Set when the last `/threads` load failed; shown inline in the inbox.
    var threadsError: String?
    private(set) var isLoadingThreads = false
    var unreadThreadCount: Int { threads?.filter(\.unread).count ?? 0 }

    // Navigation (the Messages tab pushes and clears `pendingThreadID`)
    var selectedTab: AppTab = .today
    var pendingThreadID: String?

    // In-flight mutations
    var sickInFlight: Set<Int> = []
    var savingPosts: Set<Int> = []

    nonisolated static let defaultServerURL = "http://localhost:8000"

    init() {
        let overrideToken = Config.applyLaunchOverrides()
        serverURL = Config.serverURL
        // Keep a launch-argument token in memory too, in case the Keychain write failed.
        token = overrideToken ?? Config.token
        if token.isEmpty { showSettings = true }
    }

    var client: APIClient { APIClient(baseURL: serverURL, token: token) }

    func updateConfig(serverURL: String, token: String) {
        let url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.save(serverURL: url, token: tok)
        self.serverURL = url.isEmpty ? Self.defaultServerURL : url
        self.token = tok
        Task { await load() }
    }

    // MARK: Loading

    func load() async {
        let previous = phase
        // Keep the login screen up until /today succeeds (switching away would cancel its tasks).
        if today == nil, phase != .needsLogin { phase = .loading }
        isRefreshing = true
        defer { isRefreshing = false }
        // Unstructured so a view-bound caller (login poll, .refreshable) going away can't cancel it.
        let c = client
        let result = await Task { try await c.today() }.result
        switch result {
        case .success(let t):
            today = t
            phase = .ready
            // Keeps the Messages tab badge current without holding up Today.
            Task { await loadThreads() }
        case .failure(let error as CancellationError):
            _ = error
            if phase == .loading { phase = previous == .loading ? .failed("The request was cancelled.") : previous }
        case .failure(let error):
            handle(error, fatalIfNoData: true)
        }
    }

    /// Routes an error to the right screen. Returns the message for inline display when it isn't routed.
    @discardableResult
    func handle(_ error: Error, fatalIfNoData: Bool = false) -> String? {
        switch error {
        case is CancellationError:
            return nil
        case APIError.authRequired:
            if phase != .needsLogin { auth = nil }
            phase = .needsLogin
            Task { await refreshAuthStatus() }
            return nil
        case APIError.unauthorized:
            phase = .unauthorized
            showSettings = true
            return nil
        default:
            let msg = error.localizedDescription
            if fatalIfNoData {
                if today == nil { phase = .failed(msg) } else { banner = msg }
            }
            return msg
        }
    }

    // MARK: Messages

    func loadThreads() async {
        guard !isLoadingThreads else { return }
        isLoadingThreads = true
        defer { isLoadingThreads = false }
        let c = client
        let result = await Task { try await c.threads() }.result
        switch result {
        case .success(let t):
            threads = t
            threadsError = nil
        case .failure(let error):
            if let msg = handle(error) { threadsError = msg }
        }
    }

    /// The server marks a thread read when it's fetched; mirror that locally.
    func markThreadRead(_ id: String) {
        guard let i = threads?.firstIndex(where: { $0.id == id }), threads?[i].unread == true else { return }
        threads?[i].unread = false
    }

    // MARK: Auth

    func refreshAuthStatus() async {
        do {
            let s = try await client.authStatus()
            let wasOK = auth?.state == "ok"
            auth = s
            authError = nil
            // Only reload on the transition to ok, so a server that says ok but still answers 503 can't loop.
            if s.state == "ok", !wasOK, phase == .needsLogin { await load() }
        } catch is CancellationError {
        } catch APIError.unauthorized {
            handle(APIError.unauthorized)
        } catch {
            authError = error.localizedDescription
        }
    }

    func startLogin() async {
        authError = nil
        do {
            auth = try await client.login()
        } catch is CancellationError {
        } catch APIError.unauthorized {
            handle(APIError.unauthorized)
        } catch {
            authError = error.localizedDescription
        }
    }

    // MARK: Mutations

    private func replace(_ child: Child) {
        guard let i = today?.children.firstIndex(where: { $0.id == child.id }) else { return }
        today?.children[i] = child
    }

    func toggleSick(_ child: Child) async {
        guard !sickInFlight.contains(child.id) else { return }
        sickInFlight.insert(child.id)
        defer { sickInFlight.remove(child.id) }
        do {
            let updated = child.status == "sick"
                ? try await client.undoSick(child: child.id)
                : try await client.reportSick(child: child.id)
            replace(updated)
        } catch {
            if let msg = handle(error) { banner = msg }
        }
    }

    func savePickup(child: Int, _ update: PickupUpdate) async throws {
        do {
            let updated = try await client.setPickup(child: child, update)
            replace(updated)
        } catch {
            if case APIError.authRequired = error { handle(error) }
            if case APIError.unauthorized = error { handle(error) }
            throw error
        }
    }

    func toggleSaved(_ post: Post) async {
        guard let i = today?.posts.firstIndex(where: { $0.id == post.id }), !savingPosts.contains(post.id) else { return }
        let old = post.saved
        today?.posts[i].saved = !old
        savingPosts.insert(post.id)
        defer { savingPosts.remove(post.id) }
        do {
            let saved = try await client.setSaved(post: post.id, !old)
            if let j = today?.posts.firstIndex(where: { $0.id == post.id }) { today?.posts[j].saved = saved }
        } catch {
            if let j = today?.posts.firstIndex(where: { $0.id == post.id }) { today?.posts[j].saved = old }
            if let msg = handle(error) { banner = "Couldn't update the bookmark. \(msg)" }
        }
    }

    func openThread(_ id: String?) {
        pendingThreadID = id
        selectedTab = .messages
    }
}

// MARK: - Config (UserDefaults + Keychain + launch overrides)

enum Config {
    private static let urlKey = "serverURL"

    static var serverURL: String {
        let v = UserDefaults.standard.string(forKey: urlKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? Store.defaultServerURL : v
    }

    static var token: String { Keychain.read() ?? "" }

    static func save(serverURL: String, token: String) {
        UserDefaults.standard.set(serverURL, forKey: urlKey)
        if token.isEmpty { Keychain.delete() } else { Keychain.write(token) }
    }

    /// `-serverURL <url> -token <token>` launch arguments, or `SALA_SERVER_URL` / `SALA_TOKEN`
    /// environment variables, override and persist the settings.
    @discardableResult
    static func applyLaunchOverrides() -> String? {
        let info = ProcessInfo.processInfo
        func arg(_ name: String) -> String? {
            let a = info.arguments
            guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
            return a[i + 1]
        }
        if let url = arg("-serverURL") ?? info.environment["SALA_SERVER_URL"], !url.isEmpty {
            // Write to the persistent domain (the argument domain is volatile).
            UserDefaults.standard.set(url, forKey: urlKey)
        }
        if let tok = arg("-token") ?? info.environment["SALA_TOKEN"], !tok.isEmpty {
            Keychain.write(tok)
            return tok
        }
        return nil
    }
}

enum Keychain {
    private static let service = "app.sala.ios"
    private static let account = "token"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let s = SecItemAdd(add as CFDictionary, nil)
        if s != errSecSuccess { print("Keychain write failed: \(s)") }
        return s == errSecSuccess
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}
