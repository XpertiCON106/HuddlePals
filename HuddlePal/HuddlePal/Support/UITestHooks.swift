import SwiftUI
import UIKit

/// Launch switches for the UI tests (HuddlePalUITests). Debug builds only:
/// in Release every switch reads false and the reset can't run.
///   -ui-testing                 mock backend only, whatever config is bundled
///   -ui-testing-reset           also start from a first launch (wipe storage)
///   -ui-testing-fake-camera     the Simulator has no camera: a stand-in
///                               capture screen hands Compose a test photo
///   -ui-testing-camera-denied   camera permission refused
///   -ui-testing-notifications-denied   notification permission refused
///                               (the Simulator can't reset a decided one)
///   -ui-testing-apple-unavailable   Apple can't confirm the account at
///                               deletion (no Apple Account, no network)
///   -ui-testing-plus            the seeded "You" has HuddlePals+
///   -ui-testing-plus-intro      a first post introduces HuddlePals+ (other
///                               runs skip it, so it never covers a tap)
///   -ui-testing-motion          the welcome cards and spinners move, as outside tests (for
///                               recording them; tests otherwise hold a frame)
///   -ui-testing-no-birthday     the seeded "You" has no birthday yet, as an
///                               account from before birthdays were asked for
///   -ui-testing-ineligible-birthday   a stored birthday accepted by the old
///                               one-day allowance, before strict UTC eligibility
enum UITestHooks {
    #if DEBUG
    private static let arguments = ProcessInfo.processInfo.arguments
    static let isUITesting = arguments.contains("-ui-testing")
    static let resetsState = arguments.contains("-ui-testing-reset")
    static let fakeCamera = arguments.contains("-ui-testing-fake-camera")
    static let cameraDenied = arguments.contains("-ui-testing-camera-denied")
    static let notificationsDenied = arguments.contains("-ui-testing-notifications-denied")
    static let appleUnavailable = arguments.contains("-ui-testing-apple-unavailable")
    static let plus = arguments.contains("-ui-testing-plus")
    static let plusIntro = arguments.contains("-ui-testing-plus-intro")
    static let motion = arguments.contains("-ui-testing-motion")
    static let noBirthday = arguments.contains("-ui-testing-no-birthday")
    static let ineligibleBirthday = arguments.contains("-ui-testing-ineligible-birthday")
    #else
    static let isUITesting = false
    static let resetsState = false
    static let fakeCamera = false
    static let cameraDenied = false
    static let notificationsDenied = false
    static let appleUnavailable = false
    static let plus = false
    static let plusIntro = false
    static let motion = false
    static let noBirthday = false
    static let ineligibleBirthday = false
    #endif

    /// Wipes what the app persists (settings, the local store, cached
    /// photos) so every UI test starts from a first launch.
    static func resetPersistentStateIfTesting() {
        #if DEBUG
        guard resetsState else { return }
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in (try? files.contentsOfDirectory(atPath: support.path)) ?? [] where name.hasPrefix("default.store") {
            try? files.removeItem(at: support.appendingPathComponent(name))
        }
        let documents = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? files.removeItem(at: documents.appendingPathComponent(MockMediaService.mediaDirectoryName))
        #endif
    }
}

#if DEBUG
/// Stands in for the camera in UI tests: one button that "takes" a photo.
struct FakeCameraView: View {
    var onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Test camera")
                .font(.headline)
            Button("Take test photo") {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200)).image { context in
                    UIColor.systemTeal.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
                }
                onCapture(image)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            Button("Cancel") { dismiss() }
        }
    }
}
#endif
