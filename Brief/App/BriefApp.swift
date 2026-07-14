import GoogleSignIn
import SwiftData
import SwiftUI

@main
struct BriefApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
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
        // Backgrounding is the moment right before an app update (the exact
        // event local backups exist to survive), so capture the latest
        // state here: a cheap main-context save so the snapshot sees the
        // last few seconds of changes, then a detached background backup
        // that returns immediately. The content-hash dedupe inside
        // performBackup makes ordinary app switching with no changes a
        // no-op.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background else { return }
            try? environment.modelContainer.mainContext.save()
            BackupService.backupOnBackgrounding(container: environment.modelContainer)
        }
    }

    /// The Settings text-size choice raises the Dynamic Type floor;
    /// system Dynamic Type still applies above it.
    private var typeRange: ClosedRange<DynamicTypeSize> {
        let floor = environment.preferencesStore.preferences.textSize.dynamicTypeSize ?? .xSmall
        return floor...DynamicTypeSize.accessibility3
    }
}
