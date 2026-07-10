import AVFoundation
import SwiftUI

/// Compact playback bar for audio mode: play/pause, skip story, rate.
struct AudioBar: View {
    @Environment(AppEnvironment.self) private var environment

    private var speech: SpeechService { environment.speech }

    var body: some View {
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
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.rule, lineWidth: 0.5)
        )
    }

    private func rateButton(_ title: String, rate: Float) -> some View {
        Button(title) {
            speech.rate = rate
        }
    }
}
