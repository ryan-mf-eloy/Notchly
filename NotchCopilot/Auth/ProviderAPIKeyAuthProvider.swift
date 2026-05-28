import Foundation

@MainActor
final class ProviderAPIKeyAuthProvider: AuthProvider {
    private let keychain: AppleKeychainService
    private let providerType: AuthProviderType
    private let account: String

    init(providerType: AuthProviderType, keychain: AppleKeychainService, account: String? = nil) {
        self.providerType = providerType
        self.keychain = keychain
        self.account = account ?? "API_KEY_\(providerType.rawValue)"
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
            provider: providerType,
            accessToken: apiKey,
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: ["api-key"]
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

@MainActor
final class EphemeralAuthProvider: AuthProvider {
    private var session: AuthSession?

    init(session: AuthSession?) {
        self.session = session
    }

    var isAuthenticated: Bool {
        session != nil
    }

    func signIn() async throws -> AuthSession {
        guard let session else { throw AuthError.notAuthenticated }
        return session
    }

    func refreshIfNeeded() async throws -> AuthSession {
        try await signIn()
    }

    func signOut() async throws {
        session = nil
    }

    func currentSession() async throws -> AuthSession? {
        session
    }
}
