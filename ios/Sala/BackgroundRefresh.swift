import BackgroundTasks
import Foundation
import UserNotifications
import WidgetKit

/// Best effort, from iOS background app refresh (iOS picks when, often a few times a day, never after a force-quit):
/// saves the widget snapshot and posts local notifications for what the old server pushed (API.md → Push).
/// Never starts MitID: with no session it only posts "Aula login needed".
enum BackgroundRefresh {
    static let id = (Bundle.main.bundleIdentifier ?? "sala") + ".refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// One run. Also the Debug button in Settings.
    static func run() async {
        schedule()
        do {
            let t = try await APIClient().today()
            Shared.saveSnapshot(TodaySnapshot(date: t.date, children: t.children, fetchedAt: .now))
            WidgetCenter.shared.reloadAllTimelines()
            Notifier.sessionWorks()
        } catch APIError.authRequired {
            await Notifier.loginNeeded()
            return
        } catch {}
        await Notifier.check()
    }
}

/// Local notifications and their seen-set (UserDefaults). Each kind is seeded silently on its first
/// successful read, so items that exist when notifications are turned on never notify; an item is marked
/// seen only once iOS has accepted its notification, so a failed one is tried again next run.
enum Notifier {
    private static let enabledKey = "notifications", seenKey = "pushSeen", seededKey = "pushSeeded", lossKey = "pushLoginLoss"
    private static var defaults: UserDefaults { .standard }

    static var enabled: Bool { defaults.bool(forKey: enabledKey) }

    /// Asks for permission (from the Settings toggle, never in the background) and starts over: the next run seeds again.
    static func enable() async -> Bool {
        guard (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true else { return false }
        defaults.removeObject(forKey: seededKey)
        defaults.set(true, forKey: enabledKey)
        BackgroundRefresh.schedule()
        await check()  // seed now, so what arrives before the first background run still notifies
        return true
    }

    static func disable() {
        defaults.set(false, forKey: enabledKey)
        Task {
            let center = UNUserNotificationCenter.current()
            let held = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("holiday") }
            center.removePendingNotificationRequests(withIdentifiers: held)
        }
    }

    // MARK: Seen-set

    private static var seen: [String] { defaults.stringArray(forKey: seenKey) ?? [] }

    private static func isSeen(_ key: String) -> Bool { seen.contains(key) }

    private static func markSeen(_ keys: [String]) {
        // ponytail: newest 2000 keys; a key dropped from here could notify again only if Aula still lists the item.
        defaults.set(Array((seen.filter { !keys.contains($0) } + keys).suffix(2000)), forKey: seenKey)
    }

    private static var seeded: [String: Date] { defaults.dictionary(forKey: seededKey) as? [String: Date] ?? [:] }

    // MARK: Login lost (once per loss)

    /// Aula answered: the loss, if any, is over, and the next one notifies again.
    static func sessionWorks() { defaults.removeObject(forKey: lossKey) }

    /// A deliberate logout is a loss nobody needs telling about.
    static func loggedOut() {
        let marker = Date.now.ISO8601Format()
        defaults.set(marker, forKey: lossKey)
        markSeen(["login:\(marker)"])
    }

    static func loginNeeded() async {
        guard enabled else { return }
        let marker = defaults.string(forKey: lossKey) ?? Date.now.ISO8601Format()
        defaults.set(marker, forKey: lossKey)
        let event = PushEvent(key: "login:\(marker)", title: "Aula login needed")
        if !isSeen(event.key), await post(event) { markSeen([event.key]) }
    }

    // MARK: Items

    static func check() async {
        guard enabled else { return }
        let found: [String: [PushEvent]?]
        do {
            found = try await Aula.shared.pushEvents()
        } catch APIError.authRequired {
            return await loginNeeded()
        } catch {
            return
        }
        let now = Date.now
        if let holidays = found["holiday"] ?? nil {
            // A request answered before its held 07:00 notification shows: drop that notification.
            let current = Set(holidays.map(\.key))
            let center = UNUserNotificationCenter.current()
            let stale = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("holiday") && !current.contains($0) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
        for kind in Push.kinds {
            guard let events = found[kind] ?? nil else { continue }  // read failed: neither seed nor notify
            guard let seededAt = seeded[kind] else {
                markSeen(events.map(\.key))
                var s = seeded
                s[kind] = now
                defaults.set(s, forKey: seededKey)
                continue
            }
            for e in events where !isSeen(e.key) {
                // Older than seeding (slid into the page when a newer item went): remember it, don't notify.
                if !e.notify || (e.at.map { $0 < seededAt } ?? false) {
                    markSeen([e.key])
                } else if await post(e) {
                    markSeen([e.key] + e.covers)
                }
            }
        }
    }

    /// Titles only, never message or post bodies. True once iOS has accepted it.
    private static func post(_ e: PushEvent) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = e.title
        content.sound = .default
        content.userInfo = ["link": e.link]
        var trigger: UNNotificationTrigger?
        if let at = e.notBefore, at > .now {
            // Held until 07:00: iOS shows it then, instead of waiting for a run after 07:00.
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: at.timeIntervalSinceNow, repeats: false)
        }
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: e.key, content: content, trigger: trigger))
            return true
        } catch {
            return false
        }
    }
}
