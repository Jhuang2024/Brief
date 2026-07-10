import SwiftUI

struct TodayView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel = TodayViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paper.ignoresSafeArea()
                content
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            await viewModel.onAppear()
        }
        .onChange(of: environment.engine.generationCounter) {
            viewModel.reloadIfGenerationAdvanced()
        }
        .confirmationDialog(
            "A briefing was just generated. Generate another and use additional API credits?",
            isPresented: Bindable(viewModel).showRefreshConfirmation,
            titleVisibility: .visible
        ) {
            Button("Generate Again") { viewModel.startRefresh() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: Bindable(viewModel).presentedStory) { story in
            StoryDetailView(story: story)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let brief = viewModel.brief {
            briefScroll(brief)
        } else if viewModel.engine.isGenerating {
            GenerationProgressView()
        } else if !viewModel.hasAPIKey {
            missingKeyState
        } else if let error = viewModel.engine.lastError {
            failedState(error)
        } else {
            emptyStartState
        }
    }

    // MARK: - Brief content

    private func briefScroll(_ brief: DailyBrief) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MastheadView(
                    brief: brief,
                    freshness: viewModel.freshness,
                    isRefreshing: viewModel.engine.isGenerating,
                    onRefresh: { viewModel.refreshRequested() },
                    onToggleAudio: { viewModel.toggleAudio() },
                    audioState: viewModel.speech.state
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)

                if viewModel.engine.isGenerating {
                    inlineProgressStrip
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                } else if let error = viewModel.engine.lastError {
                    updateFailedBanner(error)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                if brief.status == .partial, !brief.failureNotes.isEmpty {
                    partialBanner(brief)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                BriefContentView(
                    brief: brief,
                    preferences: viewModel.preferences,
                    onStoryTap: { story in
                        Haptics.tap()
                        viewModel.presentedStory = story
                    }
                )
                .padding(.top, 20)
            }
            .padding(.bottom, viewModel.speech.state == .idle ? 24 : 96)
        }
        .refreshable {
            viewModel.refreshRequested()
        }
        .overlay(alignment: .bottom) {
            if viewModel.speech.state != .idle {
                AudioBar()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .scrollIndicators(.hidden)
    }

    private var inlineProgressStrip: some View {
        let active = viewModel.engine.phases.first { $0.status == .active }
        return HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(active?.title ?? "Updating…")
                .font(.footnote)
                .foregroundStyle(Color.inkSecondary)
            Spacer()
            if let startedAt = active?.startedAt {
                Text(startedAt, style: .timer)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.inkSecondary)
                    .monospacedDigit()
            }
        }
        .padding(10)
        .background(Color.paperRaised, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Updating briefing. \(active?.title ?? "")")
    }

    private func updateFailedBanner(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The update failed — showing the last briefing.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ink)
            Text(error)
                .font(.caption)
                .foregroundStyle(Color.inkSecondary)
            Button("Retry") { viewModel.startRefresh() }
                .font(.footnote.weight(.semibold))
                .tint(.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.paperRaised, in: RoundedRectangle(cornerRadius: 8))
    }

    private func partialBanner(_ brief: DailyBrief) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Some sections could not be updated.", systemImage: "exclamationmark.triangle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ink)
            ForEach(brief.failureNotes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.paperRaised, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Empty & error states

    private var missingKeyState: some View {
        VStack(spacing: 20) {
            Spacer()
            header
            RestrainedEmptyState(
                symbolName: "key",
                title: "One thing before your first brief",
                message: "Add your AI provider API key in Settings to generate a briefing."
            )
            Button {
                viewModel.openSettings()
            } label: {
                Text("Open Settings")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            Spacer()
        }
    }

    private func failedState(_ error: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            header
            RestrainedEmptyState(
                symbolName: "wifi.exclamationmark",
                title: "The briefing could not be generated",
                message: error
            )
            Button {
                viewModel.startRefresh()
            } label: {
                Text("Try Again")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            Spacer()
        }
    }

    private var emptyStartState: some View {
        VStack(spacing: 20) {
            Spacer()
            header
            RestrainedEmptyState(
                symbolName: "newspaper",
                title: "No briefing yet today",
                message: "Generate your morning brief to understand the day in a few minutes."
            )
            Button {
                viewModel.startRefresh()
            } label: {
                Text("Generate Briefing")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            Spacer()
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(DateFormatting.mastheadDate.string(from: Date()))
                .font(.mastheadDate)
                .foregroundStyle(Color.ink)
            Text(DateFormatting.greeting())
                .font(.subheadline)
                .foregroundStyle(Color.inkSecondary)
        }
    }
}

#Preview("Today") {
    TodayView()
        .environment(AppEnvironment.shared)
}
