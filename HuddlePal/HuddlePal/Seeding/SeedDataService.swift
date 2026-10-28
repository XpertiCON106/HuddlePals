import Foundation
import SwiftData

/// First-launch seeding: two huddles (so the multi-huddle shelf has life),
/// four users with bios and profile photos, 45 days of history with varied
/// participation (past the free plan's 30-day archive window, so its locked
/// days show), one video drop, and a "today" where everyone except the
/// current user has deposited — so the app opens straight into the LOCKED
/// state.
@MainActor
final class SeedDataService {
    static let currentUserName = "You"
    /// The seeded huddles' invite codes (lookup part first, as live stores it).
    static let crewInviteCode = "CREW427KQ9MWXH4TBR2VNC8JPZ3DFYGS"
    static let dinnersInviteCode = "PASTA7M4QX8RZ2VKHT7WNB3CJP9DGFYS"
    /// v3: 45 days and a video. An older store is wiped and rebuilt.
    private static let seededKey = "huddlepal.mock.didSeed.v3"

    private let context: ModelContext
    private let engine: HuddleEngine
    private let media: MediaServiceProtocol
    private let skipLedger: SkipLedger
    private let dateProvider: DateProviding

    init(
        context: ModelContext,
        engine: HuddleEngine,
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
        // A pre-multi-huddle store (old seed flag) gets wiped and rebuilt.
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
        try context.deleteAllHuddleData()
        skipLedger.removeAll()
    }

    // MARK: - Seed plan

    /// "The Crew" day offsets where a member skipped or missed. Everything
    /// else in -45...(-1) is a perfect day. The last break is at -7, so the
    /// seeded streak is 6 going into today. Days -30 and older are past the
    /// free plan's archive window.
    private struct SeedPlan {
        static let historyDays = -45...(-1)
        /// The Crew's members joined the day before its history starts.
        static let crewJoinedDaysAgo = 47
        static let missedDays: [Int: String] = [-24: "Riley", -7: "Maya"] // streak breaks
        static let skippedDays: [Int: String] = [-14: "Sam"] // token spent, streak survives
        /// Maya's post yesterday is a video (Plus), so playback and the
        /// video badge have something to show.
        static let videoDeposit = (offset: -1, author: "Maya")
        static let dinnerHistoryDays = -8...(-1) // second huddle: all perfect
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
            bio: "Plant mom, trail snob, golden-hour chaser."
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
        // An account from before birthdays were asked for would be asked
        // first thing: the seeded one has one.
        if !UITestHooks.noBirthday {
            MockAuthService.storeBirthday(Birthday(year: 1995, month: 6, day: 14), for: you.id)
        }

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

        // ── Huddle 1: The Crew (all four, 45 days, textured history) ──
        // Four members: on the free plan it's full, a ready-made case for
        // the member cap.
        let crew = Huddle(name: "The Crew", emoji: "🏔", inviteCode: Self.crewInviteCode)
        context.insert(crew)
        let crewJoined = now.addingTimeInterval(TimeInterval(-SeedPlan.crewJoinedDaysAgo * 86_400))
        for (index, user) in allUsers.enumerated() {
            let joinedAt = crewJoined.addingTimeInterval(TimeInterval(index * 600))
            context.insert(Membership(
                user: user,
                huddle: crew,
                role: user === you ? .keeper : .member,
                skipTokensRemaining: user.displayName == "Sam" ? 1 : 2, // Sam spent one
                joinedAt: joinedAt,
                keeperSince: user === you ? joinedAt : nil
            ))
        }

        for offset in SeedPlan.historyDays {
            guard let key = engine.dayKey(byAdding: offset, to: todayKey),
                  let dayStart = engine.date(fromDayKey: key) else { continue }
            for (userIndex, user) in allUsers.enumerated() {
                if SeedPlan.missedDays[offset] == user.displayName { continue }
                if SeedPlan.skippedDays[offset] == user.displayName {
                    skipLedger.recordSkip(huddleID: crew.id, dayKey: key, userID: user.id)
                    continue
                }
                imageSeed += 1
                try await insertDeposit(
                    huddle: crew, author: user, dayKey: key,
                    createdAt: dayStart.addingTimeInterval(TimeInterval(9 * 3600 + userIndex * 4200 + offset * 60)),
                    imageSeed: imageSeed,
                    caption: captions[(imageSeed + userIndex) % captions.count],
                    asVideo: offset == SeedPlan.videoDeposit.offset && user.displayName == SeedPlan.videoDeposit.author
                )
            }
        }
        // Today: everyone but the current user has deposited → LOCKED.
        for (userIndex, user) in [maya, sam, riley].enumerated() {
            imageSeed += 1
            try await insertDeposit(
                huddle: crew, author: user, dayKey: todayKey,
                createdAt: now.addingTimeInterval(TimeInterval(-3600 * (userIndex + 1))),
                imageSeed: imageSeed,
                caption: captions[(imageSeed + 3) % captions.count]
            )
        }

        // ── Huddle 2: Sunday Dinners (You + Maya — multi-huddle demo) ──
        let dinners = Huddle(name: "Sunday Dinners", emoji: "🍝", inviteCode: Self.dinnersInviteCode)
        context.insert(dinners)
        let dinnersJoined = now.addingTimeInterval(-10 * 86_400)
        context.insert(Membership(user: you, huddle: dinners, role: .keeper, joinedAt: dinnersJoined, keeperSince: dinnersJoined))
        context.insert(Membership(user: maya, huddle: dinners, joinedAt: now.addingTimeInterval(-10 * 86_400 + 300)))

        for offset in SeedPlan.dinnerHistoryDays {
            guard let key = engine.dayKey(byAdding: offset, to: todayKey),
                  let dayStart = engine.date(fromDayKey: key) else { continue }
            for (userIndex, user) in [you, maya].enumerated() {
                imageSeed += 1
                try await insertDeposit(
                    huddle: dinners, author: user, dayKey: key,
                    createdAt: dayStart.addingTimeInterval(TimeInterval(18 * 3600 + userIndex * 1800)),
                    imageSeed: imageSeed,
                    caption: userIndex == 0 ? nil : captions[imageSeed % captions.count]
                )
            }
        }
        // Today in Sunday Dinners: Maya posted, You haven't → locked too.
        imageSeed += 1
        try await insertDeposit(
            huddle: dinners, author: maya, dayKey: todayKey,
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
        for huddle in [crew, dinners] {
            let result = engine.computeStreak(
                memberIDs: huddle.memberIDs,
                joinedDayKeys: huddle.memberJoinDayKeys(using: engine),
                deposits: huddle.deposits.compactMap(\.snapshot),
                skips: skipLedger.skips(for: huddle.id),
                now: now
            )
            huddle.streakCount = result.count
            huddle.lastStreakDate = result.lastCompleteDayKey.flatMap { engine.date(fromDayKey: $0) }
        }
        try context.save()
    }

    private func insertDeposit(
        huddle: Huddle,
        author: User,
        dayKey: String,
        createdAt: Date,
        imageSeed: Int,
        caption: String?,
        asVideo: Bool = false
    ) async throws {
        let name = "\(huddle.id.uuidString)/seed-\(dayKey)-\(author.id.uuidString.prefix(8))"
        // A video as the app stores one: its poster where a photo would be,
        // the clip next to it. If this Simulator can't encode one, a photo.
        if asVideo, let clip = try? await PlaceholderVideoGenerator.clip(seed: imageSeed) {
            let poster = try await media.saveImageData(clip.poster, preferredName: "\(name).jpg")
            let video = try await media.saveImageData(clip.mp4, preferredName: "\(name).mp4")
            context.insert(Deposit(
                huddle: huddle,
                author: author,
                localImagePath: poster,
                caption: HuddleEngine.sanitizedCaption(caption),
                dayKey: dayKey,
                createdAt: createdAt,
                mediaType: .video,
                localVideoPath: video,
                durationMs: clip.durationMs
            ))
            return
        }
        let data = PlaceholderImageGenerator.jpegData(seed: imageSeed)
        let path = try await media.saveImageData(data, preferredName: "\(name).jpg")
        context.insert(Deposit(
            huddle: huddle,
            author: author,
            localImagePath: path,
            caption: HuddleEngine.sanitizedCaption(caption),
            dayKey: dayKey,
            createdAt: createdAt
        ))
    }

    /// Rebuild the in-memory skip ledger from the seed plan on relaunch.
    private func reseedSkipLedger() throws {
        let huddles = try context.fetch(FetchDescriptor<Huddle>())
        let users = try context.fetch(FetchDescriptor<User>())
        // By name too: the keeper may have made the crew a new code.
        guard let crew = huddles.first(where: { $0.inviteCode == Self.crewInviteCode })
                ?? huddles.first(where: { $0.name == "The Crew" }) else { return }
        let todayKey = engine.todayKey(now: dateProvider.now)
        for (offset, name) in SeedPlan.skippedDays {
            // The seeded skip days drift as real days pass; anchoring to the
            // original seed date isn't worth persisting for a mock. Streaks
            // remain consistent because deposits dominate the math.
            guard let key = engine.dayKey(byAdding: offset, to: todayKey),
                  let user = users.first(where: { $0.displayName == name }) else { continue }
            skipLedger.recordSkip(huddleID: crew.id, dayKey: key, userID: user.id)
        }
    }
}
