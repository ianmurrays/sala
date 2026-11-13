import LocalAuthentication
import SwiftUI
import UIKit

/// Face ID lock, passcode as fallback. Opt-in from Settings.
/// The cover is its own window above everything (sheets, Quick Look), shown whenever the app isn't active too,
/// so the app switcher snapshot shows the cover. A notification that opens a screen opens it under the cover.
@MainActor @Observable
final class AppLock {
    static let shared = AppLock()
    /// Background time after which coming back asks again.
    static let grace: Duration = .seconds(5 * 60)
    private static let enabledKey = "appLock.enabled"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private(set) var locked = AppLock.active
    private(set) var authenticating = false
    /// ContinuousClock, not Date: it keeps counting while the phone sleeps, and setting the clock back can't skip the lock.
    @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?
    /// Ask on launch and on coming back from the background, never on inactive → active:
    /// the Face ID sheet itself makes the app inactive, so a cancel would ask again forever.
    @ObservationIgnored private var promptOnActive = true
    @ObservationIgnored private var window: UIWindow?

    /// Nothing to hide before the first MitID login (or after logging out): no Face ID on the login screen.
    private static var active: Bool { enabled && Aula.storedTokens != nil }

    static func expired(backgroundedAt: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Bool {
        backgroundedAt.map { now - $0 > grace } ?? false
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard Self.active else { locked = false; hide(); return }
        switch phase {
        case .background:
            backgroundedAt = backgroundedAt ?? .now
            promptOnActive = true
        case .active:
            if Self.expired(backgroundedAt: backgroundedAt, now: .now) {
                locked = true
                // A focused reply field would bring its keyboard back above the cover.
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            backgroundedAt = nil
            if locked && promptOnActive { Task { await unlock() } }
            promptOnActive = false
        default:
            break
        }
        if phase == .active && !locked { hide() } else { show() }
    }

    func unlock() async {
        guard locked, !authenticating else { return }
        // ponytail: no passcode on the phone means anyone holding it gets in anyway; don't lock the owner out.
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            locked = false; hide(); return
        }
        authenticating = true
        defer { authenticating = false }
        if await Self.authenticate() { locked = false; hide() }
    }

    /// Turning the lock on asks once, so it can't be turned on where it wouldn't work.
    func enable() async -> Bool {
        let ok = await Self.authenticate()
        Self.enabled = ok
        return ok
    }

    private static func authenticate() async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Sala")) ?? false
    }

    private func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene
        else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.rootViewController = UIHostingController(rootView: LockView(lock: self))
        w.isHidden = false
        window = w
    }

    private func hide() {
        window?.isHidden = true
        window = nil
    }

    #if DEBUG
    static func selfCheck() {
        let now = ContinuousClock.now
        assert(!expired(backgroundedAt: nil, now: now), "never backgrounded")
        assert(!expired(backgroundedAt: now - .seconds(299), now: now), "under 5 min")
        assert(expired(backgroundedAt: now - .seconds(301), now: now), "over 5 min")
    }
    #endif
}

private struct LockView: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: 32) {
            Image("LaunchLogo")
            Button("Unlock Sala", systemImage: "faceid") { Task { await lock.unlock() } }
                .buttonStyle(.borderedProminent)
                .opacity(lock.locked && !lock.authenticating ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("LaunchBackground"))
        .tint(.salaAccent)
    }
}
