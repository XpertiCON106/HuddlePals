import Foundation

protocol MediaServiceProtocol: AnyObject {
    /// Persists image data and returns a path *relative to Documents* —
    /// the sandbox container path changes between launches, so absolute
    /// paths must never be stored. Async because the live implementation
    /// also uploads to Supabase Storage.
    func saveImageData(_ data: Data, preferredName: String?) async throws -> String
    func imageURL(for relativePath: String) -> URL
    /// Async because the live implementation falls back to a Storage
    /// download when the local cache misses.
    func loadImageData(at relativePath: String) async -> Data?
    func deleteImage(at relativePath: String)

    /// Stores a huddle photo. Live: end-to-end encrypted with a fresh photo
    /// key before upload (`PhotoCrypto`); the returned wrapped key goes on
    /// the deposit row. Mock: stored as-is (nothing leaves the device).
    func saveDepositPhoto(_ data: Data, preferredName: String, huddleID: UUID) async throws -> StoredDepositPhoto
    /// Stores a video drop: its poster at "<baseName>.jpg" and its clip at
    /// "<baseName>.mp4" (baseName is "<huddle_id>/<uuid>"). Live: both sealed
    /// with one fresh photo key, the poster uploaded first; a clip Storage
    /// refuses because Plus has ended throws `DepositError.videoNeedsPlus`.
    func saveDepositVideo(poster: Data, clip: Data, baseName: String, huddleID: UUID) async throws -> StoredDepositVideo
    /// A huddle photo's bytes, or a video's poster or clip, decrypted when
    /// stored encrypted (in memory: never written back to disk). nil when
    /// this device can't open it (yet): no huddle key, or unreadable data.
    func loadDepositPhoto(at relativePath: String, huddleID: UUID, wrappedPhotoKey: String?) async -> Data?
}

/// A saved huddle photo: its Documents-relative path and, when it was
/// encrypted, the photo key sealed with the huddle key.
struct StoredDepositPhoto {
    let path: String
    let wrappedPhotoKey: String?
}

/// A saved video drop: its poster's and clip's Documents-relative paths and,
/// when encrypted, the one photo key for both, sealed with the huddle key.
struct StoredDepositVideo {
    let posterPath: String
    let videoPath: String
    let wrappedPhotoKey: String?
}

// MARK: - Mock

/// "Mock" here means local-only: files really are written to Documents.
/// The live service composes this exact class as its offline cache.
final class MockMediaService: MediaServiceProtocol {
    static let mediaDirectoryName = "Media"

    private let fileManager: FileManager
    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Paths arrive in rows other people wrote (deposit storage paths,
    /// profile photo paths), so only a plain relative path stays inside the
    /// cache: no absolute paths, no "..".
    static func isSafe(_ relativePath: String) -> Bool {
        !relativePath.isEmpty
            && !relativePath.hasPrefix("/")
            && !relativePath.split(separator: "/").contains("..")
    }

    func saveImageData(_ data: Data, preferredName: String?) async throws -> String {
        let name = preferredName ?? "\(UUID().uuidString).jpg"
        guard Self.isSafe(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let relativePath = "\(Self.mediaDirectoryName)/\(name)"
        let fileURL = documentsURL.appendingPathComponent(relativePath)
        // preferredName may carry subfolders ("<huddle_id>/<file>.jpg").
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        return relativePath
    }

    func imageURL(for relativePath: String) -> URL {
        documentsURL.appendingPathComponent(relativePath)
    }

    func loadImageData(at relativePath: String) async -> Data? {
        guard Self.isSafe(relativePath) else { return nil }
        return try? Data(contentsOf: imageURL(for: relativePath))
    }

    func deleteImage(at relativePath: String) {
        guard Self.isSafe(relativePath) else { return }
        try? fileManager.removeItem(at: imageURL(for: relativePath))
    }

    /// Deletes everything under Documents/Media.
    func removeAll() {
        try? fileManager.removeItem(at: documentsURL.appendingPathComponent(Self.mediaDirectoryName))
    }

    /// A huddle that's gone from this device: its deposits' files (each
    /// photo or video poster, and a video's clip).
    func deleteFiles(of huddle: Huddle) {
        for deposit in huddle.deposits {
            deleteImage(at: deposit.localImagePath)
            if let clip = deposit.localVideoPath { deleteImage(at: clip) }
        }
    }

    // Offline, there is no server to hide photos from and every member is
    // on this device, so there are no keys to make or share.
    func saveDepositPhoto(_ data: Data, preferredName: String, huddleID: UUID) async throws -> StoredDepositPhoto {
        StoredDepositPhoto(path: try await saveImageData(data, preferredName: preferredName), wrappedPhotoKey: nil)
    }

    func saveDepositVideo(poster: Data, clip: Data, baseName: String, huddleID: UUID) async throws -> StoredDepositVideo {
        guard clip.count <= HuddleLimits.maxVideoBytes else { throw DepositError.videoTooLarge }
        return StoredDepositVideo(
            posterPath: try await saveImageData(poster, preferredName: "\(baseName).jpg"),
            videoPath: try await saveImageData(clip, preferredName: "\(baseName).mp4"),
            wrappedPhotoKey: nil
        )
    }

    func loadDepositPhoto(at relativePath: String, huddleID: UUID, wrappedPhotoKey: String?) async -> Data? {
        await loadImageData(at: relativePath)
    }
}
