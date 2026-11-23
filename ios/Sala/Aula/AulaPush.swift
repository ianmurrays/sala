import Foundation

// The old server's push rules (push.py, API.md → Push), over raw Aula rows:
// `/threads` and `/today` drop what they need (mailbox ids, extraRecipientsCount, the deadline date).
// Background refresh (BackgroundRefresh.swift) turns these into local notifications.

struct PushEvent: Equatable, Sendable {
    var key: String
    var title: String
    var subtitle: String?
    /// A one-line excerpt of the message; nil for a sensitive thread (Aula hides those behind a second login).
    var body: String?
    var link: String = "sala://today"
    /// False: only remember it (a group or muted thread, a read one).
    var notify = true
    /// When it was sent, if known; an item older than its kind's seeding never notifies.
    var at: Date?
    /// Keys also marked seen when this one is posted.
    var covers: [String] = []
    /// Shown no earlier than this (07:00 on a deadline reminder's day).
    var notBefore: Date?
}

enum Push {
    static let kinds = ["message", "post", "holiday"]
    static let reminderHour = 7

    private static func owner(_ person: Any?) -> Int? { J.int(J.getIn(person, "mailBoxOwner.id")) }

    /// The thread's other participants by mailbox id, and how many others the row leaves out.
    /// Read the way the portal reads it (app.*.js getExtraRecipientsCount); see push.py `_others`.
    static func others(_ raw: JSONObject, mine: Set<Int>) -> (people: [Int: Any], extra: Int) {
        let extra = J.int(J.get(raw, "extraRecipientsCount")) ?? 0
        var people: [Int: Any] = [:]
        for r in J.list(J.get(raw, "recipients")) ?? [] where J.dict(r) != nil && J.get(r, "leaveTime") == nil {
            if let id = owner(r), people[id] == nil { people[id] = r }
        }
        if extra == 0 {  // otherwise they are likely among the extra recipients already
            for p in [J.get(raw, "creator"), J.getIn(raw, "latestMessage.sender")] {
                if let id = owner(p), people[id] == nil { people[id] = p! }
            }
        }
        let me = owner(raw)
        return (people.filter { !mine.contains($0.key) && $0.key != me }, extra)
    }

    /// The event for one getThreads row's newest message.
    ///
    /// Live rows have no `latestMessage.sender`, and reading the thread to find it could mark it read
    /// in Aula, so "not from me" is the row's `read == false` (sending marks a thread read). Any unread,
    /// unmuted thread notifies, group threads too, as the Aula app does. The title is the one other person
    /// when the row lists only one (subject as subtitle), else the subject, else "New message".
    static func messageEvent(_ raw: JSONObject, mine: Set<Int>) -> PushEvent? {
        let latest = J.get(raw, "latestMessage")
        guard let tid = J.val(raw["id"]), let mid = J.val(J.or(J.get(latest, "id"), J.get(latest, "sendDateTime"))) else { return nil }
        let people = others(raw, mine: mine).people
        let unread = !J.truthy(J.get(raw, "read", default: true))
        let name = people.count == 1 ? J.str(Aula.senderName(people.first!.value)).flatMap(Aula.nonEmpty) : nil
        let subject = J.str(raw["subject"]).flatMap(Aula.nonEmpty)
        let excerpt = J.truthy(raw["sensitive"]) ? nil : J.str(J.getIn(latest, "text.html")).map(Aula.preview).flatMap(Aula.nonEmpty)
        return PushEvent(
            key: "message:\(J.pyStr(tid)):\(J.pyStr(mid))",
            title: name ?? subject ?? "New message",
            subtitle: name == nil ? nil : subject,
            body: excerpt,
            link: "sala://thread/\(J.pyStr(tid))",
            notify: unread && !J.truthy(raw["muted"]),
            at: date(J.get(latest, "sendDateTime")))
    }

    static func postEvent(_ post: AulaPost) -> PushEvent? {
        guard post.isImportant else { return nil }
        return PushEvent(key: "post:\(post.id)", title: "Important post: \(Aula.nonEmpty(post.title) ?? "Untitled")",
                         at: date(post.timestamp))
    }

    /// The new-request event, plus a reminder the day before the deadline and on the deadline day.
    ///
    /// Each reminder key names its day, so it exists only on that day: never sent late or after the deadline.
    /// It waits until 07:00; a new-request event on such a day stands in for the reminder (covers it) and waits too.
    static func holidayEvents(_ reg: VacationRegistration, today: Day) -> [PushEvent] {
        guard reg.needsAnswer, let id = reg.id else { return [] }
        let start = Aula.localDate(reg.startDate), end = Aula.localDate(reg.endDate)
        let deadline = Aula.localDate(reg.responseDeadline)
        let label = Py.rstrip("Holiday request \(start.map { Aula.dateRangeLabel($0, end) } ?? reg.title ?? "")")
        // ponytail: no "high" priority; a time-sensitive local notification needs an entitlement a free team lacks.
        let daysLeft = deadline.map { $0.ordinal - today.ordinal }
        var reminder: PushEvent?
        if let deadline, let daysLeft, daysLeft == 0 || daysLeft == 1 {
            reminder = PushEvent(
                key: "holiday-due:\(id):\(deadline.iso):\(daysLeft)",
                title: label + (daysLeft == 0 ? " · answer today" : " · answer by tomorrow"),
                notBefore: Shared.calendar.date(from: DateComponents(year: today.year, month: today.month, day: today.day, hour: reminderHour)))
        }
        let request = PushEvent(
            key: "holiday:\(id)",
            title: label + (deadline.map { " · answer by \(Aula.shortDate($0))" } ?? ""),
            covers: reminder.map { [$0.key] } ?? [],
            notBefore: reminder?.notBefore)
        return [request] + (reminder.map { [$0] } ?? [])
    }

    /// One request per id from Aula's rows (one per child), skipping the children already answered for.
    static func holidayEvents(_ regs: [VacationRegistration], today: Day) -> [PushEvent] {
        var ids = Set<Int>()
        return regs.filter { $0.needsAnswer && ($0.id.map { ids.insert($0).inserted } ?? false) }
            .flatMap { holidayEvents($0, today: today) }
    }

    static func date(_ value: Any?) -> Date? {
        AulaTime.parse(value).map { Date(timeIntervalSince1970: TimeInterval($0.epoch)) }
    }
}

extension Aula {
    /// Current items per kind; nil for a kind whose read failed (neither seeded nor notified from).
    /// Throws `APIError.authRequired` when the session is gone; never starts a login.
    func pushEvents() async throws -> [String: [PushEvent]?] {
        do {
            let profile = try await profile()
            let mine = profile.guardianIds
            let today = AulaTime.today()
            let messages = try await opt("push: threads") { try await getMessageThreads().compactMap { Push.messageEvent($0, mine: mine) } }
            let posts = try await opt("push: posts") { try await getPosts(profile.institutionProfileIds).compactMap(Push.postEvent) }
            let holidays = try await opt("push: holiday requests") {
                Push.holidayEvents(try await getVacationRegistrations(profile.children.map(\.id)), today: today)
            }
            return ["message": messages, "post": posts, "holiday": holidays]
        } catch {
            throw Self.apiError(error)
        }
    }
}
