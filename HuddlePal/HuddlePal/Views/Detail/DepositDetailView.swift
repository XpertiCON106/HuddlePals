import SwiftUI

/// Full-bleed photo, caption, author, date, reaction row, comments.
struct DepositDetailView: View {
    @Environment(AppDependencies.self) private var deps
    let deposit: Deposit

    @State private var viewModel: DepositDetailViewModel?

    var body: some View {
        Group {
            if let viewModel {
                if viewModel.isLocked {
                    LockedDetail(deposit: deposit)
                } else {
                    DetailContent(viewModel: viewModel)
                }
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

/// A deposit from a day past the free plan's 30 days: who posted it and
/// when, under a lock, and the way to Plus. Nothing of it is loaded.
private struct LockedDetail: View {
    let deposit: Deposit
    @State private var showPaywall = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                LockedArchiveTile(author: deposit.author)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
                Text("\(deposit.author?.displayName ?? "Former member") · \(deposit.createdAt.formatted(.dateTime.month().day().year()))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("This day is past the free plan's 30 days. It's still here, kept safe for good.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                PrimaryButton(title: "Unlock your full archive", systemImage: "lock.open.fill") {
                    showPaywall = true
                }
            }
            .padding(Theme.screenPadding)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(context: .archive)
        }
    }
}

private struct DetailContent: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: DepositDetailViewModel
    @FocusState private var commentFocused: Bool

    @State private var showBlockConfirmation = false
    @State private var showOptions = false
    @State private var reportingComment: Comment?

    private var deposit: Deposit { viewModel.deposit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    if deposit.isVideo {
                        DepositVideoPlayer(deposit: deposit, startsMuted: false)
                    } else {
                        LocalDepositImage(deposit: deposit)
                    }
                }
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
                    UserLink(user: deposit.author) {
                        HStack(spacing: 10) {
                            AvatarView(
                                name: deposit.author?.displayName ?? "?",
                                colorHex: deposit.author?.avatarColorHex ?? "888888",
                                imagePath: deposit.author?.profilePhotoPaths.first,
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
                        }
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
        .toolbar {
            if viewModel.canReport {
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
        .appDialog(
            viewModel.blockableAuthor.map { "\($0.displayName)'s post" } ?? "This post",
            isPresented: $showOptions,
            actions: optionActions
        )
        .appDialog(
            viewModel.blockableAuthor.map { "Block \($0.displayName)?" } ?? "Block?",
            isPresented: $showBlockConfirmation,
            message: "You won't see their photos, videos or comments anymore. They won't be told.",
            actions: [
                DialogAction("Block", role: .destructive) {
                    guard let author = viewModel.blockableAuthor else { return }
                    Task {
                        await viewModel.block(author)
                        dismiss() // their content is now hidden from you
                    }
                },
                .cancel(),
            ]
        )
        .appDialog(
            "Report this comment?",
            isPresented: Binding(get: { reportingComment != nil }, set: { if !$0 { reportingComment = nil } }),
            message: reportingComment.map { "\u{201C}\($0.text)\u{201D}" },
            actions: [
                DialogAction("Report comment", role: .destructive) {
                    guard let comment = reportingComment else { return }
                    Task { await viewModel.report(comment) }
                },
                .cancel(),
            ]
        )
        .appDialog(
            ReportFeedback.title,
            isPresented: $viewModel.isReportConfirmationPresented,
            message: ReportFeedback.message,
            actions: [DialogAction("Done", role: .cancel)]
        )
    }

    /// Report the post, and block its author while they still have an account.
    private var optionActions: [DialogAction] {
        var actions = [
            DialogAction(
                viewModel.didReport ? "Reported" : "Report photo",
                role: .secondary,
                systemImage: "flag",
                isEnabled: !viewModel.didReport
            ) {
                Task { await viewModel.report() }
            },
        ]
        if let author = viewModel.blockableAuthor {
            actions.append(DialogAction("Block \(author.displayName)", role: .destructive, systemImage: "hand.raised") {
                showBlockConfirmation = true
            })
        }
        actions.append(.cancel())
        return actions
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
                .accessibilityLabel(mine ? "Remove your \(emoji) reaction" : "React with \(emoji)")
                .accessibilityValue(count > 0 ? "\(count)" : "")
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
                        UserLink(user: comment.user) {
                            AvatarView(
                                name: comment.user?.displayName ?? "?",
                                colorHex: comment.user?.avatarColorHex ?? "888888",
                                imagePath: comment.user?.profilePhotoPaths.first,
                                size: 26
                            )
                        }
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
                    .contentShape(Rectangle())
                    .onLongPressGesture {
                        guard viewModel.canReport(comment),
                              !viewModel.reportedCommentIDs.contains(comment.id) else { return }
                        Haptics.light()
                        reportingComment = comment
                    }
                    .accessibilityActions {
                        if viewModel.canReport(comment), !viewModel.reportedCommentIDs.contains(comment.id) {
                            Button("Report comment") { reportingComment = comment }
                        }
                    }
                }
                if viewModel.sortedComments.contains(where: viewModel.canReport) {
                    Text("Touch and hold a comment to report it.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var commentBar: some View {
        VStack(spacing: 6) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                TextField("Add a comment…", text: $viewModel.commentDraft)
                    .font(.system(size: 15))
                    .focused($commentFocused)
                    .onChange(of: viewModel.commentDraft) { _, newValue in
                        if newValue.serverLength > TextLimit.comment {
                            viewModel.commentDraft = newValue.prefix(serverLength: TextLimit.comment)
                        }
                    }
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
                .accessibilityLabel("Send comment")
            }
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func post() {
        Task { await viewModel.postComment() }
    }
}
