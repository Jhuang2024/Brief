import SwiftUI

/// Previously generated briefings, grouped by month like a newspaper
/// archive index. Open, delete one, or clear everything. Old briefings
/// are never regenerated.
struct HistoryView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel = HistoryViewModel()
    @State private var selectedBriefID: UUID?

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
                    archiveList
                }
            }
            .background(Color.paper)
            .toolbarBackground(Color.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("History")
            .navigationDestination(item: $selectedBriefID) { id in
                if let brief = viewModel.briefs.first(where: { $0.id == id }) {
                    HistoryDetailView(brief: brief)
                }
            }
            .toolbar {
                if !viewModel.briefs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        if viewModel.isDeletingAll {
                            ProgressView()
                        } else {
                            Button(role: .destructive) {
                                viewModel.confirmDeleteAll = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete all history")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete all briefing history?",
                isPresented: Bindable(viewModel).confirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    Task { await viewModel.deleteAll() }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { viewModel.reload() }
        .onChange(of: environment.engine.generationCounter) {
            viewModel.reloadIfGenerationAdvanced()
        }
    }

    /// A plain, chrome-free list: no default separators, row insets, or
    /// navigation-link disclosure chevrons, so the fine-rule dividers and
    /// month headers read as one continuous editorial index rather than
    /// a stock iOS list. Navigation is driven manually (`selectedBriefID`)
    /// so the row can own its own custom chevron.
    private var archiveList: some View {
        List {
            ForEach(Array(viewModel.groupedByMonth.enumerated()), id: \.element.id) { groupIndex, group in
                Text(group.monthLabel.uppercased())
                    .font(.overline)
                    .kerning(1.4)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.horizontal, 20)
                    .padding(.top, groupIndex == 0 ? 4 : 22)
                    .padding(.bottom, 6)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.paper)

                ForEach(Array(group.briefs.enumerated()), id: \.element.id) { index, brief in
                    Button {
                        Haptics.tap()
                        selectedBriefID = brief.id
                    } label: {
                        HistoryRow(brief: brief)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.paper)
                    .overlay(alignment: .bottom) {
                        if index != group.briefs.count - 1 {
                            FineRule().padding(.leading, 66)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            viewModel.delete(brief)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.paper)
    }
}

/// One archive row: a torn-calendar date block, headline, and meta line.
private struct HistoryRow: View {
    let brief: DailyBrief

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 1) {
                Text(DateFormatting.dayOfMonth.string(from: brief.briefingDate))
                    .font(.serif(20, weight: .bold))
                    .foregroundStyle(Color.ink)
                Text(DateFormatting.weekdayAbbreviated.string(from: brief.briefingDate).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Color.inkSecondary)
            }
            .frame(width: 40)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let headline = brief.topHeadline {
                        Text(headline)
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(Color.ink)
                            .lineLimit(2)
                    } else {
                        Text("No stories generated")
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(Color.inkSecondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Text("\(brief.estimatedReadingMinutes) min · \(brief.totalStoryCount) stories")
                    if brief.status != .complete {
                        Text("·")
                        StatusBadge(
                            text: brief.status.displayName,
                            emphasis: brief.status == .partial ? .warning : .neutral
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.inkSecondary)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.inkSecondary.opacity(0.6))
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Color.paper)
        .toolbarBackground(Color.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle(DateFormatting.shortDate.string(from: brief.briefingDate))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $presentedStory) { story in
            StoryDetailView(story: story)
        }
    }
}
