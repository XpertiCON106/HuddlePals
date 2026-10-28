import SwiftUI

/// The shelf: every huddle you belong to, each with its members, streak,
/// and today's lock state. Tap to step inside.
struct HuddleListView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: HuddleListViewModel?

    var body: some View {
        Group {
            if let viewModel {
                HuddleListContent(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        // Full screen whatever the content: while only the spinner shows, the
        // scroll view would otherwise shrink to its width and leave the
        // background a strip down the middle.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onAppear {
            if viewModel == nil { viewModel = HuddleListViewModel(deps: deps) }
        }
    }
}

private struct HuddleListContent: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var viewModel: HuddleListViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if viewModel.isLoading && !viewModel.hasHuddles {
                    ProgressView()
                        .padding(.top, 120)
                } else if !viewModel.hasHuddles {
                    emptyState
                } else {
                    ForEach(viewModel.rows) { row in
                        Button {
                            Haptics.light()
                            router.huddlesPath.append(.huddleHome(row.huddle))
                        } label: {
                            HuddleRowCard(row: row)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                    }
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.destructive)
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.rows.map(\.id))
        }
        .refreshable { await viewModel.refresh() }
        .navigationTitle("Huddles")
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    router.openProfile()
                } label: {
                    if let user = deps.session.currentUser {
                        AvatarView(
                            name: user.displayName, colorHex: user.avatarColorHex,
                            imagePath: user.profilePhotoPaths.first, size: 30
                        )
                    } else {
                        Image(systemName: "person.crop.circle")
                    }
                }
                .accessibilityLabel("Profile")

                Menu {
                    Button {
                        router.huddlesPath.append(.createHuddle)
                    } label: {
                        Label("Create a Huddle", systemImage: "plus.circle")
                    }
                    Button {
                        router.huddlesPath.append(.joinHuddle)
                    } label: {
                        Label("Join with a code", systemImage: "person.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityLabel("Create or join a huddle")
            }
        }
        .task {
            await viewModel.refresh()
            // A notification tap that launched the app.
            await openNotifiedHuddle()
        }
        .onChange(of: deps.session.pendingHuddleID) { _, id in
            if id != nil {
                Task { await openNotifiedHuddle() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.refresh() }
            }
        }
        .onChange(of: deps.dateProvider.dayOffset) {
            Task { await viewModel.refresh() }
        }
        .onChange(of: deps.debug.simulateNotPostedToday) {
            Task { await viewModel.refresh() }
        }
    }

    private func openNotifiedHuddle() async {
        if let huddle = await viewModel.takeNotifiedHuddle() {
            router.openHuddle(huddle)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            EmptyHuddleState(
                systemImage: "shippingbox",
                title: "No huddles yet",
                message: "A huddle is a small, private group — one with your family, one with your best friends. Create one or join with an invite code."
            )
            .padding(.top, 60)
            PrimaryButton(title: "Create a Huddle", systemImage: "plus") {
                router.huddlesPath.append(.createHuddle)
            }
            Button("Join with a code") {
                router.huddlesPath.append(.joinHuddle)
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.accent)
        }
    }
}

private struct HuddleRowCard: View {
    let row: HuddleListViewModel.Row

    var body: some View {
        HStack(spacing: 14) {
            Text(row.huddle.emoji)
                .font(.system(size: 30))
                .frame(width: 56, height: 56)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(row.huddle.name)
                    .font(Theme.displayFont(19))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    AvatarStack(users: row.members, size: 20)
                    Text(todayLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        // Two lines on small phones rather than "3 waiting fo…".
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                StreakBadge(count: row.streak)
                Image(systemName: row.isUnlockedToday ? "lock.open" : "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(row.isUnlockedToday ? Theme.textSecondary : Theme.accent)
            }
        }
        .padding(14)
        .cardSurface()
    }

    private var todayLine: String {
        if row.depositedTodayCount == 0 { return "Nobody has posted yet" }
        if row.isUnlockedToday { return "\(row.depositedTodayCount) of \(row.members.count) today" }
        return "\(row.depositedTodayCount) waiting for you"
    }
}
