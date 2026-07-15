import SwiftUI

/// A. Morning masthead: greeting, date, location, generation time,
/// reading time, refresh button, status indicator. Reveals with a brief
/// staggered animation (under one second, skipped with Reduce Motion).
struct MastheadView: View {
    let brief: DailyBrief
    let freshness: BriefFreshness
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onToggleAudio: () -> Void
    let audioState: SpeechService.PlaybackState

    @Environment(\.appReducedMotion) private var reducedMotion
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DateFormatting.mastheadDate.string(from: Date()).uppercased())
                .font(.overline)
                .kerning(1.6)
                .foregroundStyle(Color.inkSecondary)
                .revealStep(0, revealed: revealed, reduced: reducedMotion)

            HStack(alignment: .top) {
                Text(DateFormatting.greeting())
                    .font(.mastheadDate)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                HStack(spacing: 14) {
                    Button(action: onToggleAudio) {
                        Image(systemName: audioSymbol)
                            .font(.system(size: 15, weight: .medium))
                    }
                    .accessibilityLabel(audioState == .playing ? "Pause listening" : "Listen to briefing")

                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .medium))
                            .opacity(isRefreshing ? 0.35 : 1)
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("Refresh briefing")
                }
                .foregroundStyle(Color.ink)
                .padding(.top, 8)
            }
            .revealStep(1, revealed: revealed, reduced: reducedMotion)

            HStack(spacing: 6) {
                Text(brief.locationName)
                Text("·")
                Text("Generated \(DateFormatting.time.string(from: brief.generatedAt))")
                Text("·")
                Text("\(brief.estimatedReadingMinutes) min read")
                Spacer()
                statusIndicator
            }
            .font(.caption)
            .foregroundStyle(Color.inkSecondary)
            .revealStep(2, revealed: revealed, reduced: reducedMotion)
            .accessibilityElement(children: .combine)
        }
        .onAppear {
            guard !revealed else { return }
            if reducedMotion {
                revealed = true
            } else {
                withAnimation(.easeOut(duration: 0.45)) {
                    revealed = true
                }
            }
        }
    }

    private var audioSymbol: String {
        switch audioState {
        case .idle: return "headphones"
        case .playing: return "pause.fill"
        case .paused: return "play.fill"
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: freshness.symbolName)
                .font(.system(size: 10))
            Text(freshness.rawValue)
        }
        .foregroundStyle(freshness == .partial ? Color.orange : Color.inkSecondary)
        .accessibilityLabel("Briefing status: \(freshness.rawValue)")
    }
}

private extension View {
    /// Staggered entrance: three steps, ~0.12s apart, total well under 1s.
    func revealStep(_ step: Int, revealed: Bool, reduced: Bool) -> some View {
        self
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduced ? 0 : 8)
            .animation(
                reduced ? nil : .easeOut(duration: 0.4).delay(Double(step) * 0.12),
                value: revealed
            )
    }
}

/// B. Today strip: weather numbers straight from Open-Meteo plus the
/// first Calendar facts, in a compact editorial row.
struct TodayStripView: View {
    let brief: DailyBrief
    let preferences: UserPreferences

    private var firstTimedEvent: CalendarEvent? {
        brief.calendarEvents.first { !$0.isAllDay && $0.end > Date() }
    }

    private var allDayEvent: CalendarEvent? {
        brief.calendarEvents.first { $0.isAllDay }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FineRule(strong: true)
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    if let weather = brief.weather, preferences.includeWeather {
                        stripCell(
                            label: weather.conditionDescription,
                            value: weather.formatted(weather.temperature),
                            detail: "Feels \(weather.formatted(weather.apparentTemperature))",
                            symbol: weather.symbolName
                        )
                        divider
                        stripCell(
                            label: "High / Low",
                            value: "\(weather.formatted(weather.high)) / \(weather.formatted(weather.low))",
                            detail: "Rain \(weather.precipitationProbability)%"
                        )
                        divider
                    }
                    if preferences.includeCalendar && brief.calendarWasAvailable {
                        if let first = firstTimedEvent {
                            stripCell(
                                label: DateFormatting.countdown(to: first.start),
                                value: DateFormatting.time.string(from: first.start),
                                detail: String(first.title.prefix(26))
                            )
                            divider
                        }
                        stripCell(
                            label: "Today",
                            value: "\(brief.calendarEvents.count)",
                            detail: brief.calendarEvents.count == 1 ? "event" : "events"
                        )
                        if let allDay = allDayEvent {
                            divider
                            stripCell(
                                label: "All day",
                                value: String(allDay.title.prefix(18)),
                                detail: ""
                            )
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Without this, ScrollView(.horizontal) reports its content's
            // natural width (wider than the screen, by design - that's
            // what lets it scroll) as its ideal size to the enclosing
            // VStack. That width then propagates all the way up through
            // BriefContentView to Today's outer vertical ScrollView,
            // making the whole page pannable sideways. Clamping this
            // strip to the available width turns it back into a
            // screen-width window with its own content scrolling inside
            // it, instead of the window itself growing to fit the content.
            .frame(maxWidth: .infinity)

            if let note = brief.weather?.practicalNote, !note.isEmpty {
                Text(note)
                    .font(.footnote.italic())
                    .foregroundStyle(Color.inkSecondary)
            }
            FineRule()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.rule)
            .frame(width: 0.5, height: 44)
            .padding(.horizontal, 14)
    }

    private func stripCell(label: String, value: String, detail: String, symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Color.inkSecondary)
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.ink)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
