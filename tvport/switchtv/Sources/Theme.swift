// Every colour and metric of SwitchTV lives here, taken from the logo (Branding/switchtv-icon-source.png: a black and red split apple).
// Retune the look by editing this file only.
import SwiftUI

enum Theme {
    /// The logo's red (sampled from the right half of the mark): focus rings, the Play button, highlights.
    static let accent = Color(hex: 0xEE010D)
    /// The logo's black (the left half): the page.
    static let ink = Color(hex: 0x0D0D0D)
    static let background = Color(hex: 0x0A0A0B)
    static let surface = Color(hex: 0x19191B)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.68)
    static let textTertiary = Color.white.opacity(0.45)

    /// The split-apple motif: black to the left, a red glow to the right. Used behind the hero and the detail art.
    static let split = LinearGradient(stops: [.init(color: ink, location: 0), .init(color: ink.opacity(0.85), location: 0.45), .init(color: accent.opacity(0.28), location: 1)],
                                      startPoint: .leading, endPoint: .trailing)
    /// Fades art into the page at its bottom edge.
    static let fadeToPage = LinearGradient(colors: [.clear, background.opacity(0.85), background], startPoint: .top, endPoint: .bottom)

    static let cardWidth: CGFloat = 400
    static let cardAspect: CGFloat = 16.0 / 9.0
    static let cardRadius: CGFloat = 14
    static let pagePadding: CGFloat = 80
    static let rowSpacing: CGFloat = 40
    /// The hero at the top of the home screen; the poster rows get the rest of the 1080-point screen.
    static let heroHeight: CGFloat = 470
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}
