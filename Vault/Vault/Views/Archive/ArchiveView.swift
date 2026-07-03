import SwiftUI

/// Full history, newest first: month headers → day rows → horizontal photo
/// strips. Deliberately finite — an archive you flip through, not a feed
/// you fall into.
struct ArchiveView: View {
    @Environment(AppDependencies.self) private var deps
    let vault: Vault

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
            if viewModel == nil { viewModel = ArchiveViewModel(deps: deps, vault: vault) }
        }
    }
}

private struct ArchiveContent: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Bindable var viewModel: ArchiveViewModel

    @State private var showBackfillCompose = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26, pinnedViews: .sectionHeaders) {
                if let backfillKey = viewModel.backfillDayKey {
                    backfillBanner(backfillKey)
                }

                if viewModel.months.isEmpty {
                    EmptyVaultState(
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
                                    router.vaultsPath.append(.depositDetail(deposit))
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
        .sheet(isPresented: $showBackfillCompose) {
            ComposeView(vault: viewModel.vault, targetDayKey: viewModel.backfillDayKey) { success in
                if success {
                    Task { await viewModel.refresh() }
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
            Text(day.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(day.deposits) { deposit in
                        Button {
                            onTap(deposit)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                // 146pt tile → 450px covers @3x displays.
                                LocalDepositImage(relativePath: deposit.localImagePath, maxPixelSize: 450)
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
                                    Text(deposit.author?.displayName ?? "")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
