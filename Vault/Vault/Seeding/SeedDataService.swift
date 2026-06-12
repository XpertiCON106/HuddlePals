import Foundation
import SwiftData

/// First-launch seeding: two vaults (so the multi-vault shelf has life),
/// four users with bios and profile photos, ~30 days of history with varied
/// participation, and a "today" where everyone except the current user has
/// deposited — so the app opens straight into the LOCKED state.
@MainActor
final class SeedDataService {
    static let currentUserName = "You"
    private static let seededKey = "vault.mock.didSeed.v2"

    private let context: ModelContext
    private let engine: VaultEngine
    private let media: MediaServiceProtocol
    private let skipLedger: SkipLedger
    private let dateProvider: DateProviding

    init(
        context: ModelContext,
        engine: VaultEngine,
        media: MediaServiceProtocol,
        skipLedger: SkipLedger,
        dateProvider: DateProviding
    ) {
        self.context = context
        self.engine = engine
        self.media = media
        self.skipLedger = skipLedger
        self.dateProvider = dateProvider
    }

    func seedIfNeeded() async throws {
        // Skips are in-memory (see SkipLedger), so they must be re-recorded
        // every launch even when the SwiftData store already exists.
        if UserDefaults.standard.bool(forKey: Self.seededKey) {
            try reseedSkipLedger()
            return
        }
        // A pre-multi-vault store (old seed flag) gets wiped and rebuilt.
        try await wipe()
        try await seed()
        UserDefaults.standard.set(true, forKey: Self.seededKey)
    }

    /// DEBUG: wipe everything and rebuild the seed world.
    func regenerate() async throws {
        MockAuthService.resetForReseed()
        try await wipe()
        try await seed()
        UserDefaults.standard.set(true, forKey: Self.seededKey)
    }

    private func wipe() async throws {
        try context.delete(model: Reaction.self)
        try context.delete(model: Comment.self)
        try context.delete(model: Deposit.self)
        try context.delete(model: Membership.self)
        try context.delete(model: Vault.self)
        try context.delete(model: User.self)
        try context.save()
        skipLedger.removeAll()
    }

    // MARK: - Seed plan

    /// "The Crew" day offsets where a member skipped or missed. Everything
    /// else in -30...(-1) is a perfect day. The last break is at -7, so the
    /// seeded streak is 6 going into today.
    private struct SeedPlan {
        static let historyDays = -30...(-1)
        static let missedDays: [Int: String] = [-24: "Riley", -7: "Maya"] // streak breaks
        static let skippedDays: [Int: String] = [-14: "Sam"] // token spent, streak survives
        static let dinnerHistoryDays = -8...(-1) // second vault: all perfect
    }

    private func seed() async throws {
        let now = dateProvider.now
        let todayKey = engine.todayKey(now: now)

        let you = User(
            displayName: Self.currentUserName,
            avatarColorHex: "F76B15-E5484D",
            bio: "Keeper of the crew. One photo at a time."
        )
        let maya = User(
            displayName: "Maya",
            avatarColorHex: "12A594",
            bio: "Plant mom, trail snob, professional golden-hour chaser."
        )
        let sam = User(
            displayName: "Sam",
            avatarColorHex: "0091FF",
            bio: "Will trade coffee for memes."
        )
        let riley = User(
            displayName: "Riley",
            avatarColorHex: "D6409F",
            bio: "Probably baking something right now."
        )
        let allUsers = [you, maya, sam, riley]
        allUsers.forEach { context.insert($0) }

        // Profile photos (placeholder portraits into the avatars namespace).
        var portraitSeed = 500
        for user in allUsers {
            var paths: [String] = []
            for _ in 0..<(user === riley ? 1 : 2) {
                portraitSeed += 1
                let data = PlaceholderImageGenerator.jpegData(seed: portraitSeed)
                let path = try await media.saveImageData(
                    data,
                    preferredName: "avatars/\(user.id.uuidString)/p\(portraitSeed).jpg"
                )
                paths.append(path)
            }
            user.profilePhotoPaths = paths
        }

        let captions = [
            "Golden hour again", "Tiny win today", nil, "Missing you all",
            "Best coffee in town", nil, "He did a big stretch", "Trail day",
            "Burnt the toast, ate it anyway", nil, "Look what I found",
            "Quiet evening", "New favorite spot", nil, "10/10 would nap again",
        ]
        var imageSeed = 0

        // ── Vault 1: The Crew (all four, 30 days, textured history) ──
        let crew = Vault(name: "The Crew", emoji: "🏔", inviteCode: "CREW42")
        context.insert(crew)
        for (index, user) in allUsers.enumerated() {
            context.insert(Membership(
                user: user,
                vault: crew,
                role: user === you ? .keeper : .member,
                skipTokensRemaining: user.displayName == "Sam" ? 1 : 2, // Sam spent one
                joinedAt: now.addingTimeInterval(TimeInterval(-32 * 86_400 + index * 600))
            ))
        }

        for offset in SeedPlan.historyDays {
            guard let key = engine.dayKey(byAdding: offset, to: todayKey),
                  let dayStart = engine.date(fromDayKey: key) else { continue }
            for (userIndex, user) in allUsers.enumerated() {
                if SeedPlan.missedDays[offset] == user.displayName { continue }
                if SeedPlan.skippedDays[offset] == user.displayName {
                    skipLedger.recordSkip(vaultID: crew.id, dayKey: key, userID: user.id)
                    continue
                }
                imageSeed += 1
                try await insertDeposit(
                    vault: crew, author: user, dayKey: key,
                    createdAt: dayStart.addingTimeInterval(TimeInterval(9 * 3600 + userIndex * 4200 + offset * 60)),
                    imageSeed: imageSeed,
                    caption: captions[(imageSeed + userIndex) % captions.count]
                )
            }
        }
        // Today: everyone but the current user has deposited → LOCKED.
        for (userIndex, user) in [maya, sam, riley].enumerated() {
            imageSeed += 1
            try await insertDeposit(
                vault: crew, author: user, dayKey: todayKey,
                createdAt: now.addingTimeInterval(TimeInterval(-3600 * (userIndex + 1))),
                imageSeed: imageSeed,
                caption: captions[(imageSeed + 3) % captions.count]
            )
        }

        // ── Vault 2: Sunday Dinners (You + Maya — multi-vault demo) ──
        let dinners = Vault(name: "Sunday Dinners", emoji: "🍝", inviteCode: "PASTA7")
        context.insert(dinners)
        context.insert(Membership(user: you, vault: dinners, role: .keeper, joinedAt: now.addingTimeInterval(-10 * 86_400)))
        context.insert(Membership(user: maya, vault: dinners, joinedAt: now.addingTimeInterval(-10 * 86_400 + 300)))

        for offset in SeedPlan.dinnerHistoryDays {
            guard let key = engine.dayKey(byAdding: offset, to: todayKey),
                  let dayStart = engine.date(fromDayKey: key) else { continue }
            for (userIndex, user) in [you, maya].enumerated() {
                imageSeed += 1
                try await insertDeposit(
                    vault: dinners, author: user, dayKey: key,
                    createdAt: dayStart.addingTimeInterval(TimeInterval(18 * 3600 + userIndex * 1800)),
                    imageSeed: imageSeed,
                    caption: userIndex == 0 ? nil : captions[imageSeed % captions.count]
                )
            }
        }
        // Today in Sunday Dinners: Maya posted, You haven't → locked too.
        imageSeed += 1
        try await insertDeposit(
            vault: dinners, author: maya, dayKey: todayKey,
            createdAt: now.addingTimeInterval(-2 * 3600),
            imageSeed: imageSeed,
            caption: "Sauce preview"
        )

        // A few reactions/comments on yesterday so Deposit Detail has life.
        if let yesterdayKey = engine.yesterdayKey(now: now) {
            let yesterdays = crew.deposits.filter { $0.dayKey == yesterdayKey }
            if let first = yesterdays.first {
                context.insert(Reaction(deposit: first, user: maya, emoji: "🔥"))
                context.insert(Reaction(deposit: first, user: sam, emoji: "❤️"))
                context.insert(Comment(deposit: first, user: riley, text: "Saving this one forever"))
            }
            if yesterdays.count > 1 {
                context.insert(Reaction(deposit: yesterdays[1], user: you, emoji: "🥹"))
            }
        }

        try context.save()

        // Persist computed streaks (recomputed again on every refresh).
        for vault in [crew, dinners] {
            let memberIDs = Set(vault.memberships.compactMap { $0.user?.id })
            let result = engine.computeStreak(
                memberIDs: memberIDs,
                deposits: vault.deposits.compactMap(\.snapshot),
                skips: skipLedger.skips(for: vault.id),
                now: now
            )
            vault.streakCount = result.count
            vault.lastStreakDate = result.lastCompleteDayKey.flatMap { engine.date(fromDayKey: $0) }
        }
        try context.save()
    }

    private func insertDeposit(
        vault: Vault,
        author: User,
        dayKey: String,
        createdAt: Date,
        imageSeed: Int,
        caption: String?
    ) async throws {
        let data = PlaceholderImageGenerator.jpegData(seed: imageSeed)
        let path = try await media.saveImageData(
            data,
            preferredName: "\(vault.id.uuidString)/seed-\(dayKey)-\(author.id.uuidString.prefix(8)).jpg"
        )
        context.insert(Deposit(
            vault: vault,
            author: author,
            localImagePath: path,
            caption: VaultEngine.sanitizedCaption(caption),
            dayKey: dayKey,
            createdAt: createdAt
        ))
    }

    /// Rebuild the in-memory skip ledger from the seed plan on relaunch.
    private func reseedSkipLedger() throws {
        let vaults = try context.fetch(FetchDescriptor<Vault>())
        let users = try context.fetch(FetchDescriptor<User>())
        guard let crew = vaults.first(where: { $0.inviteCode == "CREW42" }) else { return }
        let todayKey = engine.todayKey(now: dateProvider.now)
        for (offset, name) in SeedPlan.skippedDays {
            // The seeded skip days drift as real days pass; anchoring to the
            // original seed date isn't worth persisting for a mock. Streaks
            // remain consistent because deposits dominate the math.
            guard let key = engine.dayKey(byAdding: offset, to: todayKey),
                  let user = users.first(where: { $0.displayName == name }) else { continue }
            skipLedger.recordSkip(vaultID: crew.id, dayKey: key, userID: user.id)
        }
    }
}
