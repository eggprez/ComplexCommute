import GTFSKit
import SwiftUI
import UIKit

// How a line and its times are drawn, the same on a station's board in the app and in the departures widget.

extension Color {
    /// Green for words, not just symbols: system green is too pale to read as text on a light background.
    static let goodText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0.07, green: 0.52, blue: 0.2, alpha: 1)
    })

    /// Orange for words, for the same reason.
    static let warningText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemOrange : UIColor(red: 0.76, green: 0.35, blue: 0, alpha: 1)
    })

    /// Black or white, whichever reads better on a fill of this color.
    static func readable(on hex: String?) -> Color? {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        func linear(_ channel: UInt32) -> Double {
            let c = Double(channel & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(value >> 16) + 0.7152 * linear(value >> 8) + 0.0722 * linear(value)
        return luminance > 0.4 ? .black : .white
    }
}

/// A line's bullet as riders know it from signs: a disc for a subway letter or number, a lozenge for anything longer.
struct RouteBadgeView: View {
    enum Size {
        case small, regular, large

        var height: CGFloat {
            switch self {
            case .small: 18
            case .regular: 22
            case .large: 30
            }
        }

        var font: Font {
            switch self {
            case .small: .caption2.weight(.bold)
            case .regular: .caption.weight(.bold)
            case .large: .callout.weight(.bold)
            }
        }
    }

    let route: RouteBadge
    var size = Size.small

    var body: some View {
        let fill = Color(hex: route.colorHex) ?? Color(.systemGray3)
        Text(route.name)
            .font(size.font)
            .lineLimit(1)
            .foregroundStyle(Color(hex: route.textColorHex) ?? Color.readable(on: route.colorHex) ?? Color.primary)
            .padding(.horizontal, route.name.count <= 2 ? 0 : size.height * 0.3)
            .frame(minWidth: size.height, minHeight: size.height)
            .background(fill, in: .rect(cornerRadius: route.name.count <= 2 ? size.height / 2 : size.height * 0.28))
            .accessibilityLabel("\(route.name) line")
    }
}
