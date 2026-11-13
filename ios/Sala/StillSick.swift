import UIKit
import UserNotifications

/// Aula resets a sick child to healthy the next day, so reporting sick schedules a
/// "Is Oskar still sick?" notification for the next weekday at 07:00 (Copenhagen).
enum StillSick {
    static let category = "still-sick"
    static let stillSickAction = "still-sick"
    static let backAction = "back-today"
    private static let asksKey = "stillSickAsks"

    static func id(_ child: Int) -> String { "still-sick-\(child)" }

    // MARK: Dates (pure)

    /// The start of the first Mon–Fri day `step` days away (+1 = next, -1 = previous) from `date`'s day.
    static func weekday(_ step: Int, from date: Date, calendar cal: Calendar = Fmt.copenhagen) -> Date {
        var day = cal.startOfDay(for: date)
        repeat {
            day = cal.date(byAdding: .day, value: step, to: day)!
        } while [1, 7].contains(cal.component(.weekday, from: day))
        return day
    }

    /// 07:00 on the next weekday after `date`'s day, in Copenhagen.
    static func nextMorning(after date: Date, calendar cal: Calendar = Fmt.copenhagen) -> Date {
        cal.date(bySettingHour: 7, minute: 0, second: 0, of: weekday(1, from: date, calendar: cal))!
    }

    /// Today as "yyyy-MM-dd" before noon (Copenhagen), when the card may ask; nil in the afternoon.
    static func askDay(now: Date = Date(), calendar cal: Calendar = Fmt.copenhagen) -> String? {
        cal.component(.hour, from: now) < 12 ? Fmt.ymd(now) : nil
    }

    #if DEBUG
    static func selfCheck() {
        let utc = ISO8601DateFormatter()
        func d(_ s: String) -> Date { utc.date(from: s)! }
        assert(nextMorning(after: d("2026-11-12T14:00:00Z")) == d("2026-11-13T06:00:00Z"), "Thu → Fri 07:00 CET")
        assert(nextMorning(after: d("2026-11-13T14:00:00Z")) == d("2026-11-16T06:00:00Z"), "Fri → Mon")
        assert(nextMorning(after: d("2026-11-14T10:00:00Z")) == d("2026-11-16T06:00:00Z"), "Sat → Mon")
        assert(nextMorning(after: d("2026-11-15T23:30:00Z")) == d("2026-11-17T06:00:00Z"), "Mon 00:30 local → Tue")
        assert(nextMorning(after: d("2026-03-27T12:00:00Z")) == d("2026-03-30T05:00:00Z"), "Fri → Mon 07:00 CEST")
        assert(askDay(now: d("2026-11-15T23:30:00Z")) == "2026-11-16", "Mon 00:30 local is Monday")
        assert(askDay(now: d("2026-11-17T12:00:00Z")) == nil, "Tue 13:00 doesn't ask")
    }
    #endif

    // MARK: The day each child's notification asks about (child id → "yyyy-MM-dd")

    static func loadAsks() -> [Int: String] {
        let raw = UserDefaults.standard.dictionary(forKey: asksKey) as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    static func saveAsks(_ asks: [Int: String]) {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: asks.map { (String($0), $1) }), forKey: asksKey)
    }

    /// Runs `op`, throwing a timeout after `seconds` (cancelling `op`), so a background action always finishes in time.
    static func withDeadline<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: Notifications

    static func registerCategory() {
        let still = UNNotificationAction(identifier: stillSickAction, title: "Still sick")
        let back = UNNotificationAction(identifier: backAction, title: "Back today")
        let cat = UNNotificationCategory(identifier: category, actions: [still, back], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    /// Asks for permission the first time (a no-op once answered), then schedules or replaces the child's prompt
    /// for `date` (Copenhagen), clearing a delivered one.
    static func schedule(child: Int, name: String, at date: Date) async {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id(child)])
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Is \(name) still sick?"
        content.body = "Aula reset the sick report overnight."
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["child": child, "name": name]
        let cal = Fmt.copenhagen
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        c.calendar = cal
        c.timeZone = cal.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: c, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id(child), content: content, trigger: trigger))
    }

    static func cancel(child: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id(child)])
        center.removeDeliveredNotifications(withIdentifiers: [id(child)])
    }

    /// Shown right away when the "Still sick" action's request fails, so a background failure isn't silent.
    static func notifyFailure(name: String, _ message: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Couldn't report \(name) sick"
        content.body = message
        content.sound = .default
        try? await UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "still-sick-failed", content: content, trigger: nil))
    }
}

// MARK: - App delegate

/// Owns the Store so a notification action can use it even when iOS launched the app in the background.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = Store()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        StillSick.selfCheck()
        AppLock.selfCheck()
        #endif
        // Must be set before launch finishes, or a response that launched the app is lost.
        UNUserNotificationCenter.current().delegate = self
        StillSick.registerCategory()
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Returning ends the call, which tells iOS the work is done (it may suspend the app then).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await handle(action: response.actionIdentifier, child: info["child"] as? Int,
                     name: info["name"] as? String ?? "Your child", link: info["link"] as? String)
    }

    private func handle(action: String, child: Int?, name: String, link: String?) async {
        switch action {
        case StillSick.stillSickAction:
            guard let child else { return }
            // Extra insurance on top of the notification's own background time; the request has a 20 s deadline.
            let app = UIApplication.shared
            let bg = app.beginBackgroundTask(withName: "still-sick", expirationHandler: nil)
            await store.reportStillSick(child: child, name: name)
            app.endBackgroundTask(bg)
        case StillSick.backAction:
            // Aula already reset the status: nothing to send, just drop the card.
            if let child { store.dismissStillSick(child) }
        case UNNotificationDefaultActionIdentifier:
            // Background refresh's notifications carry their link (sala://thread/<id>, sala://today).
            store.handleDeepLink(link.flatMap(URL.init(string:)) ?? URL(string: "sala://today")!)
        default:
            break
        }
    }
}
