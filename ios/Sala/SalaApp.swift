import SwiftUI
import UIKit

@main
struct SalaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.store)
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
