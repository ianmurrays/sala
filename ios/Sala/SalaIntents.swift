import AppIntents
import SwiftUI
import UIKit

// Shortcuts and Siri. Each intent runs in the app's process through `Aula.handle`, like the widget's
// background refresh, and never starts MitID (with no session: "Open Sala to log in.").
// Writes need the phone unlocked (`authenticationPolicy`). Reads work from a locked phone, unless App Lock is on.

/// With App Lock on, Sala's data stays behind the phone's own lock too.
@MainActor private func checkAppLock() throws {
    if AppLock.enabled && !UIApplication.shared.isProtectedDataAvailable {
        throw IntentFailure.message("Unlock your iPhone first: Sala is locked with Face ID.")
    }
}

struct TodayStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Status"
    static let description = IntentDescription("Each child's status, pickup time, who picks up and closing time.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        try checkAppLock()
        let today = try await IntentFailure.mapping { try await APIClient().today() }
        let text = today.children.isEmpty ? "No children in Aula." : today.children.map(IntentText.status).joined(separator: "\n")
        return .result(value: text, dialog: "\(text)", view: StatusSnippet(children: today.children))
    }
}

struct UnreadMessagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Unread Messages"
    static let description = IntentDescription("How many inbox threads are unread, and the newest subjects.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        try checkAppLock()
        // ponytail: the first inbox page, like the Messages badge.
        let threads = try await IntentFailure.mapping { try await APIClient().threads() }
        return .result(value: threads.filter(\.unread).count, dialog: "\(IntentText.unread(threads))")
    }
}

struct SetPickupIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Pickup Time"
    static let description = IntentDescription("Today's pickup time and who picks up, as on Today's pickup sheet.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Child") var child: ChildEntity
    @Parameter(title: "Time", kind: .time) var time: Date
    @Parameter(title: "Picked up by") var by: String?
    @Dependency private var store: Store

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$child)'s pickup to \(\.$time)") { \.$by }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let options = try await IntentFailure.mapping { try await APIClient().pickupOptions(child: child.id) }
        let c = Fmt.copenhagen.dateComponents([.hour, .minute], from: time)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if let open = Fmt.minutes(options.opensAt), let close = Fmt.minutes(options.closesAt), !(open...close).contains(minutes) {
            throw IntentFailure.message("Pick a time between \(Fmt.hhmm(open)) and \(Fmt.hhmm(close)).")
        }
        let hhmm = Fmt.hhmm(minutes)
        let person: String
        if let by, let match = options.people.first(where: { $0.localizedCaseInsensitiveContains(by) }) {
            person = match
        } else if by == nil, let current = options.current?.by, options.people.contains(current) {
            person = current
        } else if options.people.isEmpty {
            throw IntentFailure.message("Aula lists no one who can pick up \(child.name).")
        } else {
            person = try await $by.requestDisambiguation(among: options.people, dialog: "Who picks up \(child.name)?")
        }
        // The note is part of the same write; keep the one already there.
        try await IntentFailure.mapping {
            try await store.savePickup(child: child.id, PickupUpdate(time: hhmm, by: person, note: options.note ?? ""))
        }
        return .result(dialog: "\(child.name)'s pickup is \(hhmm), by \(person).")
    }
}

struct ReportSickIntent: AppIntent {
    static let title: LocalizedStringResource = "Report Sick"
    static let description = IntentDescription("Reports a child sick for today, as on Today. Asks first.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Child") var child: ChildEntity
    @Dependency private var store: Store

    static var parameterSummary: some ParameterSummary { Summary("Report \(\.$child) sick") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let today = try await IntentFailure.mapping { try await APIClient().today() }
        guard let c = today.children.first(where: { $0.id == child.id }) else {
            throw IntentFailure.message("\(child.name) isn't in Aula today.")
        }
        if c.status == "sick" { return .result(dialog: "\(c.name) is already reported sick.") }
        guard c.canReportSick else { throw IntentFailure.message("Aula doesn't let you report \(c.name) sick right now.") }
        try await requestConfirmation(dialog: "Report \(c.name) sick today?")
        try await IntentFailure.mapping { try await store.reportSick(c.id) }
        return .result(dialog: "\(c.name) is reported sick.")
    }
}

enum SalaScreen: String, AppEnum {
    case today, messages, calendar

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Screen"
    static let caseDisplayRepresentations: [SalaScreen: DisplayRepresentation] = [
        .today: "Today", .messages: "Messages", .calendar: "Calendar",
    ]
}

struct OpenSalaIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Sala"
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Screen", default: .today) var screen: SalaScreen
    @Dependency private var store: Store

    @MainActor
    func perform() async throws -> some IntentResult {
        store.handleDeepLink(URL(string: "sala://\(screen.rawValue)")!)
        return .result()
    }
}

/// The read-only intents, with phrases, so they show in Spotlight and the Shortcuts app with no setup.
struct SalaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TodayStatusIntent(), phrases: [
            "When is pickup today in \(.applicationName)",
            "\(.applicationName) status",
            "What's the status in \(.applicationName)",
        ], shortTitle: "Today's Status", systemImageName: "sun.max")
        AppShortcut(intent: UnreadMessagesIntent(), phrases: [
            "Unread messages in \(.applicationName)",
            "Do I have new messages in \(.applicationName)",
        ], shortTitle: "Unread Messages", systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(intent: OpenSalaIntent(), phrases: [
            "Open \(.applicationName)",
            "Open \(\.$screen) in \(.applicationName)",
        ], shortTitle: "Open Sala", systemImageName: "arrow.up.forward.app")
    }
}

private struct StatusSnippet: View {
    let children: [Child]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(children) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.name).font(.headline)
                        Spacer()
                        Text(c.statusLabel).foregroundStyle(.secondary)
                    }
                    if let t = c.pickup?.time {
                        Text("Pickup \(t)" + (c.pickup?.by.map { " · \($0)" } ?? "")).font(.subheadline)
                    }
                    if let close = c.closesAt {
                        Text("Closes \(close)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }
}
