import SwiftUI

/// Shown when the server reports that the Aula session is gone (503 auth_required).
struct LoginView: View {
    @Environment(Store.self) private var store
    @State private var starting = false

    private var state: String { store.auth?.state ?? "needs_login" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.salaAccent)
                        .accessibilityHidden(true)
                        .padding(.top, 40)

                    content
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .background(Color.screen)
            .navigationTitle("Log in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { store.showSettings = true }
                }
            }
        }
        // Poll every 2 s while a login is running. The task is cancelled when the view goes away
        // or when the state leaves `logging_in`.
        .task(id: state) {
            guard state == "logging_in" else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await store.refreshAuthStatus()
            }
        }
        .task { await store.refreshAuthStatus() }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case "logging_in":
            VStack(spacing: 16) {
                Text("Approve in the MitID app")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if let code = store.auth?.otpCode, !code.isEmpty {
                    Text("Enter this code in the app")
                        .foregroundStyle(.secondary)
                    Text(code)
                        .font(.system(size: 52, weight: .bold, design: .monospaced))
                        .tracking(6)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                }
                ProgressView()
                    .padding(.top, 8)
                Text("Waiting for approval…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case "error":
            VStack(spacing: 16) {
                Text("Login failed")
                    .font(.title2.bold())
                Text(store.auth?.message ?? "MitID login didn't complete.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                loginButton(title: "Try again")
            }
        case "ok":
            VStack(spacing: 16) {
                Text("Logged in")
                    .font(.title2.bold())
                Button("Load Today") { Task { await store.load() } }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        default:
            VStack(spacing: 16) {
                Text("Aula needs you to log in")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Your server holds the Aula session. Log in once with MitID and it stays signed in.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                loginButton(title: "Log in with MitID")
            }
        }

        if let err = store.authError {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Color.sickText)
                .multilineTextAlignment(.center)
        }
    }

    private func loginButton(title: String) -> some View {
        Button {
            starting = true
            Task {
                await store.startLogin()
                starting = false
            }
        } label: {
            Group {
                if starting { ProgressView() } else { Text(title).bold() }
            }
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(starting)
    }
}
