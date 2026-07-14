import SwiftUI
import SwiftData

/// Picker over every available backup (the local rotation plus the App
/// Group mirrors that survive reinstalls) instead of blindly restoring the
/// newest. The distinction is the whole point: after an update wipes the
/// app container, the NEWEST backup is usually a backup of the post-wipe,
/// nearly-empty state (the app resumed auto-backing-up immediately), while
/// the one the user actually wants is the most COMPLETE one. So that's the
/// sort order, and the badge.
struct BackupRestoreListView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment

    @State private var backups: [BackupService.BackupInfo] = []
    @State private var pendingRestore: BackupService.BackupInfo?
    @State private var result: String?

    var body: some View {
        Form {
            Section {
                if backups.isEmpty {
                    Text("No backups found on this device or in the shared container yet. Backups are taken automatically as briefs generate.")
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                }
                ForEach(backups) { backup in
                    Button {
                        pendingRestore = backup
                    } label: {
                        row(backup)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                FormSectionHeader(title: "Choose a Backup")
            } footer: {
                Text("Sorted most-complete first. Restoring merges the backup's briefings and alerts into what's on the device now; nothing is deleted. If an app update wiped your data, pick the entry with the most records, not necessarily the newest one. Restored briefings older than \(BriefStore.retentionDays) days are still pruned on the next launch.")
                    .foregroundStyle(Color.inkSecondary)
            }

            if let result {
                Section {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                }
            }
        }
        .briefFormStyle()
        .navigationTitle("Restore From Backup")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .confirmationDialog("Restore this backup?",
                            isPresented: Binding(get: { pendingRestore != nil },
                                                 set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingRestore) { backup in
            Button("Restore \(backup.recordCount) records") { restore(backup) }
        }
    }

    private func load() {
        backups = BackupService.allKnownBackups()
    }

    private func row(_ backup: BackupService.BackupInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ink)
                Spacer()
                if backup.recordCount == backups.first?.recordCount {
                    Text("Most complete")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
            Text("\(backup.recordCount) records\(backup.location == .sharedContainer ? " · shared container (survives reinstall)" : "")")
                .font(.caption)
                .foregroundStyle(Color.inkSecondary)
        }
        .contentShape(Rectangle())
    }

    private func restore(_ backup: BackupService.BackupInfo) {
        let currentCount = BackupService.currentRecordCount(context: context)
        switch BackupService.restore(
            from: backup,
            context: context,
            preferencesStore: environment.preferencesStore,
            currentRecordCount: currentCount
        ) {
        case .restored(let count, let preferencesApplied):
            result = "Restored \(count) records from the \(backup.date.formatted(date: .abbreviated, time: .omitted)) backup."
                + (preferencesApplied ? " Preferences were restored too." : "")
            BackupService.scheduleBackupSoon(container: context.container)
        case .emptyBackupSkipped:
            result = "That backup is empty; nothing to restore."
        case .failed(let error):
            result = "Restore failed: \(error.localizedDescription)"
        }
    }
}
