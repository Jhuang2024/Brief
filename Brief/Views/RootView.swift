import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        @Bindable var environment = environment
        TabView(selection: $environment.selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.horizon") }
                .tag(RootTab.today)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(RootTab.history)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .tint(Color.accentColor)
        .toolbarBackground(Color.paper, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .environment(
            \.appReducedMotion,
            systemReduceMotion || environment.preferencesStore.preferences.reducedMotion
        )
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment.shared)
}
