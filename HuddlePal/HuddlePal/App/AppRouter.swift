import Foundation
import Observation

enum AppTab: Hashable {
    case huddles
    case profile
}

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
    private(set) var selectedTab: AppTab = .huddles
    /// Single stack for the Huddles tab: list → huddle home → deeper screens.
    var huddlesPath: [Route] = []

    /// The mounted profile editor installs a synchronous guard. It returns
    /// before any router state is mutated, so a dirty editor can present its
    /// warning without the requested destination ever becoming active.
    @ObservationIgnored private var profileNavigationGuardID: UUID?
    @ObservationIgnored private var profileNavigationGuard: (() -> Bool)?
    /// The tab a blocked attempt was headed for. Saving or discarding the
    /// profile goes on there (`resumeBlockedNavigation`); Keep Editing drops
    /// it. Only the tab: a blocked deep link's route isn't replayed.
    @ObservationIgnored private(set) var blockedTab: AppTab?

    func installProfileNavigationGuard(id: UUID, handler: @escaping () -> Bool) {
        profileNavigationGuardID = id
        profileNavigationGuard = handler
    }

    /// Returns false without changing selection or path when the mounted
    /// profile editor blocks the attempt.
    @discardableResult
    func selectTab(_ destination: AppTab) -> Bool {
        guard destination != selectedTab else { return true }
        guard canNavigateAwayFromProfile(to: destination) else { return false }
        selectedTab = destination
        return true
    }

    /// The profile was saved or its changes discarded: go where the blocked
    /// attempt was going. The guard runs again, so a still-dirty editor
    /// (a save that failed) keeps the person on Profile.
    func resumeBlockedNavigation() {
        guard let destination = blockedTab else { return }
        blockedTab = nil
        selectTab(destination)
    }

    /// Keep Editing: stay on Profile and forget the attempt.
    func cancelBlockedNavigation() {
        blockedTab = nil
    }

    /// Atomically guards both the tab change and the destination route. This
    /// prevents a deep link from mutating the navigation path before the
    /// profile editor has approved leaving.
    @discardableResult
    func navigateToHuddles(route: Route? = nil) -> Bool {
        guard canNavigateAwayFromProfile(to: .huddles) else { return false }
        selectedTab = .huddles
        if let route, huddlesPath.last != route {
            huddlesPath.append(route)
        }
        return true
    }

    /// An invite link that arrived while signed out opens Join once signed in.
    func openPendingInvite(_ session: AppSession) {
        guard session.pendingInviteCode != nil else { return }
        navigateToHuddles(route: .joinHuddle)
    }

    func openHuddle(_ huddle: Huddle) {
        guard canNavigateAwayFromProfile(to: .huddles) else { return }
        selectedTab = .huddles
        huddlesPath = [.huddleHome(huddle)]
    }

    func popToHuddleList() {
        huddlesPath.removeAll()
    }

    private func canNavigateAwayFromProfile(to destination: AppTab) -> Bool {
        guard selectedTab == .profile, destination != .profile else { return true }
        let allowed = profileNavigationGuard?() ?? true
        blockedTab = allowed ? nil : destination
        return allowed
    }

    func resetAll() {
        huddlesPath.removeAll()
        profileNavigationGuardID = nil
        profileNavigationGuard = nil
        blockedTab = nil
        selectedTab = .huddles
    }
}
