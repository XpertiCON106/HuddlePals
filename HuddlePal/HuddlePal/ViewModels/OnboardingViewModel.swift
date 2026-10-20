import AuthenticationServices
import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    enum Step: Equatable {
        case welcome
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
        let systemImage: String
        let title: String
        let message: String
    }

    static let cards = [
        Card(
            systemImage: "photo.on.rectangle.angled",
            title: "One photo a day",
            message: "Everyone in your huddle deposits a single photo, every day. Small, honest, real."
        ),
        Card(
            systemImage: "lock.fill",
            title: "Locked until you share",
            message: "Today's photos stay blurred until you deposit your own. Reciprocity, not lurking."
        ),
        Card(
            systemImage: "archivebox.fill",
            title: "Yours forever",
            message: "Every day becomes part of a permanent archive your group keeps together."
        ),
    ]

    private let deps: AppDependencies

    var step: Step = .welcome
    var pageIndex = 0

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

    // Profile step
    var displayName = ""
    var selectedColorHex = AvatarPalette.hexes[0]

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
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    init(deps: AppDependencies) {
        self.deps = deps
        // Authenticated on a previous run but never finished the profile.
        if deps.session.needsProfileSetup {
            step = .profile
        }
    }

    func advanceWelcome() {
        if isLastWelcomePage {
            step = .method
        } else {
            pageIndex += 1
        }
    }

    // MARK: - Email / phone code flow

    func sendCode() async {
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
        let nonce = AppleSignInNonce.random()
        currentNonce = nonce
        request.requestedScopes = [.fullName]
        request.nonce = AppleSignInNonce.sha256Hex(nonce)
    }

    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async {
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

    func completeProfile() async {
        guard canCompleteProfile else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let user = try await deps.auth.completeProfile(
                displayName: displayName,
                avatarColorHex: selectedColorHex
            )
            deps.session.needsProfileSetup = false
            await finishSignIn(user)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Shared

    private func handle(_ state: AuthSessionState) async {
        errorMessage = nil
        switch state {
        case .signedOut:
            break
        case .needsProfile(let suggestedName):
            if let suggestedName, displayName.isEmpty {
                displayName = suggestedName
            }
            step = .profile
            Haptics.light()
        case .signedIn(let user):
            await finishSignIn(user)
        }
    }

    /// Flips the session — RootView swaps to the main app the moment
    /// currentUser is set; the huddle list loads itself on appear.
    private func finishSignIn(_ user: User) async {
        Haptics.success()
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
