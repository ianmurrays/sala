import Foundation
import Security

// Compiled into both the app and the widget: settings, the token, the child shape and a `/today` fetch.

enum Shared {
    static let defaultServerURL = "http://localhost:8000"

    private static let urlKey = "serverURL"
    private static let snapshotKey = "todaySnapshot"

    static var serverURL: String {
        let v = Keychain.string(urlKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? defaultServerURL : v
    }

    static func setServerURL(_ url: String) { Keychain.write(Data(url.utf8), urlKey) }

    static var token: String { Keychain.read() ?? "" }

    // MARK: Snapshot (the last good `/today` children, for the widget to fall back on)

    static var snapshot: TodaySnapshot? {
        Keychain.data(snapshotKey).flatMap { try? JSONDecoder().decode(TodaySnapshot.self, from: $0) }
    }

    /// Only the app writes it, so there's one writer.
    static func saveSnapshot(_ s: TodaySnapshot) {
        if let data = try? JSONEncoder().encode(s) { Keychain.write(data, snapshotKey) }
    }

    static func clearSnapshot() { Keychain.delete(snapshotKey) }

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

// MARK: - Keychain (shared by the app and the widget through a keychain access group)

/// Holds the token, the server URL and the snapshot. A keychain access group instead of an app group,
/// because a personal (free) team can't register app groups.
enum Keychain {
    private static let service = "com.example.sala"
    private static let tokenKey = "token"
    /// `$(AppIdentifierPrefix)com.example.sala`, from Info.plist, since the prefix is the signing team's ID.
    private static let group = Bundle.main.object(forInfoDictionaryKey: "SalaKeychainGroup") as? String ?? ""

    /// Every query names the group: one without it matches the items of every group the process can see.
    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: group]
    }

    static func data(_ account: String) -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s != errSecSuccess, s != errSecItemNotFound { print("Keychain read failed: \(s)") }
        return s == errSecSuccess ? out as? Data : nil
    }

    static func string(_ account: String) -> String? { data(account).flatMap { String(data: $0, encoding: .utf8) } }

    @discardableResult
    static func write(_ data: Data, _ account: String) -> Bool {
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let s = SecItemAdd(add as CFDictionary, nil)
        if s != errSecSuccess { print("Keychain write failed: \(s)") }
        return s == errSecSuccess
    }

    static func delete(_ account: String) { SecItemDelete(base(account) as CFDictionary) }

    // The token.
    static func read() -> String? { string(tokenKey) }
    @discardableResult static func write(_ token: String) -> Bool { write(Data(token.utf8), tokenKey) }
    static func delete() { delete(tokenKey) }
}
