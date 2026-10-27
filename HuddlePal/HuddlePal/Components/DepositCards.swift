import ImageIO
import SwiftUI

// MARK: - Local image loading

/// Renders a deposit photo from the Documents-relative path. Views never
/// touch MediaService — the image data is resolved by the parent's view
/// model and passed down, or loaded here via the environment dependencies'
/// media service strictly as a *display* concern.
struct LocalDepositImage: View {
    @Environment(AppDependencies.self) private var deps
    let relativePath: String
    /// Cap on the decoded bitmap's longest edge, in pixels. Thumbnail
    /// contexts (archive tiles, profile strips) must set this: a full
    /// 1440px deposit decodes to ~10 MB of RAM behind a 110pt tile.
    var maxPixelSize: CGFloat? = nil
    /// Set for huddle photos — use `init(deposit:)`. They're end-to-end
    /// encrypted in live mode; one whose key isn't loaded yet (a cold launch,
    /// before the huddle's key sync finishes) shows a lock until it is. Nil
    /// for profile photos, which aren't encrypted.
    var deposit: Deposit? = nil

    @State private var image: UIImage?
    @State private var loadedPath: String?
    @State private var isLocked = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.surfaceElevated
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if isLocked {
                    lockedPlaceholder
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        // One element for VoiceOver: whose photo it is (or that it's locked).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isImage)
        // A huddle photo that couldn't be opened retries whenever this device
        // gains a huddle key (the launch-time sync, or an invite).
        .task(id: deposit == nil ? relativePath : "\(relativePath)#\(deps.session.photoKeysVersion)") {
            // Reload when the path changes (remote sync can re-path a row);
            // skip when already loaded.
            guard loadedPath != relativePath else { return }
            let loaded: Data?
            if let deposit {
                if let huddleID = deposit.huddle?.id {
                    loaded = await deps.mediaService.loadDepositPhoto(
                        at: relativePath, huddleID: huddleID, wrappedPhotoKey: deposit.wrappedPhotoKey
                    )
                } else {
                    loaded = nil
                }
            } else {
                loaded = await deps.mediaService.loadImageData(at: relativePath)
            }
            if let maxPixelSize {
                image = loaded.flatMap { Self.downsampled($0, maxPixelSize: maxPixelSize) }
            } else {
                image = loaded.flatMap(UIImage.init(data:))
            }
            isLocked = deposit != nil && image == nil
            // Only a huddle photo that opened is final; a locked one retries.
            if deposit == nil || image != nil {
                loadedPath = relativePath
            }
        }
    }

    private var accessibilityDescription: String {
        guard let deposit else { return "Profile photo" }
        if isLocked { return "Photo locked" }
        return "Photo by \(deposit.author?.displayName ?? "Former member")"
    }

    private var lockedPlaceholder: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(16)
            .accessibilityLabel("Photo locked")
    }

    /// ImageIO thumbnail decode: never materializes the full-size bitmap.
    private static func downsampled(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}

extension LocalDepositImage {
    /// A huddle photo — decrypted with its huddle's key in live mode.
    init(deposit: Deposit, maxPixelSize: CGFloat? = nil) {
        self.init(relativePath: deposit.localImagePath, maxPixelSize: maxPixelSize, deposit: deposit)
    }
}

// MARK: - Unlocked card

/// Full deposit card for the unlocked feed: photo, caption, author row,
/// reaction summary.
struct DepositCard: View {
    let deposit: Deposit

    private var reactionSummary: [(emoji: String, count: Int)] {
        Dictionary(grouping: deposit.reactions, by: \.emoji)
            .map { (emoji: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if deposit.isVideo {
                    // Loops muted; a tap on it unmutes, the rest of the card opens it.
                    DepositVideoPlayer(deposit: deposit, startsMuted: true)
                } else {
                    LocalDepositImage(deposit: deposit)
                }
            }
            .aspectRatio(3 / 4, contentMode: .fit)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    UserLink(user: deposit.author) {
                        HStack(spacing: 10) {
                            AvatarView(
                                name: deposit.author?.displayName ?? "?",
                                colorHex: deposit.author?.avatarColorHex ?? "888888",
                                imagePath: deposit.author?.profilePhotoPaths.first,
                                size: 30
                            )
                            Text(deposit.author?.displayName ?? "Former member")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    Spacer()
                    Text(deposit.createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }

                if let caption = deposit.caption {
                    Text(caption)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                        .lineSpacing(2)
                }

                if !reactionSummary.isEmpty || !deposit.comments.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(reactionSummary, id: \.emoji) { item in
                            Text("\(item.emoji) \(item.count)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if !deposit.comments.isEmpty {
                            Label("\(deposit.comments.count)", systemImage: "bubble")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(14)
        }
        .cardSurface()
    }
}

// MARK: - Archive tile past the free window

/// A deposit from a day past the free plan's 30 days: its author's color
/// under frosted glass, and a lock. Drawn from the author alone: the photo
/// (or video) is never loaded, downloaded or decrypted, so there's nothing
/// for a blur to reveal.
struct LockedArchiveTile: View {
    let author: User?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            AvatarStyle.base(for: author?.avatarColorHex ?? "555555").opacity(0.45),
                            Theme.surfaceElevated,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Image(systemName: "lock.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent.opacity(0.6))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Locked card

/// Frosted card shown while the huddle is locked: author identity stays
/// visible, the photo and caption stay hidden. The blur teases — it never
/// reveals.
struct BlurredDepositCard: View {
    let deposit: Deposit

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                // Abstract stand-in tinted by the author's color — the real
                // image bytes are deliberately never loaded while locked.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                // `base(for:)` resolves gradient identity
                                // tokens too — a plain Color(hex:) would fall
                                // back to gray for "hex-hex" tokens.
                                AvatarStyle.base(for: deposit.author?.avatarColorHex ?? "555555").opacity(0.30),
                                Theme.surfaceElevated,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .overlay(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Image(systemName: "lock.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.accent.opacity(0.55))
            }

            HStack(spacing: 7) {
                AvatarView(
                    name: deposit.author?.displayName ?? "?",
                    colorHex: deposit.author?.avatarColorHex ?? "888888",
                    imagePath: deposit.author?.profilePhotoPaths.first,
                    size: 22
                )
                Text(deposit.author?.displayName ?? "Former member")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .cardSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(deposit.author?.displayName ?? "Former member")'s photo, locked until you share yours")
    }
}
