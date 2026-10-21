import Foundation

/// The server's text limits (supabase/schema.sql check constraints). Postgres
/// `char_length` counts Unicode code points while Swift's `count` counts
/// characters: "❤️" is one character but two code points, a family emoji one
/// character but up to seven. Limits are applied the server's way, so text
/// that fits the field also fits the database.
enum TextLimit {
    static let displayName = 40
    static let huddleName = 60
    static let comment = 500
}

extension String {
    /// Length as the server measures it (`char_length`: code points).
    var serverLength: Int { unicodeScalars.count }

    /// The longest prefix of whole characters within `limit` code points.
    /// Never splits a character (half an emoji would render as garbage).
    func prefix(serverLength limit: Int) -> String {
        var used = 0
        var end = startIndex
        for index in indices {
            let size = self[index].unicodeScalars.count
            guard used + size <= limit else { break }
            used += size
            end = self.index(after: index)
        }
        return String(self[..<end])
    }
}
