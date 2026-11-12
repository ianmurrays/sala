import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var token = ""
    @State private var showToken = false

    var body: some View {
        NavigationStack {
            Form {
                if store.token.isEmpty {
                    Section {
                        Label("Enter your server's URL and token to get started.", systemImage: "info.circle")
                    }
                } else if store.phase == .unauthorized {
                    Section {
                        Label("The server rejected the token. Check the token and server URL.", systemImage: "lock.trianglebadge.exclamationmark")
                            .foregroundStyle(Color.sickText)
                    }
                }

                Section {
                    TextField("http://localhost:8000", text: $url)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server URL")
                } footer: {
                    Text("Your home server, for example http://192.168.1.10:8000 or a Tailscale address.")
                }

                Section {
                    HStack {
                        Group {
                            if showToken {
                                TextField("Token", text: $token)
                            } else {
                                SecureField("Token", text: $token)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .fontDesign(.monospaced)
                        Button(showToken ? "Hide token" : "Show token", systemImage: showToken ? "eye.slash" : "eye") {
                            showToken.toggle()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("Bearer token")
                } footer: {
                    Text("Stored in the Keychain on this device.")
                }

                #if DEBUG
                Section("Debug") {
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm) {
                        store.updateConfig(serverURL: url, token: token)
                        dismiss()
                    }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            url = store.serverURL
            token = store.token
        }
    }
}
