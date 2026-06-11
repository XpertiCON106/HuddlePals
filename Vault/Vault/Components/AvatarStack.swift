import SwiftUI

struct AvatarView: View {
    let name: String
    let colorHex: String
    var size: CGFloat = 36

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        Circle()
            .fill(Color(hex: colorHex))
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }
}

/// Overlapping colored circles with initials; collapses the overflow into
/// a "+N" bubble.
struct AvatarStack: View {
    let users: [User]
    var size: CGFloat = 32
    var maxVisible: Int = 4

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(users.prefix(maxVisible).enumerated()), id: \.element.id) { index, user in
                AvatarView(name: user.displayName, colorHex: user.avatarColorHex, size: size)
                    .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
                    .zIndex(Double(maxVisible - index))
            }
            if users.count > maxVisible {
                Circle()
                    .fill(Theme.surfaceElevated)
                    .frame(width: size, height: size)
                    .overlay {
                        Text("+\(users.count - maxVisible)")
                            .font(.system(size: size * 0.36, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
            }
        }
    }
}
