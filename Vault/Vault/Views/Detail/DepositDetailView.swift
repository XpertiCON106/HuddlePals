import SwiftUI

/// Full-bleed photo, caption, author, date, reaction row, comments.
struct DepositDetailView: View {
    @Environment(AppDependencies.self) private var deps
    let deposit: Deposit

    @State private var viewModel: DepositDetailViewModel?

    var body: some View {
        Group {
            if let viewModel {
                DetailContent(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .onAppear {
            if viewModel == nil {
                viewModel = DepositDetailViewModel(deps: deps, deposit: deposit)
            }
        }
    }
}

private struct DetailContent: View {
    @Bindable var viewModel: DepositDetailViewModel
    @FocusState private var commentFocused: Bool

    private var deposit: Deposit { viewModel.deposit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LocalDepositImage(relativePath: deposit.localImagePath)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
                    .shadow(color: Theme.shadow, radius: 14, x: 0, y: 5)

                if let caption = deposit.caption {
                    Text(caption)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(3)
                }

                HStack(spacing: 10) {
                    AvatarView(
                        name: deposit.author?.displayName ?? "?",
                        colorHex: deposit.author?.avatarColorHex ?? "888888",
                        size: 34
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(deposit.author?.displayName ?? "Former member")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(deposit.createdAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }

                reactionRow

                Divider()
                    .overlay(Theme.surfaceElevated)

                commentSection
            }
            .padding(Theme.screenPadding)
        }
        .background(Theme.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { commentBar }
    }

    private var reactionRow: some View {
        HStack(spacing: 10) {
            ForEach(DepositDetailViewModel.reactionEmojis, id: \.self) { emoji in
                let count = viewModel.reactionCount(for: emoji)
                let mine = viewModel.currentUserReacted(with: emoji)
                Button {
                    Task { await viewModel.toggleReaction(emoji) }
                } label: {
                    HStack(spacing: 4) {
                        Text(emoji).font(.system(size: 17))
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(mine ? Theme.accent : Theme.textSecondary)
                                .contentTransition(.numericText())
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        mine ? Theme.accent.opacity(0.18) : Theme.surface,
                        in: Capsule()
                    )
                    .overlay {
                        if mine {
                            Capsule().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var commentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.sortedComments.isEmpty {
                Text("No comments yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(viewModel.sortedComments) { comment in
                    HStack(alignment: .top, spacing: 10) {
                        AvatarView(
                            name: comment.user?.displayName ?? "?",
                            colorHex: comment.user?.avatarColorHex ?? "888888",
                            size: 26
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(comment.user?.displayName ?? "Former member")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(comment.createdAt, format: .dateTime.hour().minute())
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Text(comment.text)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                        }
                    }
                }
            }
        }
    }

    private var commentBar: some View {
        HStack(spacing: 10) {
            TextField("Add a comment…", text: $viewModel.commentDraft)
                .font(.system(size: 15))
                .focused($commentFocused)
                .submitLabel(.send)
                .onSubmit { post() }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface, in: Capsule())

            Button {
                post()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(
                        viewModel.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Theme.textSecondary.opacity(0.5)
                            : Theme.accent
                    )
            }
            .disabled(viewModel.isPosting)
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func post() {
        Task { await viewModel.postComment() }
    }
}
