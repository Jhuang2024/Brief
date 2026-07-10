import SwiftUI

/// Full story sheet: complete explanation, context, what changed,
/// sources with open-in-reader buttons.
struct StoryDetailView: View {
    let story: BriefStory

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var safariURL: URL?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
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
                                    .font(.caption)
                                    .foregroundStyle(Color.inkSecondary)
                            }
                            Spacer()
                        }

                        Text(story.headline)
                            .font(.serif(26, weight: .bold))
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)

                        FineRule(strong: true)

                        Text(story.summary)
                            .font(.system(size: 16))
                            .lineSpacing(3.5)
                            .foregroundStyle(Color.ink)
                            .textSelection(.enabled)

                        if !story.whyItMatters.isEmpty {
                            block(title: "Why it matters", text: story.whyItMatters)
                        }

                        if story.isUpdate, !story.whatChanged.isEmpty {
                            block(title: "What changed", text: story.whatChanged)
                        }

                        if !story.context.isEmpty {
                            block(title: "Context", text: story.context)
                        }

                        if !story.sources.isEmpty {
                            sourcesSection
                        }
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $safariURL) { url in
            SafariView(url: url)
                .ignoresSafeArea()
        }
    }

    private func block(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.overline)
                .kerning(1.2)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(Color.ink.opacity(0.92))
                .textSelection(.enabled)
        }
        .padding(.top, 4)
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SOURCES")
                .font(.overline)
                .kerning(1.2)
                .foregroundStyle(Color.accentColor)
            ForEach(story.orderedSources) { source in
                Button {
                    guard let url = source.url else { return }
                    Haptics.tap()
                    safariURL = url
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title.isEmpty ? source.domain : source.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.ink)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                Text(source.domain)
                                if let published = source.publishedAt {
                                    Text("·")
                                    Text(DateFormatting.relativePast(published))
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(Color.inkSecondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.inkSecondary)
                    }
                    .padding(12)
                    .background(Color.paperRaised, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open source: \(source.title.isEmpty ? source.domain : source.title)")
            }
        }
        .padding(.top, 4)
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
