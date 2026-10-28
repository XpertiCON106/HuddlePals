import Foundation
import Observation

/// Typed navigation destinations. @Model classes are Hashable via identity,
/// so they can ride along in the path.
enum Route: Hashable {
    case huddleHome(Huddle)
    case archive(Huddle)
    case depositDetail(Deposit)
    case huddleSettings(Huddle)
    case createHuddle
    case joinHuddle
    case userProfile(User)
    /// Your own profile, from the shelf's top-right button.
    case profile
    /// Deleting your account, from Profile.
    case deleteAccount
}

/// The shareable invite link, https://huddlepals.com/join#<CODE>: a
/// universal link (Associated Domains) that opens Join in the app, or the
/// website's join page without it. The code is the fragment, which browsers
/// and link previews never send, so the invite's secret stays off every
/// server. Links from before, huddlepal://join/<CODE>, still open.
enum InviteLink {
    static let host = "huddlepals.com"

    static func url(for code: InviteCode) -> URL {
        URL(string: "https://\(host)/join#\(code.compact)")!
    }

    /// The code a link carries, uppercased, for the Join screen: a whole
    /// `InviteCode` (dashes and case don't matter), or an old 6-character
    /// code, which Join then explains is out of date. nil otherwise.
    static func code(from url: URL) -> String? {
        let text: String
        if url.scheme == "https", url.host?.lowercased() == host, ["/join", "/join/"].contains(url.path),
           let fragment = url.fragment {
            text = fragment
        } else if url.scheme == "huddlepal", url.host == "join" {
            text = url.lastPathComponent
        } else {
            return nil
        }
        if let code = InviteCode(text) { return code.compact }
        return InviteCode.isLegacy(text) ? InviteCode.normalized(text) : nil
    }
}

@MainActor
@Observable
final class AppRouter {
    /// The app's one stack: the huddle shelf, then a huddle, Profile, and
    /// deeper screens.
    var huddlesPath: [Route] = []

    /// The mounted profile editor installs a synchronous guard. While Profile
    /// is on top, every change to the stack asks it first, so a dirty editor
    /// can present its warning before anything leaves the screen. (Its own
    /// Back button stands in for the system one while there are unsaved
    /// changes, which also turns off the swipe back.)
    @ObservationIgnored private var profileNavigationGuardID: UUID?
    @ObservationIgnored private var profileNavigationGuard: (() -> Bool)?
    /// Where a blocked attempt was going. Saving or discarding the profile
    /// goes on there (`resumeBlockedNavigation`); Keep Editing drops it.
    @ObservationIgnored private(set) var blockedPath: [Route]?

    func installProfileNavigationGuard(id: UUID, handler: @escaping () -> Bool) {
        profileNavigationGuardID = id
        profileNavigationGuard = handler
    }

    var isShowingProfile: Bool { huddlesPath.last == .profile }

    func openProfile() {
        guard !isShowingProfile else { return }
        huddlesPath.append(.profile)
    }

    /// Delete account, from Profile: unsaved changes are asked about first.
    @discardableResult
    func openDeleteAccount() -> Bool {
        navigate(to: huddlesPath + [.deleteAccount])
    }

    /// Back from Profile, through the guard.
    @discardableResult
    func leaveProfile() -> Bool {
        guard isShowingProfile else { return true }
        return navigate(to: Array(huddlesPath.dropLast()))
    }

    /// The profile was saved or its changes discarded: go where the blocked
    /// attempt was going. The guard runs again, so a still-dirty editor
    /// (a save that failed) keeps the person on Profile.
    func resumeBlockedNavigation() {
        guard let path = blockedPath else { return }
        blockedPath = nil
        navigate(to: path)
    }

    /// Keep Editing: stay on Profile and forget the attempt.
    func cancelBlockedNavigation() {
        blockedPath = nil
    }

    /// Opens `route` from wherever the person is (an invite link), leaving
    /// Profile first if it's showing. False when the profile editor blocks it.
    @discardableResult
    func navigateToHuddles(route: Route? = nil) -> Bool {
        var path = huddlesPath
        if path.last == .profile { path.removeLast() }
        if let route, path.last != route {
            path.append(route)
        }
        return navigate(to: path)
    }

    /// An invite link that arrived while signed out opens Join once signed in.
    func openPendingInvite(_ session: AppSession) {
        guard session.pendingInviteCode != nil else { return }
        navigateToHuddles(route: .joinHuddle)
    }

    func openHuddle(_ huddle: Huddle) {
        navigate(to: [.huddleHome(huddle)])
    }

    func popToHuddleList() {
        navigate(to: [])
    }

    /// Every change made here goes through the profile editor's guard while
    /// Profile is on top.
    @discardableResult
    private func navigate(to path: [Route]) -> Bool {
        if isShowingProfile, path.last != .profile {
            let allowed = profileNavigationGuard?() ?? true
            blockedPath = allowed ? nil : path
            guard allowed else { return false }
        }
        huddlesPath = path
        return true
    }

    func resetAll() {
        huddlesPath.removeAll()
        profileNavigationGuardID = nil
        profileNavigationGuard = nil
        blockedPath = nil
    }
}
