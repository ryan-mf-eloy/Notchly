import Foundation

struct AnswerContext: Sendable, Hashable {
    var meetingTitle: String
    var transcriptWindow: String
    var completeTranscript: String = ""
    var ragContext: String
    var userRole: String
    var responseStyle: ResponseStyle
    var languageCode: String?
    var retrievedSources: [AnswerSource] = []
    var shortTermMemory: MeetingShortTermMemory?
}

struct AnswerOptions: Sendable, Hashable {
    var maxSentences: Int = 3
    var allowCommitments: Bool = false
    var enableWebSearch: Bool = false
}

enum LLMRawResponseMode: Sendable, Hashable {
    case plainText
    case jsonObject
}

struct LLMRawRequest: Sendable, Hashable {
    var prompt: String
    var maxOutputTokens: Int = 700
    var responseMode: LLMRawResponseMode = .plainText
    var enableWebSearch: Bool = false
}

struct LLMRawResponse: Sendable, Hashable {
    var text: String
    var provider: EngineName
    var usedCloud: Bool
    var sources: [AnswerSource] = []
}

struct GeneratedAnswer: Sendable, Hashable {
    var text: String
    var provider: EngineName
    var usedCloud: Bool
    var usedRAG: Bool
    var sources: [AnswerSource] = []
}

enum GeneratedAnswerStreamEvent: Sendable, Hashable {
    case delta(String)
    case completed
}

struct Insight: Identifiable, Sendable, Hashable {
    var id = UUID()
    var title: String
    var detail: String
    var confidence: Double
}

@MainActor
protocol AIProvider {
    var name: EngineName { get }
    func generateRaw(request: LLMRawRequest) async throws -> LLMRawResponse
    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer
    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary
    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String
    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem]
    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight]
}

extension AIProvider {
    func generateRaw(request: LLMRawRequest) async throws -> LLMRawResponse {
        throw AIProviderError.providerUnavailable("This provider does not support raw Notchly generation.")
    }
}

enum AIProviderError: LocalizedError {
    case cloudDisabled
    case invalidResponse
    case providerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .cloudDisabled: "Cloud processing is disabled."
        case .invalidResponse: "The AI provider returned an invalid response."
        case .providerUnavailable(let reason): reason
        }
    }
}

struct UnavailableAIProvider: AIProvider {
    var name: EngineName { .unavailable }
    var reason: String

    init(reason: String = "Connect a real AI provider to generate answers.") {
        self.reason = reason
    }

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        throw AIProviderError.providerUnavailable(reason)
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        throw AIProviderError.providerUnavailable(reason)
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        throw AIProviderError.providerUnavailable(reason)
    }

    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem] {
        throw AIProviderError.providerUnavailable(reason)
    }

    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight] {
        throw AIProviderError.providerUnavailable(reason)
    }
}
