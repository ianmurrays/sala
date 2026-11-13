import Foundation

// MARK: - Models (see API.md at the repo root)

struct Today: Codable, Sendable, Equatable {
    var date: String
    var children: [Child]
    var attention: [AttentionItem]
    var upcoming: [UpcomingItem]
    var posts: [Post]
}

struct AttentionItem: Codable, Sendable, Equatable, Identifiable {
    var id: String
    /// `holiday_request|message`
    var kind: String
    var title: String
    var subtitle: String?
    var urgent: Bool
    var threadId: String?

    enum CodingKeys: String, CodingKey { case id, kind, title, subtitle, urgent, threadId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLenientString(.id) ?? ""
        kind = try c.decode(String.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        urgent = try c.decodeIfPresent(Bool.self, forKey: .urgent) ?? false
        threadId = try c.decodeLenientString(.threadId)
    }

    init(id: String, kind: String, title: String, subtitle: String?, urgent: Bool, threadId: String?) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle; self.urgent = urgent; self.threadId = threadId
    }
}

struct UpcomingItem: Codable, Sendable, Equatable, Identifiable {
    var date: String
    var title: String
    var subtitle: String?
    var id: String { date + "|" + title }

    enum CodingKeys: String, CodingKey { case date, title, subtitle }
}

struct Post: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var title: String
    var author: String
    /// Id for `GET /attachments/{id}`; nil when the author has no picture.
    var authorPicture: String?
    /// ISO 8601 timestamp with offset.
    var date: String
    var body: String
    var important: Bool
    var saved: Bool
    var attachments: [Attachment]
}

struct Album: Decodable, Sendable, Hashable, Identifiable {
    var id: Int
    var title: String
    /// ISO 8601 timestamp, nil when Aula has none.
    var date: String?
    /// Id for `GET /attachments/{id}`, nil when the album has no cover.
    var cover: String?
    /// Aula's album of photos the child is tagged in (id 0).
    var tagged: Bool
}

/// One item of `GET /calendar` (API.md "Calendar").
struct CalendarEvent: Decodable, Sendable, Hashable, Identifiable {
    enum Kind: String, Decodable, Sendable { case absence, meeting, birthday, event }
    var id: String
    var kind: Kind
    var title: String
    var subtitle: String?
    /// `YYYY-MM-DD`, `endDate` inclusive.
    var startDate: String
    var endDate: String
    /// `HH:mm` in Copenhagen; both nil for an all-day item.
    var startTime: String?
    var endTime: String?

    var allDay: Bool { startTime == nil }
    func covers(_ ymd: String) -> Bool { startDate <= ymd && ymd <= endDate }
}

/// A row of `GET /contacts/groups`: one of a child's groups (API.md "Contacts").
struct ContactGroup: Decodable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var child: String
}

/// `GET /contacts/groups/{id}`. Other families' data: keep it in view state only, never cache or log it.
struct GroupContacts: Decodable, Sendable {
    struct Child: Decodable, Sendable, Identifiable {
        var id: Int
        var name: String
        var guardians: [Contact]
    }
    var children: [Child]
    var staff: [Contact]
}

/// No id: Aula may not give guardians one.
struct Contact: Decodable, Sendable, Hashable {
    struct Phone: Decodable, Sendable, Hashable {
        var label: String
        var number: String
    }
    var name: String
    var relation: String?
    /// False when the person doesn't let Aula show you their details.
    var shared: Bool
    var phones: [Phone]
    var email: String?
    var address: String?
}

struct Photo: Decodable, Sendable, Equatable, Identifiable {
    var id: Int
    /// Ids for `GET /attachments/{id}`: a small size for the grid, the original for the viewer and saving.
    var thumbnail: String
    var image: String
    /// Upload time, ISO 8601.
    var date: String?
}

/// `GET /search` (API.md "Search"): hit counts per type, and one page of the asked type.
struct SearchResults: Decodable, Sendable {
    struct Counts: Decodable, Sendable, Equatable {
        var messages: Int
        var posts: Int
        var photos: Int
    }
    var counts: Counts
    var messages: [SearchMessage]
    var posts: [Post]
    var photos: [Photo]
}

struct SearchMessage: Decodable, Sendable, Equatable, Identifiable {
    var id: String
    var threadId: String
    var subject: String
    var from: String
    var preview: String
    /// ISO 8601 timestamp with offset.
    var date: String
}

struct Attachment: Codable, Sendable, Equatable {
    /// Server id for `GET /attachments/{id}`; absent for links.
    var id: String?
    var name: String
    /// `file|image|link`
    var kind: String
    /// Set for `link` attachments, which open in the browser instead of being downloaded.
    var url: String?

    var isLink: Bool { kind == "link" }
    var linkURL: URL? { url.flatMap(URL.init(string:)) }

    enum CodingKeys: String, CodingKey { case id, name, kind, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLenientString(.id)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "file"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? url ?? "Attachment"
    }

    init(id: String?, name: String, kind: String, url: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.url = url
    }
}

struct PickupOptions: Codable, Sendable, Equatable {
    var date: String
    var opensAt: String?
    var closesAt: String?
    var times: [String]
    var people: [String]
    var current: Pickup?
    var note: String?
}

struct PickupUpdate: Codable, Sendable {
    var time: String
    var by: String
    var note: String
}

struct SavedResponse: Codable, Sendable { var saved: Bool }

/// A row of `GET /threads`.
struct ThreadSummary: Decodable, Sendable, Equatable, Identifiable {
    var id: String
    var subject: String
    var from: String
    /// The `from` person's picture, an id for `GET /attachments/{id}`.
    var picture: String?
    var participants: Int
    var preview: String
    /// ISO 8601 timestamp with offset.
    var date: String
    var unread: Bool
    var muted: Bool
    var starred: Bool
    /// The folder it's in; nil in the inbox.
    var folderId: Int?

    enum CodingKeys: String, CodingKey { case id, subject, from, picture, participants, preview, date, unread, muted, starred, folderId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLenientString(.id) ?? ""
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        picture = try c.decodeIfPresent(String.self, forKey: .picture)
        participants = try c.decodeIfPresent(Int.self, forKey: .participants) ?? 0
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        folderId = try c.decodeIfPresent(Int.self, forKey: .folderId)
    }
}

/// `PATCH /threads/{id}`: only the fields that are set are sent.
struct ThreadPatch: Encodable, Sendable {
    var muted: Bool?
    var starred: Bool?
    /// `.some(nil)` moves the thread back to the inbox (sent as `null`).
    var folderId: Int??

    enum CodingKeys: String, CodingKey { case muted, starred, folderId }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(muted, forKey: .muted)
        try c.encodeIfPresent(starred, forKey: .starred)
        if let folderId { try c.encode(folderId, forKey: .folderId) }
    }
}

/// A row of `GET /folders`.
struct Folder: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: Int
    var name: String
}

struct FolderNameRequest: Encodable, Sendable { var name: String }

/// `GET /threads/{id}`. Messages come oldest first.
struct MessageThread: Decodable, Sendable, Equatable {
    var id: String
    var subject: String
    var canReply: Bool
    var messages: [Message]

    enum CodingKeys: String, CodingKey { case id, subject, canReply, messages }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLenientString(.id) ?? ""
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        canReply = try c.decodeIfPresent(Bool.self, forKey: .canReply) ?? false
        messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
    }
}

struct Message: Decodable, Sendable, Equatable, Identifiable {
    var id: String
    var sender: String
    /// The sender's picture, an id for `GET /attachments/{id}`.
    var picture: String?
    var fromMe: Bool
    /// ISO 8601 timestamp with offset.
    var date: String
    var text: String
    var attachments: [Attachment]

    enum CodingKeys: String, CodingKey { case id, sender, picture, fromMe, date, text, attachments }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLenientString(.id) ?? ""
        sender = try c.decodeIfPresent(String.self, forKey: .sender) ?? ""
        picture = try c.decodeIfPresent(String.self, forKey: .picture)
        fromMe = try c.decodeIfPresent(Bool.self, forKey: .fromMe) ?? false
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
    }

    init(id: String, sender: String, fromMe: Bool, date: String, text: String, attachments: [Attachment] = []) {
        self.id = id; self.sender = sender; self.fromMe = fromMe; self.date = date; self.text = text; self.attachments = attachments
    }
}

enum ReplyAudience: String, Codable, Sendable { case everyone, sender }

struct ReplyRequest: Encodable, Sendable {
    var text: String
    var audience: ReplyAudience
    /// Required for `sender`: the message whose sender gets the new thread.
    var messageId: String?
}

struct ReplyResponse: Decodable, Sendable {
    /// The new thread for `sender`; may be null.
    var threadId: String?

    enum CodingKeys: String, CodingKey { case threadId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try c.decodeLenientString(.threadId)
    }
}

/// `GET /holiday-requests/{id}`.
struct HolidayRequest: Decodable, Sendable, Equatable {
    var id: String
    var title: String
    var note: String?
    var deadline: String?
    var startDate: String?
    var endDate: String?
    /// The institution wants drop-off and pickup times for days the child comes.
    var timesRequired: Bool
    var answered: Bool
    /// False once the deadline has passed.
    var editable: Bool
    var children: [HolidayChild]
}

struct HolidayChild: Decodable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var answered: Bool
    var comment: String
    var days: [HolidayDay]
}

struct HolidayDay: Decodable, Sendable, Equatable {
    var date: String
    /// nil = not answered yet.
    var coming: Bool?
    var entryTime: String?
    var exitTime: String?
    /// Today, past and closed days can't be answered and aren't sent.
    var editable: Bool
}

struct HolidayAnswer: Encodable, Sendable {
    struct Child: Encodable, Sendable { var id: Int; var comment: String; var days: [Day] }
    struct Day: Encodable, Sendable { var date: String; var coming: Bool; var entryTime: String?; var exitTime: String? }
    var children: [Child]
}

struct AbsenceRequest: Encodable, Sendable {
    var childIds: [Int]
    var startDate: String
    var endDate: String
    var comment: String
}

struct OkResponse: Decodable, Sendable { var ok: Bool }

extension KeyedDecodingContainer {
    /// Accepts a JSON string or number (ids whose type the contract doesn't pin down), or null.
    func decodeLenientString(_ key: Key) throws -> String? {
        if (try? decodeNil(forKey: key)) ?? true { return nil }
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        throw DecodingError.typeMismatch(String.self, .init(codingPath: codingPath + [key], debugDescription: "Expected string or number"))
    }
}

// MARK: - Errors

enum APIError: LocalizedError, Sendable {
    case authRequired
    case upstream(String?)
    case http(Int, String?)
    case notFound
    /// 409: the change isn't allowed right now (for example a pickup on an absence day).
    case conflict(String?)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .authRequired: "Log in with MitID to continue."
        case .upstream(let m): "Aula didn't answer properly" + (m.map { ": \($0)" } ?? ".")
        case .http(let code, let m): m ?? "Aula answered with HTTP \(code)."
        case .notFound: "Not found in Aula. It may have been deleted."
        case .conflict(let m): m ?? "That can't be changed right now."
        case .transport(let m): "Can't reach Aula. \(m)"
        case .decoding(let m): "Unexpected answer from Aula. \(m)"
        }
    }
}

// MARK: - Client

/// The app's view of Aula, in API.md's shapes. The routes run on the phone (`Aula.handle`, a port of the
/// old server's routes); the method names still follow them.
struct APIClient: Sendable {
    private var aula: Aula { .shared }

    func today() async throws -> Today { try await send("GET", "/today") }
    func pickupOptions(child: Int) async throws -> PickupOptions { try await send("GET", "/children/\(child)/pickup") }
    func setPickup(child: Int, _ update: PickupUpdate) async throws -> Child {
        try await send("PUT", "/children/\(child)/pickup", body: update)
    }
    func reportSick(child: Int) async throws -> Child { try await send("POST", "/children/\(child)/sick") }
    func undoSick(child: Int) async throws -> Child { try await send("DELETE", "/children/\(child)/sick") }
    /// `page` is 1-based; page 1 is the posts in `/today`. Empty means no more.
    func posts(page: Int) async throws -> [Post] { try await send("GET", "/posts?page=\(page)") }
    func setSaved(post: Int, _ saved: Bool) async throws -> Bool {
        let r: SavedResponse = try await send(saved ? "POST" : "DELETE", "/posts/\(post)/save")
        return r.saved
    }

    /// `month` is `YYYY-MM`.
    func calendar(month: String) async throws -> [CalendarEvent] { try await send("GET", "/calendar?month=\(month)") }

    func contactGroups() async throws -> [ContactGroup] { try await send("GET", "/contacts/groups") }
    func groupContacts(_ group: Int) async throws -> GroupContacts { try await send("GET", "/contacts/groups/\(group)") }

    /// `page` is 1-based. Empty means no more.
    func albums(page: Int) async throws -> [Album] { try await send("GET", "/albums?page=\(page)") }
    func photos(album: Int, page: Int) async throws -> [Photo] { try await send("GET", "/albums/\(album)/photos?page=\(page)") }

    /// `type` is `messages`, `posts` or `photos`; `page` is 1-based. Empty lists mean no more.
    func search(_ text: String, type: String, page: Int) async throws -> SearchResults {
        // Alphanumerics only: `&`, `=` and `+` would split or change the query.
        let q = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return try await send("GET", "/search?q=\(q)&type=\(type)&page=\(page)")
    }

    /// `page` is 0-based like Aula's. Empty means no more.
    /// `folder` nil is the inbox.
    func threads(page: Int = 0, folder: Int? = nil) async throws -> [ThreadSummary] {
        try await send("GET", "/threads?page=\(page)" + (folder.map { "&folder=\($0)" } ?? ""))
    }
    func updateThread(_ id: String, _ patch: ThreadPatch) async throws -> ThreadSummary {
        try await send("PATCH", "/threads/\(id.urlPathEscaped)", body: patch)
    }
    func folders() async throws -> [Folder] { try await send("GET", "/folders") }
    func createFolder(name: String) async throws -> Folder { try await send("POST", "/folders", body: FolderNameRequest(name: name)) }
    func renameFolder(_ id: Int, name: String) async throws -> Folder {
        try await send("PATCH", "/folders/\(id)", body: FolderNameRequest(name: name))
    }
    func deleteFolder(_ id: Int) async throws {
        let _: OkResponse = try await send("DELETE", "/folders/\(id)")
    }
    func thread(_ id: String) async throws -> MessageThread { try await send("GET", "/threads/\(id.urlPathEscaped)") }
    func reply(thread id: String, _ request: ReplyRequest) async throws -> ReplyResponse {
        try await send("POST", "/threads/\(id.urlPathEscaped)/reply", body: request)
    }

    func holidayRequest(_ id: String) async throws -> HolidayRequest { try await send("GET", "/holiday-requests/\(id.urlPathEscaped)") }
    func answerHolidayRequest(_ id: String, _ answer: HolidayAnswer) async throws -> HolidayRequest {
        try await send("POST", "/holiday-requests/\(id.urlPathEscaped)", body: answer)
    }
    func addAbsence(_ request: AbsenceRequest) async throws {
        let _: OkResponse = try await send("POST", "/absences", body: request)
    }

    private static let pictureCache = URL.cachesDirectory.appending(path: "pictures", directoryHint: .isDirectory)

    /// A profile picture or gallery image. The id stays the same while the picture does (API.md), so it's kept on disk.
    func picture(_ id: String) async throws -> Data {
        let file = Self.pictureCache.appending(path: id.replacingOccurrences(of: "/", with: "-"))
        if let data = try? Data(contentsOf: file) { return data }
        let data = try await perform { try await aula.attachment(id).0 }
        try? FileManager.default.createDirectory(at: Self.pictureCache, withIntermediateDirectories: true)
        try? data.write(to: file)
        return data
    }

    /// Downloads an attachment into a fresh temp directory, named after `name`.
    func download(_ attachment: Attachment) async throws -> URL {
        guard let id = attachment.id, !id.isEmpty else { throw APIError.notFound }
        let (data, fileName, _) = try await perform { try await aula.attachment(id) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = attachment.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix(".") { name = "attachment" + name }
        // QuickLook needs an extension to pick a previewer.
        if (name as NSString).pathExtension.isEmpty {
            let ext = (fileName as NSString).pathExtension
            if !ext.isEmpty { name += "." + ext }
        }
        let dest = dir.appendingPathComponent(name)
        try data.write(to: dest)
        return dest
    }

    // MARK: plumbing

    private func send<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        try await send(method, path, bodyData: nil)
    }

    private func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B) async throws -> T {
        try await send(method, path, bodyData: try JSONEncoder().encode(body))
    }

    private func send<T: Decodable>(_ method: String, _ path: String, bodyData: Data?) async throws -> T {
        let data = try await perform { try await aula.handle(method, path, body: bodyData) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Aula's own errors as the app's (`Aula.handle` already throws `APIError` for the rest).
    private func perform<R>(_ op: () async throws -> R) async throws -> R {
        do { return try await op() }
        catch Aula.Failure.authRequired { throw APIError.authRequired }
        catch Aula.Failure.transport(let m) { throw APIError.transport(m) }
        catch Aula.Failure.rejected(let status, _, _, let method) {
            throw APIError.upstream("Aula refused \(method ?? "the request") (HTTP \(status))")
        }
    }
}

private extension String {
    var urlPathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static let posix = Locale(identifier: "en_US_POSIX")
    static let display = Locale(identifier: "en_GB")

    static func day(_ ymd: String) -> Date? {
        let f = DateFormatter()
        f.locale = posix
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd)
    }

    static func timestamp(_ s: String) -> Date? {
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: s) { return d }
        a.formatOptions = [.withInternetDateTime]
        return a.date(from: s)
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = display
        f.setLocalizedDateFormatFromTemplate(pattern)
        return f.string(from: date)
    }

    /// "HH:mm" → minutes since midnight.
    static func minutes(_ hhmm: String?) -> Int? {
        guard let hhmm else { return nil }
        let parts = hhmm.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    /// Inbox style: time today, "Yesterday", weekday within a week, else "6 Nov" (with the year if it differs).
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return format(date, "HHmm") }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        if days > 0 && days < 7 { return format(date, "EEE") }
        if cal.component(.year, from: date) != cal.component(.year, from: now) { return format(date, "dMMMyyyy") }
        return format(date, "dMMM")
    }

    /// Thread style: the relative day plus the time, e.g. "Yesterday 18:45" or just "13:06" today.
    static func messageTime(_ date: Date, now: Date = Date()) -> String {
        let day = relative(date, now: now)
        return Calendar.current.isDate(date, inSameDayAs: now) ? day : "\(day) \(format(date, "HHmm"))"
    }

    static func hhmm(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    /// Gregorian calendar in Aula's time zone (Europe/Copenhagen).
    static let copenhagen: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Copenhagen") ?? .current
        return c
    }()

    /// Date → "yyyy-MM-dd" as a day in Copenhagen.
    static func ymd(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = posix
        f.calendar = copenhagen
        f.timeZone = copenhagen.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
