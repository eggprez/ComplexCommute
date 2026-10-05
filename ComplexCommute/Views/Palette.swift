import SwiftUI
import UIKit

extension String {
    /// Agencies write line bullets into alert text as "[A][C]" or "[shuttle bus icon]"; on screen the
    /// brackets are noise. Runs of bullets read as "A/C".
    var withoutBulletCodes: String {
        replacing(/\s*\[[^\]]*\bicon\]/.ignoresCase(), with: "")
            .replacing(/(?:\[[A-Za-z0-9]{1,4}\])+/) { match in
                match.output.split(separator: "]").map { $0.dropFirst() }.joined(separator: "/")
            }
    }
}

/// Icon hard against its words. Inside a List row the standard style pushes a Label's icon out to the row's
/// icon column, which strands small inline labels far from their text.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == CompactLabelStyle {
    static var compact: CompactLabelStyle { CompactLabelStyle() }
}

/// A symbol on a colored tile, as Settings draws them; round where it stands for a place, as Maps does.
struct IconTile: View {
    let systemName: String
    var color = Color.accentColor
    var size: CGFloat = 30
    var isRound = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .rect(cornerRadius: isRound ? size / 2 : size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A row's name beside its tile.
struct TileLabel: View {
    let title: String
    let systemImage: String
    var color = Color.accentColor

    var body: some View {
        Label {
            Text(title)
        } icon: {
            IconTile(systemName: systemImage, color: color, size: 29)
        }
    }
}

/// A few words on a tinted capsule: "Fastest", "by 9:00 AM".
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint = Color.accentColor
    /// The words themselves, where the tint is too pale to read as text.
    var textColor: Color?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(textColor ?? tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.16), in: .capsule)
        .lineLimit(1)
    }
}

/// A sheet's section named in the bold type Maps uses, not the small gray capitals of a form.
struct SheetSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(Color.primary)
            .textCase(nil)
    }
}

extension TravelKind {
    var label: String {
        switch self {
        case .drive: "Drive"
        case .walk: "Walk"
        case .subway: "Subway"
        case .rail: "Train"
        case .bus: "Bus"
        case .tram: "Light rail"
        case .ferry: "Ferry"
        case .cable: "Cable car"
        case .transit: "Transit"
        }
    }

    var symbol: String {
        switch self {
        case .drive: "car.fill"
        case .walk: "figure.walk"
        case .subway: "tram.fill.tunnel"
        case .rail: "train.side.front.car"
        case .bus: "bus.fill"
        case .tram: "lightrail.fill"
        case .ferry: "ferry.fill"
        case .cable: "cablecar.fill"
        case .transit: "tram.fill"
        }
    }

    var tint: Color {
        switch self {
        case .drive: .blue
        case .walk: Color(.systemGray)
        case .subway: .indigo
        case .rail: .purple
        case .bus: .teal
        case .tram: .orange
        case .ferry: .cyan
        case .cable: .mint
        case .transit: .accentColor
        }
    }
}
