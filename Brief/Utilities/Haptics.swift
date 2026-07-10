import UIKit

/// Small, restrained haptic vocabulary.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let notification = UINotificationFeedbackGenerator()

    /// Tapping a story or control.
    static func tap() {
        light.impactOccurred(intensity: 0.7)
    }

    /// A briefing finished generating.
    static func briefReady() {
        notification.notificationOccurred(.success)
    }

    /// Something failed.
    static func failure() {
        notification.notificationOccurred(.error)
    }

    /// Subtle tick for reordering or toggling.
    static func tick() {
        soft.impactOccurred(intensity: 0.5)
    }
}
