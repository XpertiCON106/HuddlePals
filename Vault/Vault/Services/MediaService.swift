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

    func saveImageData(_ data: Data, preferredName: String?) async throws -> String {
        let name = preferredName ?? "\(UUID().uuidString).jpg"
        let relativePath = "\(Self.mediaDirectoryName)/\(name)"
        let fileURL = documentsURL.appendingPathComponent(relativePath)
        // preferredName may carry subfolders ("<vault_id>/<file>.jpg").
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
        try? Data(contentsOf: imageURL(for: relativePath))
    }

    func deleteImage(at relativePath: String) {
        try? fileManager.removeItem(at: imageURL(for: relativePath))
    }
}
