import SwiftUI
import UIKit

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
