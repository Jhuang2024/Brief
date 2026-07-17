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

            if preferences.includeEmail {
                emailSection
                    .padding(.horizontal, 20)
            }

            linkedAppSections

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

    // MARK: - E. Email

    /// Shift applied to every section number after Email, so numbering
    /// stays consecutive whether or not the Email section is shown.
    private var emailSectionOffset: Int {
        preferences.includeEmail ? 1 : 0
    }

    @ViewBuilder
    private var emailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(index: 3, title: "Email")
            if !brief.emailWasAvailable {
                Text("Email unavailable for this briefing. Grant Gmail access in Settings → Connections.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if brief.emailMessages.isEmpty {
                // The section only ever shows important, still-unread mail;
                // an empty morning is stated plainly rather than padded with
                // whatever happens to be in the inbox.
                Text("Nothing important overnight.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(brief.emailMessages) { message in
                        EmailMessageRow(message: message)
                        if message != brief.emailMessages.last {
                            FineRule()
                        }
                    }
                }
            }
        }
    }

    // MARK: - F. Linked apps (LockedInFit, Social Climber)

    /// Personal sections read verbatim from the companion apps' feeds at
    /// generation time. Which apps appear is decided by the engine (the
    /// Settings toggles), so History renders exactly what each morning
    /// showed regardless of today's toggle state.
    private var linkedAppSections: some View {
        ForEach(Array(brief.linkedAppDigests.enumerated()), id: \.element.id) { index, digest in
            LinkedAppSectionView(digest: digest, index: index + 3 + emailSectionOffset)
                .padding(.horizontal, 20)
        }
    }

    // MARK: - G. News sections

    private var newsSections: some View {
        ForEach(Array(brief.orderedSections.enumerated()), id: \.element.id) { index, section in
            VStack(alignment: .leading, spacing: 4) {
                SectionHeaderView(index: index + 3 + emailSectionOffset + brief.linkedAppDigests.count, title: section.title)
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

/// One inbox message: time column, sender, subject, snippet. Mirrors
/// CalendarEventRow's layout so the brief reads as one system; everything
/// shown is verbatim from Gmail. No unread dot: the section only ever
/// contains mail that was unread when the brief was generated, and a dot
/// claiming "unread" hours later (after Jerry has read the mail itself)
/// read as the brief being wrong.
struct EmailMessageRow: View {
    let message: EmailMessage

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(DateFormatting.time.string(from: message.receivedAt))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(width: 62, alignment: .trailing)
                .foregroundStyle(Color.ink)

            Rectangle()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: 2)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.fromName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(1)
                Text(message.subject)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.snippet.isEmpty {
                    Text(message.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

/// One linked app's block: yesterday's activity lines and today's
/// reminders, straight from the app's feed. Deliberately plain and factual;
/// nothing here passed through a model.
struct LinkedAppSectionView: View {
    let digest: LinkedAppDigest
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(index: index, title: digest.app.displayName)

            if let note = digest.statusNote {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !digest.activityLines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    LinkedAppSubheading(text: digest.activityLabel)
                    // One rule for the whole block, like the "why it
                    // matters" quote: per-line bars fragmented the list
                    // into what read as separate stubby quotes.
                    HStack(alignment: .top, spacing: 12) {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: 2)
                            .padding(.vertical, 2)
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(digest.activityLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 15))
                                    .lineSpacing(2.5)
                                    .foregroundStyle(Color.ink.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            } else if digest.availability != .unavailable {
                Text("Nothing logged.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSecondary)
            }

            if !digest.todayReminders.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    LinkedAppSubheading(text: "Today")
                        .padding(.bottom, 4)
                    ForEach(digest.todayReminders) { reminder in
                        LinkedAppReminderRow(reminder: reminder)
                        if reminder != digest.todayReminders.last {
                            FineRule()
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The small "Yesterday" / "Today" label inside a linked-app section.
private struct LinkedAppSubheading: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(Color.inkSecondary)
    }
}

/// One reminder from a linked app: time column, title, optional detail,
/// overdue badge. Mirrors CalendarEventRow's layout so the brief reads as
/// one system.
struct LinkedAppReminderRow: View {
    let reminder: LinkedAppReminder

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(timeLabel)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(width: 62, alignment: .trailing)
                .foregroundStyle(reminder.overdue ? Color.accentColor : Color.ink)

            Rectangle()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: 2)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = reminder.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var timeLabel: String {
        if reminder.overdue { return "Overdue" }
        if reminder.isAllDay { return "Today" }
        return DateFormatting.time.string(from: reminder.dueDate)
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
