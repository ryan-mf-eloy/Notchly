import Foundation

@MainActor
struct AnthropicClaudeProvider: AIProvider {
    var name: EngineName { .anthropicClaude }

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
        return prefs.aiConfig.cloudProcessingEnabled && !prefs.localOnlyMode && authProvider.isAuthenticated
    }

    func availableModelCatalog() async throws -> AIModelCatalog {
        let session = try await authProvider.refreshIfNeeded()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        addAuthHeaders(to: &request, session: session)
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response)
        let decoded = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
        return AIModelCatalog.anthropic(from: decoded.data.map(\.id))
    }

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let prompt = PromptBuilder().suggestedAnswerPrompt(context: context, question: privacyGuard.redact(question), options: options)
        let text = try await callMessages(model: prefs.aiConfig.model, prompt: prompt, maxTokens: min(max(options.maxSentences * 90, 220), 520))
        return GeneratedAnswer(text: text, provider: .anthropicClaude, usedCloud: true, usedRAG: !context.ragContext.isEmpty)
    }

    func generateRaw(request: LLMRawRequest) async throws -> LLMRawResponse {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let prompt = request.responseMode == .jsonObject
            ? "\(privacyGuard.redact(request.prompt))\n\nReturn exactly one valid JSON object and no surrounding prose."
            : privacyGuard.redact(request.prompt)
        let text = try await callMessages(model: prefs.aiConfig.model, prompt: prompt, maxTokens: request.maxOutputTokens)
        return LLMRawResponse(text: text, provider: .anthropicClaude, usedCloud: true)
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let prompt = privacyGuard.redact(PromptBuilder().summaryPrompt(meeting: meeting, transcript: transcript))
        let text = try await callMessages(model: prefs.aiConfig.model, prompt: prompt, maxTokens: 900)
        return MeetingSummaryParser.parse(text, meetingId: meeting.id) ?? MeetingSummaryParser.fallback(meetingId: meeting.id, text: text)
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let target = SupportedLanguage.language(for: targetLanguage) ?? .englishUS
        let source = SupportedLanguage.displayName(for: segment.originalLanguage)
        return try await callMessages(
            model: prefs.aiConfig.model(for: .translation),
            prompt: "Translate from \(source) to \(target.promptName). Return only the translation, no commentary:\n\(privacyGuard.redact(segment.text))",
            maxTokens: 600
        )
    }

    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem] {
        []
    }

    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight] {
        []
    }

    private func callMessages(model: String, prompt: String, maxTokens: Int) async throws -> String {
        let session = try await authProvider.refreshIfNeeded()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        addAuthHeaders(to: &request, session: session)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                [
                    "role": "user",
                    "content": prompt
                ]
            ]
        ])
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response)
        let decoded = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)
        let text = decoded.content
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIProviderError.invalidResponse }
        return text
    }

    private func addAuthHeaders(to request: inout URLRequest, session: AuthSession) {
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if session.provider == .anthropicClaudeOAuth {
            request.addValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.addValue(session.accessToken, forHTTPHeaderField: "x-api-key")
        }
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                throw AuthError.unsupportedAccessMode
            }
            throw AIProviderError.invalidResponse
        }
    }
}

private struct AnthropicModelsResponse: Decodable {
    var data: [Model]

    struct Model: Decodable {
        var id: String
    }
}

private struct AnthropicMessageResponse: Decodable {
    var content: [Content]

    struct Content: Decodable {
        var type: String?
        var text: String?
    }
}
