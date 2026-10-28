import Foundation
import Observation

@MainActor
@Observable
final class DepositDetailViewModel {
    static let reactionEmojis = ["❤️", "🔥", "😂", "🥹", "👏"]

    private let deps: AppDependencies
    let deposit: Deposit

    var commentDraft = ""
    private(set) var errorMessage: String?
    private(set) var didReport = false
    private(set) var reportedCommentIDs: Set<UUID> = []
    /// Thanks the reporter once a report has gone through.
    var isReportConfirmationPresented = false

    init(deps: AppDependencies, deposit: Deposit) {
        self.deps = deps
        self.deposit = deposit
    }

    /// Past the free plan's 30 days: the screen shows the lock and the way
    /// to Plus, and loads nothing of the deposit (`ArchiveGate`).
    var isLocked: Bool {
        ArchiveGate.isLocked(deposit.dayKey, newestDayKey: deposit.huddle?.deposits.map(\.dayKey).max(), deps: deps)
    }

    var sortedComments: [Comment] {
        let blocked = deps.session.blockedUserIDs
        return deposit.comments
            .filter { !blocked.contains($0.user?.id ?? UUID()) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Anyone else's photo can be reported — including a "Former member"'s,
    /// whose account is gone but whose photo stays in the huddle.
    var canReport: Bool {
        guard let me = deps.session.currentUser?.id else { return false }
        return deposit.author?.id != me
    }

    /// The photo's author, when it's someone else who can still be blocked
    /// (a "Former member" has no account left to block).
    var blockableAuthor: User? {
        guard let author = deposit.author, author.id != deps.session.currentUser?.id else { return nil }
        return author
    }

    func report() async {
        do {
            try await deps.moderationService.report(deposit: deposit, reason: nil)
            didReport = true
            isReportConfirmationPresented = true
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Anyone else's comment can be reported, a Former member's included.
    func canReport(_ comment: Comment) -> Bool {
        guard let me = deps.session.currentUser?.id else { return false }
        return comment.user?.id != me
    }

    func report(_ comment: Comment) async {
        do {
            try await deps.moderationService.report(comment: comment)
            reportedCommentIDs.insert(comment.id)
            isReportConfirmationPresented = true
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func block(_ user: User) async {
        do {
            try await deps.moderationService.block(user)
            deps.session.blockedUserIDs.insert(user.id)
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Your reactions as of your last tap, per emoji, ahead of the stored
    /// ones. The bar changes the moment you tap instead of after the round
    /// trip, and doesn't rely on SwiftData reporting the new row to this
    /// screen (it didn't until the screen was opened again).
    private var tappedReactions: [String: Bool] = [:]
    /// Emojis whose toggle is still on its way to the server. A second tap
    /// waits: the service decides add or remove from what's stored.
    private var reactionsInFlight: Set<String> = []

    func reactionCount(for emoji: String) -> Int {
        let stored = deposit.reactions.filter { $0.emoji == emoji }.count
        guard let mine = tappedReactions[emoji], mine != storedReaction(emoji) else { return stored }
        return max(0, stored + (mine ? 1 : -1))
    }

    func currentUserReacted(with emoji: String) -> Bool {
        tappedReactions[emoji] ?? storedReaction(emoji)
    }

    private func storedReaction(_ emoji: String) -> Bool {
        guard let userID = deps.session.currentUser?.id else { return false }
        return deposit.reactions.contains { $0.emoji == emoji && $0.user?.id == userID }
    }

    func toggleReaction(_ emoji: String) async {
        guard let user = deps.session.currentUser, !reactionsInFlight.contains(emoji) else { return }
        Haptics.light()
        let before = tappedReactions[emoji]
        tappedReactions[emoji] = !currentUserReacted(with: emoji)
        reactionsInFlight.insert(emoji)
        defer { reactionsInFlight.remove(emoji) }
        do {
            try await deps.depositService.toggleReaction(emoji, on: deposit, by: user)
        } catch {
            // Didn't reach the server: show what's really there.
            tappedReactions[emoji] = before
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// Whoever is writing: their avatar sits beside the comment field.
    var currentUser: User? { deps.session.currentUser }

    /// Posts the draft. The field empties at once and the comment shows
    /// straight away (the services save it here first); true once the
    /// server has it.
    @discardableResult
    func postComment() async -> Bool {
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...TextLimit.comment).contains(text.serverLength),
              let user = deps.session.currentUser else { return false }
        let draft = commentDraft
        commentDraft = ""
        errorMessage = nil
        do {
            try await deps.depositService.addComment(text, to: deposit, by: user)
            return true
        } catch {
            // The live path can fail (network): the comment comes off again,
            // and the words come back to retry, with why.
            if commentDraft.isEmpty { commentDraft = draft }
            errorMessage = error.localizedDescription
            return false
        }
    }
}
