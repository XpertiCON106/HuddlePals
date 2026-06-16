import Foundation
import Observation

@MainActor
@Observable
final class DepositDetailViewModel {
    static let reactionEmojis = ["❤️", "🔥", "😂", "🥹", "👏"]

    private let deps: AppDependencies
    let deposit: Deposit

    var commentDraft = ""
    private(set) var isPosting = false
    private(set) var errorMessage: String?

    init(deps: AppDependencies, deposit: Deposit) {
        self.deps = deps
        self.deposit = deposit
    }

    var sortedComments: [Comment] {
        deposit.comments.sorted { $0.createdAt < $1.createdAt }
    }

    func reactionCount(for emoji: String) -> Int {
        deposit.reactions.filter { $0.emoji == emoji }.count
    }

    func currentUserReacted(with emoji: String) -> Bool {
        guard let userID = deps.session.currentUser?.id else { return false }
        return deposit.reactions.contains { $0.emoji == emoji && $0.user?.id == userID }
    }

    func toggleReaction(_ emoji: String) async {
        guard let user = deps.session.currentUser else { return }
        Haptics.light()
        try? await deps.depositService.toggleReaction(emoji, on: deposit, by: user)
    }

    func postComment() async {
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let user = deps.session.currentUser else { return }
        isPosting = true
        errorMessage = nil
        defer { isPosting = false }
        do {
            try await deps.depositService.addComment(text, to: deposit, by: user)
            commentDraft = ""
        } catch {
            // The live path can fail (network); keep the draft so the user
            // can retry, and surface why it didn't post.
            errorMessage = error.localizedDescription
        }
    }
}
