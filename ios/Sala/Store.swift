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
    /// Paging after the first `/threads` page.
    private(set) var moreThreads = Paging(next: 1)

    // More posts after the `/today` ones (`/posts?page=2`, …), appended to `today.posts`.
    private(set) var morePosts = Paging(next: 2)

    // Navigation (the Messages tab pushes and clears `pendingThreadID`)
    var selectedTab: AppTab = .today
    var pendingThreadID: String?

    // In-flight mutations
    var sickInFlight: Set<Int> = []
    var savingPosts: Set<Int> = []
    /// Bumped by every local change to `today`. Each child or post id maps to the count at its last change,
    /// so a `/today` load that started earlier keeps local state for just those ids.
    private var mutations = 0
    private var childChanges: [Int: Int] = [:]
    private var postChanges: [Int: Int] = [:]

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
        let startedAt = mutations
        let result = await Task { try await c.today() }.result
        switch result {
        case .success(var t):
            // Keep newer local state for the children and posts changed while this load was in flight.
            if let current = today {
                t.children = t.children.map { c in
                    childChanges[c.id, default: 0] > startedAt ? current.children.first { $0.id == c.id } ?? c : c
                }
                for i in t.posts.indices where postChanges[t.posts[i].id, default: 0] > startedAt {
                    if let p = current.posts.first(where: { $0.id == t.posts[i].id }) { t.posts[i].saved = p.saved }
                }
            }
            today = t
            morePosts.reset(next: 2)
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

    /// Loads the first page. `reset` (pull to refresh) drops the later pages; otherwise they stay after it,
    /// so going back from a thread or refreshing Today keeps the inbox where it was.
    func loadThreads(reset: Bool = false) async {
        guard !isLoadingThreads else { return }
        isLoadingThreads = true
        defer { isLoadingThreads = false }
        let c = client
        let result = await Task { try await c.threads() }.result
        switch result {
        case .success(let t):
            if reset || threads == nil {
                threads = t
                moreThreads.reset(next: 1)
            } else {
                let ids = Set(t.map(\.id))
                threads = t + (threads ?? []).filter { !ids.contains($0.id) }
            }
            threadsError = nil
        case .failure(let error):
            if let msg = handle(error) { threadsError = msg }
        }
    }

    /// The next `/threads` page, appended. The list calls this when its last row appears.
    func loadMoreThreads() async {
        guard threads != nil, let (page, epoch) = moreThreads.begin() else { return }
        let c = client
        let result = await Task { try await c.threads(page: page) }.result
        guard moreThreads.epoch == epoch else { return }  // refreshed meanwhile
        switch result {
        case .success(let rows):
            let ids = Set(threads?.map(\.id) ?? [])
            let new = rows.filter { !ids.contains($0.id) }
            threads?.append(contentsOf: new)
            moreThreads.finish(page: page, added: new.count)
        case .failure(let error):
            moreThreads.fail(handle(error))
        }
    }

    func retryMoreThreads() async {
        moreThreads.error = nil
        await loadMoreThreads()
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
        mutations += 1
        childChanges[child.id] = mutations
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

    private func markPost(_ id: Int) {
        mutations += 1
        postChanges[id] = mutations
    }

    func toggleSaved(_ post: Post) async {
        guard let i = today?.posts.firstIndex(where: { $0.id == post.id }), !savingPosts.contains(post.id) else { return }
        let old = post.saved
        markPost(post.id)
        today?.posts[i].saved = !old
        savingPosts.insert(post.id)
        defer { savingPosts.remove(post.id) }
        do {
            let saved = try await client.setSaved(post: post.id, !old)
            markPost(post.id)
            if let j = today?.posts.firstIndex(where: { $0.id == post.id }) { today?.posts[j].saved = saved }
        } catch {
            markPost(post.id)
            if let j = today?.posts.firstIndex(where: { $0.id == post.id }) { today?.posts[j].saved = old }
            if let msg = handle(error) { banner = "Couldn't update the bookmark. \(msg)" }
        }
    }

    /// The next `/posts` page, appended to `today.posts` so saving and the stale-load guard cover it.
    /// Today calls this when its last post appears.
    func loadMorePosts() async {
        guard today != nil, let (page, epoch) = morePosts.begin() else { return }
        let c = client
        let result = await Task { try await c.posts(page: page) }.result
        guard morePosts.epoch == epoch, today != nil else { return }  // reloaded meanwhile
        switch result {
        case .success(let rows):
            let ids = Set(today?.posts.map(\.id) ?? [])
            let new = rows.filter { !ids.contains($0.id) }
            today?.posts.append(contentsOf: new)
            morePosts.finish(page: page, added: new.count)
        case .failure(let error):
            morePosts.fail(handle(error))
        }
    }

    func retryMorePosts() async {
        morePosts.error = nil
        await loadMorePosts()
    }

    func openThread(_ id: String?) {
        pendingThreadID = id
        selectedTab = .messages
    }

    /// `sala://thread/<id>` opens a thread, `sala://today` shows and refreshes Today (links from ntfy pushes).
    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "sala" else { return }
        switch url.host()?.lowercased() {
        case "thread":
            let id = url.pathComponents.filter { $0 != "/" }.first ?? ""
            selectedTab = .messages
            // MessagesView consumes this once it's on screen (not behind the login screen or Settings).
            if !id.isEmpty { pendingThreadID = id }
        case "today":
            selectedTab = .today
            if phase != .loading { Task { await load() } }
        default:
            break
        }
    }
}

// MARK: - Paging

/// Infinite-scroll state for a list loaded page by page.
struct Paging: Equatable {
    /// The page to load next.
    private(set) var next: Int
    private(set) var isLoading = false
    /// The server sent an empty page, or one with nothing new (Aula can repeat its last page).
    private(set) var done = false
    /// Set when the last page failed; the list shows "Try again" instead of loading again by itself.
    var error: String?
    /// Bumped by `reset`, so a page that was in flight across a reload is dropped.
    private(set) var epoch = 0

    init(next: Int) { self.next = next }

    var canLoad: Bool { !isLoading && !done && error == nil }

    mutating func reset(next: Int) {
        let e = epoch + 1
        self = Paging(next: next)
        epoch = e
    }

    /// Marks a load as started; nil when one is in flight, the list ended, or the last one failed.
    mutating func begin() -> (page: Int, epoch: Int)? {
        guard canLoad else { return nil }
        isLoading = true
        return (next, epoch)
    }

    mutating func finish(page: Int, added: Int) {
        isLoading = false
        next = page + 1
        done = added == 0
    }

    /// `message` is nil when the error was routed elsewhere (login screen, Settings): then just stop for now.
    mutating func fail(_ message: String?) {
        isLoading = false
        error = message ?? "Couldn't load more."
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
