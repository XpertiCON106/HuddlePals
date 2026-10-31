import Foundation
import XCTest

@testable import HuddlePal

/// Sign-in plumbing that broke on real devices: the Keychain session must
/// survive a relaunch, phone numbers must not require "+1", and the code
/// boxes must match the code length the backend is configured to send.
@MainActor
final class AuthInputTests: XCTestCase {

    // MARK: Session persistence

    func testSavedSessionSurvivesARelaunch() throws {
        let saved = SupabaseClient.Session(
            accessToken: "access", refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000), userId: UUID()
        )
        let data = try SupabaseClient.makeEncoder().encode(saved)
        let restored = try SupabaseClient.makeDecoder().decode(SupabaseClient.Session.self, from: data)

        XCTAssertEqual(restored.userId, saved.userId)
        XCTAssertEqual(restored.refreshToken, saved.refreshToken)
        XCTAssertEqual(restored.expiresAt, saved.expiresAt)
    }

    func testSessionWrittenByTheEarlierBuildStillLoads() throws {
        // Exactly what the old `userID` struct wrote to the Keychain.
        let id = UUID()
        let json = """
        {"user_id":"\(id)","refresh_token":"r","expires_at":"2026-10-19T22:38:49Z","access_token":"a"}
        """
        let restored = try SupabaseClient.makeDecoder().decode(SupabaseClient.Session.self, from: Data(json.utf8))
        XCTAssertEqual(restored.userId, id, "users signed in on the broken build stay signed in after updating")
        XCTAssertTrue(restored.signsInWithApple, "every account before password sign-in was Apple's")
    }

    func testASessionRemembersHowItsAccountSignsIn() throws {
        let saved = SupabaseClient.Session(
            accessToken: "access", refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000), userId: UUID(), providers: ["email"]
        )
        let data = try SupabaseClient.makeEncoder().encode(saved)
        let restored = try SupabaseClient.makeDecoder().decode(SupabaseClient.Session.self, from: data)
        XCTAssertEqual(restored.providers, ["email"])
        XCTAssertFalse(restored.signsInWithApple)
    }

    // MARK: Phone numbers

    func testUSNumbersDontNeedTheCountryCode() {
        for typed in ["4155550123", "(415) 555-0123", "415.555.0123", "1 415 555 0123", "+1 (415) 555-0123"] {
            XCTAssertEqual(AuthValidation.normalizedPhone(typed), "+14155550123", typed)
        }
    }

    func testInternationalNumbersStartWithPlus() {
        XCTAssertEqual(AuthValidation.normalizedPhone("+44 20 7946 0958"), "+442079460958")
        XCTAssertNil(AuthValidation.normalizedPhone("+123"), "too short for E.164")
    }

    func testInvalidPhoneNumbersAreRejected() {
        for typed in ["", "555-0123", "22345678901", "415555012a", "+1 415 abc 0123", "41555501234"] {
            XCTAssertNil(AuthValidation.normalizedPhone(typed), typed)
        }
    }

    func testPhoneFormatsAsYouType() {
        let expected = [
            "4": "4",
            "415": "415",
            "4155": "(415) 5",
            "415555": "(415) 555",
            "4155550": "(415) 555-0",
            "4155550123": "(415) 555-0123",
            "415555012399": "(415) 555-0123", // capped at 10 digits
            "14155550123": "(415) 555-0123", // a typed country code is dropped
            "(415) ": "415", // backspacing over the space deletes back to digits
            "+44 20 7946 0958": "+44 20 7946 0958", // international: left as typed
            "+1abc": "+1",
        ]
        for (typed, shown) in expected {
            XCTAssertEqual(AuthValidation.formattedPhoneInput(typed), shown, typed)
        }
        // Whatever the field shows must still be sendable.
        XCTAssertEqual(
            AuthValidation.normalizedPhone(AuthValidation.formattedPhoneInput("4155550123")), "+14155550123"
        )
    }

    // MARK: Code length

    func testCodeLengthsComeFromTheBackendConfig() throws {
        let base: [String: Any] = ["SUPABASE_URL": "https://example.supabase.co", "SUPABASE_ANON_KEY": "key"]

        let defaults = try XCTUnwrap(BackendConfig(plist: base))
        XCTAssertEqual(defaults.emailCodeLength, 6)
        XCTAssertEqual(defaults.phoneCodeLength, 6)

        var custom = base
        custom["EMAIL_OTP_LENGTH"] = 8
        custom["SMS_OTP_LENGTH"] = "7"
        let configured = try XCTUnwrap(BackendConfig(plist: custom))
        XCTAssertEqual(configured.emailCodeLength, 8)
        XCTAssertEqual(configured.phoneCodeLength, 7)

        custom["EMAIL_OTP_LENGTH"] = 12 // Supabase allows 6–10
        XCTAssertEqual(BackendConfig(plist: custom)?.emailCodeLength, 6)
    }

    func testOnlyARefusedTokenIsCalledAnExpiredSession() {
        // QA-25: an access rule saying no (403) isn't a sign-in problem.
        typealias Failure = SupabaseClient.ClientError
        XCTAssertEqual(Failure.http(status: 401, message: "JWT expired").errorDescription,
                       "Your session has expired. Please sign in again.")
        XCTAssertEqual(Failure.http(status: 403, message: "new row violates row-level security policy").errorDescription,
                       "You don't have access to that any more.")
        XCTAssertEqual(Failure.http(status: 500, message: "boom").errorDescription,
                       "Something went wrong. Please try again.")
    }

    func testBackendConfigStillRequiresARealHTTPSProject() {
        XCTAssertNil(BackendConfig(plist: ["SUPABASE_URL": "http://example.supabase.co", "SUPABASE_ANON_KEY": "key"]))
        XCTAssertNil(BackendConfig(plist: [
            "SUPABASE_URL": "https://YOUR-PROJECT.supabase.co", "SUPABASE_ANON_KEY": "YOUR-ANON-KEY",
        ]))
    }

    func testMockCodeLengthMatchesTheMockCode() {
        let deps = AppDependencies.makeMock(inMemory: true)
        XCTAssertEqual(deps.auth.codeLength(for: .email("a@b.co")), MockAuthService.mockCode.count)
    }
}

/// QA-30: a test run never wires the live backend, and never touches the
/// app's own Keychain session.
@MainActor
final class TestIsolationTests: XCTestCase {
    func testATestRunNeverUsesTheLiveBackend() {
        let config = BackendConfig(url: URL(string: "https://example.supabase.co")!, anonKey: "anon")
        XCTAssertTrue(AppDependencies.usesLiveBackend(config: config, environment: [:]))
        XCTAssertFalse(AppDependencies.usesLiveBackend(config: config, environment: ["XCTestConfigurationFilePath": "/x.xctestconfiguration"]))
        XCTAssertFalse(AppDependencies.usesLiveBackend(config: nil, environment: [:]))
        // This very process is a test host.
        XCTAssertFalse(AppDependencies.usesLiveBackend(config: config, environment: ProcessInfo.processInfo.environment))
    }

    func testLiveServiceTestsKeepTheirSessionApartFromTheApps() async throws {
        let marker = Data("real sign-in".utf8)
        let previous = KeychainStore.load(key: "supabase.session")
        KeychainStore.save(marker, key: "supabase.session")
        defer {
            if let previous { KeychainStore.save(previous, key: "supabase.session") } else { KeychainStore.delete(key: "supabase.session") }
            KeychainStore.delete(key: LiveStub.sessionKey)
            StubURLProtocol.reset()
        }
        _ = try await LiveStub.signedInClient()
        XCTAssertEqual(KeychainStore.load(key: "supabase.session"), marker, "the app's own session is untouched")
    }
}
