import SwiftUI

/// The body of a briefing, shared between Today and History detail:
/// today strip, day-in-one-minute, calendar, news sections, ending.
struct BriefContentView: View {
    let brief: DailyBrief
    let preferences: UserPreferences
    let onStoryTap: (BriefStory) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            TodayStripView(brief: brief, preferences: preferences)
                .padding(.horizontal, 20)

            if !brief.overviewItems.isEmpty {
                overviewSection
                    .padding(.horizontal, 20)
            }

            if preferences.includeCalendar {
                calendarSection
                    .padding(.horizontal, 20)
            }

            newsSections

            ending
                .padding(.horizontal, 20)
        }
    }

    // MARK: - C. The day in one minute

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(index: 1, title: "The Day in One Minute")
            ForEach(Array(brief.overviewItems.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.system(size: 16))
                    .lineSpacing(3)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - D. Calendar

    @ViewBuilder
    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(index: 2, title: "Calendar")
            if !brief.calendarWasAvailable {
                Text("Calendar unavailable for this briefing.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSecondary)
            } else if brief.calendarEvents.isEmpty {
                Text("Nothing scheduled.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(brief.calendarEvents) { event in
                        CalendarEventRow(event: event)
                        if event != brief.calendarEvents.last {
                            FineRule()
                        }
                    }
                }
            }
        }
    }

    // MARK: - E. News sections

    private var newsSections: some View {
        ForEach(Array(brief.orderedSections.enumerated()), id: \.element.id) { index, section in
            VStack(alignment: .leading, spacing: 4) {
                SectionHeaderView(index: index + 3, title: section.title)
                    .padding(.horizontal, 20)
                ForEach(section.orderedStories) { story in
                    StoryRowView(
                        story: story,
                        showsWhyItMatters: preferences.includeWhyItMatters
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onStoryTap(story) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the full story")
                    if story != section.orderedStories.last {
                        FineRule()
                            .padding(.horizontal, 20)
                    }
                }
            }
        }
    }

    // MARK: - The deliberate ending

    private var ending: some View {
        VStack(alignment: .leading, spacing: 10) {
            FineRule(strong: true)
            Text("That's your brief.")
                .font(.serif(20))
                .foregroundStyle(Color.ink)
            Text("Have a good day.")
                .font(.subheadline)
                .foregroundStyle(Color.inkSecondary)
            Text(generationFootnote)
                .font(.caption2)
                .foregroundStyle(Color.inkSecondary.opacity(0.8))
                .padding(.top, 8)
        }
        .padding(.top, 8)
    }

    private var generationFootnote: String {
        var parts = [
            "Generated \(DateFormatting.time.string(from: brief.generatedAt))",
            String(format: "%.0fs", brief.generationDuration),
        ]
        if !brief.editorModel.isEmpty {
            parts.append(brief.editorModel)
        }
        if brief.inputTokens > 0 || brief.outputTokens > 0 {
            parts.append("\(brief.inputTokens + brief.outputTokens) tokens")
        }
        return parts.joined(separator: " · ")
    }
}

/// One calendar row: time column, title, location, countdown.
struct CalendarEventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 1) {
                if event.isAllDay {
                    Text("All day")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                } else {
                    Text(DateFormatting.time.string(from: event.start))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(DateFormatting.time.string(from: event.end))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .frame(width: 62, alignment: .trailing)
            .foregroundStyle(Color.ink)

            Rectangle()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: 2)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ink)
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !event.isAllDay, event.start > Date() {
                Text(DateFormatting.countdown(to: event.start))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.inkSecondary)
            } else if event.isHappening() {
                Text("Now")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

/// One story in a section: headline, meta, summary, why it matters, sources.
struct StoryRowView: View {
    let story: BriefStory
    let showsWhyItMatters: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if let label = story.status.label {
                    StatusBadge(
                        text: label,
                        emphasis: story.status == .breaking ? .accent : .neutral
                    )
                }
                if story.isUpdate {
                    StatusBadge(text: "Update", emphasis: .accent)
                }
                if let date = story.developmentDate {
                    Text(DateFormatting.relativePast(date))
                        .font(.caption2)
                        .foregroundStyle(Color.inkSecondary)
                }
                Spacer()
            }

            Text(story.headline)
                .font(.storyHeadline)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(story.summary)
                .font(.system(size: 15))
                .lineSpacing(2.5)
                .foregroundStyle(Color.ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            if showsWhyItMatters, !story.whyItMatters.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                    Text(story.whyItMatters)
                        .font(.system(size: 13.5).italic())
                        .lineSpacing(2)
                        .foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 1)
            }

            if !story.sources.isEmpty {
                Text(story.orderedSources.map(\.domain).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(Color.inkSecondary.opacity(0.85))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
