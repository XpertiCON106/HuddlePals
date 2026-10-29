import UIKit

/// Crossfades the whole screen into whatever comes next: a still of the
/// window as it is goes on top, the change happens underneath, and the
/// still fades away. For a change that has to happen in one render (ending
/// a session swaps the whole UI at once, so no screen reads a deleted
/// model) but shouldn't look like a cut.
@MainActor
enum ScreenCrossfade {
    /// Call just before the change, in the same main-actor turn.
    static func begin(duration: TimeInterval = 0.45) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow),
              let still = window.snapshotView(afterScreenUpdates: false)
        else { return }
        still.frame = window.bounds
        // Touches go to the new screen beneath.
        still.isUserInteractionEnabled = false
        window.addSubview(still)
        // A beat first, so the new screen has drawn underneath.
        UIView.animate(withDuration: duration, delay: 0.06, options: [.curveEaseInOut]) {
            still.alpha = 0
        } completion: { _ in
            still.removeFromSuperview()
        }
    }
}
