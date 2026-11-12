import Foundation
import Security

// Compiled into both the app and the widget: settings, the token, the child shape and a `/today` fetch.

enum Shared {
    static let appGroup = "group.app.sala.ios"
    static let defaultServerURL = "http://localhost:8000"
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    private static let urlKey = "serverURL"
    private static let snapshotKey = "todaySnapshot"

    static var serverURL: String {
        let v = defaults.string(forKey: urlKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? defaultServerURL : v
    }

    static func setServerURL(_ url: String) { defaults.set(url, forKey: urlKey) }

    static var token: String { Keychain.read() ?? "" }

    /// Before the app group, the URL was in the app's own defaults: copy it over once.
    static func migrate() {
        if defaults.string(forKey: urlKey) == nil, let old = UserDefaults.standard.string(forKey: urlKey) {
            setServerURL(old)
        }
        Keychain.migrate()
    }

    // MARK: Snapshot (the last good `/today` children, for the widget to fall back on)

    static var snapshot: TodaySnapshot? {
        defaults.data(forKey: snapshotKey).flatMap { try? JSONDecoder().decode(TodaySnapshot.self, from: $0) }
    }

    /// Only the app writes it, so there's one writer.
    static func saveSnapshot(_ s: TodaySnapshot) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: snapshotKey) }
    }

    static func clearSnapshot() { defaults.removeObject(forKey: snapshotKey) }

    // MARK: Fetch

    enum FetchError: Error { case authRequired, unauthorized, failed }

    /// `GET /today`, decoding only the date and the children.
    static func fetchToday() async throws -> TodaySnapshot {
        guard let url = URL(string: serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/today") else {
            throw FetchError.failed
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 503, (try? JSONDecoder().decode([String: String?].self, from: data))?["error"] == "auth_required" {
            throw FetchError.authRequired
        }
        if status == 401 { throw FetchError.unauthorized }
        guard (200..<300).contains(status) else { throw FetchError.failed }
        var today = try JSONDecoder().decode(TodaySnapshot.self, from: data)
        today.fetchedAt = .now
        return today
    }

    // MARK: Copenhagen days

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Copenhagen") ?? .current
        return c
    }()

    /// "yyyy-MM-dd" in Copenhagen, the format of `/today`'s `date`.
    static func ymd(_ date: Date) -> String {
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }
}

struct TodaySnapshot: Codable, Sendable, Equatable {
    var date: String
    var children: [Child]
    /// When it was fetched; not part of `/today`.
    var fetchedAt: Date? = nil
}

struct Child: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var institution: String
    var group: String
    /// `present|not_arrived|sick|gone_home|vacation|unknown`, kept as a string so a new value never breaks decoding.
    var status: String
    var statusLabel: String
    var arrivedAt: String?
    var leftAt: String?
    var pickup: Pickup?
    var closesAt: String?
    var canReportSick: Bool
}

struct Pickup: Codable, Sendable, Equatable {
    var time: String?
    var by: String?
}

// MARK: - Keychain (shared through the app group as access group)

enum Keychain {
    private static let service = "app.sala.ios"
    private static let account = "token"

    /// Every query names the group: one without it matches the items of every group the process can see.
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: Shared.appGroup]
    }

    static func read() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s != errSecSuccess, s != errSecItemNotFound { print("Keychain read failed: \(s)") }
        guard s == errSecSuccess, let data = out as? Data else { return nil }
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

    /// Moves the token stored before the app group (in the app's default access group) into the shared group.
    static func migrate() {
        guard read() == nil else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let item = out as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let oldGroup = item[kSecAttrAccessGroup as String] as? String,
              oldGroup != Shared.appGroup,
              let token = String(data: data, encoding: .utf8),
              write(token) else { return }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account,
                       kSecAttrAccessGroup as String: oldGroup] as CFDictionary)
        print("Keychain: moved the token from \(oldGroup) to \(Shared.appGroup)")
    }
}
