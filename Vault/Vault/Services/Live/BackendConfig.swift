import Foundation

/// Backend selection. The app runs against Supabase when a `Supabase.plist`
/// with real values is bundled (copy `supabase/Supabase.example.plist` into
/// `Vault/Vault/` and fill it in); otherwise it falls back to mock mode.
///
/// The anon key is a *publishable* key — safe to ship in the binary; Row
/// Level Security is what protects the data.
struct BackendConfig {
    let url: URL
    let anonKey: String

    static func load(bundle: Bundle = .main) -> BackendConfig? {
        guard
            let plistURL = bundle.url(forResource: "Supabase", withExtension: "plist"),
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let urlString = plist["SUPABASE_URL"] as? String,
            let anonKey = plist["SUPABASE_ANON_KEY"] as? String,
            !urlString.contains("YOUR-PROJECT"),
            !anonKey.isEmpty, !anonKey.contains("YOUR-ANON-KEY"),
            let url = URL(string: urlString)
        else { return nil }
        return BackendConfig(url: url, anonKey: anonKey)
    }
}
