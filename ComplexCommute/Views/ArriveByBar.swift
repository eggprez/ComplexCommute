import CommuteCore
import SwiftUI

/// How the trip is doing against the time the rider has to be there. Green within five minutes of the
/// target, lighter green when comfortably early, orange five to ten minutes late, red beyond that.
struct ArriveByBar: View {
    let progress: ArriveByProgress
    var onEdit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(progress.standing.tint.opacity(0.16))
        .contentShape(.rect)
        .onTapGesture { onEdit?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(progress.standing.label). Arriving \(progress.projectedArrival.clockTime), \(progress.deltaDescription) for \(progress.target.clockTime).")
        .accessibilityAddTraits(onEdit == nil ? [] : .isButton)
    }
}

#Preview {
    let now = Date.now
    VStack(spacing: 12) {
        ArriveByBar(progress: ArriveByProgress(target: now + 900, projectedArrival: now))
        ArriveByBar(progress: ArriveByProgress(target: now, projectedArrival: now + 120), onEdit: {})
        ArriveByBar(progress: ArriveByProgress(target: now, projectedArrival: now + 450))
        ArriveByBar(progress: ArriveByProgress(target: now, projectedArrival: now + 1_200))
    }
}
