import Foundation
import os

/// Runs before the SwiftData `ModelContainer` is created. Two
/// responsibilities, both read-only with respect to the live store (this
/// never deletes or migrates anything itself):
///
/// 1. If the app's tracked schema version has changed since the last
///    launch, copy whatever raw store files already exist into the backups
///    directory before SwiftData gets a chance to open (and possibly
///    migrate) them. A byte-for-byte safety net that doesn't depend on the
///    container opening successfully, since it runs first, which is also
///    what makes it complementary to BackupService's JSON archives, which
///    can only be built once the store has opened. This matters doubly
///    here because AppEnvironment falls back to an in-memory store when
///    the container fails to open: the session keeps working, but nothing
///    after that point can read the on-disk data this copy preserved.
/// 2. Log whenever the store's on-disk directory or the App Group container
///    path changes between launches, so a signing/provisioning change that
///    swaps containers leaves a trail instead of doing it silently.
///
/// Same design as LockedInFit's PersistenceGuard. Its DataLossGuard
/// companion (mid-session record-count monitoring with an incident UI) is
/// deliberately not ported: Brief's store regenerates daily and the
/// Settings restore picker already covers recovery, so that layer would be
/// machinery without a matching risk.
///
/// Bump `currentSchemaVersion` by hand whenever a `@Model` type gains or
/// loses a persisted property, or the container's schema list in
/// `AppEnvironment` changes, so a real migration always gets a
/// pre-migration snapshot.
enum PersistenceGuard {
    static let currentSchemaVersion = 3 // v3: DailyBrief email fields; v2: linkedAppDigestsData

    private static let logger = Logger(subsystem: "com.jerry.brief", category: "PersistenceGuard")
    private static let lastSeenSchemaVersionKey = "brief.lastSeenSchemaVersion"
    private static let lastSeenStorePathKey = "brief.lastSeenStorePath"
    private static let lastSeenAppGroupPathKey = "brief.lastSeenAppGroupPath"

    /// Call once, synchronously, before `ModelContainer(for:)` is constructed.
    static func runPreLaunchChecks() {
        backupStoreFilesIfSchemaChanged()
        logPathChangesIfAny()
    }

    /// Best-effort: SwiftData's default (no explicit `ModelConfiguration`)
    /// store is named "default.store" (plus -wal/-shm) directly under
    /// Application Support. If a future SwiftData version changes that
    /// convention, this simply finds nothing to copy and no-ops rather than
    /// failing, since it's a safety net on top of the JSON backups, not the
    /// only one.
    private static func backupStoreFilesIfSchemaChanged() {
        let defaults = UserDefaults.standard
        let lastSeen = defaults.integer(forKey: lastSeenSchemaVersionKey)
        defer { defaults.set(currentSchemaVersion, forKey: lastSeenSchemaVersionKey) }
        guard lastSeen != currentSchemaVersion else { return }

        guard let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let contents = try? FileManager.default.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) else {
            return
        }
        let storeFiles = contents.filter { $0.lastPathComponent.hasPrefix("default.store") }
        guard !storeFiles.isEmpty else { return }

        let stamp = BackupService.fileStamp(.now)
        let destination = BackupService.backupsDirectory
            .appendingPathComponent("pre-migration-v\(lastSeen)-to-v\(currentSchemaVersion)-\(stamp)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)) != nil else { return }
        for file in storeFiles {
            _ = try? FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
        }
        logger.notice("Schema version changed (\(lastSeen) -> \(currentSchemaVersion)); copied \(storeFiles.count) store file(s) to \(destination.path, privacy: .public)")
    }

    private static func logPathChangesIfAny() {
        let defaults = UserDefaults.standard
        let storePath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "unknown"
        let groupPath = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: LinkedAppsService.appGroupIdentifier
        )?.path ?? "unavailable"

        if defaults.string(forKey: lastSeenStorePathKey) != storePath {
            logger.notice("Persistence store directory is now \(storePath, privacy: .public)")
            defaults.set(storePath, forKey: lastSeenStorePathKey)
        }
        if defaults.string(forKey: lastSeenAppGroupPathKey) != groupPath {
            logger.notice("App Group container path is now \(groupPath, privacy: .public)")
            defaults.set(groupPath, forKey: lastSeenAppGroupPathKey)
        }
    }
}
