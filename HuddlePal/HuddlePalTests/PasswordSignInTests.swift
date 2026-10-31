import Foundation
import SwiftData
import XCTest

@testable import HuddlePal

/// App Review's demo account signs in with an email and a password: GoTrue's
/// password grant, with the same Terms and profile steps as Sign in with
/// Apple after it, and no Apple sheet when it's deleted.
@MainActor
final class PasswordSignInTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "PasswordSignInTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        container = try LiveStub.inMemoryContainer()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        StubURLProtocol.reset()
        KeychainStore.delete(key: LiveStub.sessionKey)
        // The mock keeps its session in the standard defaults: leave it as found.
        for key in ["huddlepal.mock.signedOutExplicitly", "huddlepal.mock.pendingIdentity",
                    "huddlepal.mock.currentUserID", "huddlepal.mock.signedInWithApple"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try await super.tearDown()
    }

    // MARK: Onboarding

    /// Past the welcome cards and the age check, on the sign-in screen.
    private func atSignIn() -> (AppDependencies, OnboardingViewModel) {
        let deps = AppDependencies.makeMock(inMemory: true, terms: TermsAcceptance(defaults: defaults))
        let onboarding = OnboardingViewModel(deps: deps)
        onboarding.pageIndex = OnboardingViewModel.cards.count - 1
        onboarding.advanceWelcome()
        onboarding.continueAfterAgeCheck(Birthday(year: 1990, month: 1, day: 1))
        return (deps, onboarding)
    }

    func testAPasswordAccountAgreesToTheTermsThenMakesItsProfile() async {
        let (deps, onboarding) = atSignIn()
        XCTAssertEqual(onboarding.step, .method)
        onboarding.showPasswordSignIn()
        XCTAssertEqual(onboarding.step, .password)
        XCTAssertFalse(onboarding.canSignInWithPassword)
        onboarding.emailInput = " Review@Example.test "
        XCTAssertFalse(onboarding.canSignInWithPassword, "a password too")
        onboarding.passwordInput = "secret"
        XCTAssertTrue(onboarding.canSignInWithPassword)

        await onboarding.signInWithPassword()
        XCTAssertNil(onboarding.errorMessage)
        XCTAssertEqual(onboarding.step, .terms, "the Terms before the profile, as with Apple")
        XCTAssertEqual(onboarding.passwordInput, "", "not kept once used")
        XCTAssertTrue(deps.session.needsProfileSetup)
        onboarding.termsReachedEnd()
        onboarding.agreeToTerms()
        XCTAssertEqual(onboarding.step, .profile)
        let apple = await deps.auth.signsInWithApple()
        XCTAssertFalse(apple)
    }

    func testBackLeavesNoPasswordBehind() {
        let (_, onboarding) = atSignIn()
        onboarding.showPasswordSignIn()
        onboarding.emailInput = "review@example.test"
        onboarding.passwordInput = "secret"
        onboarding.backToMethod()
        XCTAssertEqual(onboarding.step, .method)
        XCTAssertEqual(onboarding.passwordInput, "")
    }

    // MARK: Live service

    private func liveAuth() -> (SupabaseClient, LiveAuthService) {
        KeychainStore.delete(key: LiveStub.sessionKey)
        let client = SupabaseClient(
            config: LiveStub.config, urlSession: LiveStub.urlSession(), sessionKey: LiveStub.sessionKey
        )
        let keyring = LivePhotoKeyring(
            client: client, session: AppSession(), identityStore: InMemoryIdentityStore(),
            verifiedKeys: InMemoryVerifiedKeys()
        )
        let auth = LiveAuthService(
            client: client, store: SupabaseStore(context: container.mainContext), keyring: keyring,
            media: LiveMediaService(client: client, keyring: keyring), config: LiveStub.config
        )
        return (client, auth)
    }

    /// GoTrue's token answer, with no profile rows after it (a new account).
    private func respondWithSession(userID: UUID, providers: [String]) {
        StubURLProtocol.respond { request in
            guard request.url?.path.hasSuffix("/auth/v1/token") == true else {
                return .init(body: LiveStub.json([]))
            }
            return .init(body: LiveStub.json([
                "access_token": "access", "refresh_token": "refresh", "expires_in": 3600,
                "user": ["id": userID.uuidString, "app_metadata": ["provider": providers[0], "providers": providers]],
            ]))
        }
    }

    func testPasswordSignInUsesThePasswordGrantAndIsntAnAppleAccount() async throws {
        let (client, auth) = liveAuth()
        let userID = UUID()
        respondWithSession(userID: userID, providers: ["email"])

        guard case .needsProfile = try await auth.signInWithPassword(email: "review@example.test", password: "secret") else {
            return XCTFail("a new account goes on to the Terms and its profile")
        }

        let grant = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(grant.httpMethod, "POST")
        XCTAssertEqual(grant.url?.path, "/auth/v1/token")
        XCTAssertEqual(grant.url?.query, "grant_type=password")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(grant.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["email": "review@example.test", "password": "secret"])
        let signedIn = await client.currentUserID
        XCTAssertEqual(signedIn, userID)
        let apple = await auth.signsInWithApple()
        XCTAssertFalse(apple, "deleting it won't ask Apple")
    }

    func testAnAppleAccountStillAsksApple() async throws {
        let (_, auth) = liveAuth()
        respondWithSession(userID: UUID(), providers: ["apple"])
        _ = try await auth.signInWithApple(idToken: "token", nonce: "nonce", suggestedName: nil)
        let apple = await auth.signsInWithApple()
        XCTAssertTrue(apple)
    }

    func testAWrongPasswordIsSaidPlainlyAndSignsNothingIn() async throws {
        let (client, auth) = liveAuth()
        StubURLProtocol.respond { _ in
            .init(status: 400, body: LiveStub.json([
                "code": 400, "error_code": "invalid_credentials", "msg": "Invalid login credentials",
            ]))
        }
        do {
            _ = try await auth.signInWithPassword(email: "review@example.test", password: "wrong")
            XCTFail("a wrong password must not sign in")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That email and password don't match an account.")
        }
        let signedIn = await client.currentUserID
        XCTAssertNil(signedIn)
    }
}
