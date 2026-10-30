import Foundation
import Observation

/// The Terms of Service bundled with the app (Legal/TermsOfService.md),
/// split into the blocks the in-app reader renders. The same text must be
/// hosted at huddlepals.com/terms.
struct TermsOfService {
    /// The Terms' effective date. Bump it with any material change to
    /// Legal/TermsOfService.md: everyone is then asked to agree again.
    static let version = "2026-10-31"

    /// The bundled text, parsed once. Nil only if the resource is missing
    /// from the build.
    static let current = bundled()

    struct Block: Identifiable {
        enum Kind { case title, heading, paragraph, bullet }
        let id: Int
        let kind: Kind
        let text: AttributedString
    }

    let blocks: [Block]

    static func bundled(_ bundle: Bundle = .main) -> TermsOfService? {
        guard let url = bundle.url(forResource: "TermsOfService", withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return TermsOfService(markdown: markdown)
    }

    /// The subset of Markdown the Terms use: `#` title, `##` headings,
    /// `- ` bullets, paragraphs, and inline bold. Web and email addresses
    /// written out in the text become tappable links.
    init(markdown: String) {
        let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var blocks: [Block] = []
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let (kind, body): (Block.Kind, Substring) =
                if trimmed.hasPrefix("## ") { (.heading, trimmed.dropFirst(3)) }
                else if trimmed.hasPrefix("# ") { (.title, trimmed.dropFirst(2)) }
                else if trimmed.hasPrefix("- ") { (.bullet, trimmed.dropFirst(2)) }
                else { (.paragraph, trimmed[...]) }
            blocks.append(Block(id: blocks.count, kind: kind, text: Self.inline(String(body), linkDetector: linkDetector)))
        }
        self.blocks = blocks
    }

    private static func inline(_ text: String, linkDetector: NSDataDetector?) -> AttributedString {
        var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let plain = String(attributed.characters)
        for match in linkDetector?.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) ?? [] {
            guard let url = match.url, let range = Range(match.range, in: plain) else { continue }
            let lower = attributed.index(
                attributed.startIndex,
                offsetByCharacters: plain.distance(from: plain.startIndex, to: range.lowerBound)
            )
            let upper = attributed.index(lower, offsetByCharacters: plain.distance(from: range.lowerBound, to: range.upperBound))
            // The attribute's type, not `.link`: that key path isn't Sendable.
            attributed[lower..<upper][AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
        }
        return attributed
    }
}

/// Whether this device's user has agreed to the current Terms. Stored
/// locally, because the gate stands right after sign-in, before a new
/// account's profile exists. Persisted like the other settings objects.
/// `TermsRecorder` then ties the agreement to the account and records it on
/// the server.
@Observable
final class TermsAcceptance {
    private static let versionKey = "huddlepal.terms.acceptedVersion"
    private static let dateKey = "huddlepal.terms.acceptedAt"
    private static let claimantKey = "huddlepal.terms.claimedBy"
    private static let recordedKey = "huddlepal.terms.recorded"

    private let defaults: UserDefaults
    private(set) var acceptedVersion: String?
    private(set) var acceptedAt: Date?
    /// The account this agreement belongs to: the first one signed in since
    /// Agree was tapped. Nil until then.
    private(set) var claimedBy: UUID?
    /// The server holds the claimant's record of this agreement.
    private(set) var isRecorded: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        acceptedVersion = defaults.string(forKey: Self.versionKey)
        acceptedAt = defaults.object(forKey: Self.dateKey) as? Date
        claimedBy = defaults.string(forKey: Self.claimantKey).flatMap(UUID.init(uuidString:))
        isRecorded = defaults.bool(forKey: Self.recordedKey)
    }

    var hasAcceptedCurrentVersion: Bool {
        acceptedVersion == TermsOfService.version
    }

    /// Records the agreement with its wall-clock time: a legal record, so
    /// never the debug-shifted app clock. A new agreement belongs to nobody
    /// until an account claims it.
    func accept(at date: Date) {
        acceptedVersion = TermsOfService.version
        acceptedAt = date
        defaults.set(TermsOfService.version, forKey: Self.versionKey)
        defaults.set(date, forKey: Self.dateKey)
        setClaim(nil, recorded: false)
    }

    func claim(for userID: UUID) {
        setClaim(userID, recorded: false)
    }

    func markRecorded() {
        setClaim(claimedBy, recorded: true)
    }

    /// Another account signed in on this device: the agreement was someone
    /// else's, so the Terms come back for this account to agree to itself.
    func withdraw() {
        acceptedVersion = nil
        acceptedAt = nil
        defaults.removeObject(forKey: Self.versionKey)
        defaults.removeObject(forKey: Self.dateKey)
        setClaim(nil, recorded: false)
    }

    private func setClaim(_ userID: UUID?, recorded: Bool) {
        claimedBy = userID
        isRecorded = recorded
        defaults.set(userID?.uuidString, forKey: Self.claimantKey)
        defaults.set(recorded, forKey: Self.recordedKey)
    }
}

/// Puts the agreement on the server for the account that's signed in: which
/// version, when Agree was tapped, and the app build (`terms_acceptances`).
/// Runs on launch, foreground, sign-in and Agree; a failure waits for the next
/// of those. The first account signed in after Agree claims that agreement;
/// any other account signing in on this device sees the Terms again (the
/// sign-in step withdraws it at once) and agrees for itself.
@MainActor
final class TermsRecorder {
    private let terms: TermsAcceptance
    private let service: any TermsRecordServiceProtocol
    private let session: AppSession
    private let appVersion: String

    init(
        terms: TermsAcceptance,
        service: any TermsRecordServiceProtocol,
        session: AppSession,
        appVersion: String = TermsRecorder.bundleVersion
    ) {
        self.terms = terms
        self.service = service
        self.session = session
        self.appVersion = appVersion
    }

    func refresh() async {
        guard let userID = session.currentUser?.id,
              terms.hasAcceptedCurrentVersion,
              let acceptedAt = terms.acceptedAt
        else { return }
        if let claimant = terms.claimedBy, claimant != userID {
            terms.withdraw()
            return
        }
        if terms.claimedBy == nil { terms.claim(for: userID) }
        guard !terms.isRecorded else { return }
        do {
            try await service.record(version: TermsOfService.version, acceptedAt: acceptedAt, appVersion: appVersion)
            // The account may have changed while the request was out.
            if terms.claimedBy == userID, terms.hasAcceptedCurrentVersion { terms.markRecorded() }
        } catch {
            // Retried on the next launch, foreground or sign-in.
        }
    }

    /// "1.0 (10)": the same form as Profile → About.
    nonisolated static var bundleVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
