import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLogout = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Log out of Aula", role: .destructive) { confirmLogout = true }
                } footer: {
                    Text("Sala talks to Aula directly from this phone. Logging out forgets the session; you'll need MitID to log in again.")
                }

                #if DEBUG
                Section("Debug") {
                    Button("Expire the Aula session and reload") {
                        Task {
                            await Aula.shared.debugExpireSession()
                            await store.load()
                            dismiss()
                        }
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
