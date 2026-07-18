import AVFoundation
import Foundation
import MediaPlayer

/// Optional audio mode: reads the briefing aloud with the system
/// speech synthesizer. Free, local, and deliberately simple.
///
/// Playback exposes a Spotify-style position. The bar and clock are anchored
/// to the synthesizer's real per-word progress — so they can never run out
/// early or overshoot — and interpolated between those callbacks with a
/// wall-clock tick so the numbers advance smoothly, second by second, rather
/// than jumping a few times a second. No network, no API credits.
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

    /// Real characters spoken so far, taken word-by-word from the synthesizer.
    /// This is ground truth for where playback actually is.
    private(set) var spokenChars = 0
    private(set) var totalChars = 0

    /// Smoothly interpolated read position. Tracks `spokenChars` but advances
    /// continuously between callbacks so the clock ticks each frame. Clamped
    /// so it never gets more than a hair ahead of what's really been spoken.
    private var interpolatedChars: Double = 0

    /// Backing storage for `rate`. Clamping lives in the computed
    /// property's setter rather than a `didSet` on `rate` itself:
    /// reassigning a property from inside its own `didSet` re-triggers
    /// that same `didSet`, which previously caused unbounded recursion
    /// and a stack-overflow crash the instant the playback rate changed.
    private var _rate: Float = AVSpeechUtteranceDefaultSpeechRate

    /// Applies from the next utterance onward.
    var rate: Float {
        get { _rate }
        set {
            _rate = min(max(newValue, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
            // Times are derived from the rate, so they re-estimate at once —
            // which is exactly the "it changes with speed" behaviour we want.
            updateNowPlaying(force: true)
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var segments: [Segment] = []
    /// Cumulative UTF-16 offset at the start of each segment.
    @ObservationIgnored private var segmentOffsets: [Int] = []

    /// Lock-screen / Control Center metadata title.
    private let nowPlayingTitle = "Your morning brief"
    @ObservationIgnored private var remoteCommandsConfigured = false

    /// Best on-device voice for the current language, chosen once. Enhanced
    /// and premium voices (if the user has downloaded any) sound markedly
    /// more natural than the compact default, and cost nothing to use.
    /// `@ObservationIgnored` because `@Observable` cannot synthesize tracking
    /// for a `lazy` stored property (its init accessor can't touch the lazy
    /// backing store), and this value never needs to drive the UI anyway.
    @ObservationIgnored
    private lazy var preferredVoice: AVSpeechSynthesisVoice? = Self.bestAvailableVoice()

    // MARK: Speed model
    //
    // The displayed clock is stable: it uses a single characters-per-second
    // figure that is measured once over a short warm-up at the start of
    // playback and then held fixed (scaled by the playback rate). Because it
    // no longer wobbles per word, elapsed and remaining stop jittering. And
    // because every displayed value is derived from the *real* read position,
    // remaining still lands on exactly 0:00 when the narration actually ends,
    // even if the estimate is a little off in absolute terms.

    /// Characters per second at the default rate. Seeded, then measured once.
    private var displayBaseCPS: Double = 15
    @ObservationIgnored private var calibrated = false
    @ObservationIgnored private var warmupChars = 0.0
    @ObservationIgnored private var warmupTime = 0.0
    @ObservationIgnored private var lastRealDate: Date?
    @ObservationIgnored private var lastRealChars = 0

    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var lastInterpDate: Date?
    @ObservationIgnored private var lastNowPlayingDate: Date?

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
        interpolatedChars = 0
        currentSegmentIndex = 0

        // Reset the speed model for a fresh run.
        displayBaseCPS = 15
        calibrated = false
        warmupChars = 0
        warmupTime = 0
        lastRealDate = nil
        lastRealChars = 0
        lastInterpDate = nil

        // .playback keeps audio going when the phone is locked or the app is
        // backgrounded (paired with the `audio` UIBackgroundMode), so the
        // brief plays on like a song. The wake lock additionally stops the
        // screen auto-locking while it's in the foreground.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        WakeLock.acquire("audio")
        configureRemoteCommands()
        state = .playing
        speakCurrentSegment()
        startTicking()
        updateNowPlaying(force: true)
    }

    func pause() {
        guard state == .playing else { return }
        synthesizer.pauseSpeaking(at: .word)
        state = .paused
        lastRealDate = nil
        lastInterpDate = nil
        WakeLock.release("audio")
        updateNowPlaying(force: true)
    }

    func resume() {
        guard state == .paused else { return }
        synthesizer.continueSpeaking()
        state = .playing
        lastRealDate = nil
        lastInterpDate = nil
        WakeLock.acquire("audio")
        updateNowPlaying(force: true)
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
        anchorPosition(to: segmentOffsets[next])
        state = .playing
        speakCurrentSegment()
        updateNowPlaying(force: true)
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
        anchorPosition(to: segmentOffsets[index])
        state = .playing
        speakCurrentSegment()
        updateNowPlaying(force: true)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        stopTicking()
        segments = []
        segmentOffsets = []
        currentSegmentIndex = 0
        spokenChars = 0
        interpolatedChars = 0
        totalChars = 0
        lastRealDate = nil
        state = .idle
        WakeLock.release("audio")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Position & timing

    /// Characters per second at the current rate.
    private var displayCharsPerSecond: Double {
        max(displayBaseCPS * Double(_rate / AVSpeechUtteranceDefaultSpeechRate), 1)
    }

    /// 0…1 fraction of the whole briefing that has been read. Uses the
    /// interpolated position so the bar glides rather than steps.
    var progress: Double {
        guard totalChars > 0 else { return 0 }
        return min(max(interpolatedChars / Double(totalChars), 0), 1)
    }

    /// Estimated length of the whole briefing at the current rate.
    var totalDuration: TimeInterval {
        guard totalChars > 0 else { return 0 }
        return Double(totalChars) / displayCharsPerSecond
    }

    var elapsed: TimeInterval { interpolatedChars / displayCharsPerSecond }
    var remaining: TimeInterval { max(totalDuration - elapsed, 0) }

    // MARK: - Interpolation tick

    private func startTicking() {
        tickTask?.cancel()
        lastInterpDate = nil
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
        lastInterpDate = nil
    }

    /// Advance the interpolated position by real elapsed time, clamped so it
    /// never overtakes what has actually been spoken by more than a beat.
    private func tick() {
        guard state == .playing, totalChars > 0 else {
            lastInterpDate = nil
            return
        }
        let now = Date()
        // Clamp dt so a suspend/resume (e.g. returning from the background)
        // can't make the clock lurch forward.
        let dt = lastInterpDate.map { min(max(now.timeIntervalSince($0), 0), 1) } ?? 0
        lastInterpDate = now
        guard dt > 0 else { return }

        let maxAhead = Double(lastRealChars) + displayCharsPerSecond * 0.75
        let next = min(interpolatedChars + displayCharsPerSecond * dt, maxAhead, Double(totalChars))
        if next > interpolatedChars {
            interpolatedChars = next
            updateNowPlaying()
        }
    }

    /// Snap the read position to a known offset (after a skip or seek).
    private func anchorPosition(to offset: Int) {
        spokenChars = offset
        interpolatedChars = Double(offset)
        lastRealChars = offset
        lastRealDate = nil
        lastInterpDate = nil
    }

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

    // MARK: - Lock screen / remote controls

    /// Publish the current position to the lock screen and Control Center so
    /// the brief shows up — and can be controlled — like a playing track.
    private func updateNowPlaying(force: Bool = false) {
        guard state != .idle else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            lastNowPlayingDate = nil
            return
        }
        // The lock-screen scrubber interpolates itself from elapsed + rate, so
        // ~1 Hz is plenty; throttle the frequent tick/progress updates and let
        // real control events (play, seek, rate) push through immediately.
        let now = Date()
        if !force, let last = lastNowPlayingDate, now.timeIntervalSince(last) < 0.75 { return }
        lastNowPlayingDate = now
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = nowPlayingTitle
        info[MPMediaItemPropertyArtist] = "Brief"
        info[MPMediaItemPropertyPlaybackDuration] = totalDuration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        // Rate drives the lock-screen scrubber's smooth interpolation between
        // our updates; 0 while paused freezes it. It scales with playback rate.
        info[MPNowPlayingInfoPropertyPlaybackRate] =
            state == .playing ? Double(_rate / AVSpeechUtteranceDefaultSpeechRate) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Wire up lock-screen / headphone remote controls once. Handlers are
    /// delivered on the main thread, but the closures are non-isolated, so we
    /// hop back onto the main actor to touch playback state.
    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.state == .playing { self.pause() } else { self.resume() }
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipStory() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                guard let self, self.totalDuration > 0 else { return }
                self.seek(toProgress: event.positionTime / self.totalDuration)
            }
            return .success
        }
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
            recordRealProgress(to: position)
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
                recordRealProgress(to: end)
            }
            currentSegmentIndex += 1
            speakCurrentSegment()
        }
    }

    /// Fold in a real progress report: move the anchor, keep the interpolated
    /// position honest, and refine the one-time speed measurement.
    private func recordRealProgress(to position: Int) {
        let clamped = min(max(position, spokenChars), totalChars)
        let now = Date()

        // Measure characters-per-second once, over a short warm-up window,
        // then freeze it so the displayed clock stops moving on its own.
        if !calibrated, let last = lastRealDate {
            let dt = now.timeIntervalSince(last)
            let dChars = Double(clamped - lastRealChars)
            if dt > 0.08, dChars > 0 {
                let scale = Double(_rate / AVSpeechUtteranceDefaultSpeechRate)
                warmupChars += dChars / max(scale, 0.01)
                warmupTime += dt
                if warmupTime >= 2.5 {
                    displayBaseCPS = min(max(warmupChars / warmupTime, 5), 40)
                    calibrated = true
                }
            }
        }
        lastRealDate = now
        lastRealChars = clamped
        spokenChars = clamped

        // Keep the interpolated position in step with the truth: never behind
        // it, and never more than a beat ahead of it.
        if interpolatedChars < Double(clamped) {
            interpolatedChars = Double(clamped)
        } else {
            interpolatedChars = min(interpolatedChars, Double(clamped) + displayCharsPerSecond * 0.75)
        }
        updateNowPlaying()
    }
}
