import CommuteCore
import SwiftUI

/// How the trip is doing against the time the rider has to be there. Green within five minutes of the
/// target, lighter green when comfortably early, orange five to ten minutes late, red beyond that.
/// A card of its own at the head of the trip, not part of the sheet's edge.
struct ArriveByBar: View {
    let progress: ArriveByProgress
    var onEdit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: progress.standing.symbol)
                    .foregroundStyle(progress.standing.tint)
                Text(progress.isFinal ? "Arrived" : progress.standing.label)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(progress.deltaDescription) · by \(progress.target.clockTime)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if onEdit != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            ArriveByTrack(progress: progress)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(progress.standing.tint.opacity(0.14), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(progress.standing.tint.opacity(0.35), lineWidth: 1))
        .animation(.easeInOut, value: progress.standing)
        .contentShape(.rect(cornerRadius: 18))
        .onTapGesture { onEdit?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(progress.standing.label). Arriving \(progress.projectedArrival.clockTime), \(progress.deltaDescription) for \(progress.target.clockTime).")
        .accessibilityAddTraits(onEdit == nil ? [] : .isButton)
    }
}

#Preview {
    let now = Date.now
    VStack(spacing: 12) {
        ArriveByBar(progress: ArriveByProgress(target: now + 1_200, projectedArrival: now))
        ArriveByBar(progress: ArriveByProgress(target: now, projectedArrival: now + 120), onEdit: {})
        ArriveByBar(progress: ArriveByProgress(target: now, projectedArrival: now + 450))
        ArriveByBar(progress: ArriveByProgress(target: now, projectedArrival: now + 1_500))
    }
    .padding()
}
