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
                breakingAlertsSection(store: $store)
                listsSection
                appearanceSection(store: $store)
                dataSection
            }
            .briefFormStyle()
            .toolbarBackground(Color.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
            .onChange(of: store.preferences.breakingAlertsEnabled) {
                environment.backgroundRefresh.scheduleNextBreakingCheck()
            }
        }
    }

    private var aiProviderSummary: String {
        switch (viewModel.hasOpenRouterKey, viewModel.hasBazaarlinkKey) {
        case (true, true): return "Both saved"
        case (true, false): return "OpenRouter saved"
        case (false, true): return "Bazaarlink saved"
        case (false, false): return "Not set"
        }
    }

    private func rescheduleReminder() {
        Task {
            await environment.notificationService.updateMorningReminder(
                preferences: environment.preferencesStore.preferences
            )
        }
    }

    // MARK: - Connections

    private var connectionsSection: some View {
        Section {
            NavigationLink {
                AIProviderView(viewModel: viewModel)
            } label: {
                LabeledContent("AI Provider") {
                    Text(aiProviderSummary)
                        .foregroundStyle(
                            viewModel.hasOpenRouterKey || viewModel.hasBazaarlinkKey
                                ? Color.inkSecondary : Color.orange
                        )
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
        } header: {
            FormSectionHeader(title: "Connections")
        }
    }

    @ViewBuilder
    private var googleRow: some View {
        LabeledContent("Google Calendar") {
            Text(viewModel.googleAuth.state.displayName)
                .foregroundStyle(Color.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        switch viewModel.googleAuth.state {
        case .notConfigured:
            VStack(alignment: .leading, spacing: 4) {
                Text("Google Calendar isn't set up yet.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ink)
                Text("An iOS OAuth client ID has to be added to Info.plist before the app can connect. This is a one-time step, not something you enter here. See SETUP.md for the five-minute Google Cloud walkthrough.")
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
            }
            .padding(.vertical, 2)
        case .connected:
            Button("Disconnect Google", role: .destructive) {
                viewModel.disconnectGoogle()
            }
        default:
            Button("Connect Google Calendar") {
                Task { await viewModel.connectGoogle() }
            }
        }
        if let error = viewModel.googleError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }

        // Calendar self-test. Uses only the free Google Calendar API, so it
        // diagnoses a "Calendar unavailable" brief without regenerating one
        // or spending any AI generation credits.
        if case .notConfigured = viewModel.googleAuth.state {
            EmptyView()
        } else {
            Button {
                viewModel.testCalendar()
            } label: {
                HStack {
                    Text("Test Calendar")
                    if viewModel.isTestingCalendar {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(viewModel.isTestingCalendar)
            if let result = viewModel.calendarTestResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
                    .textSelection(.enabled)
            } else if let last = viewModel.lastCalendarDiagnostic {
                Text(last)
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Briefing

    private func briefingSection(store: Bindable<PreferencesStore>) -> some View {
        Section {
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
            Toggle("Generate automatically at morning time", isOn: store.preferences.automaticRefreshEnabled)
            Toggle("Morning notification", isOn: store.preferences.notificationsEnabled)
            Toggle("Include “Why it matters”", isOn: store.preferences.includeWhyItMatters)
            Toggle("Include Calendar", isOn: store.preferences.includeCalendar)
            Toggle("Include weather", isOn: store.preferences.includeWeather)
            Toggle("Include LockedInFit", isOn: store.preferences.includeLockedInFit)
            Toggle("Include Social Climber", isOn: store.preferences.includeSocialClimber)
            Toggle("Send event descriptions to OpenRouter", isOn: store.preferences.sendEventDescriptions)
        } header: {
            FormSectionHeader(title: "Briefing")
        } footer: {
            Text("The brief only generates automatically at the morning time above, or when you tap refresh, never in between, even if it gets old during the day. This keeps API usage predictable. LockedInFit and Social Climber are read on-device from their shared app data, never sent to any AI provider.")
                .foregroundStyle(Color.inkSecondary)
        }
    }

    private func breakingAlertsSection(store: Bindable<PreferencesStore>) -> some View {
        Section {
            Toggle("Hourly breaking check", isOn: store.preferences.breakingAlertsEnabled)
        } header: {
            FormSectionHeader(title: "Breaking Alerts")
        } footer: {
            Text("Roughly once an hour, a single small check looks for news urgent enough to interrupt your day, a very high bar, deliberately not another brief. Most hours find nothing and cost nothing. When something does qualify, it's saved here and you get a notification; otherwise you hear nothing at all.")
                .foregroundStyle(Color.inkSecondary)
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
        } header: {
            FormSectionHeader(title: "Content")
        }
    }

    // MARK: - Appearance

    private func appearanceSection(store: Bindable<PreferencesStore>) -> some View {
        Section {
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
        } header: {
            FormSectionHeader(title: "Appearance")
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
                Button("Delete All", role: .destructive) {
                    Task { await viewModel.deleteAllHistory() }
                }
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
            FormSectionHeader(title: "Data")
        } footer: {
            Text("Diagnostics describe the most recent generation and never include your OpenRouter key or Google tokens. Briefings are kept for \(BriefStore.retentionDays) days.")
                .foregroundStyle(Color.inkSecondary)
        }
    }
}

/// Both providers can hold a saved key at once. Generation tries the
/// preferred provider first and automatically retries with the other one
/// if it has a saved key and the first attempt fails — "use whichever one
/// works." Neither key is ever displayed back once saved; both live only
/// in the Keychain.
struct AIProviderView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        @Bindable var store = viewModel.preferencesStore
        Form {
            Section {
                Picker("Preferred provider", selection: $store.preferences.preferredProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            } footer: {
                Text("Brief tries this provider first. If a request fails and the other provider has a saved key, it automatically retries there instead.")
                    .foregroundStyle(Color.inkSecondary)
            }

            providerSection(.openRouter)
            providerSection(.bazaarlink)

            Section {
                Toggle("Structured JSON output", isOn: $store.preferences.useStructuredOutput)
                Toggle("Web search plugin", isOn: $store.preferences.useWebSearchPlugin)
            } header: {
                FormSectionHeader(title: "Request Shape")
            } footer: {
                Text("Both are OpenRouter-style extensions to the chat completions request that Bazaarlink also appears to support. Turn either off if a request is being rejected because of it. Brief falls back to asking for JSON in plain language when structured output is off, and research simply won't be web-grounded when the search plugin is off. Applies to whichever provider ends up handling the request.")
                    .foregroundStyle(Color.inkSecondary)
            }
        }
        .briefFormStyle()
        .navigationTitle("AI Provider")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
    }

    private func providerSection(_ provider: AIProvider) -> some View {
        Section {
            if viewModel.hasStoredKey(for: provider) {
                LabeledContent("Status", value: "Key saved in Keychain")
            }
            SecureField(
                viewModel.hasStoredKey(for: provider) ? "Replace key" : "Paste key",
                text: keyInputBinding(for: provider)
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            Button("Save Key") { viewModel.saveKey(for: provider) }
                .disabled(keyInputBinding(for: provider).wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            if viewModel.hasStoredKey(for: provider) {
                Button("Remove Key", role: .destructive) { viewModel.removeKey(for: provider) }
            }
            Button {
                viewModel.testConnection(for: provider)
            } label: {
                HStack {
                    Text("Test Connection")
                    if viewModel.isTesting(for: provider) {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!viewModel.hasStoredKey(for: provider) || viewModel.isTesting(for: provider))
            if let result = viewModel.testResult(for: provider) {
                Text(result)
                    .font(.footnote)
                    .foregroundStyle(Color.inkSecondary)
            }
        } header: {
            FormSectionHeader(title: provider.displayName)
        } footer: {
            Text("\(provider.baseURL.absoluteString): stored in the iOS Keychain, not in the app's files, and only ever sent to this provider.")
                .foregroundStyle(Color.inkSecondary)
        }
    }

    private func keyInputBinding(for provider: AIProvider) -> Binding<String> {
        switch provider {
        case .openRouter: return $viewModel.openRouterKeyInput
        case .bazaarlink: return $viewModel.bazaarlinkKeyInput
        }
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
                            .foregroundStyle(Color.inkSecondary)
                    }
                } else if !viewModel.googleAuth.isConnected {
                    Text("Connect Google Calendar first.")
                        .foregroundStyle(Color.inkSecondary)
                } else if viewModel.availableCalendars.isEmpty {
                    Text("No calendars loaded yet.")
                        .foregroundStyle(Color.inkSecondary)
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
                    .foregroundStyle(Color.inkSecondary)
            }
        }
        .briefFormStyle()
        .navigationTitle("Calendars")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadCalendarList() }
        .refreshable { await viewModel.loadCalendarList() }
    }
}
