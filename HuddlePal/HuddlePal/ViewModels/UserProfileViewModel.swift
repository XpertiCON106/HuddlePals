import Foundation
import Observation

@MainActor
@Observable
final class UserProfileViewModel {
    private let deps: AppDependencies
    let user: User

    init(deps: AppDependencies, user: User) {
        self.deps = deps
        self.user = user
    }

    var isSelf: Bool { user.id == deps.session.currentUser?.id }
    var isBlocked: Bool { deps.session.blockedUserIDs.contains(user.id) }
    private(set) var didReport = false
    /// After Report: thanks, or (if it didn't go through) a retry message.
    var isReportAlertPresented = false

    func report() async {
        do {
            try await deps.moderationService.report(user: user)
            didReport = true
            Haptics.success()
        } catch {
            didReport = false
        }
        isReportAlertPresented = true
    }

    func toggleBlock() async {
        do {
            if isBlocked {
                try await deps.moderationService.unblock(user)
                deps.session.blockedUserIDs.remove(user.id)
            } else {
                try await deps.moderationService.block(user)
                deps.session.blockedUserIDs.insert(user.id)
            }
            Haptics.light()
        } catch {
            // Best-effort; the block set re-syncs on next launch.
        }
    }
}
