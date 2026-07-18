import AVFoundation
import SwiftUI

/// Compact playback bar for audio mode: a Spotify-style progress bar with
/// elapsed / remaining time on top, and play/pause, skip and rate controls
/// underneath.
struct AudioBar: View {
    @Environment(AppEnvironment.self) private var environment

    private var speech: SpeechService { environment.speech }

    /// While the listener is dragging the bar we show their finger position
    /// instead of the live playback position, and only seek on release.
    @State private var scrubProgress: Double?

    private var displayedProgress: Double { scrubProgress ?? speech.progress }

    var body: some View {
        VStack(spacing: 12) {
            progressSection
            controls
        }
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.rule, lineWidth: 0.5)
        )
    }

    // MARK: Progress

    private var progressSection: some View {
        VStack(spacing: 5) {
            progressBar
            HStack {
                Text(Self.timeString(displayedProgress * speech.totalDuration))
                Spacer()
                Text("-" + Self.timeString(speech.totalDuration - displayedProgress * speech.totalDuration))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.inkSecondary)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let filled = width * CGFloat(min(max(displayedProgress, 0), 1))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.rule)
                    .frame(height: 4)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: filled, height: 4)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: scrubProgress == nil ? 10 : 14, height: scrubProgress == nil ? 10 : 14)
                    .offset(x: filled - (scrubProgress == nil ? 5 : 7))
                    .animation(.easeOut(duration: 0.15), value: scrubProgress == nil)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubProgress = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { value in
                        let target = min(max(value.location.x / width, 0), 1)
                        speech.seek(toProgress: target)
                        scrubProgress = nil
                        Haptics.tap()
                    }
            )
        }
        .frame(height: 20)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 18) {
            Button {
                if speech.state == .playing {
                    speech.pause()
                } else {
                    speech.resume()
                }
            } label: {
                Image(systemName: speech.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
            }
            .accessibilityLabel(speech.state == .playing ? "Pause" : "Resume")

            Button {
                speech.skipStory()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .accessibilityLabel("Skip to next story")

            Text("Listening")
                .font(.footnote)
                .foregroundStyle(Color.inkSecondary)

            Spacer()

            Menu {
                rateButton("Slower", rate: AVSpeechUtteranceDefaultSpeechRate * 0.85)
                rateButton("Normal", rate: AVSpeechUtteranceDefaultSpeechRate)
                rateButton("Faster", rate: AVSpeechUtteranceDefaultSpeechRate * 1.15)
                rateButton("Fastest", rate: AVSpeechUtteranceDefaultSpeechRate * 1.3)
            } label: {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 15, weight: .medium))
            }
            .accessibilityLabel("Playback rate")

            Button {
                speech.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
            }
            .accessibilityLabel("Stop listening")
        }
    }

    private func rateButton(_ title: String, rate: Float) -> some View {
        Button(title) {
            speech.rate = rate
        }
    }

    /// m:ss, never negative.
    private static func timeString(_ interval: TimeInterval) -> String {
        let total = Int(max(interval, 0).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
