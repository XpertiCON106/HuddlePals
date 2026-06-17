import SwiftUI

struct AvatarView: View {
    @Environment(AppDependencies.self) private var deps
    let name: String
    let colorHex: String
    /// A user's profile picture (Documents-relative path). When present it
    /// renders inside the avatar; otherwise the colored initials show.
    var imagePath: String? = nil
    var size: CGFloat = 36

    @State private var image: UIImage?
    @State private var loadedPath: String?

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        Circle()
            .fill(AvatarStyle.fill(for: colorHex))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .task(id: imagePath) {
                guard let imagePath, loadedPath != imagePath else { return }
                let data = await deps.mediaService.loadImageData(at: imagePath)
                image = data.flatMap(UIImage.init(data:))
                loadedPath = imagePath
            }
    }
}

/// Overlapping identity circles; collapses overflow into a "+N" bubble.
struct AvatarStack: View {
    let users: [User]
    var size: CGFloat = 32
    var maxVisible: Int = 4

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(users.prefix(maxVisible).enumerated()), id: \.element.id) { index, user in
                AvatarView(
                    name: user.displayName,
                    colorHex: user.avatarColorHex,
                    imagePath: user.profilePhotoPaths.first,
                    size: size
                )
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

/// Makes any name/avatar open that member's profile. Used everywhere a
/// person appears: feed cards, detail headers, comments, member lists.
struct UserLink<Content: View>: View {
    @Environment(AppRouter.self) private var router
    let user: User?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let user {
            Button {
                Haptics.light()
                router.vaultsPath.append(.userProfile(user))
            } label: {
                content()
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }
}

/// Shared identity-color picker. Default: solid swatches in a grid with
/// gradients beneath (profile editing). `singleLine`: a curated five in one
/// clean row (onboarding).
struct ColorRampPicker: View {
    @Binding var selection: String
    var singleLine = false

    /// The curated handful shown in single-line mode.
    static let compactTokens = Array(AvatarPalette.solids.prefix(5))

    var body: some View {
        if singleLine {
            HStack(spacing: 18) {
                ForEach(Self.compactTokens, id: \.self) { token in
                    swatch(token, size: 40)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                    ForEach(AvatarPalette.solids, id: \.self) { token in
                        swatch(token)
                    }
                }
                HStack(spacing: 12) {
                    ForEach(AvatarPalette.gradients, id: \.self) { token in
                        swatch(token)
                    }
                }
            }
        }
    }

    private func swatch(_ token: String, size: CGFloat = 34) -> some View {
        Circle()
            .fill(AvatarStyle.fill(for: token))
            .frame(width: size, height: size)
            .overlay {
                if token == selection {
                    Circle().strokeBorder(.white, lineWidth: 2.5)
                    Circle().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 4.5)
                }
            }
            .scaleEffect(token == selection ? 1.12 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selection)
            .onTapGesture {
                selection = token
                Haptics.light()
            }
    }
}
