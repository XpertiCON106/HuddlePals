import AuthenticationServices
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

@MainActor
@Observable
final class OnboardingViewModel {
    enum Step: Equatable {
        case terms
        case welcome
        case age
        case method
        case code
        case profile
    }

    enum Channel: String, CaseIterable, Identifiable {
        case email = "Email"
        case phone = "Phone"
        var id: String { rawValue }
    }

    struct Card: Identifiable {
        let id = UUID()
        let illustration: WelcomeIllustration.Kind
        let title: String
        let message: String
    }

    static let cards = [
        Card(
            illustration: .onePhotoADay,
            title: "One photo a day",
            message: "Everyone in your huddle deposits a single photo, every day. Small, honest, real."
        ),
        Card(
            illustration: .lockedUntilYouShare,
            title: "Locked until you share",
            message: "Today's photos stay blurred until you deposit your own."
        ),
        Card(
            illustration: .yoursForever,
            title: "Yours forever",
            message: "Every day becomes part of a permanent archive your group keeps together."
        ),
    ]

    private let deps: AppDependencies

    var step: Step = .welcome
    var pageIndex = 0
    /// Where tapping Agree on the Terms leads.
    private var stepAfterTerms: Step = .welcome
    /// Agree stays disabled until the reader scrolls to the end of the
    /// Terms, every time the Terms are shown.
    private(set) var hasReachedEndOfTerms = false

    // Method step
    var channel: Channel = .email
    var emailInput = ""
    var phoneInput = ""

    // Code step
    var codeInput = ""
    private(set) var destination: OTPDestination?
    private(set) var resendSecondsRemaining = 0
    /// Wrong-code guard: after 5 misses, verification locks until a fresh
    /// code is requested.
    private(set) var failedAttempts = 0
    private(set) var attemptsExhausted = false
    private var cooldownTask: Task<Void, Never>?

    static let maxCodeAttempts = 5
    /// Matches GoTrue's default one-request-per-60s OTP rate limit; a
    /// shorter cooldown only lets the user hit the server's refusal.
    static let resendCooldownSeconds = 60

    // Profile step: the same profile Profile edits, plus a birthday
    var displayName = ""
    var selectedColorHex = AvatarPalette.hexes[0]
    var bio = ""
    private(set) var birthday: Birthday?
    /// Downscaled, in memory until the profile is made; the first is the
    /// profile picture.
    private(set) var photos: [Data] = []
    var photoItems: [PhotosPickerItem] = [] {
        didSet { Task { await addPickedPhotos() } }
    }
    private(set) var isProcessingPhotos = false
    /// Under the minimum age: nothing goes past this step, and the birthday
    /// can't be changed to get past it.
    private(set) var isUnderage = false
    /// Made already (a later step failed): a retry picks up from there.
    private var createdUser: User?
    private var uploadedPhotoPaths: [String] = []

    private(set) var isWorking = false
    var errorMessage: String?

    /// Raw nonce for the in-flight Apple attempt (its SHA-256 went to Apple).
    private var currentNonce: String?

    var isMockBackend: Bool { !deps.isLive }
    var mockCodeHint: String? { deps.isLive ? nil : MockAuthService.mockCode }

    var isLastWelcomePage: Bool { pageIndex >= Self.cards.count - 1 }

    var canSendCode: Bool {
        guard !isWorking else { return false }
        switch channel {
        case .email: return AuthValidation.normalizedEmail(emailInput) != nil
        case .phone: return AuthValidation.normalizedPhone(phoneInput) != nil
        }
    }

    /// Digits in the code that was just sent (the backend decides: 6–10).
    var codeLength: Int {
        destination.map(deps.auth.codeLength(for:)) ?? BackendConfig.defaultCodeLength
    }

    var canVerify: Bool { codeInput.count == codeLength && !isWorking && !attemptsExhausted }

    var canCompleteProfile: Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...AuthValidation.displayNameLimit).contains(name.serverLength)
            && bio.serverLength <= AuthValidation.bioLimit
            && birthday != nil && !isUnderage
            && !isWorking && !isProcessingPhotos
    }

    var canAddPhotos: Bool { photos.count < AuthValidation.maxProfilePhotos }

    init(deps: AppDependencies) {
        self.deps = deps
        birthday = deps.ageScreening.birthday
        isUnderage = deps.ageScreening.isBlocked()
        if isUnderage {
            step = .age
            return
        }
        // Authenticated on a previous run but never finished the profile.
        let start: Step = deps.session.needsProfileSetup
            ? (deps.ageScreening.hasEligibleBirthday() ? .profile : .age)
            : .welcome
        let signedIn = deps.session.currentUser != nil || deps.session.needsProfileSetup
        if signedIn, !deps.terms.hasAcceptedCurrentVersion {
            // Signed in, but not agreed to these Terms (new ones, or the
            // sign-up stopped there): they come first.
            stepAfterTerms = start
            step = .terms
        } else {
            step = isUnderage ? .age : start
        }
    }

    /// The welcome cards lead to sign-in; the Terms come right after it.
    func advanceWelcome() {
        guard isLastWelcomePage else {
            pageIndex += 1
            return
        }
        step = .age
    }

    /// No authentication or profile collection starts until this date is
    /// eligible. The server confirms it again when the profile activates.
    func continueAfterAgeCheck(_ picked: Birthday) {
        birthdayPicked(picked)
        guard !isUnderage, deps.ageScreening.hasEligibleBirthday() else { return }
        if deps.session.needsProfileSetup {
            afterSignIn(go: .profile)
        } else {
            step = .method
        }
    }

    private func canStartSignIn() -> Bool {
        guard deps.ageScreening.hasEligibleBirthday() else {
            isUnderage = deps.ageScreening.isBlocked()
            step = .age
            return false
        }
        return true
    }

    // MARK: - Terms of Service

    /// Called repeatedly while the end of the Terms is on screen.
    func termsReachedEnd() {
        guard !hasReachedEndOfTerms else { return }
        hasReachedEndOfTerms = true
    }

    func agreeToTerms() {
        guard hasReachedEndOfTerms else { return }
        deps.terms.accept(at: .now)
        step = stepAfterTerms
        Haptics.light()
    }

    /// Someone is already signed in here: the Terms changed since they
    /// agreed, or their profile isn't finished. The Terms screen lets them
    /// sign out, to sign in with a different account.
    var isSignedIn: Bool {
        deps.session.currentUser != nil || deps.session.needsProfileSetup
    }

    var signedInName: String? { deps.session.currentUser?.displayName }

    /// Signs out, back to the first welcome card: signing in again (with
    /// any account) brings the Terms back, to be read to the end again.
    func signOut() async {
        await deps.signOut()
        hasReachedEndOfTerms = false
        pageIndex = 0
        stepAfterTerms = .welcome
        step = .welcome
    }

    /// Not agreeing: nothing goes past the Terms, so this signs out.
    func declineTerms() async {
        await signOut()
    }

    // MARK: - Email / phone code flow

    func sendCode() async {
        guard canStartSignIn() else { return }
        errorMessage = nil
        let target: OTPDestination
        switch channel {
        case .email:
            guard let email = AuthValidation.normalizedEmail(emailInput) else {
                errorMessage = AuthError.invalidEmail.errorDescription
                return
            }
            target = .email(email)
        case .phone:
            guard let phone = AuthValidation.normalizedPhone(phoneInput) else {
                errorMessage = AuthError.invalidPhone.errorDescription
                return
            }
            target = .phone(phone)
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await deps.auth.requestCode(to: target)
            destination = target
            codeInput = ""
            step = .code
            startResendCooldown()
            Haptics.light()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resendCode() async {
        guard let destination, resendSecondsRemaining == 0, !isWorking else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await deps.auth.requestCode(to: destination)
            codeInput = ""
            failedAttempts = 0
            attemptsExhausted = false
            startResendCooldown()
            Haptics.light()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func verify() async {
        guard let destination, canVerify else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let state = try await deps.auth.verifyCode(codeInput, for: destination)
            failedAttempts = 0
            await handle(state)
        } catch {
            codeInput = ""
            failedAttempts += 1
            if failedAttempts >= Self.maxCodeAttempts {
                attemptsExhausted = true
                errorMessage = "Too many attempts. Request a fresh code to continue."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func backToMethod() {
        step = .method
        codeInput = ""
        errorMessage = nil
        failedAttempts = 0
        attemptsExhausted = false
        cooldownTask?.cancel()
        resendSecondsRemaining = 0
    }

    // MARK: - Sign in with Apple

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        guard canStartSignIn() else { return }
        let nonce = AppleSignInNonce.random()
        currentNonce = nonce
        request.requestedScopes = [.fullName]
        request.nonce = AppleSignInNonce.sha256Hex(nonce)
    }

    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async {
        guard canStartSignIn() else { return }
        switch result {
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return // user dismissed the sheet — not an error
            }
            errorMessage = error.localizedDescription
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                errorMessage = "Apple didn't return a usable credential. Try again."
                return
            }
            // Apple shares the name only on the very first authorization.
            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            errorMessage = nil
            isWorking = true
            defer { isWorking = false }
            do {
                let state = try await deps.auth.signInWithApple(
                    idToken: idToken,
                    nonce: nonce,
                    suggestedName: name.isEmpty ? nil : name
                )
                await handle(state)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Mock-mode stand-in for the real Apple sheet.
    func mockAppleSignIn() async {
        guard canStartSignIn() else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let state = try await deps.auth.signInWithApple(
                idToken: "mock", nonce: "mock", suggestedName: nil
            )
            await handle(state)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Profile step

    func birthdayPicked(_ picked: Birthday) {
        let calendar = Birthday.eligibilityCalendar
        guard !isUnderage, picked.isValid,
              picked.date(in: calendar) <= calendar.startOfDay(for: .now) else { return }
        birthday = picked
        _ = deps.ageScreening.submit(picked)
        isUnderage = deps.ageScreening.isBlocked()
        if isUnderage { Haptics.light() }
    }

    /// Adds already downscaled JPEG bytes (the picker's, or a test's).
    func addPhotoData(_ data: Data) {
        guard canAddPhotos, !data.isEmpty else { return }
        photos.append(data)
    }

    func removePhoto(at index: Int) {
        guard photos.indices.contains(index), !isWorking else { return }
        photos.remove(at: index)
        // Uploads from a failed try are for the old set: start over.
        uploadedPhotoPaths = []
        Haptics.light()
    }

    private func addPickedPhotos() async {
        guard !photoItems.isEmpty else { return }
        let items = photoItems
        photoItems = []
        isProcessingPhotos = true
        defer { isProcessingPhotos = false }
        for item in items {
            guard canAddPhotos,
                  let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let scaled = ImageDownscaler.jpegData(from: image, maxDimension: ImageDownscaler.avatarMaxDimension)
            else { continue }
            addPhotoData(scaled)
        }
    }

    /// Makes the profile, then saves the birthday, the photos and the bio.
    /// A failed step can be retried without making the profile twice or
    /// uploading the same photos again.
    func completeProfile() async {
        guard canCompleteProfile, let birthday else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let isRetry = createdUser != nil
            let user: User
            if let createdUser {
                user = createdUser
            } else {
                user = try await deps.auth.completeProfile(
                    displayName: displayName, avatarColorHex: selectedColorHex, birthday: birthday
                )
                createdUser = user
            }
            let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            if isRetry || !photos.isEmpty || !trimmedBio.isEmpty {
                for data in photos.dropFirst(uploadedPhotoPaths.count) {
                    let path = try await deps.mediaService.saveImageData(
                        data,
                        preferredName: "avatars/\(user.id.uuidString.lowercased())/\(UUID().uuidString).jpg"
                    )
                    uploadedPhotoPaths.append(path)
                }
                try await deps.auth.updateProfile(
                    user: user,
                    displayName: displayName,
                    avatarColorHex: selectedColorHex,
                    bio: trimmedBio,
                    photoPaths: uploadedPhotoPaths
                )
            }
            // Activation has recorded the birthday atomically. Re-read auth
            // state so a retry cannot expose an unconfirmed account.
            if case .signedIn(let confirmed) = try await deps.auth.currentState() {
                deps.session.needsProfileSetup = false
                await finishSignIn(confirmed)
            } else {
                throw AuthError.notAuthenticated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Under the minimum age: signs out of the account just made, and back
    /// to the start. The age stays as given.
    func signOutUnderage() async {
        createdUser = nil
        uploadedPhotoPaths = []
        await signOut()
    }

    // MARK: - Shared

    private func handle(_ state: AuthSessionState) async {
        errorMessage = nil
        switch state {
        case .signedOut:
            break
        case .needsProfile(let suggestedName):
            deps.session.needsProfileSetup = true
            if let suggestedName, displayName.isEmpty {
                displayName = suggestedName
            }
            // A new account agrees for itself: an agreement this device has
            // already tied to an account is someone else's.
            if deps.terms.claimedBy != nil { deps.terms.withdraw() }
            afterSignIn(go: .profile)
            Haptics.light()
        case .needsBirthday(let user):
            deps.session.pendingBirthdayUser = user
            deps.session.currentUser = nil
        case .signedIn(let user):
            if let claimant = deps.terms.claimedBy, claimant != user.id { deps.terms.withdraw() }
            // Not agreed yet: the Terms show (RootView keeps onboarding up
            // until Agree), then the app. Agreed: straight in.
            if !deps.terms.hasAcceptedCurrentVersion { afterSignIn(go: .welcome) }
            await finishSignIn(user)
        }
    }

    /// Right after sign-in: the Terms if they aren't agreed to yet, then `next`.
    private func afterSignIn(go next: Step) {
        if deps.terms.hasAcceptedCurrentVersion {
            step = next
        } else {
            hasReachedEndOfTerms = false
            stepAfterTerms = next
            step = .terms
        }
    }

    /// Flips the session — RootView swaps to the main app the moment
    /// currentUser is set; the huddle list loads itself on appear.
    private func finishSignIn(_ user: User) async {
        Haptics.success()
        deps.ageScreening.clearPendingBirthday()
        deps.session.pendingBirthdayUser = nil
        deps.session.currentUser = user
        deps.session.blockedUserIDs = (try? await deps.moderationService.blockedUserIDs()) ?? []
    }

    private func startResendCooldown() {
        cooldownTask?.cancel()
        resendSecondsRemaining = Self.resendCooldownSeconds
        cooldownTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.resendSecondsRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.resendSecondsRemaining -= 1
            }
        }
    }
}
