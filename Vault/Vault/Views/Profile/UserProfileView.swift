import SwiftUI

/// Anyone's profile, opened by tapping their name or avatar anywhere:
/// swipeable photos, bio, and the vaults (and streaks) you share with them.
struct UserProfileView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    let user: User

    private var sharedVaults: [Vault] {
        guard let me = deps.session.currentUser else { return [] }
        let mine = Set(me.memberships.compactMap { $0.vault?.id })
        return user.memberships
            .compactMap(\.vault)
            .filter { mine.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                photoPager

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        AvatarView(
                            name: user.displayName,
                            colorHex: user.avatarColorHex,
                            imagePath: user.profilePhotoPaths.first,
                            size: 40
                        )
                        Text(user.displayName)
                            .font(Theme.displayFont(26))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    if let bio = user.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.horizontal, 28)
                    }
                    Text("Member since \(user.joinedAt.formatted(.dateTime.month(.wide).year()))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                }

                if !sharedVaults.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Vaults you share")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .textCase(.uppercase)
                            .kerning(0.5)

                        ForEach(sharedVaults) { vault in
                            Button {
                                router.vaultsPath.append(.vaultHome(vault))
                            } label: {
                                HStack(spacing: 12) {
                                    Text(vault.emoji)
                                        .font(.system(size: 24))
                                        .frame(width: 44, height: 44)
                                        .background(
                                            Theme.surfaceElevated,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        )
                                    Text(vault.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    StreakBadge(count: vault.streakCount)
                                }
                                .padding(12)
                                .cardSurface(cornerRadius: 16)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Theme.screenPadding)
        }
        .background(Theme.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
    }

    @ViewBuilder
    private var photoPager: some View {
        if user.profilePhotoPaths.isEmpty {
            AvatarView(name: user.displayName, colorHex: user.avatarColorHex, size: 132)
                .padding(.top, 16)
        } else {
            TabView {
                ForEach(user.profilePhotoPaths, id: \.self) { path in
                    LocalDepositImage(relativePath: path)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: 1)
                        )
                        .padding(.horizontal, 28)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: user.profilePhotoPaths.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            .aspectRatio(3 / 4.3, contentMode: .fit)
        }
    }
}
