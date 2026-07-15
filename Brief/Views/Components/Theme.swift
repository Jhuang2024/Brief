import SwiftUI
import UIKit

/// The editorial palette: warm off-white paper in light mode, deep
/// charcoal in dark mode, ink text, fine rules, one restrained accent.
extension Color {
    static let paper = Color(dynamicLight: 0xFAF7F1, dark: 0x181715)
    static let paperRaised = Color(dynamicLight: 0xF0EAE0, dark: 0x211F1B)
    static let ink = Color(dynamicLight: 0x1C1A16, dark: 0xEAE5DC)
    // Darker than the original 0x6D6759 (~2.2:1 contrast on paper, failed
    // legibility); this reads clearly at caption sizes while staying
    // visually distinct from primary ink.
    static let inkSecondary = Color(dynamicLight: 0x4A4538, dark: 0xA8A294)
    static let rule = Color(dynamicLight: 0xCEC4AE, dark: 0x38352F)
    static let ruleStrong = Color(dynamicLight: 0x1C1A16, dark: 0xEAE5DC)

    init(dynamicLight light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Editorial type: New York (system serif) for headlines, SF Pro for
/// body and data.
extension Font {
    static func serif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static let mastheadDate = serif(30, weight: .bold)
    static let sectionTitle = serif(24, weight: .bold)
    static let storyHeadline = serif(19, weight: .semibold)
    static let overline = Font.system(size: 11, weight: .semibold).monospaced()
}

/// Whether entrance animation should run, honouring both the system
/// setting and the in-app preference.
struct MotionPreferenceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var appReducedMotion: Bool {
        get { self[MotionPreferenceKey.self] }
        set { self[MotionPreferenceKey.self] = newValue }
    }
}

/// Recolors a Form/List's system chrome (grouped gray background, white
/// row cards) to the app's paper/ink palette, so Settings reads as part
/// of the same app as Today instead of stock iOS Settings.
private struct BriefFormStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.paper)
            .listRowBackground(Color.paperRaised)
            .tint(Color.accentColor)
    }
}

extension View {
    func briefFormStyle() -> some View {
        modifier(BriefFormStyle())
    }
}

/// An editorial-styled Section header for Form/List screens: small caps
/// overline in the same voice as the Today screen's section headers,
/// instead of the default system gray label.
struct FormSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.overline)
            .kerning(1.2)
            .foregroundStyle(Color.inkSecondary)
    }
}

/// Configures the app's global UIKit chrome (navigation bars, tab bar)
/// to match the paper/ink palette. Applies once at launch and covers
/// every navigation stack and sheet, including ones pushed later.
enum AppearanceConfiguration {
    static func apply() {
        let paper = UIColor(Color.paper)
        let ink = UIColor(Color.ink)
        let inkSecondary = UIColor(Color.inkSecondary)
        let accent = UIColor(Color.accentColor)

        let navBar = UINavigationBarAppearance()
        navBar.configureWithOpaqueBackground()
        navBar.backgroundColor = paper
        navBar.shadowColor = UIColor(Color.rule)
        navBar.titleTextAttributes = [.foregroundColor: ink]
        navBar.largeTitleTextAttributes = [.foregroundColor: ink, .font: Self.largeTitleSerifFont]
        UINavigationBar.appearance().standardAppearance = navBar
        UINavigationBar.appearance().scrollEdgeAppearance = navBar
        UINavigationBar.appearance().compactAppearance = navBar
        UINavigationBar.appearance().tintColor = accent

        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = paper
        tabBar.shadowColor = UIColor(Color.rule)
        let normal = tabBar.stackedLayoutAppearance.normal
        normal.iconColor = inkSecondary
        normal.titleTextAttributes = [.foregroundColor: inkSecondary]
        let selected = tabBar.stackedLayoutAppearance.selected
        selected.iconColor = accent
        selected.titleTextAttributes = [.foregroundColor: accent]
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar
        UITabBar.appearance().tintColor = accent

        UITableView.appearance().backgroundColor = .clear
        UISwitch.appearance().onTintColor = accent
    }

    /// New York (serif design), bold, at the system large-title point size -
    /// gives every screen's nav title the same editorial voice as the
    /// masthead instead of the system sans-serif default.
    private static var largeTitleSerifFont: UIFont {
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .largeTitle)
        let serif = base.withDesign(.serif)?.withSymbolicTraits(.traitBold) ?? base
        return UIFont(descriptor: serif, size: 0)
    }
}
