import AVFoundation
import CommuteCore
import Observation

/// Speaks turn-by-turn instructions: once when a maneuver comes up next, and again on reaching it.
@Observable
final class VoiceGuide {
    var isMuted = UserDefaults.standard.bool(forKey: "voiceGuidanceMuted") {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: "voiceGuidanceMuted")
            if isMuted { stop() }
        }
    }

    @ObservationIgnored private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        // The system's own session ducks music under the prompt and restores it afterwards.
        synthesizer.usesApplicationAudioSession = false
        return synthesizer
    }()
    @ObservationIgnored private var currentManeuver: String?
    @ObservationIgnored private var didSpeakApproach = false

    func announce(_ step: RouteStep, metersAway: Double, mode: TravelMode) {
        guard !step.instruction.isEmpty else { return }
        let nearMeters = mode == .drive ? 120.0 : 25.0

        // Re-planned routes repeat the same maneuver with new geometry; its end point is what identifies it.
        let end = step.geometry.last
        let maneuver = "\(step.instruction)@\(Int((end?.latitude ?? 0) * 10_000)),\(Int((end?.longitude ?? 0) * 10_000))"
        if maneuver != currentManeuver {
            currentManeuver = maneuver
            didSpeakApproach = metersAway <= nearMeters * 2
            let distance = Measurement(value: metersAway, unit: UnitLength.meters).formatted(.measurement(width: .wide, usage: .road))
            speak(didSpeakApproach ? step.instruction : "In \(distance), \(step.instruction)")
        } else if !didSpeakApproach, metersAway <= nearMeters {
            didSpeakApproach = true
            speak(step.instruction)
        }
    }

    func stop() {
        currentManeuver = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func speak(_ text: String) {
        guard !isMuted else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
    }
}
