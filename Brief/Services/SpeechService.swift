import AVFoundation
import Foundation

/// Optional audio mode: reads the briefing aloud with the system
/// speech synthesizer. Free, local, and deliberately simple.
///
/// Playback exposes a Spotify-style position: an accurate progress
/// fraction (driven by the synthesizer's per-word range callbacks) plus
/// elapsed/remaining times. The time estimate is calibrated against the
/// speed the device is actually speaking at, so it stays honest and moves
/// with the chosen playback rate — no network, no API credits.
@MainActor
@Observable
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    struct Segment {
        var text: String
        /// Index of the story this segment belongs to, for skipping.
        var storyIndex: Int
        /// UTF-16 length, so it lines up with `NSRange` callbacks.
        var length: Int
    }

    enum PlaybackState: Equatable {
        case idle
        case playing
        case paused
    }

    private(set) var state: PlaybackState = .idle
    private(set) var currentSegmentIndex = 0

    /// Characters spoken so far, across every segment. Drives the progress
    /// bar. Updated word-by-word from the synthesizer, so it reflects the
    /// true reading position rather than a guess.
    private(set) var spokenChars = 0
    private(set) var totalChars = 0

    /// Backing storage for `rate`. Clamping lives in the computed
    /// property's setter rather than a `didSet` on `rate` itself:
    /// reassigning a property from inside its own `didSet` re-triggers
    /// that same `didSet`, which previously caused unbounded recursion
    /// and a stack-overflow crash the instant the playback rate changed.
    private var _rate: Float = AVSpeechUtteranceDefaultSpeechRate

    /// Applies from the next utterance onward.
    var rate: Float {
        get { _rate }
        set { _rate = min(max(newValue, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate) }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var segments: [Segment] = []
    /// Cumulative UTF-16 offset at the start of each segment.
    private var segmentOffsets: [Int] = []

    /// Best on-device voice for the current language, chosen once. Enhanced
    /// and premium voices (if the user has downloaded any) sound markedly
    /// more natural than the compact default, and cost nothing to use.
    private lazy var preferredVoice: AVSpeechSynthesisVoice? = Self.bestAvailableVoice()

    // MARK: Speed calibration

    /// Characters per second at the default rate, measured from how fast the
    /// device actually speaks. Seeded with a reasonable guess and refined as
    /// playback proceeds so the remaining-time estimate converges on reality.
    private var baseCharsPerSecond = 15.0
    private var lastTickDate: Date?
    private var lastTickChars = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Build the reading list: overview, then each section heading and its
    /// stories (headline, summary, why it matters).
    func play(brief: DailyBrief, includeWhyItMatters: Bool) {
        stop()
        var built: [Segment] = []
        var storyIndex = 0

        func append(_ text: String, story: Int) {
            built.append(Segment(text: text, storyIndex: story, length: (text as NSString).length))
        }

        if !brief.overviewItems.isEmpty {
            append("The day in one minute.", story: storyIndex)
            for item in brief.overviewItems {
                append(item, story: storyIndex)
            }
            storyIndex += 1
        }
        for section in brief.orderedSections {
            append(section.title + ".", story: storyIndex)
            for story in section.orderedStories {
                storyIndex += 1
                var text = story.headline + ". " + story.summary
                if includeWhyItMatters, !story.whyItMatters.isEmpty {
                    text += " Why it matters: " + story.whyItMatters
                }
                append(text, story: storyIndex)
            }
            storyIndex += 1
        }
        guard !built.isEmpty else { return }

        segments = built
        segmentOffsets = []
        var running = 0
        for segment in built {
            segmentOffsets.append(running)
            running += segment.length
        }
        totalChars = running
        spokenChars = 0
        currentSegmentIndex = 0
        lastTickDate = nil
        lastTickChars = 0

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        state = .playing
        speakCurrentSegment()
    }

    func pause() {
        guard state == .playing else { return }
        synthesizer.pauseSpeaking(at: .word)
        state = .paused
        lastTickDate = nil
    }

    func resume() {
        guard state == .paused else { return }
        synthesizer.continueSpeaking()
        state = .playing
        lastTickDate = nil
    }

    /// Jump to the next story (not merely the next sentence).
    func skipStory() {
        guard state != .idle, currentSegmentIndex < segments.count else { return }
        let currentStory = segments[currentSegmentIndex].storyIndex
        guard let next = segments[currentSegmentIndex...].firstIndex(where: { $0.storyIndex > currentStory }) else {
            stop()
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        currentSegmentIndex = next
        spokenChars = segmentOffsets[next]
        lastTickDate = nil
        state = .playing
        speakCurrentSegment()
    }

    /// Scrub to an arbitrary position, snapping to the nearest segment
    /// boundary (the finest granularity the synthesizer can restart from).
    func seek(toProgress progress: Double) {
        guard !segments.isEmpty else { return }
        let target = Int((Double(totalChars) * min(max(progress, 0), 1)).rounded())
        // Last segment that begins at or before the target offset.
        var index = 0
        for (i, offset) in segmentOffsets.enumerated() where offset <= target {
            index = i
        }
        synthesizer.stopSpeaking(at: .immediate)
        currentSegmentIndex = index
        spokenChars = segmentOffsets[index]
        lastTickDate = nil
        state = .playing
        speakCurrentSegment()
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        segments = []
        segmentOffsets = []
        currentSegmentIndex = 0
        spokenChars = 0
        totalChars = 0
        lastTickDate = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Position & timing

    /// 0…1 fraction of the whole briefing that has been read.
    var progress: Double {
        guard totalChars > 0 else { return 0 }
        return min(max(Double(spokenChars) / Double(totalChars), 0), 1)
    }

    /// Characters per second at the current rate, honoring the calibrated
    /// base speed. Because it scales with `rate`, the times below move the
    /// instant the listener changes speed.
    private var effectiveCharsPerSecond: Double {
        let scale = Double(_rate / AVSpeechUtteranceDefaultSpeechRate)
        return max(baseCharsPerSecond * scale, 1)
    }

    /// Estimated length of the whole briefing at the current rate.
    var totalDuration: TimeInterval {
        guard totalChars > 0 else { return 0 }
        return Double(totalChars) / effectiveCharsPerSecond
    }

    var elapsed: TimeInterval { progress * totalDuration }
    var remaining: TimeInterval { max(totalDuration - elapsed, 0) }

    // MARK: - Speaking

    private func speakCurrentSegment() {
        guard currentSegmentIndex < segments.count else {
            stop()
            return
        }
        let utterance = AVSpeechUtterance(string: segments[currentSegmentIndex].text)
        utterance.voice = preferredVoice
        utterance.rate = rate
        // A touch of pre-utterance breathing room and a natural pitch make
        // the reading feel less clipped between segments.
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.15
        synthesizer.speak(utterance)
    }

    /// Pick the most natural voice installed for the user's language:
    /// premium if present, then enhanced, then whatever compact default
    /// exists. All are on-device and free.
    private static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices()

        func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
            switch quality {
            case .premium: return 3
            case .enhanced: return 2
            default: return 1
            }
        }

        // Prefer an exact language match; fall back to the same base language
        // (e.g. any en-* if the exact en-US variant isn't installed).
        let base = language.split(separator: "-").first.map(String.init) ?? language
        let exact = voices.filter { $0.language == language }
        let sameBase = voices.filter { $0.language.hasPrefix(base) }
        let pool = exact.isEmpty ? sameBase : exact

        return pool.max { rank($0.quality) < rank($1.quality) }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard state == .playing, currentSegmentIndex < segmentOffsets.count else { return }
            let position = segmentOffsets[currentSegmentIndex] + characterRange.location
            updateSpoken(to: position)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard state == .playing else { return }
            if currentSegmentIndex < segments.count {
                let end = segmentOffsets[currentSegmentIndex] + segments[currentSegmentIndex].length
                updateSpoken(to: end)
            }
            currentSegmentIndex += 1
            speakCurrentSegment()
        }
    }

    /// Advance the spoken-character count and refine the measured speaking
    /// speed from the wall-clock gap between callbacks.
    private func updateSpoken(to position: Int) {
        let clamped = min(max(position, spokenChars), totalChars)
        let now = Date()
        if let last = lastTickDate {
            let dt = now.timeIntervalSince(last)
            let dChars = Double(clamped - lastTickChars)
            // Ignore tiny or negative intervals; they make the estimate jumpy.
            if dt > 0.08, dChars > 0 {
                let scale = Double(_rate / AVSpeechUtteranceDefaultSpeechRate)
                let instantaneousBase = (dChars / dt) / max(scale, 0.01)
                // Exponential moving average keeps the estimate stable.
                baseCharsPerSecond = baseCharsPerSecond * 0.8 + instantaneousBase * 0.2
                lastTickDate = now
                lastTickChars = clamped
            }
        } else {
            lastTickDate = now
            lastTickChars = clamped
        }
        spokenChars = clamped
    }
}
