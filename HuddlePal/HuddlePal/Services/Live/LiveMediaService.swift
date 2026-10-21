import Foundation

/// Supabase Storage on top of the same local Documents cache the mock uses.
/// Cache paths are "Media/<huddle_id>/<file>.jpg"; the storage object path is
/// the same string without the "Media/" prefix, so the two stay 1:1. Huddle
/// photos are end-to-end encrypted: Storage and the cache both hold the
/// ciphertext, decrypted in memory only for display. Profile photos are not.
final class LiveMediaService: MediaServiceProtocol {
    static let bucket = "deposits"
    private static let cachePrefix = "Media/"
    /// The bucket's 5 MB file size limit, read as decimal megabytes to be
    /// safe. Checked on the ciphertext, so AES-GCM's 28 bytes are included.
    static let maxUploadBytes = 5_000_000

    private let client: SupabaseClient
    private let keyring: LivePhotoKeyring
    /// The mock *is* the local cache implementation — reused on purpose.
    private let localCache = MockMediaService()

    init(client: SupabaseClient, keyring: LivePhotoKeyring) {
        self.client = client
        self.keyring = keyring
    }

    static func cachePath(forStoragePath path: String) -> String {
        cachePrefix + path
    }

    static func storagePath(forCachePath path: String) -> String {
        path.hasPrefix(cachePrefix) ? String(path.dropFirst(cachePrefix.count)) : path
    }

    /// Plaintext upload — profile photos only. Huddle photos must go through
    /// `saveDepositPhoto`, which encrypts them.
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

    func saveDepositPhoto(_ data: Data, preferredName: String, huddleID: UUID) async throws -> StoredDepositPhoto {
        guard let huddleKey = await keyring.huddleKeyForUpload(huddleID) else {
            throw PhotoKeyError.huddleKeyUnavailable
        }
        let sealed = try PhotoCrypto.sealPhoto(data, huddleKey: huddleKey)
        guard sealed.ciphertext.count <= Self.maxUploadBytes else {
            throw PhotoKeyError.photoTooLarge
        }
        try await client.uploadObject(
            bucket: Self.bucket,
            path: preferredName,
            data: sealed.ciphertext,
            contentType: "application/octet-stream"
        )
        // Cache exactly what Storage holds; our own photo still renders
        // instantly, decrypted with the key we just used.
        let path = try await localCache.saveImageData(sealed.ciphertext, preferredName: preferredName)
        return StoredDepositPhoto(path: path, wrappedPhotoKey: sealed.wrappedPhotoKey)
    }

    func loadDepositPhoto(at relativePath: String, huddleID: UUID, wrappedPhotoKey: String?) async -> Data? {
        // No key on this device yet (or a row from before encryption): show
        // the locked placeholder rather than download what can't be opened.
        guard let wrappedPhotoKey,
              let huddleKey = await keyring.cachedHuddleKey(for: huddleID),
              let ciphertext = await loadImageData(at: relativePath)
        else { return nil }
        return try? PhotoCrypto.openPhoto(ciphertext, wrappedPhotoKey: wrappedPhotoKey, huddleKey: huddleKey)
    }

    func imageURL(for relativePath: String) -> URL {
        localCache.imageURL(for: relativePath)
    }

    func loadImageData(at relativePath: String) async -> Data? {
        guard MockMediaService.isSafe(relativePath) else { return nil }
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

    /// Sign-out / account deletion: drops every cached photo.
    func removeLocalCache() {
        localCache.removeAll()
    }

    func deleteImage(at relativePath: String) {
        // Local cache only. Unreferenced uploads (e.g. a removed profile
        // photo) leave an orphaned object in Storage — harmless at this scale.
        // TODO: BACKEND — clean up orphans with a scheduled edge function.
        localCache.deleteImage(at: relativePath)
    }
}
