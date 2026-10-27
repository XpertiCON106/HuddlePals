import SwiftUI

/// Full history, newest first: month headers → day rows → horizontal photo
/// strips. Deliberately finite — an archive you flip through, not a feed
/// you fall into.
struct ArchiveView: View {
    @Environment(AppDependencies.self) private var deps
    let huddle: Huddle

    @State private var viewModel: ArchiveViewModel?

    var body: some View {
        Group {
            if let viewModel {
                ArchiveContent(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .onAppear {
            if viewModel == nil { viewModel = ArchiveViewModel(deps: deps, huddle: huddle) }
        }
    }
}

private struct ArchiveContent: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Bindable var viewModel: ArchiveViewModel

    @State private var showBackfillCompose = false
    @State private var paywall: PaywallContext?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26, pinnedViews: .sectionHeaders) {
                if let backfillKey = viewModel.backfillDayKey {
                    backfillBanner(backfillKey)
                }

                if let error = viewModel.loadError {
                    LoadErrorBanner(message: error) {
                        Task { await viewModel.refresh() }
                    }
                }

                if !viewModel.hasLoaded {
                    if viewModel.loadError == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                            .accessibilityLabel("Loading the archive")
                    }
                } else if viewModel.months.isEmpty {
                    EmptyHuddleState(
                        systemImage: "archivebox",
                        title: "The archive starts today",
                        message: "Every day your group completes gets shelved here, forever."
                    )
                    .padding(.top, 60)
                } else {
                    ForEach(viewModel.months) { month in
                        Section {
                            ForEach(month.days) { day in
                                DayRow(day: day) { deposit in
                                    if day.isLocked {
                                        paywall = .archive
                                    } else {
                                        router.huddlesPath.append(.depositDetail(deposit))
                                    }
                                }
                            }
                        } header: {
                            Text(month.title)
                                .font(Theme.displayFont(20))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.background)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.bottom, 36)
        }
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .refreshable { await viewModel.refresh() }
        .task { await viewModel.refresh() }
        .onChange(of: deps.dateProvider.dayOffset) {
            Task { await viewModel.refresh() }
        }
        // Plus bought, run out, or the free limits started: the window moves.
        .onChange(of: deps.plus.status) {
            Task { await viewModel.refresh() }
        }
        .sheet(item: $paywall) { context in
            PaywallView(context: context)
        }
        .sheet(isPresented: $showBackfillCompose) {
            ComposeView(huddle: viewModel.huddle, targetDayKey: viewModel.backfillDayKey) { success in
                if success {
                    Task { await viewModel.handleBackfillSuccess() }
                }
            }
        }
    }

    private func backfillBanner(_ dayKey: String) -> some View {
        Button {
            showBackfillCompose = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add to yesterday")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("You have 48 hours to slip a photo into a missed day.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: Theme.shadow, radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }
}

private struct DayRow: View {
    let day: ArchiveViewModel.DaySection
    let onTap: (Deposit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(day.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                if day.isLocked {
                    Spacer()
                    Label("\(day.deposits.count) posted", systemImage: "lock.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(day.deposits) { deposit in
                        Button {
                            onTap(deposit)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Group {
                                    if day.isLocked {
                                        // Past the free 30 days: nothing loaded or decrypted.
                                        LockedArchiveTile(author: deposit.author)
                                    } else {
                                        // 146pt tile → 450px covers @3x displays.
                                        // A video shows its poster here; it plays in detail.
                                        LocalDepositImage(deposit: deposit, maxPixelSize: 450)
                                            .overlay(alignment: .topLeading) {
                                                if deposit.isVideo { VideoBadge(durationMs: deposit.durationMs).padding(6) }
                                            }
                                    }
                                }
                                .frame(width: 110, height: 146)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Theme.hairline, lineWidth: 1)
                                )
                                HStack(spacing: 5) {
                                    AvatarView(
                                        name: deposit.author?.displayName ?? "?",
                                        colorHex: deposit.author?.avatarColorHex ?? "888888",
                                        size: 16
                                    )
                                    Text(deposit.author?.displayName ?? "Former member")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.accessibilityLabel(for: deposit, locked: day.isLocked))
                        .accessibilityHint(day.isLocked ? "Unlock your full huddle archive with HuddlePals Plus." : "")
                    }
                }
            }
        }
    }

    private static func accessibilityLabel(for deposit: Deposit, locked: Bool) -> String {
        let author = deposit.author?.displayName ?? "Former member"
        if locked { return "Locked: \(author)'s post, past the free plan's 30 days" }
        return deposit.isVideo ? "Video by \(author)" : "Photo by \(author)"
    }
}
