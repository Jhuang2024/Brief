import SwiftUI

/// Compact stack of unread hourly breaking-check alerts, shown above the
/// brief. Deliberately terse — this is meant to be scanned and dismissed
/// in a second or two, not read like a brief story.
struct BreakingAlertsSection: View {
    let alerts: [BreakingAlert]
    let onDismiss: (BreakingAlert) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(alerts) { alert in
                BreakingAlertCard(alert: alert, onDismiss: { onDismiss(alert) })
            }
        }
    }
}

private struct BreakingAlertCard: View {
    let alert: BreakingAlert
    let onDismiss: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ink)
                    Text(alert.sourceDomain)
                        .font(.caption2)
                        .foregroundStyle(Color.inkSecondary)
                }
                Spacer()
                Button {
                    Haptics.tap()
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.inkSecondary)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                Text(alert.summary)
                    .font(.footnote)
                    .foregroundStyle(Color.ink)
                Text(alert.whyItMatters)
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
                if let url = alert.sourceURL {
                    Link("Read source", destination: url)
                        .font(.caption.weight(.semibold))
                        .tint(.accentColor)
                }
            }
        }
        .padding(10)
        .background(Color.paperRaised, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        }
    }
}

#Preview("Breaking Alerts") {
    BreakingAlertsSection(
        alerts: [
            BreakingAlert(
                fingerprint: "abc",
                headline: "Example urgent headline",
                summary: "A short factual summary of what happened.",
                whyItMatters: "Why this matters right now.",
                sourceTitle: "Example News",
                sourceDomain: "example.com",
                sourceURLString: "https://example.com/story"
            ),
        ],
        onDismiss: { _ in }
    )
    .padding()
    .background(Color.paper)
}
