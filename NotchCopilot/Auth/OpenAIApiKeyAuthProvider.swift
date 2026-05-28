import Foundation

@MainActor
final class OpenAIApiKeyAuthProvider: AuthProvider {
    private let keychain: AppleKeychainService
    private let account = "OPENAI_API_KEY"

    init(keychain: AppleKeychainService) {
        self.keychain = keychain
    }

    var isAuthenticated: Bool {
        keychain.contains(account: account)
    }

    var hasCachedCredential: Bool {
        keychain.hasCachedData(account: account)
    }

    func signIn() async throws -> AuthSession {
        guard let session = try await currentSession() else { throw AuthError.notAuthenticated }
        return session
    }

    func refreshIfNeeded() async throws -> AuthSession {
        try await signIn()
    }

    func signOut() async throws {
        try keychain.delete(account: account)
    }

    func currentSession() async throws -> AuthSession? {
        guard let apiKey = try keychain.get(account: account), !apiKey.isEmpty else { return nil }
        return AuthSession(
            provider: .apiKeyLegacy,
            accessToken: apiKey,
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: []
        )
    }

    func setAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.delete(account: account)
        } else {
            try keychain.set(trimmed, account: account)
        }
    }
}
