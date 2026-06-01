import Foundation

enum AIProviderAuthKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case accountLogin
    case apiKey
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accountLogin: "Account Login"
        case .apiKey: "API Key"
        case .local: "Local"
        }
    }
}

struct AIProviderDescriptor: Identifiable, Hashable {
    var id: AIProviderKind { kind }
    var kind: AIProviderKind
    var title: String
    var subtitle: String
    var logoAssetName: String?
    var supportedAuthKinds: [AIProviderAuthKind]
    var accountAuthMode: AIAuthMode?
    var apiKeyAuthMode: AIAuthMode?
    var localAuthMode: AIAuthMode?
    var defaultAuthMode: AIAuthMode
    var supportedCapabilities: Set<AIModelCapability>
    var accountLoginRequiresCLI: Bool
    var accountLoginUnsupportedMessage: String?

    func authMode(for kind: AIProviderAuthKind) -> AIAuthMode? {
        switch kind {
        case .accountLogin: accountAuthMode
        case .apiKey: apiKeyAuthMode
        case .local: localAuthMode
        }
    }

    func authKind(for mode: AIAuthMode) -> AIProviderAuthKind {
        if mode == accountAuthMode { return .accountLogin }
        if mode == apiKeyAuthMode { return .apiKey }
        if mode == localAuthMode { return .local }
        return supportedAuthKinds.first ?? .apiKey
    }
}

enum ProviderRegistry {
    static let providers: [AIProviderDescriptor] = [
        AIProviderDescriptor(
            kind: .openAI,
            title: "OpenAI",
            subtitle: "ChatGPT/Codex account login or OpenAI Platform API key.",
            logoAssetName: "ProviderOpenAI",
            supportedAuthKinds: [.accountLogin, .apiKey],
            accountAuthMode: .openAICodexCLI,
            apiKeyAuthMode: .apiKeyLegacy,
            localAuthMode: nil,
            defaultAuthMode: .openAICodexCLI,
            supportedCapabilities: [.chat, .translation, .realtime, .webSearch],
            accountLoginRequiresCLI: true,
            accountLoginUnsupportedMessage: nil
        ),
        AIProviderDescriptor(
            kind: .appleLocal,
            title: "Apple Local",
            subtitle: "On-device Apple Speech, Translation and Foundation Models when available.",
            logoAssetName: "ProviderApple",
            supportedAuthKinds: [.local],
            accountAuthMode: nil,
            apiKeyAuthMode: nil,
            localAuthMode: .appleLocal,
            defaultAuthMode: .appleLocal,
            supportedCapabilities: [.chat, .translation, .transcription],
            accountLoginRequiresCLI: false,
            accountLoginUnsupportedMessage: nil
        ),
        AIProviderDescriptor(
            kind: .googleGemini,
            title: "Google Gemini",
            subtitle: "Gemini models for chat and translation.",
            logoAssetName: "ProviderGoogle",
            supportedAuthKinds: [.accountLogin, .apiKey],
            accountAuthMode: .googleGeminiOAuth,
            apiKeyAuthMode: .googleGeminiAPIKey,
            localAuthMode: nil,
            defaultAuthMode: .googleGeminiAPIKey,
            supportedCapabilities: [.chat, .translation, .realtime],
            accountLoginRequiresCLI: true,
            accountLoginUnsupportedMessage: nil
        ),
        AIProviderDescriptor(
            kind: .anthropicClaude,
            title: "Anthropic Claude",
            subtitle: "Claude Code account login or Anthropic Console API key.",
            logoAssetName: "ProviderAnthropic",
            supportedAuthKinds: [.accountLogin, .apiKey],
            accountAuthMode: .anthropicClaudeOAuth,
            apiKeyAuthMode: .anthropicClaudeAPIKey,
            localAuthMode: nil,
            defaultAuthMode: .anthropicClaudeAPIKey,
            supportedCapabilities: [.chat, .translation],
            accountLoginRequiresCLI: true,
            accountLoginUnsupportedMessage: nil
        ),
        AIProviderDescriptor(
            kind: .perplexity,
            title: "Perplexity",
            subtitle: "Sonar models via Perplexity API key. OAuth is not available for this desktop flow.",
            logoAssetName: "ProviderPerplexity",
            supportedAuthKinds: [.apiKey],
            accountAuthMode: nil,
            apiKeyAuthMode: .perplexityAPIKey,
            localAuthMode: nil,
            defaultAuthMode: .perplexityAPIKey,
            supportedCapabilities: [.chat, .translation, .webSearch],
            accountLoginRequiresCLI: false,
            accountLoginUnsupportedMessage: nil
        )
    ]

    static var visibleProviders: [AIProviderDescriptor] {
        providers.filter { $0.kind != .appleFoundationModels }
    }

    static func descriptor(for kind: AIProviderKind) -> AIProviderDescriptor {
        let normalized = kind == .appleFoundationModels ? AIProviderKind.appleLocal : kind
        return providers.first { $0.kind == normalized } ?? providers.first { $0.kind == .openAI }!
    }

    static func authProviderType(for mode: AIAuthMode) -> AuthProviderType {
        switch mode {
        case .openAIAccountOAuth:
            return .openAIAccountOAuth
        case .openAICodexCLI:
            return .openAICodexCLI
        case .apiKeyLegacy:
            return .apiKeyLegacy
        case .googleGeminiOAuth:
            return .googleGeminiOAuth
        case .googleGeminiAPIKey:
            return .googleGeminiAPIKey
        case .anthropicClaudeOAuth:
            return .anthropicClaudeOAuth
        case .anthropicClaudeAPIKey:
            return .anthropicClaudeAPIKey
        case .perplexityOAuth:
            return .perplexityOAuth
        case .perplexityAPIKey:
            return .perplexityAPIKey
        case .appleLocal:
            return .appleLocal
        }
    }
}
