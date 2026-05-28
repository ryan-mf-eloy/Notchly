import Foundation

enum OpenAIURLSessionFactory {
    static func makeSecureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}

enum AuthProviderType: String, Codable, CaseIterable, Identifiable, Hashable {
    case openAIAccountOAuth
    case openAICodexCLI
    case apiKeyLegacy
    case googleGeminiOAuth
    case googleGeminiAPIKey
    case anthropicClaudeOAuth
    case anthropicClaudeAPIKey
    case perplexityOAuth
    case perplexityAPIKey
    case elevenLabsAPIKey
    case appleLocal

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = AuthProviderType(rawValue: rawValue) ?? .openAICodexCLI
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct AuthSession: Codable, Hashable, Sendable {
    let provider: AuthProviderType
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let accountEmail: String?
    let accountId: String?
    let scopes: [String]

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    func expires(within interval: TimeInterval) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(interval)
    }
}

enum AuthError: LocalizedError, Equatable {
    case notAuthenticated
    case unsupportedAccessMode
    case unsupportedOAuthFlow
    case missingConfiguration
    case invalidCallback
    case missingAuthorizationCode
    case stateMismatch
    case tokenRefreshUnavailable
    case invalidTokenResponse
    case authenticationSessionFailed
    case unsupportedProviderOAuth(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "No authenticated AI provider session is available."
        case .unsupportedAccessMode:
            "The current provider session is not authorized for API access."
        case .unsupportedOAuthFlow:
            "OpenAI OAuth subscription access is not currently available for this desktop integration. Use Local Mode or configure an officially supported provider."
        case .missingConfiguration:
            "OAuth is missing an official client configuration."
        case .invalidCallback:
            "The OAuth callback could not be validated."
        case .missingAuthorizationCode:
            "The OAuth callback did not include an authorization code."
        case .stateMismatch:
            "The OAuth callback state did not match the active sign-in request."
        case .tokenRefreshUnavailable:
            "The OpenAI session cannot be refreshed."
        case .invalidTokenResponse:
            "The OpenAI token endpoint returned an invalid response."
        case .authenticationSessionFailed:
            "The secure provider login session could not be started."
        case .unsupportedProviderOAuth(let provider):
            "\(provider) OAuth/account login is not currently available for this desktop integration. Use API Key, Local Mode, or configure an officially supported provider."
        }
    }
}

enum AIConnectionStatus: Equatable {
    case notConnected
    case connected(email: String?)
    case tokenExpired
    case unsupportedOAuthFlow
    case localOnlyMode

    var title: String {
        switch self {
        case .notConnected:
            "Not connected"
        case .connected(let email):
            if let email, !email.isEmpty {
                "Connected as \(email)"
            } else {
                "Connected"
            }
        case .tokenExpired:
            "Token expired"
        case .unsupportedOAuthFlow:
            "Unsupported OAuth flow"
        case .localOnlyMode:
            "Local only mode"
        }
    }
}
