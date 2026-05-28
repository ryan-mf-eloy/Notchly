import Foundation

struct OpenAIAccountOAuthConfiguration: Hashable {
    var isOfficialFlowEnabled: Bool
    var clientID: String?
    var authorizationEndpoint: URL?
    var tokenEndpoint: URL?
    var revokeEndpoint: URL?
    var userInfoEndpoint: URL?
    var redirectURI: URL
    var callbackScheme: String
    var scopes: [String]

    var canAttemptOfficialOAuth: Bool {
        isOfficialFlowEnabled &&
        clientID?.isEmpty == false &&
        authorizationEndpoint != nil &&
        tokenEndpoint != nil
    }

    static let disabled = OpenAIAccountOAuthConfiguration(
        isOfficialFlowEnabled: false,
        clientID: nil,
        authorizationEndpoint: nil,
        tokenEndpoint: nil,
        revokeEndpoint: nil,
        userInfoEndpoint: nil,
        redirectURI: URL(string: "notchcopilot://oauth/openai/callback")!,
        callbackScheme: "notchcopilot",
        scopes: []
    )

    static func fromBundle(_ bundle: Bundle = .main) -> OpenAIAccountOAuthConfiguration {
        let enabled = bundle.object(forInfoDictionaryKey: "OpenAIAccountOAuthEnabled") as? Bool ?? false
        let clientID = bundle.object(forInfoDictionaryKey: "OpenAIAccountOAuthClientID") as? String
        let authorizationEndpoint = (bundle.object(forInfoDictionaryKey: "OpenAIAccountOAuthAuthorizationEndpoint") as? String).flatMap(URL.init(string:))
        let tokenEndpoint = (bundle.object(forInfoDictionaryKey: "OpenAIAccountOAuthTokenEndpoint") as? String).flatMap(URL.init(string:))
        let revokeEndpoint = (bundle.object(forInfoDictionaryKey: "OpenAIAccountOAuthRevokeEndpoint") as? String).flatMap(URL.init(string:))
        let userInfoEndpoint = (bundle.object(forInfoDictionaryKey: "OpenAIAccountOAuthUserInfoEndpoint") as? String).flatMap(URL.init(string:))
        let scopes = (bundle.object(forInfoDictionaryKey: "OpenAIAccountOAuthScopes") as? String)?
            .split(separator: " ")
            .map(String.init) ?? []
        return OpenAIAccountOAuthConfiguration(
            isOfficialFlowEnabled: enabled,
            clientID: clientID,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            revokeEndpoint: revokeEndpoint,
            userInfoEndpoint: userInfoEndpoint,
            redirectURI: URL(string: "notchcopilot://oauth/openai/callback")!,
            callbackScheme: "notchcopilot",
            scopes: scopes
        )
    }
}

@MainActor
final class OpenAIAccountOAuthProvider: AuthProvider {
    private let configuration: OpenAIAccountOAuthConfiguration
    private let tokenStore: TokenStore
    private let sessionManager: OpenAIAuthSessionManager
    private let urlSession: URLSession
    private let refreshLeeway: TimeInterval = 60

    init(
        configuration: OpenAIAccountOAuthConfiguration,
        tokenStore: TokenStore,
        sessionManager: OpenAIAuthSessionManager,
        urlSession: URLSession = OpenAIURLSessionFactory.makeSecureSession()
    ) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.sessionManager = sessionManager
        self.urlSession = urlSession
    }

    var isAuthenticated: Bool {
        tokenStore.hasSession(provider: .openAIAccountOAuth)
    }

    var hasCachedSession: Bool {
        tokenStore.hasCachedSession(provider: .openAIAccountOAuth)
    }

    var isOfficialFlowAvailable: Bool {
        configuration.canAttemptOfficialOAuth
    }

    func signIn() async throws -> AuthSession {
        guard configuration.canAttemptOfficialOAuth else { throw AuthError.unsupportedOAuthFlow }
        guard let clientID = configuration.clientID,
              let authorizationEndpoint = configuration.authorizationEndpoint else {
            throw AuthError.missingConfiguration
        }

        let pkce = try OAuthPKCEGenerator.generatePair()
        let state = try OAuthPKCEGenerator.generateState()
        let authorizationURL = try makeAuthorizationURL(
            endpoint: authorizationEndpoint,
            clientID: clientID,
            scopes: configuration.scopes,
            redirectURI: configuration.redirectURI,
            state: state,
            challenge: pkce.challenge
        )
        let callbackURL = try await sessionManager.authenticate(
            authorizationURL: authorizationURL,
            callbackScheme: configuration.callbackScheme,
            expectedState: state
        )
        let code = try OpenAIAuthSessionManager.authorizationCode(from: callbackURL, expectedState: state)
        let token = try await exchangeCode(code, verifier: pkce.verifier)
        let metadata = try await fetchUserMetadata(accessToken: token.accessToken)
        let session = AuthSession(
            provider: .openAIAccountOAuth,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            accountEmail: metadata.email,
            accountId: metadata.id,
            scopes: token.scopes.isEmpty ? configuration.scopes : token.scopes
        )
        try tokenStore.saveSession(session)
        return session
    }

    func refreshIfNeeded() async throws -> AuthSession {
        guard let session = try tokenStore.loadSession(provider: .openAIAccountOAuth) else {
            throw AuthError.notAuthenticated
        }
        guard session.expires(within: refreshLeeway) else { return session }
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw AuthError.tokenRefreshUnavailable
        }
        guard configuration.canAttemptOfficialOAuth,
              let clientID = configuration.clientID,
              let tokenEndpoint = configuration.tokenEndpoint else {
            throw AuthError.unsupportedOAuthFlow
        }

        let token = try await refreshTokenRequest(refreshToken, clientID: clientID, tokenEndpoint: tokenEndpoint)
        let refreshed = AuthSession(
            provider: .openAIAccountOAuth,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? session.refreshToken,
            expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            accountEmail: session.accountEmail,
            accountId: session.accountId,
            scopes: token.scopes.isEmpty ? session.scopes : token.scopes
        )
        try tokenStore.saveSession(refreshed)
        return refreshed
    }

    func signOut() async throws {
        let session = try tokenStore.loadSession(provider: .openAIAccountOAuth)
        if let session, let revokeEndpoint = configuration.revokeEndpoint {
            try? await revoke(session: session, endpoint: revokeEndpoint)
        }
        try tokenStore.deleteSession(provider: .openAIAccountOAuth)
    }

    func currentSession() async throws -> AuthSession? {
        try tokenStore.loadSession(provider: .openAIAccountOAuth)
    }

    private func makeAuthorizationURL(
        endpoint: URL,
        clientID: String,
        scopes: [String],
        redirectURI: URL,
        state: String,
        challenge: String
    ) throws -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let url = components?.url else { throw AuthError.missingConfiguration }
        return url
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> OAuthTokenResponse {
        guard let clientID = configuration.clientID,
              let tokenEndpoint = configuration.tokenEndpoint else {
            throw AuthError.missingConfiguration
        }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "code_verifier": verifier
        ])
        return try await decodeTokenResponse(from: request)
    }

    private func refreshTokenRequest(_ refreshToken: String, clientID: String, tokenEndpoint: URL) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken
        ])
        return try await decodeTokenResponse(from: request)
    }

    private func decodeTokenResponse(from request: URLRequest) async throws -> OAuthTokenResponse {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw AuthError.invalidTokenResponse
        }
        return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    }

    private func fetchUserMetadata(accessToken: String) async throws -> OAuthUserMetadata {
        guard let userInfoEndpoint = configuration.userInfoEndpoint else {
            return OAuthUserMetadata(id: nil, email: nil)
        }
        var request = URLRequest(url: userInfoEndpoint)
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            return OAuthUserMetadata(id: nil, email: nil)
        }
        return (try? JSONDecoder().decode(OAuthUserMetadata.self, from: data)) ?? OAuthUserMetadata(id: nil, email: nil)
    }

    private func revoke(session: AuthSession, endpoint: URL) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "token": session.refreshToken ?? session.accessToken,
            "token_type_hint": session.refreshToken == nil ? "access_token" : "refresh_token"
        ])
        _ = try await urlSession.data(for: request)
    }

    private func formBody(_ values: [String: String]) -> Data {
        values
            .map { key, value in
                "\(formEscape(key))=\(formEscape(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let scope: String?

    var scopes: [String] {
        scope?.split(separator: " ").map(String.init) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

private struct OAuthUserMetadata: Decodable {
    let id: String?
    let email: String?
}
