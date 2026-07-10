import SwiftUI

/// Previously generated briefings, newest first. Open, delete one, or
/// clear everything. Old briefings are never regenerated.
struct HistoryView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel = HistoryViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.briefs.isEmpty {
                    RestrainedEmptyState(
                        symbolName: "clock.arrow.circlepath",
                        title: "No briefings yet",
                        message: "Each morning's brief is kept here for \(BriefStore.retentionDays) days."
                    )
                } else {
                    List {
                        ForEach(viewModel.briefs) { brief in
                            NavigationLink(value: brief.id) {
                                HistoryRow(brief: brief)
                            }
                            .listRowBackground(Color.paper)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                viewModel.delete(viewModel.briefs[index])
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.paper)
            .navigationTitle("History")
            .navigationDestination(for: UUID.self) { id in
                if let brief = viewModel.briefs.first(where: { $0.id == id }) {
                    HistoryDetailView(brief: brief)
                }
            }
            .toolbar {
                if !viewModel.briefs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            viewModel.confirmDeleteAll = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete all history")
                    }
                }
            }
            .confirmationDialog(
                "Delete all briefing history?",
                isPresented: Bindable(viewModel).confirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) { viewModel.deleteAll() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { viewModel.reload() }
        .onChange(of: environment.engine.generationCounter) {
            viewModel.reloadIfGenerationAdvanced()
        }
    }
}

private struct HistoryRow: View {
    let brief: DailyBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(DateFormatting.mastheadDate.string(from: brief.briefingDate))
                    .font(.serif(17))
                    .foregroundStyle(Color.ink)
                if brief.status != .complete {
                    StatusBadge(
                        text: brief.status.displayName,
                        emphasis: brief.status == .partial ? .warning : .neutral
                    )
                }
                Spacer()
            }
            if let headline = brief.topHeadline {
                Text(headline)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(2)
            }
            Text("\(brief.locationName) · \(brief.estimatedReadingMinutes) min · \(brief.totalStoryCount) stories")
                .font(.caption2)
                .foregroundStyle(Color.inkSecondary.opacity(0.8))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A past briefing rendered with the same layout as Today, minus the
/// live greeting and refresh affordances.
struct HistoryDetailView: View {
    let brief: DailyBrief
    @Environment(AppEnvironment.self) private var environment
    @State private var presentedStory: BriefStory?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(DateFormatting.fullDate.string(from: brief.briefingDate).uppercased())
                        .font(.overline)
                        .kerning(1.6)
                        .foregroundStyle(Color.inkSecondary)
                    Text("The brief that morning")
                        .font(.serif(26, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Text("\(brief.locationName) · generated \(DateFormatting.time.string(from: brief.generatedAt)) · \(brief.estimatedReadingMinutes) min read")
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                BriefContentView(
                    brief: brief,
                    preferences: environment.preferencesStore.preferences,
                    onStoryTap: { story in
                        Haptics.tap()
                        presentedStory = story
                    }
                )
                .padding(.top, 20)
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Color.paper)
        .navigationTitle(DateFormatting.shortDate.string(from: brief.briefingDate))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $presentedStory) { story in
            StoryDetailView(story: story)
        }
    }
}
