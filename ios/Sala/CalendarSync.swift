import EventKit
import Foundation

/// Settings → "Sync to iOS Calendar": Sala writes `GET /calendar` into a calendar of its own, on each
/// refresh. Sala owns that calendar, so it updates and removes events there by id (the event's URL)
/// and never touches any other calendar. Needs full access, to read back what it wrote earlier.
@MainActor
enum CalendarSync {
    private static let enabledKey = "calendarSync.enabled"
    private static let calendarKey = "calendarSync.calendarID"
    /// The current month and the next two.
    static let months = 3

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private static var lastSync: Date?

    /// Asks for full access; false when refused.
    static func enable() async -> Bool {
        let granted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        enabled = granted
        if granted { lastSync = nil }
        return granted
    }

    /// Turning it off removes Sala's calendar, and with it every event Sala wrote.
    static func disable() {
        enabled = false
        let store = EKEventStore()
        if let id = UserDefaults.standard.string(forKey: calendarKey), let cal = store.calendar(withIdentifier: id) {
            try? store.removeCalendar(cal, commit: true)
        }
        UserDefaults.standard.removeObject(forKey: calendarKey)
        status = nil
    }

    /// What the last sync did, for Settings ("Synced 14 events at 12:55", or why it failed).
    static var status: String? {
        get { UserDefaults.standard.string(forKey: "calendarSync.status") }
        set { UserDefaults.standard.set(newValue, forKey: "calendarSync.status") }
    }

    struct SyncError: LocalizedError {
        var errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    static func sync(_ client: APIClient) async {
        // ponytail: at most every 10 minutes, since every app activation reloads; a BGAppRefreshTask would sync while closed.
        guard enabled, lastSync.map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return }
        do {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw SyncError("Sala has no full calendar access") }
            let n = try await run(client)
            lastSync = Date()
            status = "Synced \(n) events at \(Fmt.format(Date(), "HHmm"))"
        } catch is CancellationError {
        } catch {
            status = "Sync failed: \(error.localizedDescription)"
        }
    }

    private static func run(_ client: APIClient) async throws -> Int {
        let cal = Fmt.copenhagen
        let first = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        var wanted: [String: CalendarEvent] = [:]
        for i in 0..<months {
            let month = cal.date(byAdding: .month, value: i, to: first)!
            let c = cal.dateComponents([.year, .month], from: month)
            // A failed month would read as "everything was removed": this throws before touching the calendar.
            for e in try await client.calendar(month: String(format: "%04d-%02d", c.year!, c.month!)) { wanted[e.id] = e }
        }

        // Turned off while the months loaded: disable() already removed the calendar; don't make a new one.
        guard enabled else { throw CancellationError() }
        let store = EKEventStore()
        let calendar = try ownCalendar(store)
        let end = cal.date(byAdding: .month, value: months, to: first)!
        let existing = store.events(matching: store.predicateForEvents(withStart: first, end: end, calendars: [calendar]))
        var seen = Set<String>()
        for ev in existing {
            guard let id = ev.url.flatMap(eventID), let e = wanted[id], seen.insert(id).inserted else {
                try store.remove(ev, span: .thisEvent, commit: false)
                continue
            }
            e.fill(ev)
            try store.save(ev, span: .thisEvent, commit: false)
        }
        for (id, e) in wanted where !seen.contains(id) {
            let ev = EKEvent(eventStore: store)
            ev.calendar = calendar
            e.fill(ev)
            try store.save(ev, span: .thisEvent, commit: false)
        }
        try store.commit()
        return wanted.count
    }

    private static func ownCalendar(_ store: EKEventStore) throws -> EKCalendar {
        if let id = UserDefaults.standard.string(forKey: calendarKey), let cal = store.calendar(withIdentifier: id) { return cal }
        // The account new events go to, then iCloud, then On My iPhone: some accounts (Google, Exchange)
        // don't let apps add calendars, so try the next one when saving fails.
        let candidates = [store.defaultCalendarForNewEvents?.source]
            + store.sources.filter { $0.sourceType == .calDAV && $0.title == "iCloud" }
            + store.sources.filter { $0.sourceType == .local }
        var lastError: Error = SyncError("no calendar account to add a calendar to")
        for case let source? in candidates {
            let cal = EKCalendar(for: .event, eventStore: store)
            cal.title = "Sala"
            cal.cgColor = CGColor(red: 0.85, green: 0.45, blue: 0.3, alpha: 1)
            cal.source = source
            do {
                try store.saveCalendar(cal, commit: true)
                UserDefaults.standard.set(cal.calendarIdentifier, forKey: calendarKey)
                return cal
            } catch { lastError = error }
        }
        throw lastError
    }

    private static func eventID(_ url: URL) -> String? {
        url.scheme == "sala" && url.host() == "calendar" ? url.lastPathComponent : nil
    }
}

extension CalendarEvent {
    /// Copies this item into an EventKit event (the Sala calendar's, or a new one for "Add to Calendar").
    func fill(_ ev: EKEvent) {
        ev.title = title
        ev.notes = subtitle
        ev.url = URL(string: "sala://calendar/\(id)")
        ev.isAllDay = allDay
        if allDay {
            // All-day events float: midnight on the device's calendar, whatever its time zone.
            ev.timeZone = nil
            ev.startDate = Fmt.day(startDate)
            ev.endDate = Fmt.day(endDate)
        } else {
            ev.timeZone = Fmt.copenhagen.timeZone
            ev.startDate = Self.copenhagen(startDate, startTime)
            ev.endDate = Self.copenhagen(endDate, endTime ?? startTime)
        }
    }

    static func copenhagen(_ ymd: String, _ hhmm: String?) -> Date? {
        let f = DateFormatter()
        f.locale = Fmt.posix
        f.calendar = Fmt.copenhagen
        f.timeZone = Fmt.copenhagen.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(ymd) \(hhmm ?? "00:00")")
    }
}
