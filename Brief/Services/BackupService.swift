import CryptoKit
import Foundation
import SwiftData
import UIKit

/// Automatic and manual local backups of Brief's own data — the briefing
/// history, breaking alerts, and preferences — written as a versioned JSON
/// archive into a directory of their own, separate from both the live
/// SwiftData store and the App Group container. API keys live in the
/// Keychain and are never part of an archive.
///
/// The design is deliberately the same as LockedInFit's BackupService, so
/// every app in the personal-OS family protects data the same way. Every
/// backup, automatic or manual, builds and writes on `BackupActor`, a
/// private `@ModelActor` with its own background-safe `ModelContext`;
/// fetching, encoding, and writing to disk never touch the main actor.
/// Scheduling (debounce + in-flight guard) lives on `BackupCoordinator`, a
/// plain actor, so the shared scheduling state can't race even though calls
/// come from the main thread and background tasks concurrently.
///
/// Automatic backups run, debounced, after ANY save reaches the store:
/// `AutoBackupObserver` watches `ModelContext.didSave`, and mutation sites
/// also report changes via `scheduleBackupSoon` — a brief generating, a
/// breaking alert landing. There is no minimum-interval throttle: a burst of
/// saves coalesces through the debounce, and the content-hash dedupe below
/// turns a save that changed nothing observable into a cheap no-op, so
/// backing up on every change stays cheap. Backgrounding is a deliberate
/// extra trigger (see `backupOnBackgrounding`) since it's the moment right
/// before an app update, which is exactly the event these backups exist to
/// survive, and it's also what captures preference changes without needing a
/// hook on every toggle.
///
/// Important boundary to be honest about: local backups live inside this
/// app's own sandbox, so they protect against in-app mistakes but NOT
/// against a genuine uninstall, which wipes the sandbox, backups included.
/// That's what the App Group mirrors are for — they live in the shared
/// container, which has its own lifecycle and survives updates/reinstalls.
enum BackupService {
    static let maxBackupsKept = 5
    private static let lastBackupHashKey = "brief.lastBackupContentHash"

    struct BackupInfo: Identifiable {
        enum Location {
            /// Application Support/Backups inside this app's sandbox: fast
            /// and private, but dies with the sandbox when a signing change
            /// makes an update replace the app container.
            case local
            /// The shared App Group container, which survives app
            /// updates/reinstalls; see the mirror functions below.
            case sharedContainer
        }

        let url: URL
        let date: Date
        let recordCount: Int
        var location: Location = .local
        var id: URL { url }
    }

    enum RestoreOutcome {
        case restored(count: Int, preferencesApplied: Bool)
        case emptyBackupSkipped
        case failed(Error)
    }

    /// Tiny per-backup record kept in `index.json`, so listing backups never
    /// has to decode a backup's full (potentially a month of briefing
    /// history) archive content just to read its date and record count.
    private struct IndexEntry: Codable {
        var filename: String
        var date: Date
        var recordCount: Int
    }

    // MARK: - Archive format

    /// Everything a backup captures, as plain Codable records. The nested
    /// Data blobs (calendar events, weather, linked-app digests) are copied
    /// byte-for-byte rather than re-modeled, so a restore reproduces exactly
    /// what the brief showed. `preferencesData` is the saved preferences
    /// blob as persisted — which, like the live copy, never contains keys.
    struct Archive: Codable {
        var exportedAt: Date
        var preferencesData: Data?
        var briefs: [BriefRecord]
        var alerts: [AlertRecord]

        /// Rows across the whole archive; computed, so it never drifts from
        /// the actual content. Preferences aren't a row.
        var totalRecordCount: Int {
            briefs.reduce(0) { total, brief in
                total + 1 + brief.sections.reduce(0) { sectionTotal, section in
                    sectionTotal + 1 + section.stories.reduce(0) { storyTotal, story in
                        storyTotal + 1 + story.sources.count
                    }
                }
            } + alerts.count
        }

        struct BriefRecord: Codable {
            var id: UUID
            var briefingDate: Date
            var generatedAt: Date
            var timezoneIdentifier: String
            var locationName: String
            var overviewItems: [String]
            var calendarEventsData: Data?
            var weatherData: Data?
            var linkedAppDigestsData: Data?
            var emailMessagesData: Data?
            /// Optional so archives written before the Email section
            /// existed still decode; absent reads as false.
            var emailWasAvailable: Bool?
            var calendarWasAvailable: Bool
            var estimatedReadingMinutes: Int
            var statusRaw: String
            var failureNotes: [String]
            var researchModel: String
            var editorModel: String
            var inputTokens: Int
            var outputTokens: Int
            var generationDuration: TimeInterval
            var sections: [SectionRecord]
        }

        struct SectionRecord: Codable {
            var id: UUID
            var categoryRaw: String
            var title: String
            var order: Int
            var stories: [StoryRecord]
        }

        struct StoryRecord: Codable {
            var id: UUID
            var fingerprint: String
            var headline: String
            var summary: String
            var whyItMatters: String
            var context: String
            var developmentDate: Date?
            var statusRaw: String
            var importanceScore: Double
            var relevanceScore: Double
            var isUpdate: Bool
            var whatChanged: String
            var order: Int
            var sources: [SourceRecord]
        }

        struct SourceRecord: Codable {
            var id: UUID
            var title: String
            var domain: String
            var urlString: String
            var publishedAt: Date?
            var sourceTypeRaw: String
        }

        struct AlertRecord: Codable {
            var id: UUID
            var fingerprint: String
            var headline: String
            var summary: String
            var whyItMatters: String
            var sourceTitle: String
            var sourceDomain: String
            var sourceURLString: String
            var detectedAt: Date
            var isRead: Bool
        }
    }

    /// Builds the archive from whatever `context` can see. Every collection
    /// is explicitly sorted so two archives of identical data encode to
    /// identical bytes — the content-hash dedupe below depends on that.
    static func makeArchive(context: ModelContext, now: Date = .now) -> Archive {
        let briefs = (try? context.fetch(FetchDescriptor<DailyBrief>(
            sortBy: [SortDescriptor(\.briefingDate, order: .reverse), SortDescriptor(\.generatedAt, order: .reverse)]
        ))) ?? []
        let alerts = (try? context.fetch(FetchDescriptor<BreakingAlert>(
            sortBy: [SortDescriptor(\.detectedAt, order: .reverse)]
        ))) ?? []

        return Archive(
            exportedAt: now,
            preferencesData: PreferencesStore.encodedPreferences(),
            briefs: briefs.map { brief in
                Archive.BriefRecord(
                    id: brief.id,
                    briefingDate: brief.briefingDate,
                    generatedAt: brief.generatedAt,
                    timezoneIdentifier: brief.timezoneIdentifier,
                    locationName: brief.locationName,
                    overviewItems: brief.overviewItems,
                    calendarEventsData: brief.calendarEventsData,
                    weatherData: brief.weatherData,
                    linkedAppDigestsData: brief.linkedAppDigestsData,
                    emailMessagesData: brief.emailMessagesData,
                    emailWasAvailable: brief.emailWasAvailable,
                    calendarWasAvailable: brief.calendarWasAvailable,
                    estimatedReadingMinutes: brief.estimatedReadingMinutes,
                    statusRaw: brief.statusRaw,
                    failureNotes: brief.failureNotes,
                    researchModel: brief.researchModel,
                    editorModel: brief.editorModel,
                    inputTokens: brief.inputTokens,
                    outputTokens: brief.outputTokens,
                    generationDuration: brief.generationDuration,
                    sections: brief.orderedSections.map { section in
                        Archive.SectionRecord(
                            id: section.id,
                            categoryRaw: section.categoryRaw,
                            title: section.title,
                            order: section.order,
                            stories: section.orderedStories.map { story in
                                Archive.StoryRecord(
                                    id: story.id,
                                    fingerprint: story.fingerprint,
                                    headline: story.headline,
                                    summary: story.summary,
                                    whyItMatters: story.whyItMatters,
                                    context: story.context,
                                    developmentDate: story.developmentDate,
                                    statusRaw: story.statusRaw,
                                    importanceScore: story.importanceScore,
                                    relevanceScore: story.relevanceScore,
                                    isUpdate: story.isUpdate,
                                    whatChanged: story.whatChanged,
                                    order: story.order,
                                    sources: story.orderedSources.map { source in
                                        Archive.SourceRecord(
                                            id: source.id,
                                            title: source.title,
                                            domain: source.domain,
                                            urlString: source.urlString,
                                            publishedAt: source.publishedAt,
                                            sourceTypeRaw: source.sourceTypeRaw
                                        )
                                    }
                                )
                            }
                        )
                    }
                )
            },
            alerts: alerts.map { alert in
                Archive.AlertRecord(
                    id: alert.id,
                    fingerprint: alert.fingerprint,
                    headline: alert.headline,
                    summary: alert.summary,
                    whyItMatters: alert.whyItMatters,
                    sourceTitle: alert.sourceTitle,
                    sourceDomain: alert.sourceDomain,
                    sourceURLString: alert.sourceURLString,
                    detectedAt: alert.detectedAt,
                    isRead: alert.isRead
                )
            }
        )
    }

    /// Application Support/Backups. Distinct from the live store's directory
    /// (Application Support root) and from the App Group container.
    static var backupsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL { backupsDirectory.appendingPathComponent("index.json") }

    // MARK: - Scheduling (debounced, background-safe)

    /// Call this after an actual data mutation: a brief generating, a
    /// breaking alert being saved, a restore completing. `AutoBackupObserver`
    /// also calls it after any `ModelContext.didSave`, so these per-site calls
    /// are redundant safety nets rather than the only trigger. Never call it
    /// from launch or routine refresh code, none of which are data-mutation
    /// events. Fire-and-forget: hops onto `BackupCoordinator` to debounce
    /// (coalescing a burst of changes), never blocking the caller.
    static func scheduleBackupSoon(container: ModelContainer, after seconds: Double = 3) {
        Task { await BackupCoordinator.shared.scheduleSoon(container: container, after: seconds) }
    }

    /// Explicit manual "Back Up Now": bypasses the debounce, but still
    /// refuses to overlap an in-flight backup. Fully off the main thread;
    /// callers should show their own progress UI around the await.
    @discardableResult
    static func backupNowManually(container: ModelContainer) async -> URL? {
        await BackupCoordinator.shared.backupManually(container: container)
    }

    /// Backup fired when the app is backgrounded: the moment that precedes
    /// an app update, the event local backups exist to survive. Bypasses
    /// the debounce (backgrounding frequency is bounded by the user), never
    /// blocks resigning active (all work runs on the
    /// background actor), and the content-hash check inside `performBackup`
    /// makes the no-changes case a cheap no-op, so ordinary app switching
    /// doesn't churn out duplicate backups.
    ///
    /// Explicitly requests background execution time via
    /// `beginBackgroundTask`: switching to the App Store to tap Update
    /// backgrounds this app immediately, and without an explicit assertion
    /// iOS is free to suspend the process before a plain detached task ever
    /// gets scheduled — a change made moments before updating would be
    /// backgrounded-but-never-backed-up. `@MainActor` because the call site
    /// (BriefApp's scenePhase onChange) already is, and `token.begin` must
    /// run synchronously before the detached task starts.
    @MainActor
    static func backupOnBackgrounding(container: ModelContainer) {
        let token = BackgroundTaskToken()
        token.begin(name: "brief.backup") {}
        Task.detached(priority: .utility) {
            _ = await BackupCoordinator.shared.backupManually(container: container)
            token.end()
        }
    }

    /// The actual work: fetch, encode, write, rotate, mirror. Called only
    /// from `BackupActor`'s isolated context, so it always runs off the
    /// main thread. Not private so `BackupActor` (a separate type) can call
    /// it. Second tuple element is false for the dedupe no-op path (an
    /// existing backup's URL handed back, nothing written); callers can use
    /// that to tell a real write from a no-op.
    ///
    /// `forceFreshTimestamp` only matters on the dedupe path: when true, the
    /// existing (content-identical) backup's index entry is bumped to now.
    /// Only the explicit manual "Back Up Now" tap sets this — the user asked
    /// for a backup right now and expects to see that confirmed, whereas an
    /// automatic trigger with nothing new to capture should stay silent so
    /// "Latest backup" keeps meaning "when data was last actually captured."
    static func performBackup(context: ModelContext, forceFreshTimestamp: Bool = false) -> (url: URL?, wrote: Bool) {
        let archive = makeArchive(context: context)
        let existingIndex = readIndex()
        if archive.totalRecordCount == 0, existingIndex.contains(where: { $0.recordCount > 0 }) {
            return (nil, false)
        }

        // Content dedupe: backups also fire on every app backgrounding,
        // which happens constantly during normal phone use. When nothing
        // actually changed since the last backup, skip the write entirely
        // so the rotation isn't flooded with identical snapshots (which
        // would push older, distinct backups off the list). The hash
        // excludes the exportedAt timestamp, which would otherwise differ
        // every time.
        let hash = contentHash(of: archive)
        if let hash, hash == UserDefaults.standard.string(forKey: lastBackupHashKey),
           let newest = existingIndex.max(by: { $0.date < $1.date }) {
            if forceFreshTimestamp, let index = existingIndex.firstIndex(where: { $0.filename == newest.filename }) {
                var updatedIndex = existingIndex
                updatedIndex[index].date = .now
                writeIndex(updatedIndex)
            }
            return (backupsDirectory.appendingPathComponent(newest.filename), false)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(archive) else { return (nil, false) }

        let filename = "backup-\(fileStamp(archive.exportedAt)).json"
        let destination = backupsDirectory.appendingPathComponent(filename)
        let temp = backupsDirectory.appendingPathComponent(filename + ".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return (nil, false)
        }

        var updatedIndex = existingIndex
        updatedIndex.append(IndexEntry(filename: filename, date: archive.exportedAt, recordCount: archive.totalRecordCount))
        writeIndex(updatedIndex)
        rotate()
        mirrorToAppGroup(data: data, date: archive.exportedAt, recordCount: archive.totalRecordCount)
        if let hash {
            UserDefaults.standard.set(hash, forKey: lastBackupHashKey)
        }
        return (destination, true)
    }

    /// SHA-256 of the archive with `exportedAt` normalized away, so two
    /// archives of identical data hash identically regardless of when they
    /// were taken.
    private static func contentHash(of archive: Archive) -> String? {
        var comparable = archive
        comparable.exportedAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(comparable) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Listing

    /// All local backups, newest first. Reads the small index file rather
    /// than decoding every backup's full content; falls back to a one-time
    /// full decode only if the index is missing, then persists an index so
    /// that only happens once.
    static func listBackups() -> [BackupInfo] {
        let indexed = readIndex()
        if !indexed.isEmpty {
            return indexed
                .filter { FileManager.default.fileExists(atPath: backupsDirectory.appendingPathComponent($0.filename).path) }
                .map { BackupInfo(url: backupsDirectory.appendingPathComponent($0.filename), date: $0.date, recordCount: $0.recordCount) }
                .sorted { $0.date > $1.date }
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoded = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
            .compactMap(decodeInfoFromFullFile)
            .sorted { $0.date > $1.date }
        if !decoded.isEmpty {
            writeIndex(decoded.map { IndexEntry(filename: $0.url.lastPathComponent, date: $0.date, recordCount: $0.recordCount) })
        }
        return decoded
    }

    /// Every backup this device knows about (local rotation plus the App
    /// Group mirrors that survive reinstalls), sorted most-complete first.
    /// The single source of truth for "what's the best backup we have";
    /// after an update wipes the app container, the newest backup is
    /// usually a backup of the post-wipe, nearly-empty state, and the one
    /// that matters is the most complete one.
    static func allKnownBackups() -> [BackupInfo] {
        (listBackups() + appGroupMirrorBackups()).sorted {
            if $0.recordCount != $1.recordCount { return $0.recordCount > $1.recordCount }
            return $0.date > $1.date
        }
    }

    /// The backup Settings' "Most complete backup" stat shows.
    static func mostCompleteBackup() -> BackupInfo? { allKnownBackups().first }

    /// The literal most recent backup by time, independent of completeness:
    /// the answer to "when did a backup last happen." Shown separately
    /// because after record-count churn (a wipe, a restore) an older,
    /// larger backup can permanently outrank every backup taken since,
    /// which would make a "Back Up Now" tap look like it did nothing.
    static func mostRecentBackup() -> BackupInfo? {
        (listBackups() + appGroupMirrorBackups()).max { $0.date < $1.date }
    }

    // MARK: - Restore

    /// Rows currently in the live store, comparable to a backup's
    /// `recordCount`. Used by the empty-backup guard and the restore UI.
    static func currentRecordCount(context: ModelContext) -> Int {
        ((try? context.fetchCount(FetchDescriptor<DailyBrief>())) ?? 0)
            + ((try? context.fetchCount(FetchDescriptor<BriefSection>())) ?? 0)
            + ((try? context.fetchCount(FetchDescriptor<BriefStory>())) ?? 0)
            + ((try? context.fetchCount(FetchDescriptor<BriefSource>())) ?? 0)
            + ((try? context.fetchCount(FetchDescriptor<BreakingAlert>())) ?? 0)
    }

    // MARK: - Automatic restore on empty launch

    private static let userChoseFreshStartKey = "brief.userChoseFreshStart"

    /// Set when the user deliberately wipes everything ("Delete all history"),
    /// so the empty store they asked for isn't treated as a wipe to recover
    /// from on the next launch. Cleared automatically the moment real data
    /// exists again (a new brief, or a restore).
    static var userChoseFreshStart: Bool {
        UserDefaults.standard.bool(forKey: userChoseFreshStartKey)
    }

    static func markFreshStartChosen() {
        UserDefaults.standard.set(true, forKey: userChoseFreshStartKey)
    }

    /// When Brief launches and finds its store empty — the signature of an
    /// update/reinstall that replaced the app container and wiped the sandbox
    /// — silently restore the most complete backup we still have, including
    /// the App Group mirrors that survive a reinstall. No user tap: the same
    /// automatic recovery Social Climber and LockedInFit already do on launch.
    /// It never runs when the store already has data, and never right after
    /// the user chose "Delete all history" (see `userChoseFreshStart`).
    /// Returns the number of records restored (0 when nothing was). Runs on the
    /// main context because a restore inserts records the live UI must see.
    @MainActor
    @discardableResult
    static func autoRestoreOnEmptyLaunch(context: ModelContext, preferencesStore: PreferencesStore) -> Int {
        guard currentRecordCount(context: context) == 0 else {
            // Real data present: this launch is not a wipe, and any earlier
            // "start fresh" intent no longer applies.
            UserDefaults.standard.set(false, forKey: userChoseFreshStartKey)
            return 0
        }
        guard !userChoseFreshStart else { return 0 }
        // The most complete backup known anywhere; after a true reinstall the
        // only survivors are the shared-container mirrors.
        guard let best = allKnownBackups().first(where: { $0.recordCount > 0 }) else { return 0 }
        // Re-confirm the store is still empty right before writing, so a brief
        // generated in the meantime is never overwritten.
        guard currentRecordCount(context: context) == 0 else { return 0 }
        switch restore(from: best, context: context, preferencesStore: preferencesStore, currentRecordCount: 0) {
        case .restored(let count, _):
            return count
        case .emptyBackupSkipped, .failed:
            return 0
        }
    }

    /// Restores a backup into `context`. Import is additive — briefs and
    /// alerts whose ids already exist are skipped, nothing is ever deleted —
    /// so the only real guard needed is refusing to "restore" an empty
    /// backup onto a store that already has data, which would be a
    /// confusing no-op rather than a real recovery. Preferences are applied
    /// only when the current ones are still factory-default (the post-wipe
    /// case); a restore must never clobber settings the user has since
    /// customized. Runs on the caller's (main) context since it's a rare,
    /// explicit, user-confirmed action whose records need to show up
    /// immediately in the UI.
    @MainActor
    static func restore(
        from backup: BackupInfo,
        context: ModelContext,
        preferencesStore: PreferencesStore,
        currentRecordCount: Int
    ) -> RestoreOutcome {
        guard backup.recordCount > 0 || currentRecordCount == 0 else { return .emptyBackupSkipped }
        let archive: Archive
        do {
            let data = try Data(contentsOf: backup.url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            archive = try decoder.decode(Archive.self, from: data)
        } catch {
            return .failed(error)
        }

        let existingBriefIDs = Set(((try? context.fetch(FetchDescriptor<DailyBrief>())) ?? []).map(\.id))
        let existingAlertIDs = Set(((try? context.fetch(FetchDescriptor<BreakingAlert>())) ?? []).map(\.id))
        var restoredRows = 0

        for record in archive.briefs where !existingBriefIDs.contains(record.id) {
            let sections = record.sections.map { sectionRecord -> BriefSection in
                let stories = sectionRecord.stories.map { storyRecord -> BriefStory in
                    let sources = storyRecord.sources.map { sourceRecord -> BriefSource in
                        let source = BriefSource(
                            id: sourceRecord.id,
                            title: sourceRecord.title,
                            domain: sourceRecord.domain,
                            urlString: sourceRecord.urlString,
                            publishedAt: sourceRecord.publishedAt
                        )
                        source.sourceTypeRaw = sourceRecord.sourceTypeRaw
                        return source
                    }
                    let story = BriefStory(
                        id: storyRecord.id,
                        fingerprint: storyRecord.fingerprint,
                        headline: storyRecord.headline,
                        summary: storyRecord.summary,
                        whyItMatters: storyRecord.whyItMatters,
                        context: storyRecord.context,
                        developmentDate: storyRecord.developmentDate,
                        importanceScore: storyRecord.importanceScore,
                        relevanceScore: storyRecord.relevanceScore,
                        isUpdate: storyRecord.isUpdate,
                        whatChanged: storyRecord.whatChanged,
                        order: storyRecord.order,
                        sources: sources
                    )
                    story.statusRaw = storyRecord.statusRaw
                    return story
                }
                let section = BriefSection(
                    id: sectionRecord.id,
                    category: SectionCategory(rawValue: sectionRecord.categoryRaw) ?? .worthKnowing,
                    title: sectionRecord.title,
                    order: sectionRecord.order,
                    stories: stories
                )
                // Preserve a category this build doesn't know rather than
                // rewriting it to the fallback.
                section.categoryRaw = sectionRecord.categoryRaw
                return section
            }
            let brief = DailyBrief(
                id: record.id,
                briefingDate: record.briefingDate,
                generatedAt: record.generatedAt,
                timezoneIdentifier: record.timezoneIdentifier,
                locationName: record.locationName,
                overviewItems: record.overviewItems,
                sections: sections,
                calendarWasAvailable: record.calendarWasAvailable,
                estimatedReadingMinutes: record.estimatedReadingMinutes,
                failureNotes: record.failureNotes,
                researchModel: record.researchModel,
                editorModel: record.editorModel,
                inputTokens: record.inputTokens,
                outputTokens: record.outputTokens,
                generationDuration: record.generationDuration
            )
            brief.statusRaw = record.statusRaw
            brief.calendarEventsData = record.calendarEventsData
            brief.weatherData = record.weatherData
            brief.linkedAppDigestsData = record.linkedAppDigestsData
            brief.emailMessagesData = record.emailMessagesData
            brief.emailWasAvailable = record.emailWasAvailable ?? false
            context.insert(brief)
            restoredRows += 1 + record.sections.reduce(0) { sectionTotal, section in
                sectionTotal + 1 + section.stories.reduce(0) { storyTotal, story in
                    storyTotal + 1 + story.sources.count
                }
            }
        }

        for record in archive.alerts where !existingAlertIDs.contains(record.id) {
            context.insert(BreakingAlert(
                id: record.id,
                fingerprint: record.fingerprint,
                headline: record.headline,
                summary: record.summary,
                whyItMatters: record.whyItMatters,
                sourceTitle: record.sourceTitle,
                sourceDomain: record.sourceDomain,
                sourceURLString: record.sourceURLString,
                detectedAt: record.detectedAt,
                isRead: record.isRead
            ))
            restoredRows += 1
        }

        do {
            try context.save()
        } catch {
            return .failed(error)
        }

        var preferencesApplied = false
        if let preferencesData = archive.preferencesData,
           preferencesStore.preferences == UserPreferences.default {
            preferencesApplied = preferencesStore.replacePreferences(withBackupData: preferencesData)
        }
        return .restored(count: restoredRows, preferencesApplied: preferencesApplied)
    }

    // MARK: - Index helpers

    private static func readIndex() -> [IndexEntry] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([IndexEntry].self, from: data)) ?? []
    }

    private static func writeIndex(_ entries: [IndexEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Keeps the newest `maxBackupsKept` backups, but NEVER rotates out the
    /// most complete one. After an accidental wipe (an update replacing the
    /// app container), the app starts taking fresh automatic backups of the
    /// nearly-empty post-wipe state; a plain newest-N policy would let those
    /// push the one copy of the real data off the end of the list.
    private static func rotate() {
        let sorted = readIndex().sorted { $0.date > $1.date }
        guard sorted.count > maxBackupsKept else { return }
        let bestFilename = sorted.max(by: { $0.recordCount < $1.recordCount })?.filename
        var kept: [IndexEntry] = []
        for (index, entry) in sorted.enumerated() {
            if index < maxBackupsKept || entry.filename == bestFilename {
                kept.append(entry)
            } else {
                try? FileManager.default.removeItem(at: backupsDirectory.appendingPathComponent(entry.filename))
            }
        }
        writeIndex(kept)
    }

    // MARK: - App Group mirrors (survive app updates/reinstalls)

    /// Local backups die with the sandbox when a signing/identity change
    /// makes an app update replace the container: exactly the event backups
    /// exist for. So every backup is also mirrored into the shared App
    /// Group container (when available), which has its own lifecycle:
    /// "latest" always tracks the newest backup, and "best" only ever
    /// advances to a backup with at least as many records, so a post-wipe
    /// rebuild can never overwrite the most complete copy.
    private struct MirrorMeta: Codable {
        var date: Date
        var recordCount: Int
    }

    private static var appGroupBackupsDirectory: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: LinkedAppsService.appGroupIdentifier
        ) else { return nil }
        let dir = container.appendingPathComponent("BriefBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func mirrorToAppGroup(data: Data, date: Date, recordCount: Int) {
        guard let dir = appGroupBackupsDirectory else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let meta = try? encoder.encode(MirrorMeta(date: date, recordCount: recordCount)) else { return }

        writeMirror(named: "backup-latest", data: data, meta: meta, in: dir)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bestCount = (try? Data(contentsOf: dir.appendingPathComponent("backup-best.meta.json")))
            .flatMap { try? decoder.decode(MirrorMeta.self, from: $0) }?
            .recordCount ?? -1
        if recordCount >= bestCount {
            writeMirror(named: "backup-best", data: data, meta: meta, in: dir)
        }
    }

    private static func writeMirror(named name: String, data: Data, meta: Data, in dir: URL) {
        try? data.write(to: dir.appendingPathComponent(name + ".json"), options: .atomic)
        try? meta.write(to: dir.appendingPathComponent(name + ".meta.json"), options: .atomic)
    }

    /// The App Group mirror backups, for the restore picker. Empty when the
    /// shared container is unavailable or no mirror has been written yet.
    static func appGroupMirrorBackups() -> [BackupInfo] {
        guard let dir = appGroupBackupsDirectory else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var output: [BackupInfo] = []
        for name in ["backup-best", "backup-latest"] {
            let file = dir.appendingPathComponent(name + ".json")
            guard FileManager.default.fileExists(atPath: file.path),
                  let metaData = try? Data(contentsOf: dir.appendingPathComponent(name + ".meta.json")),
                  let meta = try? decoder.decode(MirrorMeta.self, from: metaData) else { continue }
            output.append(BackupInfo(url: file, date: meta.date, recordCount: meta.recordCount,
                                     location: .sharedContainer))
        }
        // best and latest are often the same snapshot; no point listing twice.
        if output.count == 2, output[0].date == output[1].date, output[0].recordCount == output[1].recordCount {
            output.removeLast()
        }
        return output
    }

    /// Only used for the one-time recovery of an index that went missing;
    /// never called on the normal listing path.
    private static func decodeInfoFromFullFile(_ url: URL) -> BackupInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(Archive.self, from: data) else { return nil }
        return BackupInfo(url: url, date: archive.exportedAt, recordCount: archive.totalRecordCount)
    }

    /// One timestamp format across every backup this app makes.
    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

/// Owns the scheduling state (pending debounce task, in-flight flag, reused
/// backup actor) on its own actor, so concurrent calls to
/// `BackupService.scheduleBackupSoon`/`backupNowManually` from the main
/// thread and background tasks can't race on shared mutable state the way
/// plain static vars would.
private actor BackupCoordinator {
    static let shared = BackupCoordinator()

    private var pendingTask: Task<Void, Never>?
    private var backupActor: BackupActor?
    private var isRunning = false

    func scheduleSoon(container: ModelContainer, after seconds: Double) {
        pendingTask?.cancel()
        pendingTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.runAutomatic(container: container)
        }
    }

    /// Runs the debounced automatic backup. If a backup is already in flight,
    /// reschedule shortly rather than overlap; otherwise back up now. There's
    /// no rate limit — the debounce coalesces bursts and the content-hash
    /// dedupe skips no-op writes, so an automatic backup can safely follow
    /// every change. (The backgrounding hook additionally captures state
    /// immediately whenever the app leaves the foreground.)
    private func runAutomatic(container: ModelContainer) async {
        if isRunning {
            scheduleSoon(container: container, after: 5)
            return
        }
        _ = await runBackup(container: container)
    }

    func backupManually(container: ModelContainer) async -> URL? {
        guard !isRunning else { return nil }
        // The user explicitly asked for a backup right now; even when
        // there's nothing new to capture, the existing backup's timestamp
        // should be bumped so "Latest backup" confirms the tap did
        // something instead of silently reusing a stale date.
        return await runBackup(container: container, forceFreshTimestamp: true)
    }

    @discardableResult
    private func runBackup(container: ModelContainer, forceFreshTimestamp: Bool = false) async -> URL? {
        isRunning = true
        defer { isRunning = false }
        let actor = backupActor ?? BackupActor(modelContainer: container)
        backupActor = actor
        let (url, _) = await actor.backupNow(forceFreshTimestamp: forceFreshTimestamp)
        return url
    }
}

/// Private, background-safe `ModelContext` for building and writing backups
/// entirely off the main actor. `@ModelActor` gives this its own
/// actor-isolated context bound to the same persistent store as the app's
/// main context; nothing here ever touches `container.mainContext`.
@ModelActor
actor BackupActor {
    func backupNow(forceFreshTimestamp: Bool = false) -> (url: URL?, wrote: Bool) {
        BackupService.performBackup(context: modelContext, forceFreshTimestamp: forceFreshTimestamp)
    }
}

/// Wraps a `UIBackgroundTaskIdentifier` so begin/end can be called safely
/// from several different contexts — the caller (main actor), the
/// expiration handler (calling thread not guaranteed), and the backup
/// Task's own completion (a detached background task) — without racing on
/// the stored ID or double-ending it. `begin` runs on the main actor
/// directly, synchronously, before the detached backup Task starts, so `id`
/// is always set before anything could try to end it. `end` is
/// plain/nonisolated so any thread can call it, and hops to the main actor
/// via a fresh `Task` for the actual UIKit call.
private final class BackgroundTaskToken: @unchecked Sendable {
    private let lock = NSLock()
    private var id: UIBackgroundTaskIdentifier = .invalid

    @MainActor
    func begin(name: String, expiration: @escaping () -> Void) {
        lock.lock()
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            expiration()
            self?.end()
        }
        lock.unlock()
    }

    func end() {
        lock.lock()
        let current = id
        id = .invalid
        lock.unlock()
        guard current != .invalid else { return }
        Task { @MainActor in
            UIApplication.shared.endBackgroundTask(current)
        }
    }
}
