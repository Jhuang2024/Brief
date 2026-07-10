import SwiftUI
import UIKit

/// The editorial palette: warm off-white paper in light mode, deep
/// charcoal in dark mode, ink text, fine rules, one restrained accent.
extension Color {
    static let paper = Color(dynamicLight: 0xFAF7F1, dark: 0x181715)
    static let paperRaised = Color(dynamicLight: 0xF3EEE5, dark: 0x201E1B)
    static let ink = Color(dynamicLight: 0x1C1A16, dark: 0xEAE5DC)
    static let inkSecondary = Color(dynamicLight: 0x6D6759, dark: 0x9C968A)
    static let rule = Color(dynamicLight: 0xD9D2C4, dark: 0x38352F)
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
