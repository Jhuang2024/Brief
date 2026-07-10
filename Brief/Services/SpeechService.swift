import AVFoundation
import Foundation

/// Optional audio mode: reads the briefing aloud with the system
/// speech synthesizer. Free, local, and deliberately simple.
@MainActor
@Observable
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    struct Segment {
        var text: String
        /// Index of the story this segment belongs to, for skipping.
        var storyIndex: Int
    }

    enum PlaybackState: Equatable {
        case idle
        case playing
        case paused
    }

    private(set) var state: PlaybackState = .idle
    private(set) var currentSegmentIndex = 0

    /// Backing storage for `rate`. Clamping lives in the computed
    /// property's setter rather than a `didSet` on `rate` itself —
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

        if !brief.overviewItems.isEmpty {
            built.append(Segment(text: "The day in one minute.", storyIndex: storyIndex))
            for item in brief.overviewItems {
                built.append(Segment(text: item, storyIndex: storyIndex))
            }
            storyIndex += 1
        }
        for section in brief.orderedSections {
            built.append(Segment(text: section.title + ".", storyIndex: storyIndex))
            for story in section.orderedStories {
                storyIndex += 1
                var text = story.headline + ". " + story.summary
                if includeWhyItMatters, !story.whyItMatters.isEmpty {
                    text += " Why it matters: " + story.whyItMatters
                }
                built.append(Segment(text: text, storyIndex: storyIndex))
            }
            storyIndex += 1
        }
        guard !built.isEmpty else { return }

        segments = built
        currentSegmentIndex = 0
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        state = .playing
        speakCurrentSegment()
    }

    func pause() {
        guard state == .playing else { return }
        synthesizer.pauseSpeaking(at: .word)
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        synthesizer.continueSpeaking()
        state = .playing
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
        state = .playing
        speakCurrentSegment()
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        segments = []
        currentSegmentIndex = 0
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func speakCurrentSegment() {
        guard currentSegmentIndex < segments.count else {
            stop()
            return
        }
        let utterance = AVSpeechUtterance(string: segments[currentSegmentIndex].text)
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.15
        synthesizer.speak(utterance)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard state == .playing else { return }
            currentSegmentIndex += 1
            speakCurrentSegment()
        }
    }
}
