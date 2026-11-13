import SwiftUI
import WebKit

/// Shown when there is no Aula session. MitID runs on Aula's own login pages in a web view; only
/// the user starts it, and nothing retries it (repeated failed MitID attempts can lock the identity).
struct LoginView: View {
    @Environment(Store.self) private var store
    @State private var showWeb = false
    @State private var finishing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.salaAccent)
                        .accessibilityHidden(true)
                        .padding(.top, 40)

                    Text("Log in to Aula")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("Sala signs in to Aula on this phone with MitID. Aula ends the session now and then; then you log in again.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Button {
                        error = nil
                        showWeb = true
                    } label: {
                        Group {
                            if finishing { ProgressView() } else { Text("Log in with MitID").bold() }
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(finishing)

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.sickText)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .background(Color.screen)
            .navigationTitle("Log in")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showWeb) {
            LoginSheet { redirect, verifier, state in
                showWeb = false
                finishing = true
                Task {
                    defer { finishing = false }
                    do {
                        try await Aula.shared.completeLogin(redirect: redirect, verifier: verifier, state: state)
                        await store.load()
                    } catch {
                        self.error = "Login didn't complete. \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

private struct LoginSheet: View {
    let onRedirect: (URL, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var verifier = Aula.randomURLSafe()
    @State private var state = Aula.randomURLSafe()

    var body: some View {
        NavigationStack {
            AulaLoginWebView(url: Aula.authorizeURL(verifier: verifier, state: state)) { onRedirect($0, verifier, state) }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("MitID")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark", role: .close) { dismiss() }
                    }
                }
        }
    }
}

/// Aula's login pages. The OAuth redirect to `app-private.aula.dk` (the official app's, which we
/// can't claim as a universal link) is caught here instead of loaded.
private struct AulaLoginWebView: UIViewRepresentable {
    let url: URL
    let onRedirect: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onRedirect) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onRedirect: (URL) -> Void
        private var done = false
        init(_ onRedirect: @escaping (URL) -> Void) { self.onRedirect = onRedirect }

        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .allow }
            if url.host == Aula.redirectHost {
                if !done { done = true; onRedirect(url) }
                return .cancel
            }
            switch url.scheme {
            case "http", "https": return .allow
            // MitID's "use the MitID app" opens about:blank first; loading it over the page would blank it.
            case "about", "blob", "data": return action.targetFrame?.isMainFrame == false ? .allow : .cancel
            default:
                // Another app's link (the MitID app, say).
                await UIApplication.shared.open(url)
                return .cancel
            }
        }

        // target=_blank links (MitID's "open the app", help pages) load in the same view.
        func webView(_ web: WKWebView, createWebViewWith config: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let scheme = action.request.url?.scheme, scheme == "http" || scheme == "https" { web.load(action.request) }
            return nil
        }
    }
}
