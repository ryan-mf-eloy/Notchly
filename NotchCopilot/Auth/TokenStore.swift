import Foundation

protocol TokenStore {
    func loadSession(provider: AuthProviderType) throws -> AuthSession?
    func saveSession(_ session: AuthSession) throws
    func deleteSession(provider: AuthProviderType) throws
    func deleteAllSessions() throws
    func hasSession(provider: AuthProviderType) -> Bool
    func hasCachedSession(provider: AuthProviderType) -> Bool
}

extension TokenStore {
    func hasSession(provider: AuthProviderType) -> Bool {
        ((try? loadSession(provider: provider)) ?? nil) != nil
    }

    func hasCachedSession(provider: AuthProviderType) -> Bool {
        hasSession(provider: provider)
    }
}

final class KeychainTokenStore: TokenStore {
    private let keychain: AppleKeychainService
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(keychain: AppleKeychainService) {
        self.keychain = keychain
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadSession(provider: AuthProviderType) throws -> AuthSession? {
        guard let value = try keychain.get(account: account(for: provider)) else { return nil }
        guard let data = value.data(using: .utf8) else { throw AuthError.invalidTokenResponse }
        return try decoder.decode(AuthSession.self, from: data)
    }

    func saveSession(_ session: AuthSession) throws {
        let data = try encoder.encode(session)
        guard let value = String(data: data, encoding: .utf8) else { throw AuthError.invalidTokenResponse }
        try keychain.set(value, account: account(for: session.provider))
    }

    func deleteSession(provider: AuthProviderType) throws {
        try keychain.delete(account: account(for: provider))
    }

    func deleteAllSessions() throws {
        for provider in AuthProviderType.allCases {
            try deleteSession(provider: provider)
        }
    }

    func hasSession(provider: AuthProviderType) -> Bool {
        keychain.contains(account: account(for: provider))
    }

    func hasCachedSession(provider: AuthProviderType) -> Bool {
        keychain.hasCachedData(account: account(for: provider))
    }

    private func account(for provider: AuthProviderType) -> String {
        "AUTH_SESSION_\(provider.rawValue)"
    }
}
