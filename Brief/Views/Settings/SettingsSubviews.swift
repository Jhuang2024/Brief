import SwiftUI

/// Enable, disable, rename, reorder sections and set per-section limits.
struct SectionsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var store = environment.preferencesStore
        List {
            Section {
                ForEach(sortedIndices(of: store.preferences.sections), id: \.self) { index in
                    sectionRow(store: $store, index: index)
                }
                .onMove { source, destination in
                    move(store: $store, from: source, to: destination)
                }
            } footer: {
                Text("Limits are maximums, not quotas — a section with nothing worthwhile is omitted. Drag to reorder.")
            }
        }
        .navigationTitle("Sections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func sortedIndices(of sections: [SectionConfiguration]) -> [Int] {
        sections.indices.sorted { sections[$0].order < sections[$1].order }
    }

    private func sectionRow(store: Bindable<PreferencesStore>, index: Int) -> some View {
        let sections = store.preferences.sections
        let section = sections.wrappedValue[index]
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: sections[index].isEnabled) {
                Text(section.category.defaultTitle)
                    .font(.system(size: 15, weight: .medium))
            }
            if section.isEnabled {
                TextField("Custom name (optional)", text: sections[index].customTitle)
                    .font(.system(size: 14))
                    .textFieldStyle(.roundedBorder)
                Stepper(
                    "Max stories: \(section.maxStories)",
                    value: sections[index].maxStories,
                    in: 1...8
                )
                .font(.system(size: 14))
            }
        }
        .padding(.vertical, 2)
    }

    /// Reorder within the sorted presentation, then persist as `order` values.
    private func move(store: Bindable<PreferencesStore>, from source: IndexSet, to destination: Int) {
        var prefs = store.preferences.wrappedValue
        var sorted = prefs.sections.sorted { $0.order < $1.order }
        sorted.move(fromOffsets: source, toOffset: destination)
        for (newOrder, section) in sorted.enumerated() {
            if let index = prefs.sections.firstIndex(where: { $0.category == section.category }) {
                prefs.sections[index].order = newOrder
            }
        }
        store.preferences.wrappedValue = prefs
        Haptics.tick()
    }
}

/// Editable interest lists: topics, companies, people, F1, sports,
/// universities, excluded keywords — plus the spoiler toggle.
struct InterestsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var store = environment.preferencesStore
        List {
            Section("Follow") {
                interestLink("Topics", items: $store.preferences.topics, placeholder: "Topic")
                interestLink("Companies", items: $store.preferences.companies, placeholder: "Company")
                interestLink("People", items: $store.preferences.people, placeholder: "Person")
                interestLink("F1 Drivers & Teams", items: $store.preferences.f1DriversAndTeams, placeholder: "Driver or team")
                interestLink("Sports Leagues", items: $store.preferences.sportsLeagues, placeholder: "League")
                interestLink("Sports Teams", items: $store.preferences.sportsTeams, placeholder: "Team")
                interestLink("Athletes", items: $store.preferences.athletes, placeholder: "Athlete")
                interestLink("Universities", items: $store.preferences.universities, placeholder: "University")
            }
            Section {
                interestLink("Keywords to Exclude", items: $store.preferences.excludedKeywords, placeholder: "Keyword")
            } footer: {
                Text("Stories matching excluded keywords are suppressed during research.")
            }
            Section {
                Toggle("Show scores (spoilers)", isOn: $store.preferences.spoilersEnabled)
            } footer: {
                Text("When off, the sports section is asked to keep final scores out of headlines.")
            }
        }
        .navigationTitle("Interests")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func interestLink(_ title: String, items: Binding<[String]>, placeholder: String) -> some View {
        NavigationLink {
            EditableListView(title: title, placeholder: placeholder, items: items)
        } label: {
            LabeledContent(title, value: "\(items.wrappedValue.count)")
        }
    }
}

/// Preferred/excluded domains and sourcing policy toggles.
struct SourcesSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var store = environment.preferencesStore
        List {
            Section {
                NavigationLink {
                    EditableListView(
                        title: "Preferred Domains",
                        placeholder: "example.com",
                        items: $store.preferences.preferredDomains
                    )
                } label: {
                    LabeledContent("Preferred domains", value: "\(store.preferences.preferredDomains.count)")
                }
                NavigationLink {
                    EditableListView(
                        title: "Excluded Domains",
                        placeholder: "example.com",
                        items: $store.preferences.excludedDomains
                    )
                } label: {
                    LabeledContent("Excluded domains", value: "\(store.preferences.excludedDomains.count)")
                }
            } footer: {
                Text("Sources from excluded domains are removed from research results entirely.")
            }
            Section {
                Toggle("Prefer official sources", isOn: $store.preferences.preferOfficialSources)
                Toggle("Require multiple sources for major breaking news", isOn: $store.preferences.requireMultipleSourcesForBreaking)
            }
        }
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Research and editor model slugs plus research depth.
struct ModelsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    private static let suggestedModels = [
        "openrouter/auto",
        "anthropic/claude-sonnet-4.5",
        "openai/gpt-5.1",
        "google/gemini-2.5-pro",
        "perplexity/sonar-pro",
    ]

    var body: some View {
        @Bindable var store = environment.preferencesStore
        Form {
            Section {
                modelField(title: "Research model", text: $store.preferences.researchModel)
            } footer: {
                Text("Used for the web-grounded research requests. Any OpenRouter model slug works; openrouter/auto lets OpenRouter choose.")
            }
            Section {
                modelField(title: "Editor model", text: $store.preferences.editorModel)
            } footer: {
                Text("Used for editorial synthesis and structured output.")
            }
            Section {
                Picker("Research depth", selection: $store.preferences.researchDepth) {
                    ForEach(ResearchDepth.allCases) { depth in
                        Text(depth.displayName).tag(depth)
                    }
                }
            } footer: {
                Text("Depth controls web-search result counts and how many candidate stories each research request may return. Deeper is slower and uses more credits.")
            }
        }
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modelField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("model/slug", text: text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 15, design: .monospaced))
            Menu("Suggestions") {
                ForEach(Self.suggestedModels, id: \.self) { slug in
                    Button(slug) { text.wrappedValue = slug }
                }
            }
            .font(.footnote)
        }
        .padding(.vertical, 2)
    }
}
