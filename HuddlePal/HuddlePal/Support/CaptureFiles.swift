import Foundation

/// The one place a plaintext video is ever on disk: `tmp/Capture`, while the
/// camera records into it and until the clip is read into memory a moment
/// later (`ClipPreparer` deletes it). Complete file protection, so it can't
/// be read while the phone is locked, and swept at launch in case the app
/// was killed mid-recording. Everything after that — sealing, uploading,
/// the cache, playback — handles the clip in memory or as ciphertext.
enum CaptureFiles {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Capture", isDirectory: true)
    }

    /// A fresh, empty file name to record into.
    static func newClipURL() throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        return directory.appendingPathComponent("\(UUID().uuidString).mp4")
    }

    /// Deletes every recording left behind.
    static func sweep() {
        try? FileManager.default.removeItem(at: directory)
    }
}
