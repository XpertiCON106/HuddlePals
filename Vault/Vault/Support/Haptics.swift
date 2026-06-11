import UIKit

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// The signature lock-opening thump: heavy impact then success chime.
    static func unlock() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
