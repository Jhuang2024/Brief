import UIKit

/// Keeps the screen awake while some piece of work needs the app to stay
/// foreground-active — currently briefing generation and audio playback.
///
/// Callers acquire and release a named reason; the display idle timer is
/// disabled as long as at least one reason is held. Using named reasons
/// (rather than a bare bool) means two overlapping activities — say, audio
/// playing while a refresh generates — don't stomp on each other's state:
/// the timer only re-enables once the last reason is released.
@MainActor
enum WakeLock {
    private static var reasons: Set<String> = []

    static func acquire(_ reason: String) {
        reasons.insert(reason)
        apply()
    }

    static func release(_ reason: String) {
        reasons.remove(reason)
        apply()
    }

    private static func apply() {
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
    }
}
