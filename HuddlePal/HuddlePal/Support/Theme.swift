import SwiftUI
import UIKit

/// Adaptive "gallery print" palette. Light: warm paper, true-white cards,
/// ink actions. Dark: deep charcoal (never flat black), softly elevated
/// surfaces, paper-white actions. Every constant is a dynamic color, so the
/// whole app flips with the system (or the in-app appearance setting) with
/// no per-view work. Member avatars carry the color; chrome stays neutral.
enum Theme {
    private static func dynamic(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

    /// Canvas: warm paper / deep charcoal.
    static let background = dynamic(
        light: (0.980, 0.978, 0.972),
        dark: (0.090, 0.088, 0.082)
    )
    /// Cards, fields, list rows — lifted off the canvas.
    static let surface = dynamic(
        light: (1.0, 1.0, 1.0),
        dark: (0.137, 0.134, 0.126)
    )
    /// Pressed / recessed surfaces.
    static let surfaceElevated = dynamic(
        light: (0.942, 0.940, 0.933),
        dark: (0.190, 0.186, 0.176)
    )
    /// The single action color: ink on paper, paper on charcoal.
    static let accent = dynamic(
        light: (0.086, 0.086, 0.078),
        dark: (0.952, 0.948, 0.938)
    )
    /// Text/icon color drawn on top of `accent` fills.
    static let onAccent = dynamic(
        light: (1.0, 1.0, 1.0),
        dark: (0.090, 0.088, 0.082)
    )
    static let textPrimary = dynamic(
        light: (0.102, 0.102, 0.094),
        dark: (0.945, 0.941, 0.930)
    )
    /// Light mode ≈ 5:1 on the paper canvas (WCAG AA for small text; the
    /// earlier 0.478 gray was ≈ 4.2:1).
    static let textSecondary = dynamic(
        light: (0.400, 0.400, 0.388),
        dark: (0.604, 0.600, 0.584)
    )
    /// Muted brick red — destructive actions and errors only.
    static let destructive = dynamic(
        light: (0.62, 0.21, 0.16),
        dark: (0.88, 0.42, 0.36)
    )

    /// Hairline edges that define layering in both modes.
    static let hairline = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.09)
            : UIColor(white: 0, alpha: 0.08)
    })
    /// Soft ambient card shadow (near-invisible in dark; surfaces carry depth).
    static let shadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0, alpha: 0.30)
            : UIColor(white: 0, alpha: 0.07)
    })

    static let cardCornerRadius: CGFloat = 18
    static let screenPadding: CGFloat = 20

    /// Display type is serif (New York); body stays SF.
    static func displayFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Appearance preference

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil follows the device.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// User-facing app settings, persisted across launches.
@Observable
final class AppearanceSettings {
    private static let key = "huddlepal.appearance"

    var preference: AppearancePreference {
        didSet { UserDefaults.standard.set(preference.rawValue, forKey: Self.key) }
    }

    init() {
        preference = UserDefaults.standard.string(forKey: Self.key)
            .flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }
}

extension View {
    /// The signature surface: card on canvas, hairline edge, soft shadow.
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
    /// "FF5E5B" → Color. Falls back to a neutral for malformed input.
    init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: .alphanumerics.inverted)
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self.init(white: 0.5)
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Avatar identity colors

/// A member's identity color token: either a solid ("FF5E5B") or a gradient
/// ("FF5E5B-FF9F1C"). Stored as-is in `avatarColorHex` locally and in the
/// `profiles.avatar_color_hex` column, so the choice follows the user
/// everywhere their name or avatar appears.
enum AvatarStyle {
    static func components(of token: String) -> [Color] {
        let parts = token.split(separator: "-").map { Color(hex: String($0)) }
        return parts.isEmpty ? [Color(white: 0.5)] : parts
    }

    /// Fill for avatars and large identity surfaces.
    static func fill(for token: String) -> AnyShapeStyle {
        let colors = components(of: token)
        if colors.count >= 2 {
            return AnyShapeStyle(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
        return AnyShapeStyle(colors[0])
    }

    /// Single representative color (tints, locked-card washes).
    static func base(for token: String) -> Color {
        components(of: token)[0]
    }
}

/// Identity palette: a small, curated set — six saturated solids plus two
/// gradients (eight total). All dark enough for white initials, vivid in
/// both light and dark mode.
enum AvatarPalette {
    static let solids = [
        "E5484D", // coral red
        "F76B15", // tangerine
        "46A758", // leaf
        "0091FF", // azure
        "6E56CF", // violet
        "D6409F", // magenta
    ]
    static let gradients = [
        "F76B15-E5484D", // sunset
        "0091FF-6E56CF", // twilight
    ]
    static let hexes = solids + gradients

    /// Spoken names for the identity colors (VoiceOver); a custom token
    /// falls back to a generic name.
    static func name(for token: String) -> String {
        switch token {
        case "E5484D": "Coral red"
        case "F76B15": "Tangerine"
        case "46A758": "Leaf green"
        case "0091FF": "Azure"
        case "6E56CF": "Violet"
        case "D6409F": "Magenta"
        case "F76B15-E5484D": "Sunset gradient"
        case "0091FF-6E56CF": "Twilight gradient"
        default: "Custom color"
        }
    }
}
