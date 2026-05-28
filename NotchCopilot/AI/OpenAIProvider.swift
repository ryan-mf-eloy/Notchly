import Foundation

@MainActor
struct OpenAIProvider: AIProvider {
    var name: EngineName { .openAI }

    private let authProvider: any AuthProvider
    private let privacyGuard: PrivacyGuard
    private let preferences: () -> AppPreferences
    private let urlSession: URLSession

    init(
        authProvider: any AuthProvider,
        privacyGuard: PrivacyGuard = PrivacyGuard(),
        urlSession: URLSession = OpenAIURLSessionFactory.makeSecureSession(),
        preferences: @escaping () -> AppPreferences
    ) {
        self.authProvider = authProvider
        self.privacyGuard = privacyGuard
        self.urlSession = urlSession
        self.preferences = preferences
    }

    var isConfiguredForCloud: Bool {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { return false }
        return authProvider.isAuthenticated
    }

    @discardableResult
    func prepareForLowLatencyUse() async throws -> AuthSession {
        try await authProvider.refreshIfNeeded()
    }

    func authorizationSession() async throws -> AuthSession {
        try await authProvider.refreshIfNeeded()
    }

    func preferencesSnapshot() -> AppPreferences {
        preferences()
    }

    func availableModelCatalog() async throws -> AIModelCatalog {
        let session = try await authProvider.refreshIfNeeded()
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.addValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, sessionProvider: session.provider)
        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return AIModelCatalog.openAI(from: decoded.data.map(\.id))
    }

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }

        let prompt = PromptBuilder().suggestedAnswerPrompt(context: context, question: privacyGuard.redact(question), options: options)
        let response = try await callResponses(
            model: prefs.aiConfig.model,
            prompt: prompt,
            maxOutputTokens: maxOutputTokens(for: options),
            enableWebSearch: options.enableWebSearch,
            responseMode: .plainText
        )
        let text = try response.outputTextValue()
        return GeneratedAnswer(
            text: text,
            provider: .openAI,
            usedCloud: true,
            usedRAG: !context.ragContext.isEmpty,
            sources: response.answerSources()
        )
    }

    func generateRaw(request: LLMRawRequest) async throws -> LLMRawResponse {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let response = try await callResponses(
            model: prefs.aiConfig.model,
            prompt: privacyGuard.redact(request.prompt),
            maxOutputTokens: request.maxOutputTokens,
            enableWebSearch: request.enableWebSearch,
            responseMode: request.responseMode
        )
        return LLMRawResponse(
            text: try response.outputTextValue(),
            provider: .openAI,
            usedCloud: true,
            sources: response.answerSources()
        )
    }

    func streamAnswer(
        context: AnswerContext,
        question: String,
        options: AnswerOptions
    ) async throws -> AsyncThrowingStream<GeneratedAnswerStreamEvent, Error> {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }

        let prompt = PromptBuilder().suggestedAnswerPrompt(context: context, question: privacyGuard.redact(question), options: options)
        let session = try await authProvider.refreshIfNeeded()
        let request = try makeResponsesRequest(
            model: prefs.aiConfig.model,
            prompt: prompt,
            stream: true,
            maxOutputTokens: maxOutputTokens(for: options),
            enableWebSearch: options.enableWebSearch,
            responseMode: .plainText,
            session: session
        )

        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let (bytes, response) = try await urlSession.bytes(for: request)
                    try validate(response: response, sessionProvider: session.provider)
                    var parser = OpenAIResponseStreamParser()
                    for try await line in bytes.lines {
                        for event in try parser.consume(line) {
                            continuation.yield(event)
                        }
                    }
                    for event in try parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }

        let prompt = PromptBuilder().summaryPrompt(meeting: meeting, transcript: transcript)
        let text = try await callResponsesAPI(model: prefs.aiConfig.model, prompt: privacyGuard.redact(prompt), maxOutputTokens: 900, enableWebSearch: false)
        return MeetingSummaryParser.parse(text, meetingId: meeting.id) ?? MeetingSummaryParser.fallback(meetingId: meeting.id, text: text)
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let target = SupportedLanguage.language(for: targetLanguage) ?? .englishUS
        let source = SupportedLanguage.displayName(for: segment.originalLanguage)
        return try await callResponsesAPI(
            model: prefs.aiConfig.model(for: .translation),
            prompt: "Translate from \(source) to \(target.promptName). Return only the translation, no commentary:\n\(privacyGuard.redact(segment.text))",
            maxOutputTokens: 600,
            enableWebSearch: false
        )
    }

    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem] {
        []
    }

    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight] {
        []
    }

    func embed(texts: [String]) async throws -> [[Double]] {
        []
    }

    private func callResponsesAPI(model: String, prompt: String, maxOutputTokens: Int, enableWebSearch: Bool) async throws -> String {
        try await callResponses(model: model, prompt: prompt, maxOutputTokens: maxOutputTokens, enableWebSearch: enableWebSearch, responseMode: .plainText).outputTextValue()
    }

    private func callResponses(model: String, prompt: String, maxOutputTokens: Int, enableWebSearch: Bool, responseMode: LLMRawResponseMode) async throws -> OpenAIResponse {
        let session = try await authProvider.refreshIfNeeded()
        let request = try makeResponsesRequest(
            model: model,
            prompt: prompt,
            stream: false,
            maxOutputTokens: maxOutputTokens,
            enableWebSearch: enableWebSearch,
            responseMode: responseMode,
            session: session
        )

        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, sessionProvider: session.provider)
        return try JSONDecoder().decode(OpenAIResponse.self, from: data)
    }

    private func makeResponsesRequest(
        model: String,
        prompt: String,
        stream: Bool,
        maxOutputTokens: Int,
        enableWebSearch: Bool = false,
        responseMode: LLMRawResponseMode = .plainText,
        session: AuthSession
    ) throws -> URLRequest {
        guard !session.accessToken.isEmpty else { throw AuthError.notAuthenticated }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 14 : 18
        request.addValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(UUID().uuidString, forHTTPHeaderField: "X-Client-Request-Id")
        var body: [String: Any] = [
            "model": model,
            "input": prompt,
            "store": false,
            "max_output_tokens": maxOutputTokens
        ]
        if stream {
            body["stream"] = true
        }
        if enableWebSearch {
            body["tools"] = [[
                "type": "web_search",
                "search_context_size": "low"
            ]]
            body["tool_choice"] = "auto"
            body["include"] = ["web_search_call.action.sources"]
        }
        if responseMode == .jsonObject {
            body["text"] = [
                "format": [
                    "type": "json_object"
                ]
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func validate(response: URLResponse, sessionProvider: AuthProviderType) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            if let http = response as? HTTPURLResponse,
               (http.statusCode == 401 || http.statusCode == 403),
               sessionProvider == .openAIAccountOAuth {
                throw AuthError.unsupportedAccessMode
            }
            throw AIProviderError.invalidResponse
        }
    }

    private func maxOutputTokens(for options: AnswerOptions) -> Int {
        min(max(options.maxSentences * 80, 180), 420)
    }
}

private struct OpenAIModelsResponse: Decodable {
    var data: [OpenAIModelRecord]
}

private struct OpenAIModelRecord: Decodable {
    var id: String
}

struct OpenAIResponseStreamParser {
    private var currentEvent: String?
    private var dataLines: [String] = []

    mutating func consume(_ line: String) throws -> [GeneratedAnswerStreamEvent] {
        if line.isEmpty {
            return try flush()
        }
        if line.hasPrefix("event:") {
            let emitted = dataLines.isEmpty ? [] : try flush()
            currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return emitted
        }
        if line.hasPrefix("data:") {
            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            dataLines.append(data)
            return []
        }
        return []
    }

    mutating func finish() throws -> [GeneratedAnswerStreamEvent] {
        try flush()
    }

    private mutating func flush() throws -> [GeneratedAnswerStreamEvent] {
        defer {
            currentEvent = nil
            dataLines.removeAll()
        }
        let data = dataLines.joined(separator: "\n")
        guard !data.isEmpty, data != "[DONE]" else {
            return data == "[DONE]" ? [.completed] : []
        }
        guard let payload = data.data(using: .utf8) else { return [] }
        let decoded = try JSONDecoder().decode(OpenAIStreamingResponse.self, from: payload)
        if let errorMessage = decoded.error?.message, !errorMessage.isEmpty {
            throw OpenAIStreamingError.providerError(errorMessage)
        }
        let type = decoded.type ?? currentEvent
        switch type {
        case "response.output_text.delta":
            return decoded.delta.map { [.delta($0)] } ?? []
        case "response.output_text.done":
            return []
        case "response.completed":
            return [.completed]
        case "response.failed", "error":
            throw OpenAIStreamingError.providerError(decoded.error?.message ?? "OpenAI streaming failed.")
        default:
            if let delta = decoded.delta, !delta.isEmpty {
                return [.delta(delta)]
            }
            return []
        }
    }
}

enum OpenAIStreamingError: LocalizedError, Equatable {
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .providerError(let message):
            message
        }
    }
}

private struct OpenAIStreamingResponse: Decodable {
    var type: String?
    var delta: String?
    var text: String?
    var error: OpenAIStreamingErrorPayload?
}

private struct OpenAIStreamingErrorPayload: Decodable {
    var message: String?
}

private struct OpenAIResponse: Decodable {
    var outputText: String?
    var output: [Output]?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }

    struct Output: Decodable {
        var type: String?
        var content: [Content]?
        var action: Action?
    }

    struct Content: Decodable {
        var text: String?
        var annotations: [Annotation]?
    }

    struct Annotation: Decodable {
        var type: String?
        var url: String?
        var title: String?
        var urlCitation: URLCitation?

        enum CodingKeys: String, CodingKey {
            case type
            case url
            case title
            case urlCitation = "url_citation"
        }
    }

    struct URLCitation: Decodable {
        var url: String?
        var title: String?
    }

    struct Action: Decodable {
        var type: String?
        var query: String?
        var sources: [Source]?
    }

    struct Source: Decodable {
        var type: String?
        var url: String?
        var title: String?
    }
}

private extension OpenAIResponse {
    func outputTextValue() throws -> String {
        if let outputText, !outputText.isEmpty {
            return outputText
        }
        let text = output?
            .flatMap { $0.content ?? [] }
            .compactMap(\.text)
            .joined(separator: "\n") ?? ""
        guard !text.isEmpty else { throw AIProviderError.invalidResponse }
        return text
    }

    func answerSources() -> [AnswerSource] {
        let annotationSources = output?
            .flatMap { $0.content ?? [] }
            .flatMap { $0.annotations ?? [] }
            .compactMap { annotation -> AnswerSource? in
                let url = annotation.url ?? annotation.urlCitation?.url
                let title = annotation.title ?? annotation.urlCitation?.title ?? url
                guard let title, !title.isEmpty else { return nil }
                return AnswerSource(type: .web, title: title, snippet: nil, reference: url)
            } ?? []
        let toolSources = output?
            .flatMap { $0.action?.sources ?? [] }
            .compactMap { source -> AnswerSource? in
                let reference = source.url
                let title = source.title ?? reference
                guard let title, !title.isEmpty else { return nil }
                return AnswerSource(type: .web, title: title, snippet: nil, reference: reference)
            } ?? []
        var seen: Set<AnswerSource> = []
        return (annotationSources + toolSources).filter { seen.insert($0).inserted }
    }
}
