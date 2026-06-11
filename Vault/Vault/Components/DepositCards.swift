import SwiftUI

// MARK: - Local image loading

/// Renders a deposit photo from the Documents-relative path. Views never
/// touch MediaService — the image data is resolved by the parent's view
/// model and passed down, or loaded here via the environment dependencies'
/// media service strictly as a *display* concern.
struct LocalDepositImage: View {
    @Environment(AppDependencies.self) private var deps
    let relativePath: String

    @State private var image: UIImage?
    @State private var loadedPath: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.surfaceElevated
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: relativePath) {
            // Reload when the path changes (same-day replacement keeps the
            // deposit id but swaps the file); skip when already loaded.
            guard loadedPath != relativePath else { return }
            let loaded = await deps.mediaService.loadImageData(at: relativePath)
            image = loaded.flatMap(UIImage.init(data:))
            loadedPath = relativePath
        }
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
            LocalDepositImage(relativePath: deposit.localImagePath)
                .aspectRatio(3 / 4, contentMode: .fit)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AvatarView(
                        name: deposit.author?.displayName ?? "?",
                        colorHex: deposit.author?.avatarColorHex ?? "888888",
                        size: 30
                    )
                    Text(deposit.author?.displayName ?? "Former member")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
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

// MARK: - Locked card

/// Frosted card shown while the vault is locked: author identity stays
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
                                Color(hex: deposit.author?.avatarColorHex ?? "555555").opacity(0.30),
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
                    size: 22
                )
                Text(deposit.author?.displayName ?? "Member")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .cardSurface()
    }
}
