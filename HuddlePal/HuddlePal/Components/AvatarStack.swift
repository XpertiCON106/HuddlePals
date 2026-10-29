import SwiftUI

struct AvatarView: View {
    @Environment(AppDependencies.self) private var deps
    let name: String
    let colorHex: String
    /// A user's profile picture (Documents-relative path). When present it
    /// renders inside the avatar; otherwise the colored initials show.
    var imagePath: String? = nil
    /// In-memory draft preview used by the profile editor before a confirmed
    /// save uploads and commits the new first photo.
    var imageData: Data? = nil
    var size: CGFloat = 36

    @State private var image: UIImage?
    @State private var loadedPath: String?
    /// Its picture is in, or a second has gone by (`MediaReadyKey`): a card
    /// shouldn't wait on a slow profile picture for long.
    @State private var isSettled = false

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// A picture already shown somewhere in the app, drawn from the first
    /// frame: opening a huddle shows its members' pictures at once, not
    /// their colours first.
    private var cachedImage: UIImage? {
        guard imageData == nil, let imagePath else { return nil }
        return AvatarImageCache.shared.image(for: imagePath)
    }

    /// A picture is on its way: a plain circle meanwhile, not the colour and
    /// initials of someone who has no picture.
    private var isWaitingForPicture: Bool {
        imagePath != nil && imageData == nil && !isSettled
    }

    var body: some View {
        let shown = cachedImage ?? image
        Circle()
            .fill(shown == nil && isWaitingForPicture ? AnyShapeStyle(Theme.surfaceElevated) : AvatarStyle.fill(for: colorHex))
            .frame(width: size, height: size)
            .overlay {
                if let shown {
                    Image(uiImage: shown)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if !isWaitingForPicture {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            // Decorative: a name is always next to it, or the surrounding
            // link / stack carries it (UserLink, AvatarStack).
            .accessibilityHidden(true)
            .preference(key: MediaReadyKey.self, value: !isWaitingForPicture || shown != nil)
            .task(id: imageLoadID) {
                if let imageData {
                    image = UIImage(data: imageData)
                    loadedPath = nil
                    return
                }
                guard let imagePath else {
                    image = nil
                    loadedPath = nil
                    return
                }
                if let cached = AvatarImageCache.shared.image(for: imagePath) {
                    image = cached
                    loadedPath = imagePath
                    isSettled = true
                    return
                }
                guard loadedPath != imagePath else { return }
                let patience = Task {
                    try? await Task.sleep(for: .seconds(1))
                    isSettled = true
                }
                let data = await deps.mediaService.loadImageData(at: imagePath)
                let loaded = await AvatarImageCache.shared.decode(data, for: imagePath)
                patience.cancel()
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
                loadedPath = imagePath
                isSettled = true
            }
    }

    private var imageLoadID: String {
        if let imageData { return "draft:\(imageData.hashValue)" }
        return "persisted:\(imagePath ?? "none")"
    }
}

/// Profile pictures already decoded, by path, in memory only. A path's
/// picture never changes (every upload gets a new name), so an avatar drawn
/// again shows it at once. NSCache drops them under memory pressure;
/// sign-out empties it.
final class AvatarImageCache: @unchecked Sendable {
    static let shared = AvatarImageCache()
    private let cache = NSCache<NSString, UIImage>()

    /// Enough for the largest avatar that shows a picture (52 pt at 3x).
    private static let maxPixelSize: CGFloat = 180

    init() {
        cache.countLimit = 300
    }

    func image(for path: String) -> UIImage? {
        cache.object(forKey: path as NSString)
    }

    /// Decodes `data` small, off the main actor, and keeps it for `path`.
    func decode(_ data: Data?, for path: String) async -> UIImage? {
        guard let data else { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            LocalDepositImage.downsampled(data, maxPixelSize: Self.maxPixelSize)
        }.value
        if let image { cache.setObject(image, forKey: path as NSString) }
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(users.isEmpty ? "No members" : "Members: " + users.map(\.displayName).joined(separator: ", "))
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
                router.huddlesPath.append(.userProfile(user))
            } label: {
                content()
            }
            .buttonStyle(.plain)
            // Content is sometimes only the (decorative) avatar.
            .accessibilityLabel(user.displayName)
            .accessibilityHint("Shows their profile")
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

    /// The curated base shown in single-line mode.
    static let compactTokens = Array(AvatarPalette.solids.prefix(5))

    /// Always exactly five, and always including the current selection — so
    /// an existing color (even a gradient) stays highlighted on the profile
    /// editor.
    private var compactRow: [String] {
        if Self.compactTokens.contains(selection) { return Self.compactTokens }
        return [selection] + Self.compactTokens.prefix(4)
    }

    var body: some View {
        if singleLine {
            HStack(spacing: 18) {
                ForEach(compactRow, id: \.self) { token in
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
            // A bare shape with a tap gesture is invisible to VoiceOver.
            .accessibilityElement()
            .accessibilityLabel(AvatarPalette.name(for: token))
            .accessibilityAddTraits(token == selection ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction {
                selection = token
            }
    }
}
