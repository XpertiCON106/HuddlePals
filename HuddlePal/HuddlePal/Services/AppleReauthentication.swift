import AuthenticationServices
import UIKit

/// Asks Apple to confirm the signed-in person once more (Face ID or the
/// passcode, on Apple's own sheet) and hands back a fresh authorization
/// code. Account deletion sends it to the server, which trades it for the
/// app's Apple tokens and revokes them, as App Review guideline 5.1.1(v)
/// expects. A code works once, within minutes, so it's asked for at the
/// moment of deletion and never stored.
@MainActor
protocol AppleReauthenticating: AnyObject {
    /// Throws `CancellationError` when the person closes Apple's sheet.
    func authorizationCode() async throws -> String
}

enum AppleReauthError: LocalizedError {
    case noAuthorizationCode

    var errorDescription: String? { "Apple didn't return a usable credential. Try again." }
}

/// The real Apple sheet.
@MainActor
final class SystemAppleReauthenticator: NSObject, AppleReauthenticating {
    /// The request in flight. The controller is kept alive until it answers.
    private var pending: (controller: ASAuthorizationController, continuation: CheckedContinuation<ASAuthorization, Error>)?

    func authorizationCode() async throws -> String {
        // One sheet at a time (the delete button is disabled meanwhile).
        guard pending == nil else { throw CancellationError() }
        let authorization: ASAuthorization
        do {
            authorization = try await withCheckedThrowingContinuation { continuation in
                // No scopes: the name was shared at sign-up, and isn't needed.
                let controller = ASAuthorizationController(
                    authorizationRequests: [ASAuthorizationAppleIDProvider().createRequest()]
                )
                controller.delegate = self
                controller.presentationContextProvider = self
                pending = (controller, continuation)
                controller.performRequests()
            }
        } catch let error as ASAuthorizationError where error.code == .canceled {
            throw CancellationError()
        }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.authorizationCode,
              let code = String(data: data, encoding: .utf8) else {
            throw AppleReauthError.noAuthorizationCode
        }
        return code
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        let continuation = pending?.continuation
        pending = nil
        continuation?.resume(with: result)
    }
}

extension SystemAppleReauthenticator: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(error))
    }
}

extension SystemAppleReauthenticator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.lazy.compactMap(\.keyWindow).first { return window }
        return scenes.first.map { UIWindow(windowScene: $0) } ?? ASPresentationAnchor()
    }
}

/// Mock mode has no Apple Account to confirm: answers at once with a
/// placeholder code, which the mock auth service never sends anywhere.
@MainActor
final class MockAppleReauthenticator: AppleReauthenticating {
    static let code = "mock-apple-authorization-code"

    func authorizationCode() async throws -> String {
        if UITestHooks.appleUnavailable { throw ASAuthorizationError(.failed) }
        return Self.code
    }
}
