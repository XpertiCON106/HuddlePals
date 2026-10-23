import Foundation
import XCTest

@testable import HuddlePal

/// The Terms of Service gate: the Terms come first, Agree works only after
/// scrolling to the end, Decline returns to the first welcome card, nothing
/// past the welcome cards opens until Agree, and the agreement is remembered
/// per Terms version. Uses its own defaults
/// suite so the test host's real acceptance is never touched.
@MainActor
final class TermsAgreementTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TermsAgreementTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeDeps() -> AppDependencies {
        AppDependencies.makeMock(inMemory: true, terms: TermsAcceptance(defaults: defaults))
    }

    /// Scrolls to the end, then taps Agree.
    private func readAndAgree(_ onboarding: OnboardingViewModel) {
        onboarding.termsReachedEnd()
        onboarding.agreeToTerms()
    }

    // MARK: Gate

    func testTermsAreTheFirstScreenUntilAgreed() {
        XCTAssertEqual(OnboardingViewModel(deps: makeDeps()).step, .terms)
    }

    func testDeclineReturnsToTheFirstWelcomeCardWithoutAgreeing() {
        let deps = makeDeps()
        let onboarding = OnboardingViewModel(deps: deps)
        onboarding.pageIndex = 2
        onboarding.declineTerms()
        XCTAssertEqual(onboarding.step, .welcome)
        XCTAssertEqual(onboarding.pageIndex, 0, "back to \"One photo a day\"")
        XCTAssertFalse(deps.terms.hasAcceptedCurrentVersion)
    }

    func testGetStartedAfterDecliningAsksAgainThenContinuesToSignIn() {
        let onboarding = OnboardingViewModel(deps: makeDeps())
        onboarding.declineTerms()
        onboarding.pageIndex = OnboardingViewModel.cards.count - 1
        onboarding.advanceWelcome()
        XCTAssertEqual(onboarding.step, .terms, "no way past the welcome cards without Agree")
        readAndAgree(onboarding)
        XCTAssertEqual(onboarding.step, .method)
    }

    func testAgreeingFirstShowsTheWelcomeCards() {
        let onboarding = OnboardingViewModel(deps: makeDeps())
        readAndAgree(onboarding)
        XCTAssertEqual(onboarding.step, .welcome)
    }

    // MARK: Scroll to the end

    func testAgreeDoesNothingUntilTheTermsAreScrolledToTheEnd() {
        let deps = makeDeps()
        let onboarding = OnboardingViewModel(deps: deps)
        XCTAssertFalse(onboarding.hasReachedEndOfTerms, "Agree starts disabled")
        onboarding.agreeToTerms()
        XCTAssertEqual(onboarding.step, .terms)
        XCTAssertFalse(deps.terms.hasAcceptedCurrentVersion)

        onboarding.termsReachedEnd()
        XCTAssertTrue(onboarding.hasReachedEndOfTerms, "Agree enabled at the end")
        onboarding.agreeToTerms()
        XCTAssertTrue(deps.terms.hasAcceptedCurrentVersion)
    }

    func testDecliningMeansScrollingToTheEndAgain() {
        let onboarding = OnboardingViewModel(deps: makeDeps())
        onboarding.termsReachedEnd()
        onboarding.declineTerms()
        onboarding.pageIndex = OnboardingViewModel.cards.count - 1
        onboarding.advanceWelcome()
        XCTAssertEqual(onboarding.step, .terms)
        XCTAssertFalse(onboarding.hasReachedEndOfTerms)
        onboarding.agreeToTerms()
        XCTAssertEqual(onboarding.step, .terms, "the earlier scroll doesn't count")
    }

    func testAnInterruptedSignUpResumesAtTheProfileAfterAgreeing() {
        let deps = makeDeps()
        deps.session.needsProfileSetup = true
        let onboarding = OnboardingViewModel(deps: deps)
        XCTAssertEqual(onboarding.step, .terms)
        readAndAgree(onboarding)
        XCTAssertEqual(onboarding.step, .profile)
    }

    // MARK: Persistence

    func testAgreementIsRememberedAcrossLaunches() throws {
        let deps = makeDeps()
        let before = Date()
        readAndAgree(OnboardingViewModel(deps: deps))

        let relaunched = TermsAcceptance(defaults: defaults)
        XCTAssertTrue(relaunched.hasAcceptedCurrentVersion)
        XCTAssertEqual(relaunched.acceptedVersion, TermsOfService.version)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(relaunched.acceptedAt), before.addingTimeInterval(-1))
        XCTAssertEqual(OnboardingViewModel(deps: makeDeps()).step, .welcome, "agreed once, not asked again")
    }

    func testAgreementToAnEarlierVersionAsksAgain() {
        defaults.set("2000-01-01", forKey: "huddlepal.terms.acceptedVersion")
        XCTAssertFalse(TermsAcceptance(defaults: defaults).hasAcceptedCurrentVersion)
        XCTAssertEqual(OnboardingViewModel(deps: makeDeps()).step, .terms)
    }

    // MARK: Server record

    private func makeRecorder() -> (TermsAcceptance, MockTermsRecordService, AppSession, TermsRecorder) {
        let terms = TermsAcceptance(defaults: defaults)
        let service = MockTermsRecordService()
        let session = AppSession()
        return (terms, service, session, TermsRecorder(terms: terms, service: service, session: session, appVersion: "1.0 (10)"))
    }

    func testTheAgreementIsRecordedOnceForTheAccountThatSignsIn() async {
        let (terms, service, session, recorder) = makeRecorder()
        let tapped = Date(timeIntervalSince1970: 1_792_700_000)
        terms.accept(at: tapped)
        await recorder.refresh()
        XCTAssertEqual(service.records, [], "nobody is signed in yet")

        let ada = User(displayName: "Ada", avatarColorHex: "E5484D")
        session.currentUser = ada
        await recorder.refresh()
        await recorder.refresh()

        XCTAssertEqual(service.records, [.init(version: TermsOfService.version, acceptedAt: tapped, appVersion: "1.0 (10)")])
        XCTAssertEqual(terms.claimedBy, ada.id)
        XCTAssertTrue(TermsAcceptance(defaults: defaults).isRecorded, "remembered across launches")
    }

    func testARecordThatDidntReachTheServerIsRetried() async {
        let (terms, service, session, recorder) = makeRecorder()
        terms.accept(at: .now)
        session.currentUser = User(displayName: "Ada", avatarColorHex: "E5484D")
        service.failNext = true
        await recorder.refresh()
        XCTAssertFalse(terms.isRecorded)
        await recorder.refresh()
        XCTAssertEqual(service.records.count, 1)
        XCTAssertTrue(terms.isRecorded)
    }

    func testAnotherAccountOnTheSameDeviceMustAgreeForItself() async {
        let (terms, service, session, recorder) = makeRecorder()
        terms.accept(at: .now)
        session.currentUser = User(displayName: "Ada", avatarColorHex: "E5484D")
        await recorder.refresh()

        let ben = User(displayName: "Ben", avatarColorHex: "0091FF")
        session.currentUser = ben
        await recorder.refresh()
        XCTAssertFalse(terms.hasAcceptedCurrentVersion, "the Terms come back for Ben")
        XCTAssertEqual(service.records.count, 1, "Ada's agreement isn't recorded as Ben's")

        terms.accept(at: .now)
        await recorder.refresh()
        XCTAssertEqual(service.records.count, 2)
        XCTAssertEqual(terms.claimedBy, ben.id)
    }

    func testSigningBackInWithTheSameAccountDoesntAskAgain() async {
        let (terms, service, session, recorder) = makeRecorder()
        terms.accept(at: .now)
        let ada = User(displayName: "Ada", avatarColorHex: "E5484D")
        session.currentUser = ada
        await recorder.refresh()
        session.currentUser = nil
        session.currentUser = ada
        await recorder.refresh()
        XCTAssertTrue(terms.hasAcceptedCurrentVersion)
        XCTAssertEqual(service.records.count, 1)
    }

    func testANewVersionIsRecordedAgain() async {
        // Agreed to and recorded an older version.
        defaults.set("2000-01-01", forKey: "huddlepal.terms.acceptedVersion")
        defaults.set(Date(), forKey: "huddlepal.terms.acceptedAt")
        defaults.set(true, forKey: "huddlepal.terms.recorded")
        let (terms, service, session, recorder) = makeRecorder()
        XCTAssertTrue(terms.isRecorded)
        session.currentUser = User(displayName: "Ada", avatarColorHex: "E5484D")
        await recorder.refresh()
        XCTAssertEqual(service.records, [], "an old agreement records nothing")
        terms.accept(at: .now)
        await recorder.refresh()
        XCTAssertEqual(service.records.map(\.version), [TermsOfService.version])
    }

    func testOfflineModeKeepsNoRecorder() {
        XCTAssertNil(makeDeps().termsRecorder)
    }

    // MARK: Bundled text

    func testBundledTermsHaveEverySectionAndNoPlaceholders() throws {
        let terms = try XCTUnwrap(TermsOfService.current, "Legal/TermsOfService.md must be in the app bundle")
        XCTAssertEqual(terms.blocks.filter { $0.kind == .heading }.count, 17)
        let text = terms.blocks.map { String($0.text.characters) }.joined(separator: "\n")
        XCTAssertFalse(text.contains("["), "unfilled placeholder")
        XCTAssertFalse(text.contains("Drafting Notes"))
    }

    func testAddressesWrittenInTheTermsAreTappable() {
        let text = "See https://huddlepals.com/privacy, or write to help@example.com."
        let block = TermsOfService(markdown: text).blocks[0].text
        XCTAssertEqual(String(block.characters), text, "the wording is unchanged")
        XCTAssertEqual(block.runs.compactMap(\.link), [
            URL(string: "https://huddlepals.com/privacy")!,
            URL(string: "mailto:help@example.com")!,
        ], "trailing punctuation stays outside the links")
    }

    /// App Review 5.1.1(i) and 1.2: the Terms link the privacy policy and
    /// give the same contact address as Profile → About.
    func testTheBundledTermsLinkThePrivacyPolicyAndTheContactAddress() throws {
        let terms = try XCTUnwrap(TermsOfService.current)
        let links = Set(terms.blocks.flatMap { $0.text.runs.compactMap(\.link) })
        XCTAssertTrue(links.contains(AppLinks.privacyPolicy))
        XCTAssertTrue(links.contains(AppLinks.contact))
    }

    /// Editing the Terms without bumping `TermsOfService.version` would let
    /// existing users skip agreeing to the new text.
    func testVersionMatchesTheTermsLastUpdatedDate() throws {
        let terms = try XCTUnwrap(TermsOfService.current)
        let line = try XCTUnwrap(terms.blocks.lazy.map { String($0.text.characters) }.first { $0.hasPrefix("Last updated: ") })
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "MMMM d, yyyy"
        let date = try XCTUnwrap(parser.date(from: String(line.dropFirst("Last updated: ".count))))
        parser.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(parser.string(from: date), TermsOfService.version)
    }
}
