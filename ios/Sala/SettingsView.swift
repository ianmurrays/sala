import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLogout = false
    @State private var calendarSync = CalendarSync.enabled
    @State private var calendarDenied = false
    @State private var syncStatus = CalendarSync.status
    @State private var appLock = AppLock.enabled
    @State private var notifications = Notifier.enabled
    @State private var notificationsDenied = false
    #if DEBUG
    @State private var captureTraffic = TrafficLog.enabled
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Log out of Aula", role: .destructive) { confirmLogout = true }
                } footer: {
                    Text("Sala talks to Aula directly from this phone. Logging out forgets the session; you'll need MitID to log in again.")
                }

                Section {
                    Toggle("Lock with Face ID", isOn: Binding(get: { appLock }, set: { on in
                        appLock = on
                        Task {
                            if !on { AppLock.enabled = false; return }
                            appLock = await AppLock.shared.enable()
                        }
                    }))
                } footer: {
                    Text("Asks for Face ID or your passcode when Sala opens, and when you come back after more than 5 minutes away. The widget still shows today.")
                }

                Section {
                    Toggle("Sync to iOS Calendar", isOn: Binding(get: { calendarSync }, set: { on in
                        calendarSync = on
                        Task {
                            if !on { CalendarSync.disable(); return }
                            calendarSync = await CalendarSync.enable()
                            calendarDenied = !calendarSync
                            if calendarSync { await CalendarSync.sync(store.client) }
                            syncStatus = CalendarSync.status
                        }
                    }))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(calendarDenied
                            ? "Sala needs full calendar access for this. Turn it on in the Settings app under Privacy & Security → Calendars."
                            : "Keeps a Sala calendar with the next \(CalendarSync.months) months of Aula events, updated each time you open the app. Turning it off removes that calendar.")
                        if calendarSync, let s = syncStatus { Text(s) }
                    }
                }

                Section {
                    Toggle("Notifications", isOn: Binding(get: { notifications }, set: { on in
                        notifications = on
                        guard on else { return Notifier.disable() }
                        Task {
                            notifications = await Notifier.enable()
                            notificationsDenied = !notifications
                        }
                    }))
                } footer: {
                    Text(notificationsDenied
                        ? "Sala isn't allowed to notify. Turn notifications on for Sala in the Settings app."
                        : "New direct messages, important posts, holiday requests and their deadlines, and when Aula needs you to log in again. iOS decides when Sala may check in the background: often a few times a day, and never after you swipe Sala away, so they can arrive hours late.")
                }

                #if DEBUG
                Section {
                    Toggle("Capture Aula traffic", isOn: Binding(get: { captureTraffic }, set: {
                        captureTraffic = $0
                        TrafficLog.enabled = $0
                    }))
                    Button("Clear captured traffic", role: .destructive) { TrafficLog.clear() }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Writes every Aula call and its answer to aula-traffic.jsonl. Pull it with scripts/pull-aula-traffic.sh.")
                }

                Section {
                    Button("Expire the Aula session and reload") {
                        Task {
                            await Aula.shared.debugExpireSession()
                            await store.load()
                            dismiss()
                        }
                    }
                    Button("Run background refresh now") {
                        Task { await BackgroundRefresh.run() }
                    }
                    Button("Test still-sick notification in 5 s") {
                        let child = store.today?.children.first
                        Task { await StillSick.schedule(child: child?.id ?? 0, name: child?.name ?? "Oskar", at: Date() + 5) }
                    }
                }
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
            .confirmationDialog("Log out of Aula?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Log out", role: .destructive) {
                    Task {
                        await store.logout()
                        dismiss()
                    }
                }
            }
        }
    }
}
