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
        .backgroundTask(.appRefresh(BackgroundRefresh.id)) { await BackgroundRefresh.run() }
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
                // At most 5 tabs, Search included. On iPhone a sixth sends the overflow under iOS's More,
                // where a tab's own NavigationStack shows a second navigation bar (#32). Apple's answer
                // is fewer tabs: https://developer.apple.com/forums/thread/764293
                TabView(selection: $store.selectedTab) {
                    Tab("Today", systemImage: "sun.max", value: AppTab.today) {
                        TodayView()
                    }
                    Tab("Calendar", systemImage: "calendar", value: AppTab.calendar) {
                        CalendarView()
                    }
                    Tab("Messages", systemImage: "bubble.left.and.bubble.right", value: AppTab.messages) {
                        MessagesView()
                    }
                    .badge(store.unreadThreadCount)
                    Tab("Gallery", systemImage: "photo.on.rectangle", value: AppTab.gallery) {
                        GalleryView()
                    }
                    Tab(value: AppTab.search, role: .search) {
                        SearchView()
                    }
                }
            }
        }
        .sheet(isPresented: $store.showSettings) {
            SettingsView()
        }
        .task { await store.load() }
        .onOpenURL { store.handleDeepLink($0) }
        .onChange(of: scenePhase, initial: true) { _, phase in AppLock.shared.scenePhaseChanged(phase) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundRefresh.schedule() }
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
