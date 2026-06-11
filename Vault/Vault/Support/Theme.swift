import SwiftUI

/// Dark, warm "heirloom" palette: deep charcoal, warm amber, generous
/// spacing, rounded display type. No social-media tropes.
enum Theme {
    static let background = Color(red: 0.09, green: 0.082, blue: 0.07)
    static let surface = Color(red: 0.135, green: 0.124, blue: 0.108)
    static let surfaceElevated = Color(red: 0.18, green: 0.165, blue: 0.145)
    static let accent = Color(red: 0.91, green: 0.64, blue: 0.24)
    static let textPrimary = Color(white: 0.96)
    static let textSecondary = Color(white: 0.62)
    static let destructive = Color(red: 0.85, green: 0.4, blue: 0.32)

    static let cardCornerRadius: CGFloat = 18
    static let screenPadding: CGFloat = 20

    static func displayFont(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Color {
    /// "E8A33D" → Color. Falls back to amber for malformed input.
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

/// Avatar colors offered during onboarding/profile editing.
enum AvatarPalette {
    static let hexes = [
        "E8A33D", "7FB069", "5B8DEF", "C97FD6",
        "E07A5F", "81B29A", "F2CC8F", "6D9DC5",
    ]
}
