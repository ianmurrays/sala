import CryptoKit
import Foundation
import os
import UniformTypeIdentifiers

// Aula -> API.md shapes, plus the Aula reads and writes the routes need (port of server/sala/mapping.py).

/// What a route answers when Aula's data says no (mapping.py's BadRequest / NotFound / Conflict /
/// UpstreamFailure, which the server turned into 400 / 404 / 409 / 502).
enum MapError: Error {
    /// The request is valid JSON but makes no sense against Aula's data.
    case badRequest(String)
    /// Unknown child, thread, message, folder or holiday request.
    case notFound(String)
    /// The write makes no sense in today's state, e.g. a pickup on a day off.
    case conflict(String)
    /// Aula answered but did not do what was asked.
    case upstream(String)
}

/// State the routes keep for the session: the attachment register, the thread rows seen in
/// listings (for PATCH) and the profile.
struct AulaLocalState {
    /// id -> [url, name]: Aula file URLs the app may fetch by id (store.py's attachments table).
    var attachments: [String: [String]] = [:]
    var attachmentsLoaded = false
    var attachmentsDirty = false
    /// thread id -> the last getThreads row listed for it.
    var threadRows: [String: JSONObject] = [:]
    var profile: (generation: Int, value: AulaProfile)?
}

/// Everything known about one child today, fetched once.
struct ChildDay: Sendable {
    var child: AulaChild
    var overview: DailyOverview?
    var template: DayTemplate?
    var config: PresenceConfiguration?
    var opensAt: String?
    var closesAt: String?
    var people: [String]?
}

/// One day of a holiday answer from the app.
struct DayAnswer: Sendable {
    var date: String
    var coming: Bool
    var entryTime: String?
    var exitTime: String?
}

struct ChildAnswer: Sendable {
    var days: [DayAnswer]
    var comment: String
}

/// `PATCH /threads/{id}`: only the fields the body had. `folderId` `.some(nil)` is the inbox.
struct ThreadChanges: Sendable {
    var muted: Bool?
    var starred: Bool?
    var folderId: Int??
    var isEmpty: Bool { muted == nil && starred == nil && folderId == nil }
}

let aulaLog = Logger(subsystem: "sala", category: "aula")

extension Aula {
    // MARK: small helpers

    /// A safe one-line description of a failure for the log (never a URL or a token).
    static func describe(_ e: Error) -> String {
        switch e {
        case let Failure.rejected(status, code, sub, method):
            return "Aula rejected \(method ?? "request") (HTTP \(status), code \(code.map(String.init) ?? "-"), sub-code \(sub.map(String.init) ?? "-"))"
        case Failure.authRequired: return "login needed"
        case Failure.transport: return "network error"
        case let e as MapError: return "\(e)"
        case let e as LibraryError: return e.description
        default: return String(describing: type(of: e))
        }
    }

    /// Errors that mean the Aula session itself is dead (they propagate through `optional`), plus
    /// cancellation, which must never turn into a quietly missing part.
    static func sessionGone(_ e: Error) -> Bool {
        if e is CancellationError { return true }
        // Offline is not "this part is missing": /today must fail rather than overwrite good data with blanks.
        if case Failure.transport = e { return true }
        if case Failure.authRequired = e { return true }
        if case let Failure.rejected(status, _, _, _) = e, status == 401 { return true }
        return false
    }

    /// Await a read whose failure should not fail the whole response. A dead session still
    /// propagates so the session layer can react; a 403 or step-up on one source (e.g. a guessed
    /// endpoint) is just a missing part.
    /// The same for a sequential read inside the actor (its result may be raw JSON).
    func opt<T>(_ label: String, _ op: () async throws -> T) async throws -> T? {
        do {
            return try await op()
        } catch {
            if Self.sessionGone(error) { throw error }
            aulaLog.warning("\(label, privacy: .public) failed: \(Self.describe(error), privacy: .public)")
            return nil
        }
    }

    static func optional<T: Sendable>(_ label: String, _ op: @Sendable () async throws -> T) async throws -> T? {
        do {
            return try await op()
        } catch {
            if sessionGone(error) { throw error }
            aulaLog.warning("\(label, privacy: .public) failed: \(describe(error), privacy: .public)")
            return nil
        }
    }

    /// "16:15", "16:15:00" or "2026-11-12T16:15:00+01:00" -> "16:15".
    static func hhmm(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let t = Py.prefix(value.components(separatedBy: "T").last ?? "", 5)
        let c = Array(t.unicodeScalars)
        return c.count == 5 && c[2] == ":" ? t : nil
    }

    /// Exactly "HH:mm".
    static func validHHmm(_ value: String?) -> Bool {
        guard let value else { return false }
        let c = Array(value.unicodeScalars)
        guard c.count == 5, c[2] == ":", let h = AulaTime.digits(c, 0, 2), let m = AulaTime.digits(c, 3, 2) else { return false }
        return h < 24 && m < 60
    }

    static func minutes(_ hhmm: String) -> Int? {
        guard validHHmm(hhmm) else { return nil }
        let c = Array(hhmm.unicodeScalars)
        return AulaTime.digits(c, 0, 2)! * 60 + AulaTime.digits(c, 3, 2)!
    }

    /// Aula HTML -> plain text for the views.
    static func plain(_ html: String) -> String { AulaText.plain(html) }

    /// Plain text from the app -> the HTML Aula's editor would send. The portal's reply box holds
    /// editor HTML (it runs `stripHTML(this.message)` before validating length), so a plain string
    /// would show up unformatted.
    static func textToHTML(_ text: String) -> String {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").filter { !Py.strip($0).isEmpty }
        return paragraphs.map { p in
            "<p>" + p.components(separatedBy: "\n").map(Py.htmlEscape).joined(separator: "<br>") + "</p>"
        }.joined()
    }

    /// A date or timestamp from Aula -> the date in Copenhagen ("2026-12-20T23:00:00Z" is 21 Dec).
    static func localDate(_ value: Any?) -> Day? { date(AulaTime.iso(value) ?? value) }

    static func date(_ value: Any?) -> Day? {
        guard let s = value as? String, Py.len(s) >= 10 else { return nil }
        return Day.parse(Py.prefix(s, 10))
    }

    static func shortDate(_ d: Day) -> String { "\(d.day) \(Day.monthAbbr[d.month - 1])" }

    /// 21–23 Dec, 30 Dec – 2 Jan, 21 Dec.
    static func dateRangeLabel(_ start: Day, _ end: Day?) -> String {
        guard let end, end != start else { return shortDate(start) }
        if start.year == end.year && start.month == end.month { return "\(start.day)–\(end.day) \(Day.monthAbbr[end.month - 1])" }
        return "\(shortDate(start)) – \(shortDate(end))"
    }

    func findChild(_ profile: AulaProfile, _ childId: Int) throws -> AulaChild {
        guard let child = profile.children.first(where: { $0.id == childId }) else { throw MapError.notFound("child \(childId)") }
        return child
    }

    // MARK: attachments

    static func attachmentId(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    /// Remember an Aula file URL and return the opaque id for it. The id hashes `key` (default: the
    /// URL); re-registering an id stores the newest URL, so a stable key keeps one id across signed URLs.
    func register(_ url: String, _ name: String, key: String? = nil) -> String {
        loadAttachments()
        let id = Self.attachmentId(key ?? url)
        if local.attachments[id] != [url, name] {
            local.attachments[id] = [url, name]
            local.attachmentsDirty = true
        }
        return id
    }

    func attachmentRef(_ id: String) -> (url: String, name: String)? {
        loadAttachments()
        guard let v = local.attachments[id], v.count == 2 else { return nil }
        return (v[0], v[1])
    }

    private static var attachmentsFile: URL { URL.cachesDirectory.appending(path: "aula-attachments.json") }

    /// The register survives relaunches (in Caches), so ids handed out before still open.
    private func loadAttachments() {
        guard !local.attachmentsLoaded else { return }
        local.attachmentsLoaded = true
        if let data = try? Data(contentsOf: Self.attachmentsFile),
           let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            local.attachments.merge(saved) { current, _ in current }
        }
    }

    func saveAttachments() {
        guard local.attachmentsDirty else { return }
        local.attachmentsDirty = false
        if let data = try? JSONEncoder().encode(local.attachments) {
            try? data.write(to: Self.attachmentsFile, options: .atomic)
        }
    }

    /// Only https URLs on Aula's own hosts are ever fetched. Aula hands out file URLs on `*.aula.dk`;
    /// the library and the portal bundle name no other file host.
    static func fileURLAllowed(_ url: String?) -> Bool {
        guard let url, !url.isEmpty else { return false }
        let parts = URLParts(url)
        guard parts.scheme == "https", let host = parts.hostname, !host.isEmpty else { return false }
        return host.hasSuffix(".aula.dk") || host == "aula.dk"
    }

    static func isWebLink(_ url: String?) -> Bool {
        guard let url, !url.isEmpty else { return false }
        return ["http", "https"].contains(URLParts(url).scheme)
    }

    private static let imageExt: Set<String> = [".png", ".jpg", ".jpeg", ".gif", ".heic", ".webp", ".bmp"]

    /// `mimetypes.guess_type(name)[0]`.
    static func mimeType(_ name: String) -> String? {
        let base = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return nil }
        let ext = String(base[base.index(after: dot)...]).lowercased()
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.preferredMIMEType
    }

    func mapAttachments(_ attachments: [AulaAttachment]) -> [JSONObject] {
        var out: [JSONObject] = []
        for att in attachments {
            if !att.hasFile {
                // A cloud-drive link (or a secure document, which has no URL): the app opens links
                // in the browser; nothing fetches them.
                let link = att.hasLink ? att.linkURL : nil
                if Self.isWebLink(link) {
                    out.append(["id": NSNull(), "name": att.name.isEmpty ? link! : att.name, "kind": "link", "url": link!])
                }
                continue
            }
            guard let url = att.fileURL, Self.fileURLAllowed(url) else {
                if let url = att.fileURL, !url.isEmpty {
                    aulaLog.warning("Skipping attachment on a non-Aula host: \(URLParts(url).hostname ?? "?", privacy: .private)")
                }
                continue
            }
            let name = !att.name.isEmpty ? att.name : !att.fileName.isEmpty ? att.fileName : "attachment"
            let mediaType = (att.mediaType ?? "").lowercased()
            let ext = name.contains(".") ? "." + (name.components(separatedBy: ".").last ?? "").lowercased() : ""
            let mime = Self.mimeType(name) ?? ""
            let isImage = mediaType == "image" || mediaType == "media" || Self.imageExt.contains(ext) || mime.hasPrefix("image/")
            out.append(["id": register(url, name), "name": name, "kind": isImage ? "image" : "file"])
        }
        return out
    }

    /// A person's `profilePicture` (Aula's dict with `url`, or the URL itself) as an attachment id.
    /// Picture URLs may be signed, so the id hashes the URL without its query: it stays the same
    /// across loads (the app caches by it) while the stored URL is refreshed each time.
    func pictureId(_ picture: Any?, register shouldRegister: Bool) -> String? {
        let url = picture is JSONObject ? J.getIn(picture, "url") : J.val(picture)
        guard shouldRegister, J.truthy(url), let url = url as? String else { return nil }
        guard Self.fileURLAllowed(url) else {
            aulaLog.warning("Skipping picture on a non-Aula host: \(URLParts(url).hostname ?? "?", privacy: .private)")
            return nil
        }
        let parts = URLParts(url)
        let last = parts.path.components(separatedBy: "/").last ?? ""
        return register(url, last.isEmpty ? "picture" : last, key: parts.withoutQuery)
    }

    // MARK: children

    private static let status: [PresenceState: String] = [
        .present: "present", .fieldtrip: "present", .sleeping: "present", .spareTimeActivity: "present",
        .physicalPlacement: "present", .notPresent: "not_arrived", .notArrived: "not_arrived", .sick: "sick",
        .checkedOut: "gone_home", .reportedAbsent: "vacation",
    ]

    func todayTemplate(_ childId: Int, _ today: Day) async throws -> DayTemplate? {
        for week in try await getPresenceTemplates([childId], from: today, to: today) where week.institutionProfileId == childId {
            for day in week.dayTemplates {
                if let by = day.byDate, !by.isEmpty, Py.prefix(by, 10) == today.iso { return day }
            }
        }
        return nil
    }

    /// Opening/closing time for `day`, or (nil, nil).
    func openingHours(_ institutionCode: String, _ day: Day) async throws -> (String?, String?) {
        for entry in try await openingHoursRows(institutionCode, day, day) {
            if Py.prefix(J.pyStr(J.get(entry, "date", default: "")), 10) == day.iso {
                if J.eq(J.get(entry, "type"), "closed_day") { return (nil, nil) }
                return (Self.hhmm(J.str(J.get(entry, "openTime"))), Self.hhmm(J.str(J.get(entry, "closeTime"))))
            }
        }
        return (nil, nil)
    }

    /// The library has no method for this. Endpoint and response shape come from the portal bundle
    /// (app.*.js, LOAD_PRESENCE_OPEN_HOURS_GUARDIAN_DASHBOARD: `?method=presence.getOpeningHoursByInstitutionCodes`
    /// with params institutionCodes/startDate/endDate; components read
    /// `data.openingHoursOverviewDto[].openingHoursDto[]` with date/type/openTime/closeTime, type one of
    /// specific_opening_hours, general_opening_hours, closed_day, default_opening_hours). Axios sends
    /// array params as `institutionCodes[]`.
    func openingHoursRows(_ institutionCode: String, _ start: Day, _ end: Day) async throws -> [JSONObject] {
        let r = try await get("presence.getOpeningHoursByInstitutionCodes", [
            ("institutionCodes[]", institutionCode), ("startDate", start.iso), ("endDate", end.iso),
        ])
        var rows: [JSONObject] = []
        for case let overview as JSONObject in J.list(J.getIn(r, "data.openingHoursOverviewDto")) ?? [] {
            if J.eq(J.get(overview, "institutionCode"), institutionCode) {
                rows += (J.list(J.or(J.get(overview, "openingHoursDto"), nil)) ?? []).compactMap { $0 as? JSONObject }
            }
        }
        return rows
    }

    /// 'Name (Relation)', the format Aula wants in exitWith.
    static func personLabel(_ p: ChildPickupResponsibles.Person) -> String? {
        if let relation = p.relation, !relation.isEmpty { return "\(p.name ?? "None") (\(relation))" }
        return p.name
    }

    func pickupPeople(_ childId: Int) async throws -> [String] {
        var people: [String] = []
        for responsibles in try await getPickupResponsibles([childId]) {
            if responsibles.uniStudentId != 0 && responsibles.uniStudentId != childId { continue }
            for person in responsibles.persons {
                if let label = Self.personLabel(person), !label.isEmpty, !people.contains(label) { people.append(label) }
            }
        }
        return people
    }

    func loadChildDay(_ child: AulaChild, withPeople: Bool = false) async throws -> ChildDay {
        let today = AulaTime.today()
        async let overview = Self.optional("daily overview") { try await self.getDailyOverview(child.id) }
        async let template = Self.optional("presence template") { try await self.todayTemplate(child.id, today) }
        async let config = Self.optional("presence configuration") {
            try await self.getPresenceConfiguration([child.id]).first { $0.childId == nil || $0.childId == child.id }
        }
        async let hours = Self.optional("opening hours") { () -> (String?, String?)? in
            guard let code = child.institutionCode, !code.isEmpty else { return nil }
            return try await self.openingHours(code, today)
        }
        async let people = withPeople ? Self.optional("pickup responsibles") { try await self.pickupPeople(child.id) } : nil
        var day = ChildDay(child: child)
        day.overview = try await overview ?? nil
        day.template = try await template ?? nil
        day.config = try await config ?? nil
        let oh = try await hours ?? nil
        day.people = try await people
        if let oh {
            day.opensAt = oh.0
            day.closesAt = oh.1
        }
        return day
    }

    static func currentPickup(_ day: ChildDay) -> (when: String?, who: String?, note: String) {
        let t = day.template, ov = day.overview
        let when = hhmm(nonEmpty(t?.exitTime) ?? ov?.exitTime)
        let who = nonEmpty(t?.exitWith) ?? nonEmpty(ov?.exitWith)
        let note = nonEmpty(t?.comment) ?? nonEmpty(ov?.comment) ?? ""
        return (when, who, note)
    }

    static func nonEmpty(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }

    func childOut(_ day: ChildDay) -> JSONObject {
        let ov = day.overview
        let state = ov?.status
        let (when, who, _) = Self.currentPickup(day)
        let institution = Self.nonEmpty(day.child.institutionName) ?? ov?.institutionName
        let group = Self.nonEmpty(ov?.mainGroupName) ?? day.child.metadata
        return [
            "id": day.child.id,
            "name": day.child.name ?? "",
            // The overview is fetched fresh; the profile (and its signed URL) is kept for the session.
            "picture": J.out(pictureId(Self.nonEmpty(ov?.pictureURL) ?? day.child.profilePicture, register: true)),
            "institution": institution ?? "",
            "group": group ?? "",
            "status": state.map { Self.status[$0] ?? "unknown" } ?? "unknown",
            "statusLabel": state?.displayName ?? "Unknown",
            "arrivedAt": J.out(Self.hhmm(ov?.checkInTime)),
            "leftAt": J.out(Self.hhmm(ov?.checkOutTime)),
            "pickup": ["time": J.out(when), "by": J.out(who)] as JSONObject,
            "closesAt": J.out(day.closesAt),
            "canReportSick": day.config?.canEdit(.reportSick) ?? false,
        ]
    }

    /// 30-minute grid from now (or 3 h before closing) to closing, plus the current pickup time and
    /// closing time, as in API.md's own example.
    static func pickupTimes(current: String?, opensAt: String?, closesAt: String?, nowMinutes: Int) throws -> [String] {
        let closeM: Int
        if let closesAt {
            guard let m = minutes(closesAt) else { throw LibraryError(description: "Invalid isoformat string: '\(closesAt)'") }
            closeM = m
        } else {
            closeM = 17 * 60
        }
        var startM = max(nowMinutes, closeM - 180)
        if let opensAt {
            guard let o = minutes(opensAt) else { throw LibraryError(description: "Invalid isoformat string: '\(opensAt)'") }
            startM = max(startM, o)
        }
        let first = Int((Double(startM) / 30).rounded(.up)) * 30  // round up to the half hour
        var slots = Set(stride(from: first, through: closeM, by: 30))
        if nowMinutes <= closeM { slots.insert(closeM) }
        var out = Set(slots.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) })
        if let current, !current.isEmpty { out.insert(current) }
        return out.sorted()
    }

    func pickupOut(_ day: ChildDay) throws -> JSONObject {
        let (when, who, note) = Self.currentPickup(day)
        return [
            "date": AulaTime.today().iso,
            "opensAt": J.out(day.opensAt),
            "closesAt": J.out(day.closesAt),
            "times": try Self.pickupTimes(current: when, opensAt: day.opensAt, closesAt: day.closesAt, nowMinutes: AulaTime.nowMinutes()),
            "people": day.people ?? [],
            "current": ["time": J.out(when), "by": J.out(who)] as JSONObject,
            "note": note,
        ]
    }

    /// Change today's pickup only, the way the portal's guardian dashboard does.
    ///
    /// Today's existing day template supplies the entry time and (unless the app sent a note) the
    /// comment. If that template repeats (weekly etc.) it is left alone: we write a single-day
    /// template for today with no id and repeatPattern "never". So does a template whose
    /// repeatPattern is missing. That matches the portal's "edit today" drawer (app.*.js
    /// `updateTemplate`: posts {institutionProfileId, byDate, presenceActivity, comment} and never an
    /// id; the week editor doesn't send an id either). Only a template that is already a one-off for
    /// today is updated by id, as `aula update-presence` does (cli.py ~3770). A day the child is
    /// registered absent (vacation) is refused (-> 409) rather than overwritten.
    func setPickup(_ child: AulaChild, when: String, by: String, note inputNote: String?) async throws {
        let today = AulaTime.today()
        // These reads decide what gets written, so a failure stops the write (-> 502) instead of
        // posting a blank entry time / comment over real ones.
        let people: [String]
        let t: DayTemplate?
        do {
            people = try await pickupPeople(child.id)
            t = try await todayTemplate(child.id, today)
        } catch {
            if Self.sessionGone(error) { throw error }
            throw MapError.upstream("Could not read today's pickup before changing it: \(Self.describe(error))")
        }
        if !people.contains(by) { throw MapError.badRequest("by must be one of people") }
        if let t, t.isOnVacation { throw MapError.conflict("\(child.name ?? "None") is registered absent today") }
        let ov = try await Self.optional("daily overview") { try await self.getDailyOverview(child.id) } ?? nil
        // No invented default: the portal sends entryTime null when drop-off time isn't set
        // (preparePresenceTemplateParams), so nil is passed through.
        let entry = Self.hhmm(Self.nonEmpty(t?.entryTime) ?? ov?.entryTime)
        let note = inputNote ?? Self.nonEmpty(t?.comment) ?? Self.nonEmpty(ov?.comment) ?? ""
        // Only an explicit one-off ("never") is updated in place; a missing or unknown repeatPattern
        // may be a series, so it gets a new day override.
        let oneOff = t.map { ($0.repeatPattern ?? "").lowercased() == "never" } ?? false
        let templateId = oneOff && Py.prefix(t?.byDate ?? "", 10) == today.iso ? t?.id : nil
        try await updatePresenceTemplate(
            child.id, byDate: today, entryTime: entry, exitTime: when, exitWith: by, comment: note, templateId: templateId)
    }

    /// Report sick, or take it back. Undo restores PRESENT when the child was checked in today and
    /// not yet checked out, otherwise NOT_PRESENT.
    func setSick(_ child: AulaChild, _ sick: Bool) async throws {
        let status: PresenceState
        if sick {
            status = .sick
        } else {
            let ov: DailyOverview?
            do {
                ov = try await getDailyOverview(child.id)
            } catch {
                if Self.sessionGone(error) { throw error }
                throw MapError.upstream("Could not read today's presence before undoing sick: \(Self.describe(error))")
            }
            let checkedIn = Self.nonEmpty(ov?.checkInTime) != nil && Self.nonEmpty(ov?.checkOutTime) == nil
            status = checkedIn ? .present : .notPresent
        }
        if !(try await updatePresenceStatus([child.id], status)) { throw MapError.upstream("Aula did not accept the status change") }
    }

    // MARK: attention / upcoming

    func holidayRequests(_ childIds: [Int]) async throws -> [JSONObject] {
        let today = AulaTime.today()
        var out: [(JSONObject, Day)] = []
        var ids = Set<Int?>()
        for reg in try await getVacationRegistrations(childIds) {
            if !reg.needsAnswer || ids.contains(reg.id) { continue }  // one row per child; one card per request
            ids.insert(reg.id)
            let start = Self.localDate(reg.startDate), end = Self.localDate(reg.endDate)
            let deadline = Self.localDate(reg.responseDeadline)
            let what = start.map { Self.dateRangeLabel($0, end) } ?? Self.nonEmpty(reg.title) ?? "no dates"
            out.append(([
                "id": "vacation-\(J.pyStr(reg.id))",
                "kind": "holiday_request",
                "title": "Holiday request: \(what)",
                "subtitle": J.out(deadline.map { "Answer by \(Self.shortDate($0))" }),
                "urgent": deadline.map { $0.ordinal - today.ordinal <= 2 } ?? false,
                "threadId": NSNull(),
            ], deadline ?? Day(ordinal: Int.max)))
        }
        // A stable sort by deadline, like Python's.
        return out.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
    }

    static func unreadThreadsAttention(_ threads: [JSONObject], limit: Int = 3) -> [JSONObject] {
        var out: [JSONObject] = []
        for t in threads {
            if J.truthy(t["unread"]) {
                out.append([
                    "id": "thread-\(J.pyStr(t["id"]))",
                    "kind": "message",
                    "title": J.out(t["subject"]),
                    "subtitle": J.out(t["from"]),
                    "urgent": false,
                    "threadId": J.out(t["id"]),
                ])
            }
            if out.count >= limit { break }
        }
        return out
    }

    func upcoming(_ children: [AulaChild], limit: Int = 5) async throws -> [JSONObject] {
        let today = AulaTime.today()
        let horizon = today.adding(30)
        var items: [(String, JSONObject)] = []

        let events = try await opt("important dates") { try await getImportantDates(limit: 10, includeToday: true) } ?? []
        for case let ev as JSONObject in events {
            let d = Self.date(AulaTime.iso(J.get(ev, "startDateTime")) ?? J.or(J.get(ev, "startDateTime"), J.get(ev, "startDate")))
            if let d, today <= d, d <= horizon, J.truthy(J.get(ev, "title")) {
                items.append((d.iso, ["date": d.iso, "title": ev["title"]!, "subtitle": NSNull()]))
            }
        }

        // Birthday rows: shape is a guess (name / birthday / mainGroupName); the library returns them
        // untyped and the bundle doesn't show the fields.
        let codes = Set(children.compactMap { Self.nonEmpty($0.institutionCode) }).sorted()
        if !codes.isEmpty {
            let start = AulaTime.combine(today, endOfDay: false)
            let end = AulaTime.combine(horizon, endOfDay: true)
            let rows = try await opt("birthdays") { try await getBirthdayEvents(codes, start: start, end: end) } ?? []
            for case let row as JSONObject in rows {
                let born = Self.date(J.or(J.get(row, "birthday"), J.or(J.get(row, "birthDate"), J.get(row, "startDateTime"))))
                let name = J.or(J.get(row, "name"), J.get(row, "fullName"))
                guard let born, J.truthy(name) else { continue }
                var d = born.replacing(year: today.year) ?? Day(today.year, 3, 1)!  // 29 Feb
                if d < today {
                    guard let next = d.replacing(year: today.year + 1) else { throw LibraryError(description: "day is out of range for month") }
                    d = next
                }
                if d <= horizon {
                    let group = J.or(J.get(row, "mainGroupName"), J.get(row, "groupName"))
                    items.append((d.iso, ["date": d.iso, "title": "\(J.pyStr(name))'s birthday", "subtitle": J.out(group)]))
                }
            }
        }

        return items.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.prefix(limit).map(\.element.1)
    }

    // MARK: calendar

    /// `GET /calendar?month=`. Events from the portal's calendar call, one month at a time (Aula refuses
    /// longer ranges), plus the institution's birthdays. Field names from live captures
    /// (docs/aula-shapes/calendar.getEventsByProfileIdsAndResourceIds.json).
    func calendar(_ profile: AulaProfile, year: Int, month: Int) async throws -> [JSONObject] {
        guard let first = Day(year, month, 1) else { throw MapError.badRequest("month is out of range") }
        let next = month == 12 ? Day(year + 1, 1, 1)! : Day(year, month + 1, 1)!
        let last = next.adding(-1)
        let names = Dictionary(profile.children.map { ($0.id, $0.name ?? "") }, uniquingKeysWith: { a, _ in a })
        var out: [JSONObject] = []

        func item(_ id: String, _ kind: String, _ title: Any?, _ subtitle: Any?, _ start: Day, _ end: Day, _ times: (String, String)? = nil) -> JSONObject {
            ["id": id, "kind": kind, "title": J.pyStr(J.or(title, "")), "subtitle": J.out(subtitle.flatMap { Self.nonEmpty(J.pyStr($0)) }),
             "startDate": start.iso, "endDate": end.iso, "startTime": J.out(times?.0), "endTime": J.out(times?.1)]
        }
        // Copenhagen day and HH:mm of an Aula timestamp.
        func local(_ v: Any?) -> (Day, String)? {
            guard let st = AulaTime.parse(v) else { return nil }
            let l = AulaTime.local(st.epoch)
            return (l.day, String(format: "%02d:%02d", l.seconds / 3600, l.seconds / 60 % 60))
        }

        for e in try await getEvents(profile.institutionProfileIds, from: first, to: next) {
            guard let id = J.int(J.get(e, "id")) else { continue }
            let type = J.str(J.get(e, "type")) ?? ""
            let key = "event-\(id)-\(Self.date(J.get(e, "startDateTime"))?.iso ?? "")"
            if type == "presence_holiday" {
                // All-day stamps are midnight and 23:59 UTC: read their dates as written, not in Copenhagen.
                guard let s = Self.date(J.get(e, "startDateTime")), let end = Self.date(J.get(e, "endDateTime")) else { continue }
                let who = (J.list(J.get(e, "belongsToProfiles")) ?? []).compactMap { J.int($0).flatMap { names[$0] } }.filter { !$0.isEmpty }
                out.append(item(key, "absence", J.get(e, "title"), who.isEmpty ? nil : who.joined(separator: ", "), s, end))
            } else if let slots = J.list(J.getIn(e, "timeSlot.timeSlots")) {
                // The booked slot: our child's (or our own) answer points into that day's timeSlotIndexes.
                let ours = Set(profile.institutionProfileIds)
                var booked: (Day, String, String)?
                for case let slot as JSONObject in slots {
                    for case let a as JSONObject in J.list(J.get(slot, "answers")) ?? [] {
                        guard let who = J.int(J.get(a, "concerningProfileId")), ours.contains(who),
                              let i = J.int(J.get(a, "selectedTimeSlotIndex")),
                              let idx = J.list(J.get(slot, "timeSlotIndexes")), idx.indices.contains(i),
                              let s = local(J.get(idx[i], "startTime")), let end = local(J.get(idx[i], "endTime")) else { continue }
                        booked = (s.0, s.1, end.1)
                    }
                }
                if let (d, s, end) = booked {
                    out.append(item(key, "meeting", J.get(e, "title"), J.get(e, "institutionName"), d, d, (s, end)))
                } else if let s = local(J.get(e, "startDateTime")), let end = local(J.get(e, "endDateTime")) {
                    out.append(item(key, "meeting", J.get(e, "title"), "Not booked", s.0, end.0))
                }
            } else if J.truthy(J.get(e, "allDay")) {
                guard let s = Self.date(J.get(e, "startDateTime")), let end = Self.date(J.get(e, "endDateTime")) else { continue }
                out.append(item(key, "event", J.get(e, "title"), J.get(e, "institutionName"), s, end))
            } else if let s = local(J.get(e, "startDateTime")), let end = local(J.get(e, "endDateTime")) {
                out.append(item(key, "event", J.get(e, "title"), J.get(e, "institutionName"), s.0, end.0, (s.1, end.1)))
            }
        }

        let codes = Set(profile.children.compactMap { Self.nonEmpty($0.institutionCode) }).sorted()
        if !codes.isEmpty {
            let start = AulaTime.combine(first, endOfDay: false)
            let end = AulaTime.combine(last, endOfDay: true)
            let rows = try await opt("birthdays") { try await getBirthdayEvents(codes, start: start, end: end) } ?? []
            for case let row as JSONObject in rows {
                guard let born = Self.date(J.get(row, "birthday")), let name = J.str(J.get(row, "name")) else { continue }
                let d = born.replacing(year: year) ?? Day(year, 3, 1)!  // 29 Feb
                guard first <= d, d <= last else { continue }
                let id = "birthday-\(J.pyStr(J.get(row, "institutionProfileId")))-\(year)"
                out.append(item(id, "birthday", "\(name)'s birthday", J.get(row, "mainGroupName"), d, d))
            }
        }

        // Only what touches the month: a meeting's booked slot can fall outside the window that matched it.
        out = out.filter { ($0["startDate"] as! String) <= last.iso && ($0["endDate"] as! String) >= first.iso }
        // By date, all-day first, then by time; stable otherwise.
        func key(_ o: JSONObject) -> String { "\(o["startDate"]!) \((o["startTime"] as? String) ?? "") \(o["endDate"]!)" }
        return out.enumerated().sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }.map(\.element)
    }

    // MARK: holidays

    static func weekdays(_ start: Day, _ end: Day) -> [Day] {
        guard end >= start else { return [] }
        return (0...(end.ordinal - start.ordinal)).map { start.adding($0) }.filter { $0.isoWeekday <= 5 }
    }

    /// One child's answer to a holiday request.
    ///
    /// Endpoint from the portal bundle (0.*.js LOAD_VACATION_REQUEST_RESPONSE: GET
    /// `?method=presence.getVacationRegistrationResponse` with param `vacationRegistrationResponseId`,
    /// the request row's `responseId`). The drawer (10.*.js) reads `data.vacationRegistrationResponse`
    /// with vacationRegistrationResponseId, childId, comment and days[]{date, isComing, entryTime,
    /// exitTime}. Not in the library.
    func vacationResponse(_ responseId: Int) async throws -> SendableJSON {
        let r = try await get("presence.getVacationRegistrationResponse", [("vacationRegistrationResponseId", String(responseId))])
        guard let data = J.dict(J.getIn(r, "data.vacationRegistrationResponse")) else {
            throw MapError.upstream("Aula sent no answer for the holiday request")
        }
        return SendableJSON(data)
    }

    func closedDays(_ code: String, _ start: Day, _ end: Day) async throws -> Set<Day> {
        Set(try await openingHoursRows(code, start, end).filter { J.eq(J.get($0, "type"), "closed_day") }.compactMap { Self.date(J.get($0, "date")) })
    }

    /// `GET /holiday-requests/{id}`, plus each child's raw Aula answer by child id.
    ///
    /// Title, note, deadline and dates come from the request rows (`presence.getVacationRegistrationsByChildren`,
    /// one row per child); the answer read gives only the days, the comment and the ids. Days follow
    /// the portal drawer (10.*.js populateVacationRequestDaysList / updateDisabled): Mon–Fri from
    /// startDate to endDate; a day is disabled when it is today or earlier, a closed day, or the
    /// deadline has passed. `strict` (before a write) fails on any read; otherwise the answer and
    /// closed-day reads are optional.
    func holiday(_ profile: AulaProfile, _ requestId: String, strict: Bool) async throws -> (JSONObject, [Int?: JSONObject]) {
        let regId = requestId.hasPrefix("vacation-") ? String(requestId.dropFirst("vacation-".count)) : requestId
        guard requestId.hasPrefix("vacation-"), Py.isDigits(regId), let wanted = Int(regId) else {
            throw MapError.notFound("holiday request \(requestId)")
        }
        let regs = try await getVacationRegistrations(profile.children.map(\.id)).filter { $0.id == wanted }
        guard let first = regs.first else { throw MapError.notFound("holiday request \(requestId)") }
        let today = AulaTime.today()
        let start = Self.localDate(first.startDate), end = Self.localDate(first.endDate)
        let deadline = Self.localDate(first.responseDeadline)
        let isOpen = deadline.map { today <= $0 } ?? true

        func read<T: Sendable>(_ label: String, _ op: @Sendable () async throws -> T) async throws -> T? {
            strict ? try await op() : try await Self.optional(label, op)
        }

        var children: [JSONObject] = []
        var responses: [Int?: JSONObject] = [:]
        for reg in regs {
            let child = profile.children.first { $0.id == reg.childId }
            var response: JSONObject = [:]
            if let rid = reg.responseId, rid != 0 {
                response = try await read("holiday answer") { try await self.vacationResponse(rid) }?.value as? JSONObject ?? [:]
            }
            responses[reg.childId] = response
            var answers: [Day: JSONObject] = [:]
            for d in J.list(J.or(J.get(response, "days"), nil)) ?? [] {
                if let d = d as? JSONObject, let day = Self.localDate(J.get(d, "date")) { answers[day] = d }
            }
            var closed = Set<Day>()
            if let code = Self.nonEmpty(child?.institutionCode), let start, let end {
                closed = try await read("opening hours") { try await self.closedDays(code, start, end) } ?? []
            }
            // The portal's own gate (app.*.js canEdit), per child's row: isEditable, custody and the deadline.
            let mayAnswer = isOpen && reg.isEditable && (child == nil || child?.hasCustodyOrExtendedAccess != false)
            var days: [JSONObject] = []
            if let start, let end {
                for day in Self.weekdays(start, end) {
                    let a = answers[day] ?? [:]
                    let coming = J.bool(J.get(a, "isComing"))
                    days.append([
                        "date": day.iso,
                        "coming": J.out(coming),
                        "entryTime": J.out(Self.hhmm(J.str(J.get(a, "entryTime")))),
                        "exitTime": J.out(Self.hhmm(J.str(J.get(a, "exitTime")))),
                        "editable": mayAnswer && day > today && !closed.contains(day),
                    ])
                }
            }
            children.append([
                "id": J.out(reg.childId),
                "name": Self.nonEmpty(child?.name) ?? Self.nonEmpty(reg.childName) ?? "",
                "answered": !reg.isMissingAnswer,
                "comment": J.or(J.get(response, "comment"), "") ?? "",
                "days": days,
            ])
        }
        let out: JSONObject = [
            "id": "vacation-\(J.pyStr(first.id))",
            "title": Self.nonEmpty(first.title) ?? "",
            "note": J.out(Self.nonEmpty(first.noteToGuardian)),
            "deadline": J.out(deadline?.iso),
            "startDate": J.out(start?.iso),
            "endDate": J.out(end?.iso),
            "timesRequired": first.isPresenceTimesRequired,
            "answered": children.allSatisfy { ($0["answered"] as? Bool) ?? false },
            "editable": isOpen && regs.contains(where: \.isEditable),
            "children": children,
        ]
        return (out, responses)
    }

    func holidayRequest(_ profile: AulaProfile, _ requestId: String) async throws -> JSONObject {
        try await holiday(profile, requestId, strict: false).0
    }

    /// Answer a holiday request for one or more children, one Aula write per child.
    ///
    /// Payload from the portal bundle (10.*.js, the guardian's vacation response drawer,
    /// `updateVacationResponses` -> `ADD_VACATION` action in 0.*.js, which POSTs it to
    /// `?method=calendar.respondToVacationRegistrationRequest`): `{vacationRegistrationResponseId,
    /// childId, days:[{date, isComing, entryTime, exitTime}], comment}`, both ids from the answer read
    /// (`vacationRegistrationResponse`). `days` holds only the enabled days (`filter(!isDisabled)`),
    /// dates as "YYYY-MM-DD"; times are "" unless the child comes and the request has
    /// `isPresenceTimesRequired` ("HH:mm" from the time picker). Every enabled day must have an
    /// answer (validateIsComing). Never tried against live Aula.
    func answerHolidayRequest(_ profile: AulaProfile, _ requestId: String, _ answers: [(Int, ChildAnswer)]) async throws {
        if answers.isEmpty { throw MapError.badRequest("children is empty") }
        let (out, responses) = try await holiday(profile, requestId, strict: true)
        if !((out["editable"] as? Bool) ?? false) {
            let passed = (out["deadline"] as? String).flatMap(Day.parse).map { $0 < AulaTime.today() } ?? false
            throw MapError.conflict(passed ? "The deadline for this holiday request has passed" : "Aula no longer takes an answer to this holiday request")
        }
        let withTimes = (out["timesRequired"] as? Bool) ?? false
        var byChild: [Int: JSONObject] = [:]
        for c in out["children"] as? [JSONObject] ?? [] {
            if let id = J.int(c["id"]) { byChild[id] = c }
        }
        var payloads: [JSONObject] = []
        for (childId, answer) in answers {
            guard let child = byChild[childId] else { throw MapError.badRequest("child \(childId) is not part of this holiday request") }
            let name = Self.nonEmpty(child["name"] as? String) ?? String(childId)
            var known: [String: JSONObject] = [:]
            for d in child["days"] as? [JSONObject] ?? [] { known[d["date"] as! String] = d }
            var given: [String: DayAnswer] = [:]
            for a in answer.days {
                guard let info = known[a.date] else { throw MapError.badRequest("\(a.date) is not a day of this holiday request") }
                if !((info["editable"] as? Bool) ?? false) { throw MapError.badRequest("\(a.date) can no longer be answered") }
                if given[a.date] != nil { throw MapError.badRequest("\(a.date) is answered twice") }
                for t in [a.entryTime, a.exitTime] {
                    if let t, !Self.validHHmm(t) { throw MapError.badRequest("\(a.date): times must be HH:mm") }
                }
                if a.coming && withTimes {
                    guard let entry = Self.nonEmpty(a.entryTime), let exit = Self.nonEmpty(a.exitTime) else {
                        throw MapError.badRequest("\(a.date): entryTime and exitTime are required")
                    }
                    if entry >= exit { throw MapError.badRequest("\(a.date): entryTime must be before exitTime") }
                }
                given[a.date] = a
            }
            let missing = known.filter { (($0.value["editable"] as? Bool) ?? false) && given[$0.key] == nil }.keys.sorted()
            if let firstMissing = missing.first { throw MapError.badRequest("\(name): no answer for \(firstMissing)") }
            if given.isEmpty { throw MapError.conflict("\(name) has no days left to answer") }
            let response = responses[childId] ?? [:]
            let responseId = J.get(response, "vacationRegistrationResponseId")
            guard J.truthy(responseId) else { throw MapError.upstream("Aula gave no answer id for \(name)") }
            payloads.append([
                "vacationRegistrationResponseId": responseId!,
                "childId": J.or(J.get(response, "childId"), childId)!,
                "days": given.keys.sorted().map { d -> JSONObject in
                    let a = given[d]!
                    return [
                        "date": d,
                        "isComing": a.coming,
                        "entryTime": a.coming && withTimes ? J.out(a.entryTime) : "",
                        "exitTime": a.coming && withTimes ? J.out(a.exitTime) : "",
                    ]
                },
                "comment": answer.comment,  // per child: each answer has its own comment in Aula
            ])
        }
        for payload in payloads {
            _ = try await post("calendar.respondToVacationRegistrationRequest", payload)
        }
    }

    /// Children Aula is known to refuse an absence for, with the reason (the library CLI's
    /// `_vacation_denials`): no custody, or the presence configuration doesn't let guardians edit
    /// VACATION. A child Aula hasn't said either way about (configuration unreadable or missing) is
    /// left out, so Aula decides.
    func vacationDenials(_ children: [AulaChild]) async throws -> [(Int, String)] {
        var denials: [(Int, String)] = children.filter { $0.hasCustodyOrExtendedAccess == false }.map {
            ($0.id, "you have no custody of or extended access to this child; a guardian with custody must register it")
        }
        let candidates = children.filter { c in !denials.contains { $0.0 == c.id } }
        if candidates.isEmpty { return denials }
        let configs: [PresenceConfiguration]
        do {
            configs = try await getPresenceConfiguration(candidates.map(\.id))
        } catch {
            if Self.sessionGone(error) { throw error }
            aulaLog.warning("Could not fetch presence configuration, leaving it to Aula: \(Self.describe(error), privacy: .public)")
            return denials
        }
        var byChild: [Int: PresenceConfiguration] = [:]
        for c in configs { if let id = c.childId { byChild[id] = c } }
        for child in candidates {
            guard let config = byChild[child.id] else {
                aulaLog.warning("No presence configuration for a child, leaving it to Aula")
                continue
            }
            if !config.canEdit(.vacation) {
                denials.append((child.id, config.permission(.vacation) == .readable
                    ? "absence registration is read-only for guardians; contact the institution"
                    : "the institution has not enabled absence registration for guardians; contact the institution"))
            }
        }
        return denials
    }

    /// Register a holiday / days off (the library's `calendar.addVacation`). Its own checks run first
    /// so a bad request is a 400.
    func addAbsence(_ profile: AulaProfile, _ childIds: [Int], _ start: Day, _ end: Day, _ comment: String) async throws {
        if childIds.isEmpty { throw MapError.badRequest("childIds is empty") }
        var known: [Int: AulaChild] = [:]
        for c in profile.children where known[c.id] == nil { known[c.id] = c }
        for cid in childIds where known[cid] == nil { throw MapError.badRequest("unknown child \(cid)") }
        if let err = Self.validateVacation(start: start, end: end, comment: comment, today: AulaTime.today()) {
            throw MapError.badRequest(err)
        }
        var unique: [Int] = []
        for cid in childIds where !unique.contains(cid) { unique.append(cid) }
        let denials = try await vacationDenials(unique.map { known[$0]! })
        if let (cid, reason) = denials.first {
            throw MapError.badRequest("\(Self.nonEmpty(known[cid]?.name) ?? String(cid)): \(reason)")
        }
        try await addVacation(unique, start: start, end: end, comment: comment)
    }

    /// `GET /holiday-requests`: requests whose period hasn't ended, answered or not, like the portal's
    /// list. Past the deadline (or locked by Aula) they stay, read-only: `holiday` says so.
    func openHolidayRequests(_ profile: AulaProfile) async throws -> [JSONObject] {
        let today = AulaTime.today()
        var order: [Int] = []
        var rows: [Int: [VacationRegistration]] = [:]
        for reg in try await getVacationRegistrations(profile.children.map(\.id)) {
            guard let id = reg.id, id != 0 else { continue }
            if let end = Self.localDate(reg.endDate), end < today { continue }
            if rows[id] == nil { order.append(id) }
            rows[id, default: []].append(reg)
        }
        let out = order.map { id -> (JSONObject, Day) in
            let regs = rows[id]!, first = regs[0]
            let deadline = Self.localDate(first.responseDeadline)
            return ([
                "id": "vacation-\(id)",
                "title": Self.nonEmpty(first.title) ?? "",
                "startDate": J.out(Self.localDate(first.startDate)?.iso),
                "endDate": J.out(Self.localDate(first.endDate)?.iso),
                "deadline": J.out(deadline?.iso),
                "answered": regs.allSatisfy { !$0.isMissingAnswer },
                "editable": (deadline.map { today <= $0 } ?? true) && regs.contains(where: \.isEditable),
            ], deadline ?? Day(ordinal: Int.max))
        }
        return out.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
    }

    // MARK: registered absences

    struct RegisteredAbsence {
        var id: Int
        var children: [(id: Int, name: String)]
        var start: Day
        var end: Day
        var comment: String
        var editable: Bool

        var json: JSONObject {
            ["id": "absence-\(id)", "children": children.map { ["id": $0.id, "name": $0.name] as JSONObject },
             "startDate": start.iso, "endDate": end.iso, "comment": comment, "editable": editable]
        }
    }

    /// Registered holidays and days off that haven't ended, one per Aula event, by start date.
    ///
    /// From the portal bundle (app.*.js, the guardian's absence list, LOAD_VACATION_ANNOUCEMENTS_BY_CHILDREN
    /// in 0.*.js: GET `?method=presence.getVacationAnnouncementsByChildren` with `childIds`). The list
    /// reads `data` as [{child, vacationAnnouncements: [{vacationId, startDate, endDate, description,
    /// isEditable}]}], and `vacationId` is the calendar event's id. Live shape:
    /// docs/aula-shapes/presence.getVacationAnnouncementsByChildren.json (dates are plain "YYYY-MM-DD").
    func absences(_ profile: AulaProfile) async throws -> [RegisteredAbsence] {
        let today = AulaTime.today()
        let r = try await get("presence.getVacationAnnouncementsByChildren", Self.ids("childIds[]", profile.children.map(\.id)))
        var out: [RegisteredAbsence] = []
        for case let group as JSONObject in J.list(J.get(r, "data")) ?? [] {
            let childId = J.int(J.getIn(group, "child.id"))
            let child = childId.flatMap { id in profile.children.first { $0.id == id } }
            let name = Self.nonEmpty(child?.name) ?? J.str(J.getIn(group, "child.name")) ?? ""
            for case let a as JSONObject in J.list(J.get(group, "vacationAnnouncements")) ?? [] {
                guard let id = J.int(J.get(a, "vacationId")), let start = Self.date(J.get(a, "startDate")),
                      let end = Self.date(J.get(a, "endDate")), end >= today else { continue }
                let editable = J.truthy(J.get(a, "isEditable")) && child?.hasCustodyOrExtendedAccess != false
                if let i = out.firstIndex(where: { $0.id == id }) {
                    // The same event under two children: one entry, editable only if it is for both.
                    if let childId, !out[i].children.contains(where: { $0.id == childId }) { out[i].children.append((childId, name)) }
                    out[i].editable = out[i].editable && editable
                    continue
                }
                out.append(RegisteredAbsence(id: id, children: childId.map { [($0, name)] } ?? [], start: start, end: end,
                                   comment: J.str(J.get(a, "description")) ?? "", editable: editable))
            }
        }
        return out.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    /// The absence `id` names, if it is one of ours that may be changed. The writes act on any calendar
    /// event, so only an id from our own list is ever sent.
    private func editableAbsence(_ profile: AulaProfile, _ id: String) async throws -> RegisteredAbsence {
        let digits = id.hasPrefix("absence-") ? String(id.dropFirst("absence-".count)) : ""
        guard Py.isDigits(digits), let wanted = Int(digits),
              let absence = try await absences(profile).first(where: { $0.id == wanted }) else { throw MapError.notFound("absence \(id)") }
        if !absence.editable { throw MapError.conflict("This absence can no longer be changed") }
        return absence
    }

    /// Change an absence's dates or comment.
    ///
    /// Payload from the portal bundle (app.*.js, the register-vacation drawer's `updateVacation` ->
    /// UPDATE_SIMPLE_EVENT in 0.*.js, POST `?method=calendar.updateSimpleEvent`): the event read by
    /// `calendar.getEventById` (`eventId`) gives `title`, `responseRequired`, `addedToInstitutionCalendar`,
    /// `hideInOwnCalendar` and `canEditStartDate` (the drawer locks the start date unless it is true);
    /// dates are "YYYY-MM-DD", `description` the plain comment. The store's `w()` adds
    /// `addToInstitutionCalendar` when `hideInOwnCalendar` is set. Never tried against live Aula.
    func updateAbsence(_ profile: AulaProfile, _ id: String, _ start: Day, _ end: Day, _ comment: String) async throws {
        let today = AulaTime.today()
        if end < today { throw MapError.badRequest("end date \(end.iso) is in the past") }
        // The start date's own rule waits for the event: an unchanged start may be in the past.
        if let err = Self.validateVacation(start: start, end: end, comment: comment, today: min(start, today)) {
            throw MapError.badRequest(err)
        }
        let absence = try await editableAbsence(profile, id)
        guard let event = J.dict(J.get(try await get("calendar.getEventById", [("eventId", String(absence.id))]), "data")) else {
            throw MapError.upstream("Aula sent no event for \(id)")
        }
        if start != (Self.date(J.get(event, "startDateTime")) ?? absence.start) {
            if J.bool(J.get(event, "canEditStartDate")) != true {
                throw MapError.badRequest("the start date can no longer be changed")
            }
            if let err = Self.validateVacation(start: start, end: end, comment: comment, today: today) { throw MapError.badRequest(err) }
        }
        let hide = J.get(event, "hideInOwnCalendar")
        var body: JSONObject = [
            "eventId": absence.id,
            "startDateTime": start.iso,
            "endDateTime": end.iso,
            "type": "presence_holiday",
            "description": comment,
            "title": J.get(event, "title") ?? "",
            "allDay": true,
            "private": false,
            "responseRequired": J.get(event, "responseRequired") ?? NSNull(),
            "addedToInstitutionCalendar": J.get(event, "addedToInstitutionCalendar") ?? NSNull(),
            "hideInOwnCalendar": hide ?? NSNull(),
            "isEditEvent": true,
        ]
        if J.truthy(hide) { body["addToInstitutionCalendar"] = hide! }
        _ = try await post("calendar.updateSimpleEvent", body)
    }

    /// Cancel an absence. From the portal bundle (app.*.js drawer `deleteVacation` -> DELETE_EVENT in
    /// 0.*.js: POST `?method=calendar.deleteEvent` with `{id, occurrenceDateTime}`; the latter is unset
    /// for an absence, so not sent). Never tried against live Aula.
    func deleteAbsence(_ profile: AulaProfile, _ id: String) async throws {
        let absence = try await editableAbsence(profile, id)
        _ = try await post("calendar.deleteEvent", ["id": absence.id] as JSONObject)
    }

    // MARK: contacts

    /// `GET /contacts/groups`: one getGroupsByContext call per child, so each group is paired with its
    /// child whatever Aula's outer entries are (per child or per institution).
    func contactGroups(_ profile: AulaProfile) async throws -> [JSONObject] {
        var out: [JSONObject] = []
        for child in profile.children {
            var seen = Set<Int>()
            for entry in try await getGroupsByContext(child.id) {
                for case let g as JSONObject in J.list(J.get(entry, "groups")) ?? [] {
                    guard let id = J.int(J.get(g, "id")), seen.insert(id).inserted else { continue }
                    out.append(["id": id, "name": J.str(J.get(g, "name")) ?? "", "child": child.name ?? ""])
                }
            }
        }
        return out
    }

    /// `GET /contacts/groups/{id}`: the children with their guardians (filter child, whose rows carry
    /// `relations`), then the staff (filter employee).
    func groupContacts(_ groupId: Int) async throws -> JSONObject {
        // Children without an id are left out. Guardians and staff carry none in the answer: the portal keys
        // relation rows by index, so they may have no id.
        let children = try await getContactList(group: groupId, filter: "child").compactMap { row -> JSONObject? in
            guard let id = J.int(J.get(row, "id")) else { return nil }
            let guardians = (J.list(J.get(row, "relations")) ?? []).compactMap { $0 as? JSONObject }.map { Self.contactOut($0, topLevel: false) }
            return ["id": id, "name": Self.contactName(row), "guardians": guardians]
        }
        let staff = try await getContactList(group: groupId, filter: "employee").map { Self.contactOut($0, topLevel: true) }
        return ["children": children, "staff": staff]
    }

    static func contactName(_ p: JSONObject) -> String {
        if let full = nonEmpty(J.str(J.get(p, "fullName"))) { return full }
        return [J.get(p, "firstName"), J.get(p, "lastName")].compactMap { J.str($0) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A guardian or staff member, with only what the portal shows (ContactsFragment's contact row): details
    /// only with `userHasGivenConsentToShowContactInformation`, and on a top-level row (staff) also
    /// `currentUserCanViewContactInformation`; no address for a child, no home phone for a group home.
    /// Aula may send fields the portal hides, so the gate is here and not in the view.
    static func contactOut(_ p: JSONObject, topLevel: Bool) -> JSONObject {
        let shared = J.bool(J.get(p, "userHasGivenConsentToShowContactInformation")) == true
            && (!topLevel || J.bool(J.get(p, "currentUserCanViewContactInformation")) == true)
        let groupHome = J.str(J.get(p, "contactType")) == "groupHome"
        var phones: [JSONObject] = []
        var address: String?
        var email: String?
        if shared {
            let numbers: [(String, String)] = groupHome
                ? [("mobilePhoneNumber", "Primary"), ("workPhoneNumber", "Secondary")]
                : [("homePhoneNumber", "Home"), ("mobilePhoneNumber", "Mobile"), ("workPhoneNumber", "Work")]
            for (key, label) in numbers {
                if let n = nonEmpty(J.str(J.get(p, key)).map(Py.strip)) { phones.append(["label": label, "number": n]) }
            }
            email = nonEmpty(J.str(J.get(p, "email")).map(Py.strip))
            if J.str(J.get(p, "role")) != "child" { address = contactAddress(J.get(p, "address")) }
        }
        return [
            "name": contactName(p), "relation": J.out(nonEmpty(J.str(J.get(p, "relation")))),
            "shared": shared, "phones": phones, "email": J.out(email), "address": J.out(address),
        ]
    }

    /// The portal's generateAddress ("street, postalCode postalDistrict"), leaving out what's unknown;
    /// the portal writes a street of "Ukendt" for none.
    static func contactAddress(_ a: Any?) -> String? {
        guard let street = nonEmpty(J.str(J.get(a, "street")).map(Py.strip)), street != "Ukendt" else { return nil }
        let town = [J.get(a, "postalCode"), J.get(a, "postalDistrict")].compactMap { $0 }.map(J.pyStr).filter { !$0.isEmpty }
        return town.isEmpty ? street : "\(street), \(town.joined(separator: " "))"
    }

    // MARK: posts

    func postOut(_ post: AulaPost) -> JSONObject {
        let author = [Self.nonEmpty(post.ownerFullName) ?? post.ownerRole, post.ownerInstitutionName]
            .compactMap { Self.nonEmpty($0) }.joined(separator: " · ")
        return [
            "id": post.id,
            "title": Self.nonEmpty(post.title) ?? "",
            "author": author,
            "authorPicture": J.out(pictureId(post.ownerPicture, register: true)),
            "date": J.out(AulaTime.iso(post.timestamp)),
            "body": Self.plain(post.contentHTML),
            "important": post.isImportant,
            "saved": post.isBookmarked,
            "attachments": mapAttachments(post.attachments),
        ]
    }

    func posts(_ profile: AulaProfile, page: Int = 1, limit: Int = 10) async throws -> [JSONObject] {
        // A post without a timestamp has no valid "date" for the app; skip it.
        try await getPosts(profile.institutionProfileIds, page: page, limit: limit).filter { $0.timestamp != nil }.map(postOut)
    }

    // MARK: gallery

    static let taggedAlbum = 0

    private func galleryGet(_ method: String, _ params: [(String, String)]) async throws -> Any? {
        J.get(try await get(method, params), "data", default: nil)
    }

    func albums(_ profile: AulaProfile, page: Int = 1, limit: Int = 20) async throws -> [JSONObject] {
        let data = try await galleryGet("gallery.getAlbums", [
            ("index", String((page - 1) * limit)), ("limit", String(limit)), ("sortOn", "createdAt"),
            ("orderDirection", "desc"), ("filterBy", "all"),
        ] + Self.ids("filterInstProfileIds[]", profile.institutionProfileIds))
        var out: [JSONObject] = []
        for a in J.list(data) ?? [] {
            let id = J.get(a, "id", default: nil)
            guard J.dict(a) != nil, J.int(id) != nil || (id == nil && page == 1) else { continue }
            // Live: on page 1 a row with id null comes first, Aula's virtual album of photos the child is
            // tagged in. It doesn't count towards `limit`; it's served as album 0 (see albumPhotos).
            let thumbs = (J.list(J.get(a, "thumbnailsUrls", default: nil)) ?? []).compactMap { $0 as? String }
            out.append([
                "id": J.int(id) ?? Self.taggedAlbum,
                "title": J.or(J.get(a, "title", default: nil), "") ?? "",
                "date": J.out(AulaTime.iso(J.get(a, "creationDate", default: nil))),
                "cover": J.out(thumbs.first.flatMap { pictureId($0, register: true) }),
                "tagged": id == nil,
            ])
        }
        return out
    }

    func albumPhotos(_ profile: AulaProfile, _ albumId: Int, page: Int = 1, limit: Int = 60) async throws -> [JSONObject] {
        // The tagged album has no id: Aula asks for it as userSpecificAlbum without albumId.
        let album: [(String, String)] = albumId == Self.taggedAlbum
            ? [("userSpecificAlbum", "true")] : [("albumId", String(albumId)), ("userSpecificAlbum", "false")]
        let data = try await galleryGet("gallery.getMedia", album + [
            ("index", String((page - 1) * limit)), ("limit", String(limit)), ("sortOn", "uploadedAt"),
            ("orderDirection", "desc"), ("filterBy", "all"),
        ] + Self.ids("filterInstProfileIds[]", profile.institutionProfileIds))
        return (J.list(J.getIn(data, "results")) ?? []).compactMap(photoOut)
    }

    /// One gallery.getMedia result (also a search.findGeneric Media result) as a Photo.
    /// A video's `image` is its still (Aula's thumbnails are frames of it) and `video` the mp4.
    func photoOut(_ p: Any) -> JSONObject? {
        guard J.dict(p) != nil, let id = J.int(J.get(p, "id", default: nil)),
              let file = pictureId(J.getIn(p, "file.url"), register: true) else { return nil }
        // Live sizes (one photo): large 900x1200, medium 600x800, small 300x400 (~55 kB), extraSmall 150x200.
        // Small fills a third of a phone's width at 3x.
        let thumb = pictureId(J.or(J.get(p, "smallThumbnailUrl", default: nil), J.get(p, "thumbnailUrl", default: nil)), register: true)
        var out: JSONObject = ["id": id, "date": J.out(AulaTime.iso(J.getIn(p, "file.created")))]
        switch J.get(p, "mediaType", default: nil) as? String {
        case "image":
            out["thumbnail"] = thumb ?? file
            out["image"] = file
        case "video":
            // The portal skips playing these too (conversionStatus completed|processing|failed).
            guard !["processing", "failed"].contains(J.get(p, "conversionStatus", default: nil) as? String) else { return nil }
            // The portal shows the large thumbnail as the still, when there is one.
            out["thumbnail"] = thumb
            out["image"] = pictureId(J.get(p, "largeThumbnailUrl", default: nil), register: true) ?? thumb
            out["video"] = file
        default: return nil
        }
        return out
    }

    // MARK: search

    static let searchTypes = ["messages": "ThreadMessage", "posts": "Post", "photos": "Media"]

    /// Aula's global search, one docType per call. Params from the portal bundle (app.*.js globalSearch
    /// store: limit, offset, institutionProfileIds = the user's own (activeInstitutionProfiles),
    /// activeChildrenInstitutionProfileIds, text, docType, docTypeCount; Media adds sortOn/orderDirection).
    /// Result fields from live answers (docs/aula-shapes/search.findGeneric.json): a Post result is a
    /// post with `creator` for getAllPosts' `ownerProfile` and `content` as the HTML string, no isBookmarked.
    func search(_ profile: AulaProfile, _ text: String, type: String, page: Int, limit: Int = 20, skips: Int = 0) async throws -> JSONObject {
        guard let docType = Self.searchTypes[type] else { throw MapError.badRequest("type must be messages, posts or photos") }
        var params = [("text", text), ("docType", docType), ("docTypeCount", "true"),
                      ("limit", String(limit)), ("offset", String((page - 1) * limit))]
            + Self.ids("institutionProfileIds[]", profile.guardianIds.sorted())
            + Self.ids("activeChildrenInstitutionProfileIds[]", profile.children.map(\.id))
        if docType == "Media" { params += [("sortOn", "datetime"), ("orderDirection", "desc")] }
        let data = J.get(try await get("search.findGeneric", params), "data", default: nil)
        var counts: JSONObject = ["messages": 0, "posts": 0, "photos": 0]
        for c in J.list(J.get(data, "docTypeCount", default: nil)) ?? [] {
            if let key = Self.searchTypes.first(where: { J.eq(J.get(c, "key"), $0.value) })?.key {
                counts[key] = J.int(J.get(c, "count")) ?? 0
            }
        }
        let results = J.list(J.get(data, "results", default: nil)) ?? []
        var out: JSONObject = ["counts": counts, "messages": [Any](), "posts": [Any](), "photos": [Any]()]
        switch type {
        case "messages":
            out["messages"] = results.compactMap { r -> JSONObject? in
                guard J.eq(J.get(r, "docType"), "ThreadMessage"), let thread = J.get(r, "threadId"), !J.isNone(thread),
                      let date = AulaTime.iso(J.get(r, "latestMessageSendTime")) else { return nil }
                return [
                    "id": J.pyStr(J.or(J.get(r, "messageId"), J.get(r, "id"))),
                    "threadId": J.pyStr(thread),
                    "subject": J.or(J.get(r, "title"), "") ?? "",
                    "from": J.or(J.get(r, "author"), "") ?? "",
                    "preview": Self.preview(J.str(J.get(r, "message")) ?? ""),
                    "date": date,
                ]
            }
        case "posts":
            out["posts"] = results.compactMap { r -> JSONObject? in
                guard var d = J.dict(r), J.eq(d["docType"], "Post") else { return nil }
                if let id = J.str(d["id"]).flatMap({ Int($0) }) { d["id"] = id }
                d["ownerProfile"] = d["creator"]
                if let html = J.str(d["content"]) { d["content"] = ["html": html] as JSONObject }
                guard let post = try? AulaPost(d), post.timestamp != nil else { return nil }
                return postOut(post)
            }
        default:
            out["photos"] = (J.list(J.get(data, "mediaResults", default: nil)) ?? []).compactMap(photoOut)
        }
        // An Aula page whose hits were all left out (converting videos, threadless messages) would read as the end
        // to the client, so answer the next Aula page instead; the client drops the repeats by id.
        // ponytail: at most 5 pages skipped in one call; a longer run of left-out hits still ends the list.
        let raw = (J.list(J.get(data, "mediaResults", default: nil)) ?? []).count + results.count
        if (out[type] as? [Any])?.isEmpty == true, raw > 0, skips < 5, page < 100 {
            return try await search(profile, text, type: type, page: page + 1, limit: limit, skips: skips + 1)
        }
        return out
    }

    /// Endpoints from the portal bundle (10.*.js): POST ?method=posts.bookmark / posts.unbookmark
    /// with body {postId}. Not in the library.
    func setBookmark(_ postId: Int, _ saved: Bool) async throws {
        _ = try await post(saved ? "posts.bookmark" : "posts.unbookmark", ["postId": postId])
    }

    // MARK: messages

    private static let shownTypes: Set<String> = ["Message", "MessageEdited", "AutoReply", "Forward"]

    static func senderName(_ sender: Any?) -> Any? { J.or(J.getIn(sender, "fullName"), J.getIn(sender, "answerDirectlyName")) }

    /// getThreads rows (live) have no picture on creator or latestMessage.sender; the same person's
    /// entry in recipients (matched by mailbox owner id) has it.
    static func rowPicture(_ sender: Any?, _ raw: JSONObject) -> Any? {
        let owner = J.getIn(sender, "mailBoxOwner.id")
        let match = (J.list(J.or(raw["recipients"], nil)) ?? []).first {
            $0 is JSONObject && J.eq(J.getIn($0, "mailBoxOwner.id"), owner)
        }
        return J.or(J.getIn(sender, "profilePicture"), owner != nil ? J.getIn(match, "profilePicture") : nil)
    }

    /// A message's HTML as one line of at most 140 characters.
    static func preview(_ html: String) -> String {
        let text = Py.split(plain(html)).joined(separator: " ")
        return Py.len(text) > 140 ? Py.rstrip(Py.prefix(text, 139)) + "…" : text
    }

    /// One row of messaging.getThreads. Field names (read, muted, marked, recipients[].leaveTime,
    /// latestMessage.text.html / sendDateTime, creator) are the ones the portal reads;
    /// latestMessage.sender is a guess with creator as fallback.
    func threadOut(_ raw: JSONObject, register: Bool) -> JSONObject {
        let latest = J.dict(J.or(raw["latestMessage"], nil)) ?? [:]
        let recipients = (J.list(J.or(raw["recipients"], nil)) ?? []).filter { ($0 is JSONObject) && J.get($0, "leaveTime") == nil }
        let preview = Self.preview(J.str(J.or(J.getIn(latest, "text.html"), "")) ?? "")
        let sender = J.truthy(Self.senderName(J.get(latest, "sender"))) ? J.get(latest, "sender") : J.get(raw, "creator")
        let participants = recipients.count > 0 ? recipients.count : (J.list(J.or(raw["participants"], nil)) ?? []).count
        return [
            "id": J.pyStr(raw["id"]),
            "subject": J.or(raw["subject"], "") ?? "",
            "from": J.or(Self.senderName(sender), "") ?? "",
            // No picture without a register: /today only reads rows for attention items.
            "picture": J.out(pictureId(Self.rowPicture(sender, raw), register: register)),
            "participants": participants,
            "preview": preview,
            "date": J.out(AulaTime.iso(J.or(J.get(latest, "sendDateTime"), J.get(raw, "lastUpdatedDate")))),
            "unread": !J.truthy(J.get(raw, "read", default: true)),
            "muted": J.truthy(raw["muted"]),
            "starred": J.truthy(raw["marked"]),
            "folderId": J.out(raw["folderId"]),
        ]
    }

    /// One page of threads, newest first. Aula's pages are 0-based; past the end it returns none.
    ///
    /// `folder` lists one folder: the portal adds `folderId` to getThreads' params, and leaves it out
    /// for the inbox (0.*.js, "inbox"!=t.folderId&&(_.folderId=...)). The folder listing is not tried
    /// live (the portal also sends mailBoxOwnerIds; we don't). `collect` keeps the raw rows by thread
    /// id, for updateThread.
    func threads(page: Int = 0, folder: Int? = nil, collect: Bool = false, register: Bool = false) async throws -> [JSONObject] {
        let raws: [JSONObject]
        if page == 0 && folder == nil {
            raws = try await getMessageThreads()
        } else {
            // The library only reads page 0 of the inbox; same request as its get_all_message_threads_result.
            var params = [("sortOn", "date"), ("orderDirection", "desc"), ("page", String(page))]
            if let folder { params.append(("folderId", String(folder))) }
            let r = try await get("messaging.getThreads", params)
            raws = (J.list(J.getIn(r, "data.threads")) ?? []).compactMap { $0 as? JSONObject }
        }
        if collect {
            for raw in raws where !J.isNone(raw["id"]) { local.threadRows[J.pyStr(raw["id"])] = raw }
        }
        // "date" is non-nullable in API.md; a row without any timestamp is skipped.
        return raws.map { threadOut($0, register: register) }.filter { !J.isNone($0["date"]) }
    }

    func postAula(_ method: String, _ body: JSONObject) async throws {
        _ = try await post(method, body)
    }

    // Folders. Bodies from the portal bundle (app.*.js folder modal, 0.*.js store):
    // createFolder {folderName}, updateFolder {folderName, folderId}, deleteFolder {folderId};
    // getFolders also returns Aula's own "Slettet post" folder (type "deleted", enum in 0.*.js),
    // which is not the user's to rename, delete or move into. Never tried against live Aula
    // (the getFolders row shape, incl. "type", is from the bundle, not a logged response).

    func folders() async throws -> [JSONObject] {
        try await getMessageFolders().filter(\.isNormal).map { ["id": J.out($0.id), "name": J.out($0.name)] }
    }

    static func folderName(_ name: String) throws -> String {
        let name = Py.strip(name)
        let n = Py.len(name)
        if !(1...100).contains(n) { throw MapError.badRequest("name must be 1–100 characters") }  // the portal's isValidFolderName
        return name
    }

    private func folder(_ folderId: Int) async throws -> JSONObject {
        guard let found = try await folders().first(where: { J.int($0["id"]) == folderId }) else { throw MapError.notFound("folder \(folderId)") }
        return found
    }

    func createFolder(_ rawName: String) async throws -> JSONObject {
        let name = try Self.folderName(rawName)
        let before = Set(try await folders().map { J.pyStr($0["id"]) })
        try await postAula("messaging.createFolder", ["folderName": name])
        // The portal ignores the answer and reloads the folders; so do we.
        let new = try await folders().filter { !before.contains(J.pyStr($0["id"])) }
        guard let found = new.first(where: { J.eq($0["name"], name) }) ?? new.first else {
            throw MapError.upstream("Aula did not show the new folder")
        }
        return found
    }

    func renameFolder(_ folderId: Int, _ rawName: String) async throws -> JSONObject {
        let name = try Self.folderName(rawName)
        _ = try await folder(folderId)
        try await postAula("messaging.updateFolder", ["folderName": name, "folderId": folderId])
        return ["id": folderId, "name": name]
    }

    /// Aula deletes the folder's messages with it (portal's confirm text).
    func deleteFolder(_ folderId: Int) async throws {
        _ = try await folder(folderId)
        try await postAula("messaging.deleteFolder", ["folderId": folderId])
    }

    /// Mute, star ("marked") and move one thread, like the portal's swipe actions on a thread row
    /// (app.*.js subscription list item), which all name the row's subscriptionId, never the thread id:
    ///
    /// - setThreadsMuted {muted, subscriptionIds:[s], commonInboxId:null, otpInboxId:null} (setThreadMutedStatus)
    /// - setThreadsMarked {threadIds:[], subscriptionIds:[s], marked, commonInboxId:null, otpInboxId:null}
    ///   (markSubscriptionToggle -> SWITCH_MARK_SUBSCRIPTIONS in 0.*.js)
    /// - moveThreadsToFolder {folderId, threadIds:[], subscriptionIds:[s], commonInboxId:null}
    ///   (move-to-folder-modal subscription-ids -> MOVE_THREADS_TO_FOLDER; null = inbox)
    ///
    /// The subscription id is only in getThreads rows (not in getMessagesForThread), so the row must
    /// have been listed. Never tried against live Aula.
    func updateThread(_ threadId: String, _ changes: ThreadChanges) async throws -> JSONObject {
        var raw = local.threadRows[threadId]
        if raw == nil {
            _ = try await threads(page: 0, collect: true)
            raw = local.threadRows[threadId]
        }
        guard var row = raw, let subscriptionId = J.get(row, "subscriptionId") else {
            throw MapError.conflict("Thread not in the listed threads; reload the list and try again")
        }
        if case let .some(.some(folderId)) = changes.folderId,
           !(try await folders()).contains(where: { J.int($0["id"]) == folderId }) {
            throw MapError.badRequest("unknown folder \(folderId)")
        }
        local.threadRows[threadId] = row  // a copy, updated as each write lands
        if let muted = changes.muted {
            try await postAula("messaging.setThreadsMuted", [
                "muted": muted, "subscriptionIds": [subscriptionId], "commonInboxId": NSNull(), "otpInboxId": NSNull(),
            ])
            row["muted"] = muted
            local.threadRows[threadId] = row
        }
        if let starred = changes.starred {
            try await postAula("messaging.setThreadsMarked", [
                "threadIds": [Any](), "subscriptionIds": [subscriptionId], "marked": starred,
                "commonInboxId": NSNull(), "otpInboxId": NSNull(),
            ])
            row["marked"] = starred
            local.threadRows[threadId] = row
        }
        if let folderId = changes.folderId {
            try await postAula("messaging.moveThreadsToFolder", [
                "folderId": J.out(folderId), "threadIds": [Any](), "subscriptionIds": [subscriptionId], "commonInboxId": NSNull(),
            ])
            row["folderId"] = J.out(folderId)
            local.threadRows[threadId] = row
        }
        return threadOut(row, register: true)
    }

    /// Portal (app.*.js senderIsSelf): sender.mailBoxOwner.id is one of the user's institution profile ids.
    static func fromMe(_ message: Any?, _ mine: Set<Int>) -> Bool {
        J.int(J.getIn(message, "sender.mailBoxOwner.id")).map(mine.contains) ?? false
    }

    func threadMeta(_ threadId: String) async throws -> JSONObject {
        let r = try await get("messaging.getMessagesForThread", [("threadId", threadId), ("page", "0"), ("limit", "20")])
        guard let data = J.dict(r["data"]) else { throw MapError.notFound("thread \(threadId)") }
        return data
    }

    func threadDetail(_ profile: AulaProfile, _ threadId: String) async throws -> JSONObject {
        let meta = try await threadMeta(threadId)
        let rawMessages = try await getAllMessagesForThread(threadId)
        let mine = profile.guardianIds
        let shown = rawMessages.filter {
            (J.str($0["messageType"]).map(Self.shownTypes.contains) ?? false) && AulaTime.iso($0["sendDateTime"]) != nil
        }
        let newest = shown.first.flatMap { J.val($0["id"]) }
        // Aula sends newest first; the app gets oldest first.
        let messages: [JSONObject] = shown.reversed().map { m in
            let textHTML = J.str(J.getIn(m, "text.html"))
            let text = Self.nonEmpty(textHTML) ?? (m["text"] as? String ?? "")
            return [
                "id": J.pyStr(m["id"]),
                "sender": J.or(Self.senderName(m["sender"]), "") ?? "",
                "picture": J.out(pictureId(J.getIn(m, "sender.profilePicture"), register: true)),
                "fromMe": Self.fromMe(m, mine),
                "date": J.out(AulaTime.iso(m["sendDateTime"])),
                "text": Self.plain(text),
                "attachments": mapAttachments(AulaAttachment.parse(m["attachments"])),
            ]
        }
        if J.truthy(newest) && !J.eq(J.get(meta, "lastReadMessageId"), newest) {
            _ = try await Self.optional("mark thread read") { try await self.markThreadRead(threadId) }
        }
        return [
            "id": threadId,
            "subject": J.or(meta["subject"], "") ?? "",
            "canReply": !J.truthy(meta["isArchived"]) && J.get(meta, "leaveTime") == nil,
            "messages": messages,
        ]
    }

    static func intOrStr(_ value: String) -> Any { Py.isDigits(value) ? (Int(value) ?? value) as Any : value }

    /// Body from the portal bundle (0.*.js REPLY_MESSAGE): {threadId, message:{text, attachmentIds}, commonInboxId, otpInboxId}.
    func replyAll(_ threadId: String, _ text: String) async throws -> String {
        try await postAula("messaging.reply", [
            "threadId": Self.intOrStr(threadId),
            "message": ["text": Self.textToHTML(text), "attachmentIds": [Any]()] as JSONObject,
            "commonInboxId": NSNull(),
            "otpInboxId": NSNull(),
        ])
        return threadId
    }

    /// Portal's mapInstitutionProfileToRecipient(message.sender) + the NewMessage recipient class
    /// (app.*.js): id is the sender's mailbox owner id (forwardMessage overwrites sender.id with
    /// sender.mailBoxOwner.id), and an OTP/common inbox sender turns the type into that inbox.
    static func recipientFromSender(_ sender: JSONObject) -> JSONObject {
        let owner = J.dict(J.or(sender["mailBoxOwner"], nil)) ?? [:]
        let ownerType = J.get(owner, "mailBoxOwnerType")
        let ownerId = J.or(J.get(owner, "id"), J.get(sender, "id"))
        let otp = J.eq(ownerType, "otpInbox") ? ownerId : nil
        let common = J.eq(ownerType, "commonInbox") ? ownerId : nil
        let fullName = J.get(sender, "fullName"), metadata = J.get(sender, "metadata")
        return [
            "id": J.out(ownerId),
            "profileId": J.out(J.get(sender, "profileId")),
            "mailBoxOwnerType": J.truthy(otp) ? "otpInbox" : J.truthy(common) ? "commonInbox" : "institutionProfile",
            "otpInboxId": J.out(otp),
            "commonInboxId": J.out(common),
            "name": J.out(fullName),
            "fullName": J.out(fullName),
            "metadata": J.out(metadata),
            "label": J.truthy(metadata) ? "\(J.pyStr(fullName)) (\(J.pyStr(metadata)))" : J.out(fullName),
            "institutionCode": J.out(J.get(sender, "institutionCode")),
            "type": "profile",
            "portalRole": J.out(J.get(sender, "role")),
        ]
    }

    /// startNewThread's answer. The portal opens `response.data.data.data` (handleSendMessageResponse),
    /// i.e. body.data.data; unverified live, so a bare id or an object with data/id/threadId is accepted.
    static func newThreadId(_ data: Any?) -> String? {
        guard let data = J.val(data), !J.isBool(data) else { return nil }
        if let s = data as? String { return s.isEmpty ? nil : s }
        if let i = J.int(data) { return String(i) }
        if let d = data as? JSONObject {
            for key in ["data", "threadId", "id", "subscriptionId"] {
                if let found = newThreadId(d[key]), !found.isEmpty { return found }
            }
        }
        return nil
    }

    /// Aula's "Svar afsender direkte" (ANSWER_DIRECTLY): a new thread to the sender of one message
    /// only, via messaging.startNewThread.
    ///
    /// Shape from the portal bundle (app.*.js / 0.*.js):
    /// - START_NEW_THREAD body: {subject, recipients, bccRecipients, sensitive, creator:{id,
    ///   mailBoxOwnerType}, message:{text, attachmentIds}, forwardInfo}
    /// - a guardian's creator is their institution profile for the thread's institution, with
    ///   mailBoxOwnerType "institutionProfile"
    /// - subject "Vs. " + subject and sensitivity from messaging.getMessageInfoLight (populateRelatedMessageInfo)
    /// - forwardInfo for ANSWER_DIRECTLY: {forwardedThreadId, forwardedMessageIds:[id], directReply:true}
    func replySender(_ profile: AulaProfile, _ threadId: String, _ messageId: String, _ text: String) async throws -> String? {
        let mine = profile.guardianIds
        let rawMessages = try await getAllMessagesForThread(threadId)
        guard let message = rawMessages.first(where: { J.pyStr($0["id"]) == messageId }) else { throw MapError.notFound("message \(messageId)") }
        if Self.fromMe(message, mine) { throw MapError.badRequest("messageId is one of your own messages") }
        if J.bool(message["canReplyToMessage"]) == false { throw MapError.badRequest("Aula does not allow a direct reply to this message") }

        let info = try await opt("message info") { try await getMessageInfo(threadId, messageId) } ?? nil ?? [:]
        let meta = try await threadMeta(threadId)
        var subject = J.or(J.get(info, "subject"), J.get(meta, "subject"))
        if !J.truthy(subject) {
            let rows = try await opt("threads") { try await getMessageThreads() } ?? []
            subject = rows.first { J.pyStr($0["id"]) == threadId }.flatMap { J.get($0, "subject") }
        }
        guard J.truthy(subject) else { throw MapError.upstream("could not read the thread subject for a direct reply") }
        let sender = J.dict(J.or(J.getIn(info, "message.sender"), J.or(J.get(message, "sender"), nil))) ?? [:]
        let owner = J.dict(J.or(meta["mailBoxOwner"], nil)) ?? [:]
        var creatorId: Any? = J.eq(J.get(owner, "mailBoxOwnerType"), "institutionProfile") ? J.get(owner, "id") : nil
        if creatorId == nil { creatorId = mine.sorted().first }
        guard let creatorId, J.truthy(J.getIn(sender, "mailBoxOwner.id")) else {
            throw MapError.upstream("could not work out sender or recipient for a direct reply")
        }
        let sensitive = J.has(info, "isSensitive") ? J.get(info, "isSensitive") : J.get(meta, "sensitive", default: false)
        let r = try await post("messaging.startNewThread", [
            "subject": "Vs. \(J.pyStr(subject))",
            "recipients": [Self.recipientFromSender(sender)],
            "bccRecipients": [Any](),
            "sensitive": J.truthy(sensitive),
            "creator": ["id": creatorId, "mailBoxOwnerType": "institutionProfile"] as JSONObject,
            "message": ["text": Self.textToHTML(text), "attachmentIds": [Any]()] as JSONObject,
            "forwardInfo": [
                "forwardedThreadId": Self.intOrStr(threadId),
                "forwardedMessageIds": [J.out(message["id"])],
                "directReply": true,
            ] as JSONObject,
        ] as JSONObject)
        return Self.newThreadId(r["data"])
    }
}

/// Raw JSON carried out of a concurrent read and straight back into the actor. JSONSerialization's
/// output is immutable Foundation objects, so this is safe to hand across.
struct SendableJSON: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// Python's `urlsplit`, as far as the URL checks need it.
struct URLParts {
    var scheme = ""
    var netloc = ""
    var path = ""
    var hasNetloc = false

    init(_ url: String) {
        var rest = Substring(url)
        if let colon = rest.firstIndex(of: ":"), colon != rest.startIndex,
           rest[..<colon].first!.isLetter,
           rest[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) {
            scheme = rest[..<colon].lowercased()
            rest = rest[rest.index(after: colon)...]
        }
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            let end = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
            netloc = String(rest[..<end])
            hasNetloc = true
            rest = rest[end...]
        }
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        if let q = rest.firstIndex(of: "?") { rest = rest[..<q] }
        path = String(rest)
    }

    /// `hostname`: lower-cased, without userinfo and port.
    var hostname: String? {
        guard hasNetloc else { return nil }
        var host = Substring(netloc)
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            return host[host.index(after: host.startIndex)..<close].lowercased()
        }
        if let colon = host.firstIndex(of: ":") { host = host[..<colon] }
        return host.isEmpty ? nil : host.lowercased()
    }

    /// `parts._replace(query="", fragment="").geturl()`.
    var withoutQuery: String {
        var out = scheme.isEmpty ? "" : scheme + ":"
        if hasNetloc || scheme == "https" || scheme == "http" { out += "//" + netloc }
        return out + path
    }
}
