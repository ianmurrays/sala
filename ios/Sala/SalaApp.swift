import SwiftUI
import UIKit

@main
struct SalaApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.salaAccent)
        }
    }
}

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var store = store
        Group {
            if store.phase == .needsLogin {
                LoginView()
            } else {
                TabView(selection: $store.selectedTab) {
                    Tab("Today", systemImage: "sun.max", value: AppTab.today) {
                        TodayView()
                    }
                    Tab("Messages", systemImage: "bubble.left.and.bubble.right", value: AppTab.messages) {
                        MessagesView()
                    }
                    .badge(store.unreadThreadCount)
                }
            }
        }
        .sheet(isPresented: $store.showSettings) {
            SettingsView()
        }
        .task { await store.load() }
        .onOpenURL { store.handleDeepLink($0) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, store.phase != .needsLogin, store.phase != .loading else { return }
            Task { await store.load() }
        }
    }
}

// MARK: - Theme

extension Color {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let salaAccent = dynamic(light: 0x0062CC, dark: 0x4C9EFF)
    static let sickText = dynamic(light: 0xB23F00, dark: 0xFF9F66)
    static let sickFill = dynamic(light: 0xFDEBDF, dark: 0x4A2210)
    static let sickButton = dynamic(light: 0xB23F00, dark: 0xD9621F)
    static let presentText = dynamic(light: 0x1B6B33, dark: 0x7EDC97)
    static let presentFill = dynamic(light: 0xE3F5E8, dark: 0x173D22)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let screen = Color(uiColor: .systemGroupedBackground)
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: .rect(cornerRadius: 26, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
