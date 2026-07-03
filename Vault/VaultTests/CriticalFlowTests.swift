import SwiftData
import XCTest

@testable import Vault

/// Smoke tests over the assembled mock stack for the flows a launch cannot
/// break: bootstrap (seed + session restore), the reciprocity gate on the
/// primary deposit journey, once-and-permanent enforcement, and create/join.
/// Uses an in-memory store; the only side effects are the mock services'
/// own UserDefaults keys inside the test host.
@MainActor
final class CriticalFlowTests: XCTestCase {
    private var deps: AppDependencies!

    override func setUp() async throws {
        try await super.setUp()
        deps = AppDependencies.makeMock(inMemory: true)
        // Regenerate unconditionally: seedIfNeeded's UserDefaults flag can
        // linger from an earlier run while the in-memory store starts empty.
        try await deps.seeder.regenerate()
    }

    private func signedInUser() async throws -> User {
        let state = try await deps.auth.currentState()
        guard case .signedIn(let user) = state else {
            throw XCTSkip("expected the seeded user to be signed in")
        }
        return user
    }

    // MARK: Launch

    func testBootstrapSignsInSeededUserWithTwoLockedVaults() async throws {
        let user = try await signedInUser()
        XCTAssertEqual(user.displayName, SeedDataService.currentUserName)

        let vaults = try await deps.vaultService.vaults(for: user)
        XCTAssertEqual(vaults.count, 2, "seed world ships The Crew + Sunday Dinners")

        for vault in vaults {
            let deposits = try await deps.depositService.deposits(in: vault)
            XCTAssertFalse(deposits.isEmpty, "seeded vaults carry history")
            XCTAssertFalse(
                deps.engine.isUnlocked(
                    vaultID: vault.id,
                    currentUserID: user.id,
                    deposits: deposits.compactMap(\.snapshot),
                    now: deps.dateProvider.now
                ),
                "the seeded world opens LOCKED: others deposited today, you haven't"
            )
        }
    }

    // MARK: Primary journey — deposit unlocks the gate, once and permanent

    func testDepositUnlocksGateAndSecondDepositIsRefused() async throws {
        let user = try await signedInUser()
        let vaults = try await deps.vaultService.vaults(for: user)
        let vault = try XCTUnwrap(vaults.first)
        let today = deps.engine.todayKey(now: deps.dateProvider.now)

        let path = try await deps.mediaService.saveImageData(
            PlaceholderImageGenerator.jpegData(seed: 1),
            preferredName: "\(vault.id.uuidString)/smoke-test.jpg"
        )
        try await deps.depositService.createDeposit(
            in: vault, author: user, localImagePath: path, caption: "smoke", dayKey: today
        )

        let deposits = try await deps.depositService.deposits(in: vault)
        XCTAssertTrue(
            deps.engine.isUnlocked(
                vaultID: vault.id,
                currentUserID: user.id,
                deposits: deposits.compactMap(\.snapshot),
                now: deps.dateProvider.now
            ),
            "your own deposit for today must open the gate"
        )

        do {
            try await deps.depositService.createDeposit(
                in: vault, author: user, localImagePath: path, caption: nil, dayKey: today
            )
            XCTFail("a second same-day deposit must be refused")
        } catch DepositError.alreadyDepositedToday {
            // once and permanent — expected
        }
    }

    // MARK: Create / join

    func testCreateAndJoinVaultFlow() async throws {
        let keeper = try await signedInUser()
        let vault = try await deps.vaultService.createVault(
            name: "Smoke Vault", emoji: "🔥", keeper: keeper
        )
        XCTAssertEqual(vault.inviteCode.count, 6)
        XCTAssertEqual(vault.memberships.first?.role, .keeper)

        let friend = User(displayName: "Friend", avatarColorHex: "0091FF")
        deps.modelContainer.mainContext.insert(friend)

        // Codes are case-insensitive on join.
        let joined = try await deps.vaultService.joinVault(
            inviteCode: vault.inviteCode.lowercased(), user: friend
        )
        XCTAssertEqual(joined.id, vault.id)
        XCTAssertEqual(joined.memberships.count, 2)

        do {
            _ = try await deps.vaultService.joinVault(inviteCode: vault.inviteCode, user: friend)
            XCTFail("joining twice must be refused")
        } catch VaultServiceError.alreadyMember {
            // expected
        }

        do {
            _ = try await deps.vaultService.joinVault(inviteCode: "ZZZZZZ", user: friend)
            XCTFail("an unknown code must be refused")
        } catch VaultServiceError.inviteCodeNotFound {
            // expected
        }
    }

    // MARK: Sign out / sign in round trip

    func testSignOutThenCurrentStateIsSignedOut() async throws {
        _ = try await signedInUser()
        try await deps.auth.signOut()
        let state = try await deps.auth.currentState()
        guard case .signedOut = state else {
            return XCTFail("after sign-out the session must be gone, got \(state)")
        }
    }
}
