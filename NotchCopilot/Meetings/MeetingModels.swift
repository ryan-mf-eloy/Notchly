import Foundation

enum MeetingSource: String, Codable, CaseIterable, Identifiable {
    case manual
    case calendar
    case activeApp
    case unknown

    var id: String { rawValue }
}

enum MeetingStatus: String, Codable, CaseIterable, Identifiable {
    case detected
    case listening
    case paused
    case summarizing
    case ended
    case failed

    var id: String { rawValue }
}

enum MeetingTranscriptionStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case idle
    case listening
    case hearingMic
    case hearingSystem
    case hearingMicAndSystem
    case restartingSource
    case micTooQuiet
    case systemAudioActive
    case permissionRequired
    case unavailable

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .idle: "Ready"
        case .listening: "Listening"
        case .hearingMic: "Hearing mic..."
        case .hearingSystem: "Hearing system audio..."
        case .hearingMicAndSystem: "Hearing mic + system audio..."
        case .restartingSource: "Restarting recognition..."
        case .micTooQuiet: "Mic too quiet"
        case .systemAudioActive: "System audio active"
        case .permissionRequired: "Speech permission required"
        case .unavailable: "Transcription unavailable"
        }
    }
}

enum CopilotASRStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case idle
    case listening
    case processing
    case pausedDuringMeeting
    case failed

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .idle: "Notchly ready"
        case .listening: "Listening"
        case .processing: "Processing"
        case .pausedDuringMeeting: "Notchly paused during recording"
        case .failed: "Notchly unavailable"
        }
    }
}

enum MeetingType: String, Codable, CaseIterable, Identifiable {
    case general
    case engineering
    case product
    case marketing
    case sales
    case interview
    case oneOnOne
    case incident
    case planning
    case retro
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oneOnOne: "1:1"
        default: rawValue.capitalized
        }
    }
}

enum ParticipantSource: String, Codable, CaseIterable, Identifiable {
    case diarization
    case calendar
    case manual
    case unknown

    var id: String { rawValue }
}

enum TranscriptAudioSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphone
    case system
    case mixed
    case cloud
    case unknown

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = TranscriptAudioSource(rawValue: rawValue) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .microphone: "Mic"
        case .system: "System"
        case .mixed: "Mixed"
        case .cloud: "Cloud"
        case .unknown: "Audio"
        }
    }

    var isUserSide: Bool {
        self == .microphone
    }
}

enum TranslationState: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case pending
    case drafting
    case draftTranslated
    case refining
    case translated
    case preserved
    case unavailable
    case failed

    var id: String { rawValue }
}

enum TranslationPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case draft
    case refinement
    case final
    case preserved

    var id: String { rawValue }
}

enum ActionPriority: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case urgent

    var id: String { rawValue }
}

enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAI
    case googleGemini
    case anthropicClaude
    case perplexity
    case appleLocal
    case appleFoundationModels

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "appleFoundationModels":
            self = .appleLocal
        case "mock":
            self = .openAI
        default:
            self = AIProviderKind(rawValue: rawValue) ?? .openAI
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AIAuthMode: String, Codable, CaseIterable, Identifiable {
    case openAIAccountOAuth
    case openAICodexCLI
    case apiKeyLegacy
    case googleGeminiOAuth
    case googleGeminiAPIKey
    case anthropicClaudeOAuth
    case anthropicClaudeAPIKey
    case perplexityOAuth
    case perplexityAPIKey
    case appleLocal

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "apiKey":
            self = .apiKeyLegacy
        case "oauthPlaceholder":
            self = .openAIAccountOAuth
        case "googleOAuth":
            self = .googleGeminiOAuth
        case "googleAPIKey":
            self = .googleGeminiAPIKey
        case "anthropicOAuth":
            self = .anthropicClaudeOAuth
        case "anthropicAPIKey":
            self = .anthropicClaudeAPIKey
        case "mock":
            self = .openAICodexCLI
        default:
            self = AIAuthMode(rawValue: rawValue) ?? .openAICodexCLI
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AIModelCapability: String, Codable, CaseIterable, Hashable {
    case chat
    case translation
    case realtime
    case transcription
    case embedding
    case webSearch
}

enum RealtimeTranscriptionProvider: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case elevenLabs
    case openAI
    case googleGemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .openAI: "OpenAI"
        case .googleGemini: "Google Gemini"
        }
    }

    var defaultModelID: String {
        switch self {
        case .elevenLabs:
            "scribe_v2_realtime"
        case .openAI:
            "gpt-realtime-whisper"
        case .googleGemini:
            "gemini-3.1-flash-live-preview"
        }
    }

    var usesSharedLLMAPIKey: Bool {
        switch self {
        case .openAI, .googleGemini:
            true
        case .elevenLabs:
            false
        }
    }

    var authProviderType: AuthProviderType {
        switch self {
        case .elevenLabs:
            .elevenLabsAPIKey
        case .openAI:
            .apiKeyLegacy
        case .googleGemini:
            .googleGeminiAPIKey
        }
    }

    var llmProviderKind: AIProviderKind? {
        switch self {
        case .openAI:
            .openAI
        case .googleGemini:
            .googleGemini
        case .elevenLabs:
            nil
        }
    }

    var llmAuthMode: AIAuthMode? {
        switch self {
        case .openAI:
            .apiKeyLegacy
        case .googleGemini:
            .googleGeminiAPIKey
        case .elevenLabs:
            nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = RealtimeTranscriptionProvider(rawValue: rawValue) ?? .elevenLabs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct AIModelOption: Codable, Hashable, Identifiable {
    var id: String
    var displayName: String
    var description: String?
    var capabilities: Set<AIModelCapability>

    init(id: String, displayName: String? = nil, description: String? = nil, capabilities: Set<AIModelCapability>) {
        self.id = id
        self.displayName = displayName ?? id
        self.description = description
        self.capabilities = capabilities
    }
}

struct AIModelCatalog: Codable, Hashable {
    var chatModels: [AIModelOption]
    var translationModels: [AIModelOption]
    var realtimeModels: [AIModelOption]
    var transcriptionModels: [AIModelOption]
    var embeddingModels: [AIModelOption]
    var source: String
    var isDynamic: Bool

    var allModels: [AIModelOption] {
        var seen = Set<String>()
        return (chatModels + translationModels + realtimeModels + transcriptionModels + embeddingModels).filter { option in
            seen.insert(option.id).inserted
        }
    }

    init(
        chatModels: [AIModelOption],
        translationModels: [AIModelOption]? = nil,
        realtimeModels: [AIModelOption],
        transcriptionModels: [AIModelOption],
        embeddingModels: [AIModelOption]? = nil,
        source: String,
        isDynamic: Bool
    ) {
        self.chatModels = chatModels
        self.translationModels = translationModels ?? chatModels.filter { $0.capabilities.contains(.translation) || $0.capabilities.contains(.chat) }
        self.realtimeModels = realtimeModels
        self.transcriptionModels = transcriptionModels
        self.embeddingModels = embeddingModels ?? []
        self.source = source
        self.isDynamic = isDynamic
    }

    static let local = AIModelCatalog(
        chatModels: [AIModelOption(id: "apple-local", displayName: "Apple Local", capabilities: [.chat, .translation])],
        translationModels: [AIModelOption(id: "apple-local", displayName: "Apple Local", capabilities: [.translation])],
        realtimeModels: [],
        transcriptionModels: [AIModelOption(id: "apple-speech", displayName: "Apple Speech", capabilities: [.transcription])],
        embeddingModels: [],
        source: "Local Apple",
        isDynamic: false
    )

    static let openAIFallback = AIModelCatalog(
        chatModels: [
            AIModelOption(id: "gpt-5-mini", capabilities: [.chat, .translation]),
            AIModelOption(id: "gpt-4o-mini", capabilities: [.chat, .translation]),
            AIModelOption(id: "gpt-4o", capabilities: [.chat, .translation])
        ],
        translationModels: [
            AIModelOption(id: "gpt-5-mini", capabilities: [.translation]),
            AIModelOption(id: "gpt-4o-mini", capabilities: [.translation]),
            AIModelOption(id: "gpt-4o", capabilities: [.translation])
        ],
        realtimeModels: [AIModelOption(id: "gpt-realtime", capabilities: [.realtime])],
        transcriptionModels: [
            AIModelOption(
                id: "gpt-realtime-whisper",
                displayName: "GPT Realtime Whisper",
                description: "OpenAI realtime transcription model",
                capabilities: [.transcription, .realtime]
            )
        ],
        embeddingModels: [AIModelOption(id: "text-embedding-3-small", capabilities: [.embedding])],
        source: "OpenAI fallback",
        isDynamic: false
    )

    static let codexFallback = AIModelCatalog(
        chatModels: [
            AIModelOption(id: "gpt-5.4", displayName: "GPT-5.4", capabilities: [.chat, .translation]),
            AIModelOption(id: "gpt-5.4-mini", displayName: "GPT-5.4 Mini", capabilities: [.chat, .translation])
        ],
        translationModels: [
            AIModelOption(id: "gpt-5.4", displayName: "GPT-5.4", capabilities: [.translation]),
            AIModelOption(id: "gpt-5.4-mini", displayName: "GPT-5.4 Mini", capabilities: [.translation])
        ],
        realtimeModels: [],
        transcriptionModels: [],
        embeddingModels: [],
        source: "Codex CLI fallback",
        isDynamic: false
    )

    static let geminiFallback = AIModelCatalog(
        chatModels: [
            AIModelOption(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", capabilities: [.chat, .translation]),
            AIModelOption(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", capabilities: [.chat, .translation]),
            AIModelOption(id: "gemini-2.5-flash-lite", displayName: "Gemini 2.5 Flash-Lite", capabilities: [.chat, .translation])
        ],
        translationModels: [
            AIModelOption(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", capabilities: [.translation]),
            AIModelOption(id: "gemini-2.5-flash-lite", displayName: "Gemini 2.5 Flash-Lite", capabilities: [.translation])
        ],
        realtimeModels: [
            AIModelOption(
                id: "gemini-3.1-flash-live-preview",
                displayName: "Gemini 3.1 Flash Live Preview",
                description: "Gemini Live input audio transcription preview",
                capabilities: [.transcription, .realtime]
            ),
            AIModelOption(
                id: "gemini-2.5-flash-live-preview",
                displayName: "Gemini 2.5 Flash Live Preview",
                description: "Gemini Live input audio transcription preview",
                capabilities: [.transcription, .realtime]
            )
        ],
        transcriptionModels: [
            AIModelOption(
                id: "gemini-3.1-flash-live-preview",
                displayName: "Gemini 3.1 Flash Live Preview",
                description: "Gemini Live input audio transcription preview",
                capabilities: [.transcription, .realtime]
            ),
            AIModelOption(
                id: "gemini-2.5-flash-live-preview",
                displayName: "Gemini 2.5 Flash Live Preview",
                description: "Gemini Live input audio transcription preview",
                capabilities: [.transcription, .realtime]
            )
        ],
        embeddingModels: [AIModelOption(id: "text-embedding-004", displayName: "Text Embedding 004", capabilities: [.embedding])],
        source: "Gemini fallback",
        isDynamic: false
    )

    static let anthropicFallback = AIModelCatalog(
        chatModels: [
            AIModelOption(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5", capabilities: [.chat, .translation]),
            AIModelOption(id: "claude-3-7-sonnet-latest", displayName: "Claude 3.7 Sonnet", capabilities: [.chat, .translation]),
            AIModelOption(id: "claude-3-5-haiku-latest", displayName: "Claude 3.5 Haiku", capabilities: [.chat, .translation])
        ],
        translationModels: [
            AIModelOption(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5", capabilities: [.translation]),
            AIModelOption(id: "claude-3-7-sonnet-latest", displayName: "Claude 3.7 Sonnet", capabilities: [.translation]),
            AIModelOption(id: "claude-3-5-haiku-latest", displayName: "Claude 3.5 Haiku", capabilities: [.translation])
        ],
        realtimeModels: [],
        transcriptionModels: [],
        embeddingModels: [],
        source: "Anthropic fallback",
        isDynamic: false
    )

    static let perplexityFallback = AIModelCatalog(
        chatModels: [
            AIModelOption(id: "sonar", displayName: "Sonar", capabilities: [.chat, .translation, .webSearch]),
            AIModelOption(id: "sonar-pro", displayName: "Sonar Pro", capabilities: [.chat, .translation, .webSearch]),
            AIModelOption(id: "sonar-reasoning", displayName: "Sonar Reasoning", capabilities: [.chat, .translation, .webSearch]),
            AIModelOption(id: "sonar-reasoning-pro", displayName: "Sonar Reasoning Pro", capabilities: [.chat, .translation, .webSearch]),
            AIModelOption(id: "sonar-deep-research", displayName: "Sonar Deep Research", capabilities: [.chat, .translation, .webSearch])
        ],
        translationModels: [
            AIModelOption(id: "sonar", displayName: "Sonar", capabilities: [.translation]),
            AIModelOption(id: "sonar-pro", displayName: "Sonar Pro", capabilities: [.translation])
        ],
        realtimeModels: [],
        transcriptionModels: [],
        embeddingModels: [],
        source: "Perplexity fallback",
        isDynamic: false
    )

    static let elevenLabsRealtime = AIModelCatalog(
        chatModels: [],
        translationModels: [],
        realtimeModels: [],
        transcriptionModels: [
            AIModelOption(
                id: "scribe_v2_realtime",
                displayName: "Scribe v2 Realtime",
                description: "ElevenLabs realtime speech-to-text",
                capabilities: [.transcription, .realtime]
            )
        ],
        embeddingModels: [],
        source: "ElevenLabs realtime fallback",
        isDynamic: false
    )

    static let openAIRealtimeTranscription = AIModelCatalog(
        chatModels: [],
        translationModels: [],
        realtimeModels: [],
        transcriptionModels: openAIFallback.transcriptionModels,
        embeddingModels: [],
        source: "OpenAI realtime fallback",
        isDynamic: false
    )

    static let geminiLiveRealtime = AIModelCatalog(
        chatModels: [],
        translationModels: [],
        realtimeModels: geminiFallback.realtimeModels,
        transcriptionModels: geminiFallback.transcriptionModels,
        embeddingModels: [],
        source: "Gemini Live fallback",
        isDynamic: false
    )

    static func openAI(from modelIds: [String], source: String = "OpenAI API") -> AIModelCatalog {
        let uniqueIds = Array(Set(modelIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        let options = uniqueIds.map { id in
            AIModelOption(id: id, capabilities: capabilities(forOpenAIModel: id))
        }
        let chat = options.filter { $0.capabilities.contains(.chat) }.sortedByModelName()
        let translation = chat.map { AIModelOption(id: $0.id, displayName: $0.displayName, description: $0.description, capabilities: [.translation]) }
        let realtime = options.filter { $0.capabilities.contains(.realtime) }.sortedByModelName()
        let transcription = options.filter { $0.capabilities.contains(.transcription) }
        let transcriptionWithRealtimeWhisper = (transcription + openAIFallback.transcriptionModels.filter { fallback in
            !transcription.contains(where: { $0.id == fallback.id })
        }).sortedByModelName()
        let embeddings = options.filter { $0.capabilities.contains(.embedding) }.sortedByModelName()
        return AIModelCatalog(
            chatModels: chat.isEmpty ? openAIFallback.chatModels : chat,
            translationModels: translation.isEmpty ? openAIFallback.translationModels : translation,
            realtimeModels: realtime,
            transcriptionModels: transcriptionWithRealtimeWhisper,
            embeddingModels: embeddings.isEmpty ? openAIFallback.embeddingModels : embeddings,
            source: source,
            isDynamic: true
        )
    }

    static func codex(from models: [AIModelOption], source: String = "Codex CLI") -> AIModelCatalog {
        let chatModels = models
            .filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { model in
                AIModelOption(
                    id: model.id,
                    displayName: model.displayName,
                    description: model.description,
                    capabilities: [.chat, .translation]
                )
            }
            .sortedByCodexPreference()
        guard !chatModels.isEmpty else { return codexFallback }
        return AIModelCatalog(
            chatModels: chatModels,
            translationModels: chatModels.map { AIModelOption(id: $0.id, displayName: $0.displayName, description: $0.description, capabilities: [.translation]) },
            realtimeModels: [],
            transcriptionModels: [],
            embeddingModels: [],
            source: source,
            isDynamic: true
        )
    }

    static func gemini(from models: [GeminiModelDescriptor], source: String = "Gemini API") -> AIModelCatalog {
        let options = models.map { model in
            AIModelOption(
                id: model.id,
                displayName: model.displayName,
                description: model.description,
                capabilities: capabilities(forGeminiModel: model)
            )
        }
        let chat = options.filter { $0.capabilities.contains(.chat) }.sortedByModelName()
        let translation = chat.map { AIModelOption(id: $0.id, displayName: $0.displayName, description: $0.description, capabilities: [.translation]) }
        let realtime = options.filter { $0.capabilities.contains(.realtime) }.sortedByModelName()
        let transcription = options.filter { $0.capabilities.contains(.transcription) }.sortedByModelName()
        let embeddings = options.filter { $0.capabilities.contains(.embedding) }.sortedByModelName()
        return AIModelCatalog(
            chatModels: chat.isEmpty ? geminiFallback.chatModels : chat,
            translationModels: translation.isEmpty ? geminiFallback.translationModels : translation,
            realtimeModels: realtime.isEmpty ? geminiFallback.realtimeModels : realtime,
            transcriptionModels: transcription.isEmpty ? geminiFallback.transcriptionModels : transcription,
            embeddingModels: embeddings.isEmpty ? geminiFallback.embeddingModels : embeddings,
            source: source,
            isDynamic: true
        )
    }

    static func anthropic(from modelIds: [String], source: String = "Anthropic API") -> AIModelCatalog {
        let uniqueIds = Array(Set(modelIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        let chat = uniqueIds
            .map { AIModelOption(id: $0, displayName: anthropicDisplayName(for: $0), capabilities: [.chat, .translation]) }
            .sortedByModelName()
        guard !chat.isEmpty else { return anthropicFallback }
        return AIModelCatalog(
            chatModels: chat,
            translationModels: chat.map { AIModelOption(id: $0.id, displayName: $0.displayName, description: $0.description, capabilities: [.translation]) },
            realtimeModels: [],
            transcriptionModels: [],
            embeddingModels: [],
            source: source,
            isDynamic: true
        )
    }

    private static func capabilities(forOpenAIModel id: String) -> Set<AIModelCapability> {
        let lower = id.lowercased()
        if lower == "gpt-realtime-whisper" {
            return [.transcription, .realtime]
        }
        if lower.contains("realtime") {
            return [.realtime]
        }
        if lower.contains("transcribe") { return [.transcription] }
        if lower.contains("embedding") {
            return [.embedding]
        }
        let excludedTextFamilies = ["embedding", "moderation", "tts", "audio", "image", "dall-e"]
        if excludedTextFamilies.contains(where: lower.contains) {
            return []
        }
        if lower.hasPrefix("gpt-") || lower.hasPrefix("o") || lower.contains("codex") {
            return [.chat, .translation]
        }
        return []
    }

    private static func capabilities(forGeminiModel model: GeminiModelDescriptor) -> Set<AIModelCapability> {
        let lower = model.id.lowercased()
        if lower.contains("live") || lower.contains("native-audio") || model.supportedGenerationMethods.contains("bidiGenerateContent") {
            return [.transcription, .realtime]
        }
        if lower.contains("embedding") || model.supportedGenerationMethods.contains("embedContent") || model.supportedGenerationMethods.contains("batchEmbedContents") {
            return [.embedding]
        }
        if model.supportedGenerationMethods.contains("generateContent") || lower.contains("gemini") {
            return [.chat, .translation]
        }
        return []
    }

    private static func anthropicDisplayName(for id: String) -> String {
        id
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

}

struct GeminiModelDescriptor: Hashable {
    var id: String
    var displayName: String
    var description: String?
    var supportedGenerationMethods: [String]
}

private extension Array where Element == AIModelOption {
    func sortedByModelName() -> [AIModelOption] {
        sorted { lhs, rhs in
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    func sortedByCodexPreference() -> [AIModelOption] {
        sorted { lhs, rhs in
            let preferred = ["gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex-spark"]
            let leftRank = preferred.firstIndex(of: lhs.id) ?? Int.max
            let rightRank = preferred.firstIndex(of: rhs.id) ?? Int.max
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

}

enum ProcessingMode: String, Codable, CaseIterable, Identifiable {
    case local
    case cloud
    case unavailable

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ProcessingMode(rawValue: rawValue) ?? .unavailable
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum EngineName: String, Codable, CaseIterable, Identifiable {
    case appleSpeech = "Apple Speech"
    case speechAnalyzer = "SpeechAnalyzer"
    case elevenLabs = "ElevenLabs Realtime STT"
    case openAIRealtimeTranscription = "OpenAI Realtime STT"
    case googleGeminiLiveTranscription = "Google Gemini Live STT"
    case appleNaturalLanguage = "Apple Natural Language"
    case appleTranslation = "Apple Translation"
    case appleFoundationModels = "Apple On-Device AI"
    case mlxLocalLLM = "MLX Local LLM"
    case openAI = "OpenAI Cloud AI"
    case googleGemini = "Google Gemini"
    case anthropicClaude = "Anthropic Claude"
    case perplexity = "Perplexity"
    case avFoundationScreenCaptureKit = "AVFoundation + ScreenCaptureKit"
    case accelerate = "Accelerate"
    case swiftUI = "SwiftUI"
    case unavailable = "Unavailable"

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = EngineName(rawValue: rawValue) ?? .unavailable
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum TranscriptionPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case draft
    case refined
    case final

    var id: String { rawValue }
}

enum TranscriptionEngineName: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleSpeech
    case speechAnalyzer
    case dictationTranscriber
    case whisperKit
    case elevenLabs
    case openAIRealtime
    case googleGeminiLive
    case unavailable

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = TranscriptionEngineName(rawValue: rawValue) ?? .unavailable
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct AudioSourceFrameRange: Codable, Hashable, Sendable {
    var start: Int64
    var end: Int64
}

struct TranscriptWordTimestamp: Codable, Hashable, Sendable {
    var word: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Double?
}

struct TranscriptAlternative: Codable, Hashable, Sendable {
    enum Source: String, Codable, CaseIterable, Identifiable, Sendable {
        case transcription
        case wordAlternative = "word_alternative"
        case speechAnalyzer = "speech_analyzer"
        case localRefiner = "local_refiner"
        case repair

        var id: String { rawValue }
    }

    var text: String
    var confidence: Double?
    var languageCode: String?
    var source: Source

    init(
        text: String,
        confidence: Double? = nil,
        languageCode: String? = nil,
        source: Source = .transcription
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.confidence = confidence
        self.languageCode = languageCode
        self.source = source
    }
}

enum TranscriptionRetentionReason: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleFinalRetained
    case appleDraftRetained
    case localRefinerAccepted
    case localRefinerRejected
    case lowEnergyRejected
    case hallucinationRejected
    case overlapDeduplicated
    case ambiguousAudioQueued

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = TranscriptionRetentionReason(rawValue: rawValue) ?? .appleFinalRetained
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct Participant: Identifiable, Codable, Hashable {
    var id: UUID
    var displayName: String
    var voiceFingerprintId: String?
    var confidence: Double
    var source: ParticipantSource

    init(id: UUID = UUID(), displayName: String, voiceFingerprintId: String? = nil, confidence: Double = 0.5, source: ParticipantSource = .unknown) {
        self.id = id
        self.displayName = displayName
        self.voiceFingerprintId = voiceFingerprintId
        self.confidence = confidence
        self.source = source
    }
}

struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var meetingId: UUID
    var speakerId: UUID?
    var speakerLabel: String
    var audioSource: TranscriptAudioSource
    var text: String
    var originalLanguage: String?
    var sourceLanguage: String?
    var targetLanguage: String?
    var draftTranslatedText: String?
    var translatedText: String?
    var translatedLanguage: String?
    var translationPhase: TranslationPhase?
    var translationConfidence: Double?
    var preservedTerms: [String]
    var translationState: TranslationState
    var transcriptionPhase: TranscriptionPhase?
    var transcriptionEngine: TranscriptionEngineName?
    var engineConfidence: Double?
    var languageConfidence: Double?
    var languageEvidenceSource: String?
    var languageDetectionWindowMs: Double?
    var languageSpanCodes: [String]
    var revisionOfSegmentId: UUID?
    var revisionNumber: Int
    var finalizedBy: TranscriptionEngineName?
    var latencyMs: Double?
    var sourceFrameRange: AudioSourceFrameRange?
    var audioEnergy: Double?
    var stitchingConfidence: Double?
    var retentionReason: TranscriptionRetentionReason?
    var wordTimestamps: [TranscriptWordTimestamp]
    var alternatives: [TranscriptAlternative]
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Double
    var isFinal: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        meetingId: UUID,
        speakerId: UUID? = nil,
        speakerLabel: String = "Speaker 1",
        audioSource: TranscriptAudioSource = .unknown,
        text: String,
        originalLanguage: String? = nil,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        draftTranslatedText: String? = nil,
        translatedText: String? = nil,
        translatedLanguage: String? = nil,
        translationPhase: TranslationPhase? = nil,
        translationConfidence: Double? = nil,
        preservedTerms: [String] = [],
        translationState: TranslationState = .none,
        transcriptionPhase: TranscriptionPhase? = nil,
        transcriptionEngine: TranscriptionEngineName? = nil,
        engineConfidence: Double? = nil,
        languageConfidence: Double? = nil,
        languageEvidenceSource: String? = nil,
        languageDetectionWindowMs: Double? = nil,
        languageSpanCodes: [String] = [],
        revisionOfSegmentId: UUID? = nil,
        revisionNumber: Int = 0,
        finalizedBy: TranscriptionEngineName? = nil,
        latencyMs: Double? = nil,
        sourceFrameRange: AudioSourceFrameRange? = nil,
        audioEnergy: Double? = nil,
        stitchingConfidence: Double? = nil,
        retentionReason: TranscriptionRetentionReason? = nil,
        wordTimestamps: [TranscriptWordTimestamp] = [],
        alternatives: [TranscriptAlternative] = [],
        startTime: TimeInterval = 0,
        endTime: TimeInterval = 0,
        confidence: Double = 0.8,
        isFinal: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.speakerId = speakerId
        self.speakerLabel = speakerLabel
        self.audioSource = audioSource
        self.text = text
        self.originalLanguage = originalLanguage
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.draftTranslatedText = draftTranslatedText
        self.translatedText = translatedText
        self.translatedLanguage = translatedLanguage
        self.translationPhase = translationPhase
        self.translationConfidence = translationConfidence
        self.preservedTerms = preservedTerms
        self.translationState = translationState
        self.transcriptionPhase = transcriptionPhase
        self.transcriptionEngine = transcriptionEngine
        self.engineConfidence = engineConfidence
        self.languageConfidence = languageConfidence
        self.languageEvidenceSource = languageEvidenceSource
        self.languageDetectionWindowMs = languageDetectionWindowMs
        self.languageSpanCodes = languageSpanCodes
        self.revisionOfSegmentId = revisionOfSegmentId
        self.revisionNumber = revisionNumber
        self.finalizedBy = finalizedBy
        self.latencyMs = latencyMs
        self.sourceFrameRange = sourceFrameRange
        self.audioEnergy = audioEnergy
        self.stitchingConfidence = stitchingConfidence
        self.retentionReason = retentionReason
        self.wordTimestamps = wordTimestamps
        self.alternatives = alternatives
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.isFinal = isFinal
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case meetingId
        case speakerId
        case speakerLabel
        case audioSource
        case text
        case originalLanguage
        case sourceLanguage
        case targetLanguage
        case draftTranslatedText
        case translatedText
        case translatedLanguage
        case translationPhase
        case translationConfidence
        case preservedTerms
        case translationState
        case transcriptionPhase
        case transcriptionEngine
        case engineConfidence
        case languageConfidence
        case languageEvidenceSource
        case languageDetectionWindowMs
        case languageSpanCodes
        case revisionOfSegmentId
        case revisionNumber
        case finalizedBy
        case latencyMs
        case sourceFrameRange
        case audioEnergy
        case stitchingConfidence
        case retentionReason
        case wordTimestamps
        case alternatives
        case startTime
        case endTime
        case confidence
        case isFinal
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        meetingId = try container.decode(UUID.self, forKey: .meetingId)
        speakerId = try container.decodeIfPresent(UUID.self, forKey: .speakerId)
        speakerLabel = try container.decodeIfPresent(String.self, forKey: .speakerLabel) ?? "Speaker 1"
        audioSource = try container.decodeIfPresent(TranscriptAudioSource.self, forKey: .audioSource) ?? .unknown
        text = try container.decode(String.self, forKey: .text)
        originalLanguage = try container.decodeIfPresent(String.self, forKey: .originalLanguage)
        sourceLanguage = try container.decodeIfPresent(String.self, forKey: .sourceLanguage)
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage)
        draftTranslatedText = try container.decodeIfPresent(String.self, forKey: .draftTranslatedText)
        translatedText = try container.decodeIfPresent(String.self, forKey: .translatedText)
        translatedLanguage = try container.decodeIfPresent(String.self, forKey: .translatedLanguage)
        translationPhase = try container.decodeIfPresent(TranslationPhase.self, forKey: .translationPhase)
        translationConfidence = try container.decodeIfPresent(Double.self, forKey: .translationConfidence)
        preservedTerms = try container.decodeIfPresent([String].self, forKey: .preservedTerms) ?? []
        translationState = try container.decodeIfPresent(TranslationState.self, forKey: .translationState) ?? (translatedText == nil ? .none : .translated)
        transcriptionPhase = try container.decodeIfPresent(TranscriptionPhase.self, forKey: .transcriptionPhase)
        transcriptionEngine = try container.decodeIfPresent(TranscriptionEngineName.self, forKey: .transcriptionEngine)
        engineConfidence = try container.decodeIfPresent(Double.self, forKey: .engineConfidence)
        languageConfidence = try container.decodeIfPresent(Double.self, forKey: .languageConfidence)
        languageEvidenceSource = try container.decodeIfPresent(String.self, forKey: .languageEvidenceSource)
        languageDetectionWindowMs = try container.decodeIfPresent(Double.self, forKey: .languageDetectionWindowMs)
        languageSpanCodes = try container.decodeIfPresent([String].self, forKey: .languageSpanCodes) ?? []
        revisionOfSegmentId = try container.decodeIfPresent(UUID.self, forKey: .revisionOfSegmentId)
        revisionNumber = try container.decodeIfPresent(Int.self, forKey: .revisionNumber) ?? 0
        finalizedBy = try container.decodeIfPresent(TranscriptionEngineName.self, forKey: .finalizedBy)
        latencyMs = try container.decodeIfPresent(Double.self, forKey: .latencyMs)
        sourceFrameRange = try container.decodeIfPresent(AudioSourceFrameRange.self, forKey: .sourceFrameRange)
        audioEnergy = try container.decodeIfPresent(Double.self, forKey: .audioEnergy)
        stitchingConfidence = try container.decodeIfPresent(Double.self, forKey: .stitchingConfidence)
        retentionReason = try container.decodeIfPresent(TranscriptionRetentionReason.self, forKey: .retentionReason)
        wordTimestamps = try container.decodeIfPresent([TranscriptWordTimestamp].self, forKey: .wordTimestamps) ?? []
        alternatives = try container.decodeIfPresent([TranscriptAlternative].self, forKey: .alternatives) ?? []
        startTime = try container.decodeIfPresent(TimeInterval.self, forKey: .startTime) ?? 0
        endTime = try container.decodeIfPresent(TimeInterval.self, forKey: .endTime) ?? 0
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.8
        isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct ActionItem: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var owner: String?
    var dueDate: Date?
    var priority: ActionPriority
    var sourceQuote: String?

    init(id: UUID = UUID(), title: String, owner: String? = nil, dueDate: Date? = nil, priority: ActionPriority = .medium, sourceQuote: String? = nil) {
        self.id = id
        self.title = title
        self.owner = owner
        self.dueDate = dueDate
        self.priority = priority
        self.sourceQuote = sourceQuote
    }
}

struct MeetingSummary: Identifiable, Codable, Hashable {
    var id: UUID
    var meetingId: UUID
    var executiveSummary: String
    var keyDecisions: [String]
    var actionItems: [ActionItem]
    var risks: [String]
    var openQuestions: [String]
    var strategicInsights: [String]
    var followUps: [String]
    var generatedAt: Date

    init(
        id: UUID = UUID(),
        meetingId: UUID,
        executiveSummary: String = "",
        keyDecisions: [String] = [],
        actionItems: [ActionItem] = [],
        risks: [String] = [],
        openQuestions: [String] = [],
        strategicInsights: [String] = [],
        followUps: [String] = [],
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.executiveSummary = executiveSummary
        self.keyDecisions = keyDecisions
        self.actionItems = actionItems
        self.risks = risks
        self.openQuestions = openQuestions
        self.strategicInsights = strategicInsights
        self.followUps = followUps
        self.generatedAt = generatedAt
    }
}

struct MeetingSession: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var source: MeetingSource
    var appName: String?
    var meetingURL: String?
    var startedAt: Date
    var endedAt: Date?
    var status: MeetingStatus
    var primaryLanguage: String?
    var participants: [Participant]
    var transcriptSegments: [TranscriptSegment]
    var audioFileURL: URL?
    var summary: MeetingSummary?
    var tags: [String]
    var meetingType: MeetingType
    var automationSourceAppName: String?
    var automationSourceBundleId: String?
    var wasAutoEnded: Bool

    init(
        id: UUID = UUID(),
        title: String,
        source: MeetingSource = .manual,
        appName: String? = nil,
        meetingURL: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        status: MeetingStatus = .detected,
        primaryLanguage: String? = nil,
        participants: [Participant] = [],
        transcriptSegments: [TranscriptSegment] = [],
        audioFileURL: URL? = nil,
        summary: MeetingSummary? = nil,
        tags: [String] = [],
        meetingType: MeetingType = .general,
        automationSourceAppName: String? = nil,
        automationSourceBundleId: String? = nil,
        wasAutoEnded: Bool = false
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.appName = appName
        self.meetingURL = meetingURL
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.primaryLanguage = primaryLanguage
        self.participants = participants
        self.transcriptSegments = transcriptSegments
        self.audioFileURL = audioFileURL
        self.summary = summary
        self.tags = tags
        self.meetingType = meetingType
        self.automationSourceAppName = automationSourceAppName
        self.automationSourceBundleId = automationSourceBundleId
        self.wasAutoEnded = wasAutoEnded
    }
}

struct AIProviderConfig: Codable, Hashable {
    var provider: AIProviderKind
    var authMode: AIAuthMode
    var model: String
    var translationModel: String?
    var realtimeModel: String?
    var realtimeTranscriptionProvider: RealtimeTranscriptionProvider?
    var realtimeTranscriptionModel: String?
    var embeddingModel: String?
    var translationEnabled: Bool
    var webSearchEnabled: Bool
    var ragEnabled: Bool
    var cloudProcessingEnabled: Bool
    var legacyAPIKeyAccessEnabled: Bool

    static let `default` = AIProviderConfig(
        provider: .openAI,
        authMode: .openAICodexCLI,
        model: "gpt-5-mini",
        translationModel: nil,
        realtimeModel: "gpt-realtime",
        realtimeTranscriptionProvider: .elevenLabs,
        realtimeTranscriptionModel: "scribe_v2_realtime",
        embeddingModel: nil,
        translationEnabled: false,
        webSearchEnabled: false,
        ragEnabled: true,
        cloudProcessingEnabled: false,
        legacyAPIKeyAccessEnabled: false
    )

    init(
        provider: AIProviderKind,
        authMode: AIAuthMode,
        model: String,
        translationModel: String? = nil,
        realtimeModel: String?,
        realtimeTranscriptionProvider: RealtimeTranscriptionProvider? = .elevenLabs,
        realtimeTranscriptionModel: String? = "scribe_v2_realtime",
        embeddingModel: String? = nil,
        translationEnabled: Bool,
        webSearchEnabled: Bool,
        ragEnabled: Bool,
        cloudProcessingEnabled: Bool,
        legacyAPIKeyAccessEnabled: Bool
    ) {
        self.provider = provider
        self.authMode = authMode
        self.model = model
        self.translationModel = translationModel
        self.realtimeModel = realtimeModel
        self.realtimeTranscriptionProvider = realtimeTranscriptionProvider
        self.realtimeTranscriptionModel = realtimeTranscriptionModel
        self.embeddingModel = embeddingModel
        self.translationEnabled = translationEnabled
        self.webSearchEnabled = webSearchEnabled
        self.ragEnabled = ragEnabled
        self.cloudProcessingEnabled = cloudProcessingEnabled
        self.legacyAPIKeyAccessEnabled = legacyAPIKeyAccessEnabled
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case authMode
        case model
        case translationModel
        case realtimeModel
        case realtimeTranscriptionProvider
        case realtimeTranscriptionModel
        case embeddingModel
        case translationEnabled
        case webSearchEnabled
        case ragEnabled
        case cloudProcessingEnabled
        case legacyAPIKeyAccessEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(AIProviderKind.self, forKey: .provider) ?? .openAI
        authMode = try container.decodeIfPresent(AIAuthMode.self, forKey: .authMode) ?? .openAICodexCLI
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "gpt-5-mini"
        translationModel = try container.decodeIfPresent(String.self, forKey: .translationModel)
        realtimeModel = try container.decodeIfPresent(String.self, forKey: .realtimeModel)
        realtimeTranscriptionProvider = try container.decodeIfPresent(RealtimeTranscriptionProvider.self, forKey: .realtimeTranscriptionProvider) ?? .elevenLabs
        realtimeTranscriptionModel = try container.decodeIfPresent(String.self, forKey: .realtimeTranscriptionModel) ?? "scribe_v2_realtime"
        embeddingModel = nil
        translationEnabled = try container.decodeIfPresent(Bool.self, forKey: .translationEnabled) ?? false
        webSearchEnabled = try container.decodeIfPresent(Bool.self, forKey: .webSearchEnabled) ?? false
        ragEnabled = try container.decodeIfPresent(Bool.self, forKey: .ragEnabled) ?? true
        cloudProcessingEnabled = try container.decodeIfPresent(Bool.self, forKey: .cloudProcessingEnabled) ?? false
        legacyAPIKeyAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .legacyAPIKeyAccessEnabled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(authMode, forKey: .authMode)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(translationModel, forKey: .translationModel)
        try container.encodeIfPresent(realtimeModel, forKey: .realtimeModel)
        try container.encodeIfPresent(realtimeTranscriptionProvider, forKey: .realtimeTranscriptionProvider)
        try container.encodeIfPresent(realtimeTranscriptionModel, forKey: .realtimeTranscriptionModel)
        try container.encode(translationEnabled, forKey: .translationEnabled)
        try container.encode(webSearchEnabled, forKey: .webSearchEnabled)
        try container.encode(ragEnabled, forKey: .ragEnabled)
        try container.encode(cloudProcessingEnabled, forKey: .cloudProcessingEnabled)
        try container.encode(legacyAPIKeyAccessEnabled, forKey: .legacyAPIKeyAccessEnabled)
    }

    func model(for capability: AIModelCapability) -> String {
        switch capability {
        case .translation:
            return translationModel ?? model
        case .realtime:
            return realtimeModel ?? model
        case .transcription:
            return realtimeTranscriptionModel ?? "apple-speech"
        case .embedding:
            if let embeddingModel { return embeddingModel }
            return provider == .googleGemini ? "text-embedding-004" : "text-embedding-3-small"
        case .chat, .webSearch:
            return model
        }
    }

}

extension AIProviderConfig {
    mutating func normalizeRealtimeTranscriptionDefaults() {
        realtimeTranscriptionProvider = realtimeTranscriptionProvider ?? .elevenLabs
        let provider = realtimeTranscriptionProvider ?? .elevenLabs
        let supportedModelIDs: Set<String>
        switch provider {
        case .elevenLabs:
            supportedModelIDs = Set(AIModelCatalog.elevenLabsRealtime.transcriptionModels.map(\.id))
        case .openAI:
            supportedModelIDs = Set(AIModelCatalog.openAIRealtimeTranscription.transcriptionModels.map(\.id))
        case .googleGemini:
            supportedModelIDs = Set(AIModelCatalog.geminiLiveRealtime.transcriptionModels.map(\.id))
        }
        if let realtimeTranscriptionModel, supportedModelIDs.contains(realtimeTranscriptionModel) {
            return
        }
        realtimeTranscriptionModel = provider.defaultModelID
    }
}
