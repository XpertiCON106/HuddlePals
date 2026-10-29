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
    /// Just sent one: the next comment to arrive is yours, to bring into view.
    @State private var scrollToNewest = false

    private var deposit: Deposit { viewModel.deposit }

    var body: some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: viewModel.sortedComments.last?.id) {
                    guard scrollToNewest, let last = viewModel.sortedComments.last else { return }
                    scrollToNewest = false
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
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

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    if deposit.isVideo {
                        DepositVideoPlayer(deposit: deposit, startsMuted: false, tapPlaysAndPauses: true)
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
        .scrollDismissesKeyboard(.interactively)
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
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Comments")
                    .font(Theme.displayFont(19))
                    .foregroundStyle(Theme.textPrimary)
                if !viewModel.sortedComments.isEmpty {
                    Text("\(viewModel.sortedComments.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .contentTransition(.numericText())
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if viewModel.sortedComments.isEmpty {
                Text("No comments yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(viewModel.sortedComments) { comment in
                    commentRow(comment)
                        .id(comment.id)
                }
                if viewModel.sortedComments.contains(where: viewModel.canReport) {
                    Text("Touch and hold a comment to report it.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    /// The avatar; beside it the name and time, and under them only the
    /// words, in a soft bubble whose top corner points up at the name.
    private func commentRow(_ comment: Comment) -> some View {
        let reportable = viewModel.canReport(comment) && !viewModel.reportedCommentIDs.contains(comment.id)
        let bubble = UnevenRoundedRectangle(
            topLeadingRadius: 5, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: 18,
            style: .continuous
        )
        return HStack(alignment: .top, spacing: 10) {
            UserLink(user: comment.user) {
                AvatarView(
                    name: comment.user?.displayName ?? "?",
                    colorHex: comment.user?.avatarColorHex ?? "888888",
                    imagePath: comment.user?.profilePhotoPaths.first,
                    size: 32
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(comment.user?.displayName ?? "Former member")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(comment.createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.leading, 2)
                Text(comment.text)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.surface, in: bubble)
                    .overlay(bubble.strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .contentShape(Rectangle())
            .onLongPressGesture {
                guard reportable else { return }
                Haptics.light()
                reportingComment = comment
            }
            .accessibilityElement(children: .combine)
            .accessibilityActions {
                if reportable {
                    Button("Report comment") { reportingComment = comment }
                }
            }
            Spacer(minLength: 32)
        }
    }

    private var canSend: Bool {
        !viewModel.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Your avatar beside a rounded field that grows with the comment (up to
    /// five lines), with the send button inside it.
    private var commentBar: some View {
        let me = viewModel.currentUser
        let remaining = TextLimit.comment - viewModel.commentDraft.serverLength
        return VStack(spacing: 6) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 10) {
                AvatarView(
                    name: me?.displayName ?? "?",
                    colorHex: me?.avatarColorHex ?? "888888",
                    imagePath: me?.profilePhotoPaths.first,
                    size: 32
                )
                .padding(.bottom, 6)
                .accessibilityHidden(true)

                HStack(alignment: .bottom, spacing: 0) {
                    // 16pt, as the caption field: a 15pt line is too short a
                    // touch target for the accessibility audit.
                    TextField("Add a comment…", text: $viewModel.commentDraft, axis: .vertical)
                        .font(.system(size: 16))
                        .lineLimit(1...5)
                        .accessibilityIdentifier("commentField")
                        .focused($commentFocused)
                        .submitLabel(.send)
                        .onChange(of: viewModel.commentDraft) { old, new in
                            draftChanged(from: old, to: new)
                        }
                        .padding(.leading, 16)
                        .padding(.vertical, 12)
                    sendButton
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(commentFocused ? Theme.textSecondary.opacity(0.45) : Theme.hairline, lineWidth: 1)
                        // Only the outline: the bar itself rises with the
                        // keyboard, at the keyboard's own pace.
                        .animation(.easeOut(duration: 0.15), value: commentFocused)
                )
            }

            if remaining <= 50 {
                Text("\(remaining)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("\(remaining) characters left")
            }
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.background)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private var sendButton: some View {
        Button(action: post) {
            ZStack {
                Circle()
                    .fill(canSend ? Theme.accent : Theme.surfaceElevated)
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(canSend ? Theme.onAccent : Theme.textSecondary)
            }
            .frame(width: 34, height: 34)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("Send comment")
    }

    /// The field is multi-line, so Return arrives as a newline: one typed
    /// newline is taken back out and sends. Newlines pasted in stay.
    private func draftChanged(from old: String, to new: String) {
        func newlines(_ text: String) -> Int { text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } }
        if new.count == old.count + 1, newlines(new) == newlines(old) + 1 {
            viewModel.commentDraft = old
            post()
            return
        }
        if new.serverLength > TextLimit.comment {
            viewModel.commentDraft = new.prefix(serverLength: TextLimit.comment)
        }
    }

    /// Sends: the comment shows at once, the keyboard goes, and the list
    /// scrolls to it while it uploads.
    private func post() {
        guard canSend else { return }
        Haptics.light()
        commentFocused = false
        scrollToNewest = true
        Task { await viewModel.postComment() }
    }
}
