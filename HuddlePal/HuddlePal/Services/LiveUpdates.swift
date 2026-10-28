import SwiftUI
import UIKit

/// What other people do, as it happens: a photo or video posted, a comment,
/// a reaction. Each change arrives as the id of the huddle it's in (nil when
/// that isn't known, say a reaction taken back), and open screens refresh.
@MainActor
protocol LiveUpdatesProtocol: AnyObject {
    /// The changes from now on, for one listener, until its task ends.
    /// Only the newest is kept while the listener is busy: one refresh
    /// covers any number of changes.
    func changes() -> AsyncStream<UUID?>
    /// Listen while signed in and in the foreground; stop otherwise.
    func setActive(_ active: Bool)
}

/// The offline world: nobody else is there to change anything.
final class NoLiveUpdates: LiveUpdatesProtocol {
    nonisolated init() {}

    func changes() -> AsyncStream<UUID?> {
        AsyncStream { _ in }
    }

    func setActive(_ active: Bool) {}
}

extension View {
    /// Keeps a screen current while it's open: `refresh` runs as soon as a
    /// change to `huddleID` arrives (any huddle's, when nil), and every half
    /// minute in the foreground, in case live updates can't connect. Live
    /// backend only: offline, nothing changes behind the screen.
    func refreshesLive(huddleID: UUID?, _ refresh: @escaping () async -> Void) -> some View {
        modifier(LiveRefresh(huddleID: huddleID, refresh: refresh))
    }
}

private struct LiveRefresh: ViewModifier {
    @Environment(AppDependencies.self) private var deps
    let huddleID: UUID?
    let refresh: () async -> Void

    /// The backstop's pace, in seconds.
    static let backstop = 30.0

    func body(content: Content) -> some View {
        content
            .task(id: huddleID) {
                guard deps.isLive else { return }
                for await changed in deps.liveUpdates.changes()
                where huddleID == nil || changed == nil || changed == huddleID {
                    await refresh()
                }
            }
            .task(id: huddleID) {
                guard deps.isLive else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.backstop))
                    guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { continue }
                    await refresh()
                }
            }
    }
}
