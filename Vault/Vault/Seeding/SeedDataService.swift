import Foundation
import SwiftData

/// First-launch seeding: one vault ("The Crew" 🏔), four users, ~30 days of
/// history with varied participation, and a "today" where everyone except
/// the current user has deposited — so the app opens straight into the
/// LOCKED state.
@MainActor
final class SeedDataService {
    static let currentUserName = "You"
    private static let seededKey = "vault.mock.didSeed"

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

    func seedIfNeeded() throws {
        // Skips are in-memory (see SkipLedger), so they must be re-recorded
        // every launch even when the SwiftData store already exists.
        if UserDefaults.standard.bool(forKey: Self.seededKey) {
            try reseedSkipLedger()
            return
        }
        try seed()
        UserDefaults.standard.set(true, forKey: Self.seededKey)
    }

    /// DEBUG: wipe everything and rebuild the seed world.
    func regenerate() throws {
        try context.delete(model: Reaction.self)
        try context.delete(model: Comment.self)
        try context.delete(model: Deposit.self)
        try context.delete(model: Membership.self)
        try context.delete(model: Vault.self)
        try context.delete(model: User.self)
        try context.save()
        skipLedger.removeAll()
        try seed()
        UserDefaults.standard.set(true, forKey: Self.seededKey)
    }

    // MARK: - Seed plan

    /// Day offsets (relative to today) where a member skipped or missed.
    /// Everything else in -30...(-1) is a perfect day. The last break is at
    /// -7, so the seeded streak is 6 going into today.
    private struct SeedPlan {
        static let historyDays = -30...(-1)
        static let missedDays: [Int: String] = [-24: "Riley", -7: "Maya"] // streak breaks
        static let skippedDays: [Int: String] = [-14: "Sam"] // token spent, streak survives
    }

    private func seed() throws {
        let now = dateProvider.now
        let todayKey = engine.todayKey(now: now)

        let you = User(displayName: Self.currentUserName, avatarColorHex: "E8A33D")
        let maya = User(displayName: "Maya", avatarColorHex: "7FB069")
        let sam = User(displayName: "Sam", avatarColorHex: "5B8DEF")
        let riley = User(displayName: "Riley", avatarColorHex: "C97FD6")
        let allUsers = [you, maya, sam, riley]
        allUsers.forEach { context.insert($0) }

        let vault = Vault(name: "The Crew", emoji: "🏔", inviteCode: "CREW42")
        context.insert(vault)

        for (index, user) in allUsers.enumerated() {
            let membership = Membership(
                user: user,
                vault: vault,
                role: user === you ? .keeper : .member,
                skipTokensRemaining: user.displayName == "Sam" ? 1 : 2, // Sam spent one
                joinedAt: now.addingTimeInterval(TimeInterval(-32 * 86_400 + index * 600))
            )
            context.insert(membership)
        }

        let captions = [
            "Golden hour again", "Tiny win today", nil, "Missing you all",
            "Best coffee in town", nil, "He did a big stretch", "Trail day",
            "Burnt the toast, ate it anyway", nil, "Look what I found",
            "Quiet evening", "New favorite spot", nil, "10/10 would nap again",
        ]

        var imageSeed = 0
        for offset in SeedPlan.historyDays {
            guard let key = engine.dayKey(byAdding: offset, to: todayKey),
                  let dayStart = engine.date(fromDayKey: key) else { continue }

            for (userIndex, user) in allUsers.enumerated() {
                if SeedPlan.missedDays[offset] == user.displayName { continue }
                if SeedPlan.skippedDays[offset] == user.displayName {
                    skipLedger.recordSkip(vaultID: vault.id, dayKey: key, userID: user.id)
                    continue
                }
                imageSeed += 1
                try insertDeposit(
                    vault: vault, author: user, dayKey: key,
                    createdAt: dayStart.addingTimeInterval(TimeInterval(9 * 3600 + userIndex * 4200 + offset * 60)),
                    imageSeed: imageSeed,
                    caption: captions[(imageSeed + userIndex) % captions.count]
                )
            }
        }

        // Today: everyone but the current user has deposited → LOCKED.
        for (userIndex, user) in [maya, sam, riley].enumerated() {
            imageSeed += 1
            try insertDeposit(
                vault: vault, author: user, dayKey: todayKey,
                createdAt: now.addingTimeInterval(TimeInterval(-3600 * (userIndex + 1))),
                imageSeed: imageSeed,
                caption: captions[(imageSeed + 3) % captions.count]
            )
        }

        // A few reactions/comments on yesterday so Deposit Detail has life.
        if let yesterdayKey = engine.yesterdayKey(now: now) {
            let yesterdays = vault.deposits.filter { $0.dayKey == yesterdayKey }
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

        // Persist the computed streak (recomputed again on every launch).
        let memberIDs = Set(allUsers.map(\.id))
        let result = engine.computeStreak(
            memberIDs: memberIDs,
            deposits: vault.deposits.compactMap(\.snapshot),
            skips: skipLedger.skips(for: vault.id),
            now: now
        )
        vault.streakCount = result.count
        vault.lastStreakDate = result.lastCompleteDayKey.flatMap { engine.date(fromDayKey: $0) }
        try context.save()
    }

    private func insertDeposit(
        vault: Vault,
        author: User,
        dayKey: String,
        createdAt: Date,
        imageSeed: Int,
        caption: String?
    ) throws {
        let data = PlaceholderImageGenerator.jpegData(seed: imageSeed)
        let path = try media.saveImageData(data, preferredName: "seed-\(dayKey)-\(author.displayName).jpg")
        let deposit = Deposit(
            vault: vault,
            author: author,
            localImagePath: path,
            caption: VaultEngine.sanitizedCaption(caption),
            dayKey: dayKey,
            createdAt: createdAt
        )
        context.insert(deposit)
    }

    /// Rebuild the in-memory skip ledger from the seed plan on relaunch.
    private func reseedSkipLedger() throws {
        let vaults = try context.fetch(FetchDescriptor<Vault>())
        let users = try context.fetch(FetchDescriptor<User>())
        guard let vault = vaults.first(where: { $0.inviteCode == "CREW42" }) else { return }
        let todayKey = engine.todayKey(now: dateProvider.now)
        for (offset, name) in SeedPlan.skippedDays {
            // The seeded skip days drift as real days pass; anchoring to the
            // original seed date isn't worth persisting for a mock. Streaks
            // remain consistent because deposits dominate the math.
            guard let key = engine.dayKey(byAdding: offset, to: todayKey),
                  let user = users.first(where: { $0.displayName == name }) else { continue }
            skipLedger.recordSkip(vaultID: vault.id, dayKey: key, userID: user.id)
        }
    }
}
