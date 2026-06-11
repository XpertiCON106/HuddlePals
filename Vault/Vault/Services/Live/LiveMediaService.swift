import Foundation

/// Supabase Storage on top of the same local Documents cache the mock uses.
/// Cache paths are "Media/<vault_id>/<file>.jpg"; the storage object path is
/// the same string without the "Media/" prefix, so the two stay 1:1.
final class LiveMediaService: MediaServiceProtocol {
    static let bucket = "deposits"
    private static let cachePrefix = "Media/"

    private let client: SupabaseClient
    /// The mock *is* the local cache implementation — reused on purpose.
    private let localCache = MockMediaService()

    init(client: SupabaseClient) {
        self.client = client
    }

    static func cachePath(forStoragePath path: String) -> String {
        cachePrefix + path
    }

    static func storagePath(forCachePath path: String) -> String {
        path.hasPrefix(cachePrefix) ? String(path.dropFirst(cachePrefix.count)) : path
    }

    func saveImageData(_ data: Data, preferredName: String?) async throws -> String {
        let storagePath = preferredName ?? "misc/\(UUID().uuidString).jpg"
        try await client.uploadObject(
            bucket: Self.bucket,
            path: storagePath,
            data: data,
            contentType: "image/jpeg"
        )
        // Mirror into the local cache so our own photo renders instantly.
        return try await localCache.saveImageData(data, preferredName: storagePath)
    }

    func imageURL(for relativePath: String) -> URL {
        localCache.imageURL(for: relativePath)
    }

    func loadImageData(at relativePath: String) async -> Data? {
        if let cached = await localCache.loadImageData(at: relativePath) {
            return cached
        }
        let storagePath = Self.storagePath(forCachePath: relativePath)
        guard let data = try? await client.downloadObject(bucket: Self.bucket, path: storagePath) else {
            return nil
        }
        _ = try? await localCache.saveImageData(data, preferredName: storagePath)
        return data
    }

    func deleteImage(at relativePath: String) {
        // Local cache only. Replaced deposits leave an orphaned object in
        // Storage — harmless at this scale.
        // TODO: BACKEND — clean up orphans with a scheduled edge function.
        localCache.deleteImage(at: relativePath)
    }
}
