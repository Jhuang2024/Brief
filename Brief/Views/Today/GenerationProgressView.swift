import SwiftUI

/// Full-screen progress while the first briefing of the day generates.
/// Shows real phases, never fake percentages. The tab bar stays usable,
/// so Jerry can browse History or Settings while this runs.
struct GenerationProgressView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.appReducedMotion) private var reducedMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Text(DateFormatting.mastheadDate.string(from: Date()).uppercased())
                .font(.overline)
                .kerning(1.6)
                .foregroundStyle(Color.inkSecondary)
            Text("Preparing your brief")
                .font(.serif(28, weight: .bold))
                .foregroundStyle(Color.ink)
                .padding(.top, 4)
            Text("Web research takes a moment. You can use the other tabs meanwhile.")
                .font(.footnote)
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 6)

            FineRule(strong: true)
                .padding(.vertical, 18)

            VStack(alignment: .leading, spacing: 13) {
                ForEach(environment.engine.phases) { phase in
                    HStack(spacing: 12) {
                        phaseIcon(phase.status)
                            .frame(width: 18)
                        Text(phase.title)
                            .font(.system(size: 15))
                            .foregroundStyle(phase.status == .pending ? Color.inkSecondary : Color.ink)
                        Spacer()
                        // A visibly ticking counter proves the phase is
                        // still alive during a long retry - a static
                        // spinner alone reads as frozen past a few
                        // seconds even when it isn't.
                        if phase.status == .active, let startedAt = phase.startedAt {
                            Text(startedAt, style: .timer)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Color.inkSecondary)
                                .monospacedDigit()
                        }
                    }
                    .animation(reducedMotion ? nil : .easeInOut(duration: 0.25), value: phase.status)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(phase.title): \(accessibilityStatus(phase.status))")
                }
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Generating your briefing")
    }

    @ViewBuilder
    private func phaseIcon(_ status: BriefingEngine.PhaseProgress.Status) -> some View {
        switch status {
        case .pending:
            Circle()
                .strokeBorder(Color.rule, lineWidth: 1.5)
                .frame(width: 14, height: 14)
        case .active:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .transition(.opacity)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(Color.orange)
        }
    }

    private func accessibilityStatus(_ status: BriefingEngine.PhaseProgress.Status) -> String {
        switch status {
        case .pending: return "waiting"
        case .active: return "in progress"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}
