import Foundation

/// Backend selection. The app runs against Supabase when a `Supabase.plist`
/// with real values is bundled (copy `supabase/Supabase.example.plist` into
/// `HuddlePal/HuddlePal/` and fill it in); otherwise it falls back to mock mode.
///
/// The anon key is a *publishable* key — safe to ship in the binary; Row
/// Level Security is what protects the data.
struct BackendConfig {
    let url: URL
    let anonKey: String
    /// Digits in the verification codes the project sends. Supabase lets
    /// each project pick 6–10 per channel (Authentication → Email "OTP
    /// length", and the SMS equivalent), and the code entry must match it.
    /// Optional plist keys `EMAIL_OTP_LENGTH` / `SMS_OTP_LENGTH`; default 6.
    var emailCodeLength = BackendConfig.defaultCodeLength
    var phoneCodeLength = BackendConfig.defaultCodeLength

    static let defaultCodeLength = 6
    static let codeLengthRange = 6...10

    static func load(bundle: Bundle = .main) -> BackendConfig? {
        guard
            let plistURL = bundle.url(forResource: "Supabase", withExtension: "plist"),
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }
        return BackendConfig(plist: plist)
    }

    init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }

    /// nil (→ mock mode) unless the plist carries a real https URL and key.
    init?(plist: [String: Any]) {
        guard
            let urlString = plist["SUPABASE_URL"] as? String,
            let anonKey = plist["SUPABASE_ANON_KEY"] as? String,
            !urlString.contains("YOUR-PROJECT"),
            !anonKey.isEmpty, !anonKey.contains("YOUR-ANON-KEY"),
            let url = URL(string: urlString),
            // Defense in depth: never speak to the backend over cleartext.
            url.scheme?.lowercased() == "https"
        else { return nil }
        self.init(url: url, anonKey: anonKey)
        emailCodeLength = Self.codeLength(plist["EMAIL_OTP_LENGTH"])
        phoneCodeLength = Self.codeLength(plist["SMS_OTP_LENGTH"])
    }

    /// Accepts a plist number or string; anything missing or outside what
    /// Supabase allows falls back to the default.
    private static func codeLength(_ value: Any?) -> Int {
        let parsed = (value as? Int) ?? (value as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let parsed, codeLengthRange.contains(parsed) else { return defaultCodeLength }
        return parsed
    }
}
