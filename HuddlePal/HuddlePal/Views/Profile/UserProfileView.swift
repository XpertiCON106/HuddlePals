import SwiftUI

/// Anyone's profile, opened by tapping their name or avatar anywhere:
/// swipeable photos, bio, and the huddles (and streaks) you share with them.
struct UserProfileView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    let user: User

    @State private var viewModel: UserProfileViewModel?
    @State private var showBlockConfirmation = false

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
                    Menu {
                        Button(viewModel.didReport ? "Reported" : "Report \(user.displayName)", systemImage: "flag") {
                            Task { await viewModel.report() }
                        }
                        .disabled(viewModel.didReport)
                        Button(
                            viewModel.isBlocked ? "Unblock \(user.displayName)" : "Block \(user.displayName)",
                            systemImage: viewModel.isBlocked ? "hand.raised.slash" : "hand.raised",
                            role: viewModel.isBlocked ? nil : .destructive
                        ) {
                            if viewModel.isBlocked {
                                Task { await viewModel.toggleBlock() }
                            } else {
                                showBlockConfirmation = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("More options")
                }
            }
        }
        .confirmationDialog(
            "Block \(user.displayName)?",
            isPresented: $showBlockConfirmation,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) {
                Task { await viewModel?.toggleBlock() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see their photos, videos or comments anymore. They won't be told.")
        }
        .alert(
            viewModel?.didReport == false ? "Couldn't send the report" : ReportFeedback.title,
            isPresented: Binding(
                get: { viewModel?.isReportAlertPresented ?? false },
                set: { viewModel?.isReportAlertPresented = $0 }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel?.didReport == false ? "Check your connection and try again." : ReportFeedback.message)
        }
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
