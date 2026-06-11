import SwiftUI

/// Monochrome "gallery print" palette: warm paper background, true-white
/// cards lifted by hairlines and soft shadows, ink-black type and actions,
/// serif display headings. Photos are the only color in the app — the
/// chrome stays black and white so the memories carry the room.
enum Theme {
    /// Warm paper — the canvas everything sits on.
    static let background = Color(red: 0.980, green: 0.978, blue: 0.972)
    /// True white — cards, fields, list rows. Lifts off the paper.
    static let surface = Color.white
    /// Pressed/recessed surfaces.
    static let surfaceElevated = Color(red: 0.942, green: 0.940, blue: 0.933)
    /// Ink — the single action color. Buttons, badges, highlights.
    static let accent = Color(red: 0.086, green: 0.086, blue: 0.078)
    static let textPrimary = Color(red: 0.102, green: 0.102, blue: 0.094)
    static let textSecondary = Color(red: 0.478, green: 0.478, blue: 0.463)
    /// The one permitted non-monochrome: a muted brick red, reserved for
    /// destructive actions and errors.
    static let destructive = Color(red: 0.62, green: 0.21, blue: 0.16)

    /// Hairline strokes that define edges on white-on-paper layering.
    static let hairline = Color.black.opacity(0.08)
    /// Soft ambient card shadow.
    static let shadow = Color.black.opacity(0.07)

    static let cardCornerRadius: CGFloat = 18
    static let screenPadding: CGFloat = 20

    /// Display type is serif (New York) — the editorial, printed-album
    /// voice of the app. Body text stays SF for crispness.
    static func displayFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

extension View {
    /// The signature surface treatment: white card on paper, hairline
    /// edge, soft shadow. Used by every card-like component.
    func cardSurface(cornerRadius: CGFloat = Theme.cardCornerRadius) -> some View {
        self
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: Theme.shadow, radius: 14, x: 0, y: 5)
    }
}

extension Color {
    /// "1A1A18" → Color. Falls back to ink for malformed input.
    init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: .alphanumerics.inverted)
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self = Theme.accent
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Avatar colors offered during onboarding/profile editing — an ink ramp,
/// near-black to warm gray, so member identity reads in pure monochrome.
/// All values stay dark enough for white initials.
enum AvatarPalette {
    static let hexes = [
        "161614", "2B2B28", "403F3C", "555450",
        "6A6964", "7E7D78", "343431", "4A4946",
    ]
}
