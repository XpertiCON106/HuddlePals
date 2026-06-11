import Foundation

protocol MediaServiceProtocol: AnyObject {
    /// Persists image data and returns a path *relative to Documents* —
    /// the sandbox container path changes between launches, so absolute
    /// paths must never be stored.
    func saveImageData(_ data: Data, preferredName: String?) throws -> String
    func imageURL(for relativePath: String) -> URL
    func loadImageData(at relativePath: String) -> Data?
    func deleteImage(at relativePath: String)
}

// MARK: - Mock

/// "Mock" here means local-only: files really are written to Documents,
/// which is exactly what the offline cache will keep doing post-backend.
final class MockMediaService: MediaServiceProtocol {
    static let mediaDirectoryName = "Media"

    private let fileManager: FileManager
    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func saveImageData(_ data: Data, preferredName: String?) throws -> String {
        // TODO: BACKEND — also enqueue an upload to Supabase Storage
        // (bucket "deposits"); the deposit row stores the remote object key
        // and this local file becomes the cache entry.
        let directory = documentsURL.appendingPathComponent(Self.mediaDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = preferredName ?? "\(UUID().uuidString).jpg"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return "\(Self.mediaDirectoryName)/\(name)"
    }

    func imageURL(for relativePath: String) -> URL {
        documentsURL.appendingPathComponent(relativePath)
    }

    func loadImageData(at relativePath: String) -> Data? {
        // TODO: BACKEND — fall back to a signed-URL download when the local
        // cache misses.
        try? Data(contentsOf: imageURL(for: relativePath))
    }

    func deleteImage(at relativePath: String) {
        try? fileManager.removeItem(at: imageURL(for: relativePath))
    }
}
