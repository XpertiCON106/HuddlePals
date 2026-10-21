import Foundation
import Observation

/// The Terms of Service bundled with the app (Legal/TermsOfService.md),
/// split into the blocks the in-app reader renders. The same text must be
/// hosted at huddlepals.com/terms.
struct TermsOfService {
    /// The Terms' effective date. Bump it with any material change to
    /// Legal/TermsOfService.md: everyone is then asked to agree again.
    static let version = "2026-10-20"

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
/// locally, because the gate stands in front of sign-in, before any account
/// exists. Persisted like the other settings objects.
@Observable
final class TermsAcceptance {
    private static let versionKey = "huddlepal.terms.acceptedVersion"
    private static let dateKey = "huddlepal.terms.acceptedAt"

    private let defaults: UserDefaults
    private(set) var acceptedVersion: String?
    private(set) var acceptedAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        acceptedVersion = defaults.string(forKey: Self.versionKey)
        acceptedAt = defaults.object(forKey: Self.dateKey) as? Date
    }

    var hasAcceptedCurrentVersion: Bool {
        acceptedVersion == TermsOfService.version
    }

    /// Records the agreement with its wall-clock time: a legal record, so
    /// never the debug-shifted app clock.
    func accept(at date: Date) {
        acceptedVersion = TermsOfService.version
        acceptedAt = date
        defaults.set(TermsOfService.version, forKey: Self.versionKey)
        defaults.set(date, forKey: Self.dateKey)
    }
}
