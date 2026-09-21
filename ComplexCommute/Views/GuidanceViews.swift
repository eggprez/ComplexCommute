import CommuteCore
import SwiftUI

extension RouteStep {
    /// MapKit describes maneuvers only in words, so the arrow is read back out of them.
    var symbol: String {
        let text = instruction.lowercased()
        func has(_ words: String...) -> Bool { words.contains(where: text.contains) }

        if has("arrive", "destination") { return "mappin.and.ellipse" }
        if has("u-turn") { return "arrow.uturn.left" }
        if has("roundabout", "traffic circle") { return "arrow.clockwise" }
        if has("merge") { return "arrow.merge" }
        if has("slight left", "keep left", "bear left") { return "arrow.up.left" }
        if has("slight right", "keep right", "bear right", "exit", "ramp") { return "arrow.up.right" }
        if has("left") { return "arrow.turn.up.left" }
        if has("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }
}

extension Double {
    /// "400 ft", "1.2 mi"
    var roadDistance: String {
        Measurement(value: self, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// The next maneuver, shown over the map while a drive or walk leg is under way. Laid out like Maps: a dark sign with
/// the arrow and distance writ large, the road beneath, and the turn after that tucked under it.
struct GuidanceBanner: View {
    let leg: Leg
    let progress: RouteProgress
    @Bindable var voice: VoiceGuide

    private static let sign = Color(red: 0.11, green: 0.12, blue: 0.13)

    var body: some View {
        let steps = leg.option.steps
        let step = steps[progress.stepIndex]
        let next = steps[(progress.stepIndex + 1)...].first { !$0.instruction.isEmpty }

        VStack(alignment: .trailing, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: step.symbol)
                        .font(.system(size: 40, weight: .bold))
                        .frame(width: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progress.metersToManeuver.roadDistance)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(step.instruction.isEmpty ? "\(leg.mode.label) to \(leg.to.name)" : step.instruction)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if let next {
                    HStack(spacing: 8) {
                        Text("Then")
                            .foregroundStyle(.white.opacity(0.6))
                        Image(systemName: next.symbol)
                            .fontWeight(.bold)
                        Text(next.instruction)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.1))
                }
            }
            .foregroundStyle(.white)
            .background(Self.sign, in: .rect(cornerRadius: 20))
            .clipShape(.rect(cornerRadius: 20))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .accessibilityElement(children: .combine)

            Toggle("Voice Guidance", systemImage: voice.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                   isOn: Binding(get: { !voice.isMuted }, set: { voice.isMuted = !$0 }))
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 44, height: 44)
                .glassEffect(in: .circle)
        }
        .padding(.horizontal, 12)
    }
}

/// Every maneuver of a drive or walk leg, for reading ahead.
struct StepList: View {
    let steps: [RouteStep]
    var currentIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if !step.instruction.isEmpty, index >= (currentIndex ?? 0) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: step.symbol)
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color(.systemGray), in: .rect(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 1) {
                            if step.distanceMeters > 0 {
                                Text(step.distanceMeters.roadDistance)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.primary)
                            }
                            Text(step.instruction)
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
