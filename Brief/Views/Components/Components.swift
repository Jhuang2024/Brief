import SafariServices
import SwiftUI

/// Hairline horizontal rule.
struct FineRule: View {
    var strong = false

    var body: some View {
        Rectangle()
            .fill(strong ? Color.ruleStrong : Color.rule)
            .frame(height: strong ? 2 : 0.5)
    }
}

/// Editorial section header: numbered overline, serif title, full-width rule.
struct SectionHeaderView: View {
    let index: Int
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FineRule(strong: true)
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%02d", index))
                    .font(.overline)
                    .foregroundStyle(Color.accentColor)
                Text(title.uppercased())
                    .font(.overline)
                    .foregroundStyle(Color.inkSecondary)
                    .kerning(1.4)
                Spacer()
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("Section: \(title)")
    }
}

/// Small status label used on stories (Breaking, Result, …) and briefs.
struct StatusBadge: View {
    enum Emphasis { case accent, neutral, warning }

    let text: String
    var emphasis: Emphasis = .neutral

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .kerning(0.8)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .foregroundStyle(foreground)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(foreground.opacity(0.55), lineWidth: 1)
            )
    }

    private var foreground: Color {
        switch emphasis {
        case .accent: return .accentColor
        case .neutral: return .inkSecondary
        case .warning: return .orange
        }
    }
}

/// In-app reader for source links, preferring SFSafariViewController.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(Color.accentColor)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// A reorderable, deletable, addable list of free-text strings, used by
/// the Interests and Sources settings screens.
struct EditableListView: View {
    let title: String
    let placeholder: String
    @Binding var items: [String]
    @State private var newItem = ""

    var body: some View {
        List {
            Section {
                ForEach(items, id: \.self) { item in
                    Text(item)
                }
                .onDelete { offsets in
                    items.remove(atOffsets: offsets)
                }
                .onMove { source, destination in
                    items.move(fromOffsets: source, toOffset: destination)
                }

                HStack {
                    TextField(placeholder, text: $newItem)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Add \(placeholder)")
                }
            } footer: {
                Text("Swipe to delete. Drag to reorder.")
            }
        }
        .navigationTitle(title)
        .toolbar { EditButton() }
    }

    private func add() {
        let trimmed = newItem.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !items.contains(trimmed) else { return }
        items.append(trimmed)
        newItem = ""
        Haptics.tick()
    }
}

/// Uniform empty-state used across tabs.
struct RestrainedEmptyState: View {
    let symbolName: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.inkSecondary)
            Text(title)
                .font(.serif(20))
                .foregroundStyle(Color.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }
}
