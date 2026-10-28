import SwiftUI

/// Anyone's profile, opened by tapping their name or avatar anywhere:
/// swipeable photos, bio, and the huddles (and streaks) you share with them.
struct UserProfileView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    let user: User

    @State private var viewModel: UserProfileViewModel?
    @State private var showBlockConfirmation = false
    @State private var showOptions = false

    private var sharedHuddles: [Huddle] {
        guard let me = deps.session.currentUser else { return [] }
        let mine = Set(me.memberships.compactMap { $0.huddle?.id })
        return user.memberships
            .compactMap(\.huddle)
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

                if !sharedHuddles.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Huddles you share")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .textCase(.uppercase)
                            .kerning(0.5)

                        ForEach(sharedHuddles) { huddle in
                            Button {
                                router.huddlesPath.append(.huddleHome(huddle))
                            } label: {
                                HStack(spacing: 12) {
                                    Text(huddle.emoji)
                                        .font(.system(size: 24))
                                        .frame(width: 44, height: 44)
                                        .background(
                                            Theme.surfaceElevated,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        )
                                    Text(huddle.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    StreakBadge(count: huddle.streakCount)
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
        .onAppear {
            if viewModel == nil { viewModel = UserProfileViewModel(deps: deps, user: user) }
        }
        .toolbar {
            if let viewModel, !viewModel.isSelf {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showOptions = true
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("More options")
                }
            }
        }
        .appDialog(user.displayName, isPresented: $showOptions, actions: optionActions)
        .appDialog(
            "Block \(user.displayName)?",
            isPresented: $showBlockConfirmation,
            message: "You won't see their photos, videos or comments anymore. They won't be told.",
            actions: [
                DialogAction("Block", role: .destructive) {
                    Task { await viewModel?.toggleBlock() }
                },
                .cancel(),
            ]
        )
        .appDialog(
            viewModel?.didReport == false ? "Couldn't send the report" : ReportFeedback.title,
            isPresented: Binding(
                get: { viewModel?.isReportAlertPresented ?? false },
                set: { viewModel?.isReportAlertPresented = $0 }
            ),
            message: viewModel?.didReport == false ? "Check your connection and try again." : ReportFeedback.message,
            actions: [DialogAction("Done", role: .cancel)]
        )
    }

    /// Report them; block or unblock them.
    private var optionActions: [DialogAction] {
        guard let viewModel else { return [.cancel()] }
        return [
            DialogAction(
                viewModel.didReport ? "Reported" : "Report \(user.displayName)",
                role: .secondary,
                systemImage: "flag",
                isEnabled: !viewModel.didReport
            ) {
                Task { await viewModel.report() }
            },
            viewModel.isBlocked
                ? DialogAction("Unblock \(user.displayName)", role: .secondary, systemImage: "hand.raised.slash") {
                    Task { await viewModel.toggleBlock() }
                }
                : DialogAction("Block \(user.displayName)", role: .destructive, systemImage: "hand.raised") {
                    showBlockConfirmation = true
                },
            .cancel(),
        ]
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
