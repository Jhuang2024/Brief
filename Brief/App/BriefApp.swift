import GoogleSignIn
import SwiftData
import SwiftUI

@main
struct BriefApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .modelContainer(environment.modelContainer)
                .preferredColorScheme(environment.preferencesStore.preferences.theme.colorScheme)
                .dynamicTypeSize(typeRange)
                .tint(.accentColor)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    await environment.ensureLaunched()
                }
        }
    }

    /// The Settings text-size choice raises the Dynamic Type floor;
    /// system Dynamic Type still applies above it.
    private var typeRange: ClosedRange<DynamicTypeSize> {
        let floor = environment.preferencesStore.preferences.textSize.dynamicTypeSize ?? .xSmall
        return floor...DynamicTypeSize.accessibility3
    }
}
