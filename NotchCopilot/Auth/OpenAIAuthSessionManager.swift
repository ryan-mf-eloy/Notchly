import AppKit
import AuthenticationServices
import Foundation

@MainActor
final class OpenAIAuthSessionManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var activeSession: ASWebAuthenticationSession?

    func authenticate(
        authorizationURL: URL,
        callbackScheme: String,
        expectedState: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authorizationURL, callbackURLScheme: callbackScheme) { callbackURL, error in
                Task { @MainActor in
                    self.activeSession = nil
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let callbackURL else {
                        continuation.resume(throwing: AuthError.invalidCallback)
                        return
                    }
                    do {
                        try Self.validate(callbackURL: callbackURL, expectedState: expectedState)
                        continuation.resume(returning: callbackURL)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            activeSession = session
            guard session.start() else {
                activeSession = nil
                continuation.resume(throwing: AuthError.authenticationSessionFailed)
                return
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        }
    }

    static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        try validate(callbackURL: callbackURL, expectedState: expectedState)
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AuthError.missingAuthorizationCode
        }
        return code
    }

    private static func validate(callbackURL: URL, expectedState: String) throws {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw AuthError.invalidCallback
        }
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        guard state == expectedState else { throw AuthError.stateMismatch }
    }
}
