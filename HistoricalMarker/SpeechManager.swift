import Foundation
import AVFoundation
import Combine

@MainActor
final class SpeechManager: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()

    func configureAudioSession(playOverOthers: Bool) {
        do {
            let session = AVAudioSession.sharedInstance()
            let category: AVAudioSession.Category = .playback
            var options: AVAudioSession.CategoryOptions = [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            if playOverOthers {
                options.insert(.mixWithOthers)
            }
            try session.setCategory(category, mode: .spokenAudio, options: options)
            try session.setActive(true, options: [])
        } catch {
            print("Audio session error: \(error)")
        }
    }

    func speak(marker: HistoricalMarker) {
        stop()
        let utterance = AVSpeechUtterance(string: "\(marker.title). \(marker.text)")
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}
