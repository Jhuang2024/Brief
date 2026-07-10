import SwiftUI

/// Root Settings: Connections, Briefing, Sections, Interests, Sources,
/// Models, Appearance, Data.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel = SettingsViewModel()
    @State private var confirmDeleteAll = false
    @State private var confirmReset = false

    var body: some View {
        @Bindable var store = environment.preferencesStore
        NavigationStack {
            Form {
                connectionsSection
                briefingSection(store: $store)
                listsSection
                appearanceSection(store: $store)
                dataSection
            }
            .navigationTitle("Settings")
            .task {
                await environment.notificationService.refreshAuthorizationStatus()
                if viewModel.googleAuth.isConnected {
                    await viewModel.loadCalendarList()
                }
            }
            .onChange(of: store.preferences.morningMinutesAfterMidnight) {
                rescheduleReminder()
            }
            .onChange(of: store.preferences.notificationsEnabled) {
                rescheduleReminder()
            }
        }
    }

    private func rescheduleReminder() {
        Task {
            await environment.notificationService.updateMorningReminder(
                preferences: environment.preferencesStore.preferences
            )
            environment.backgroundRefresh.scheduleNextRefresh()
        }
    }

    // MARK: - Connections

    private var connectionsSection: some View {
        Section("Connections") {
            NavigationLink {
                OpenRouterKeyView(viewModel: viewModel)
            } label: {
                LabeledContent("OpenRouter API Key") {
                    Text(viewModel.hasStoredKey ? "Saved" : "Not set")
                        .foregroundStyle(viewModel.hasStoredKey ? Color.secondary : Color.orange)
                }
            }

            googleRow

            NavigationLink {
                CalendarSelectionView(viewModel: viewModel)
            } label: {
                Text("Select Calendars")
            }
            .disabled(!viewModel.googleAuth.isConnected)

            LabeledContent("Location", value: viewModel.locationStatusDescription)
            LabeledContent("Notifications", value: viewModel.notificationStatusDescription)
        }
    }

    @ViewBuilder
    private var googleRow: some View {
        LabeledContent("Google Calendar") {
            Text(viewModel.googleAuth.state.displayName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        if viewModel.googleAuth.isConnected {
            Button("Disconnect Google", role: .destructive) {
                viewModel.disconnectGoogle()
            }
        } else {
            Button("Connect Google Calendar") {
                Task { await viewModel.connectGoogle() }
            }
        }
        if let error = viewModel.googleError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Briefing

    private func briefingSection(store: Bindable<PreferencesStore>) -> some View {
        Section("Briefing") {
            DatePicker(
                "Morning time",
                selection: morningTimeBinding,
                displayedComponents: .hourAndMinute
            )
            Picker("Length", selection: store.preferences.briefLength) {
                ForEach(BriefLength.allCases) { length in
                    Text(length.displayName).tag(length)
                }
            }
            Stepper(
                "Max reading time: \(store.preferences.maxReadingMinutes.wrappedValue) min",
                value: store.preferences.maxReadingMinutes,
                in: 3...15
            )
            Toggle("Refresh automatically when stale", isOn: store.preferences.automaticRefreshEnabled)
            Toggle("Morning notification", isOn: store.preferences.notificationsEnabled)
            Toggle("Include “Why it matters”", isOn: store.preferences.includeWhyItMatters)
            Toggle("Include Calendar", isOn: store.preferences.includeCalendar)
            Toggle("Include weather", isOn: store.preferences.includeWeather)
            Toggle("Send event descriptions to OpenRouter", isOn: store.preferences.sendEventDescriptions)
        }
    }

    private var morningTimeBinding: Binding<Date> {
        Binding(
            get: {
                let minutes = environment.preferencesStore.preferences.morningMinutesAfterMidnight
                return Calendar.current.date(
                    bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()
                ) ?? Date()
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                environment.preferencesStore.preferences.morningMinutesAfterMidnight =
                    (components.hour ?? 7) * 60 + (components.minute ?? 30)
            }
        )
    }

    // MARK: - Sections / Interests / Sources / Models

    private var listsSection: some View {
        Section {
            NavigationLink("Sections") { SectionsSettingsView() }
            NavigationLink("Interests") { InterestsSettingsView() }
            NavigationLink("Sources") { SourcesSettingsView() }
            NavigationLink("Models") { ModelsSettingsView() }
        }
    }

    // MARK: - Appearance

    private func appearanceSection(store: Bindable<PreferencesStore>) -> some View {
        Section("Appearance") {
            Picker("Theme", selection: store.preferences.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            Picker("Text size", selection: store.preferences.textSize) {
                ForEach(TextSizePreference.allCases) { size in
                    Text(size.displayName).tag(size)
                }
            }
            Toggle("Reduce motion", isOn: store.preferences.reducedMotion)
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            Button("Delete today's briefing", role: .destructive) {
                viewModel.deleteTodaysBrief()
                Haptics.tick()
            }
            Button("Delete all history", role: .destructive) {
                confirmDeleteAll = true
            }
            .confirmationDialog(
                "Delete every stored briefing?",
                isPresented: $confirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) { viewModel.deleteAllHistory() }
                Button("Cancel", role: .cancel) {}
            }
            Button("Reset preferences", role: .destructive) {
                confirmReset = true
            }
            .confirmationDialog(
                "Reset all preferences to their defaults? Briefing history is kept.",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) { viewModel.resetPreferences() }
                Button("Cancel", role: .cancel) {}
            }
            ShareLink(
                item: viewModel.diagnosticsJSON,
                preview: SharePreview("Brief diagnostics")
            ) {
                Text("Export diagnostic JSON")
            }
            #if DEBUG
            Button("Load sample briefing (debug)") {
                SampleBrief.insertSample(into: environment.briefStore)
                Haptics.briefReady()
            }
            #endif
        } header: {
            Text("Data")
        } footer: {
            Text("Diagnostics describe the most recent generation and never include your OpenRouter key or Google tokens. Briefings are kept for \(BriefStore.retentionDays) days.")
        }
    }
}

/// OpenRouter key entry and connection test. The stored key is never
/// displayed back; it lives only in the Keychain.
struct OpenRouterKeyView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                if viewModel.hasStoredKey {
                    LabeledContent("Status", value: "Key saved in Keychain")
                }
                SecureField(
                    viewModel.hasStoredKey ? "Replace key (sk-or-…)" : "Paste key (sk-or-…)",
                    text: $viewModel.apiKeyInput
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                Button("Save Key") { viewModel.saveAPIKey() }
                    .disabled(viewModel.apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if viewModel.hasStoredKey {
                    Button("Remove Key", role: .destructive) { viewModel.removeAPIKey() }
                }
            } header: {
                Text("OpenRouter API Key")
            } footer: {
                Text("Create a key at openrouter.ai → Keys. It is stored in the iOS Keychain, not in the app's files, and is only sent to openrouter.ai.")
            }

            Section {
                Button {
                    viewModel.testConnection()
                } label: {
                    HStack {
                        Text("Test Connection")
                        if viewModel.isTestingConnection {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!viewModel.hasStoredKey || viewModel.isTestingConnection)
                if let result = viewModel.connectionTestResult {
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("OpenRouter")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Calendar selection: fetch the list, toggle calendars, primary by default.
struct CalendarSelectionView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                if viewModel.isLoadingCalendars {
                    HStack {
                        ProgressView()
                        Text("Loading calendars…")
                            .foregroundStyle(.secondary)
                    }
                } else if viewModel.availableCalendars.isEmpty {
                    Text("No calendars loaded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.availableCalendars) { calendar in
                        Toggle(isOn: Binding(
                            get: { viewModel.isCalendarSelected(calendar) },
                            set: { viewModel.toggleCalendar(calendar, selected: $0) }
                        )) {
                            HStack {
                                Text(calendar.summary)
                                if calendar.isPrimary {
                                    StatusBadge(text: "Primary", emphasis: .accent)
                                }
                            }
                        }
                    }
                }
            } footer: {
                Text("Events from the selected calendars are merged chronologically and deduplicated. Access is read-only.")
            }
        }
        .navigationTitle("Calendars")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadCalendarList() }
        .refreshable { await viewModel.loadCalendarList() }
    }
}
