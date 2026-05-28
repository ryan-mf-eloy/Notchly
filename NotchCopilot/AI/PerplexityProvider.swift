import Foundation

@MainActor
struct PerplexityProvider: AIProvider {
    var name: EngineName { .perplexity }

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
        _ = try await authProvider.refreshIfNeeded()
        return .perplexityFallback
    }

    func validateConnection() async throws {
        _ = try await callChatCompletions(model: "sonar", prompt: "Reply OK.", maxTokens: 1)
    }

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let prompt = PromptBuilder().suggestedAnswerPrompt(context: context, question: privacyGuard.redact(question), options: options)
        let text = try await callChatCompletions(model: prefs.aiConfig.model, prompt: prompt, maxTokens: min(max(options.maxSentences * 90, 220), 520))
        return GeneratedAnswer(text: text, provider: .perplexity, usedCloud: true, usedRAG: !context.ragContext.isEmpty)
    }

    func generateRaw(request: LLMRawRequest) async throws -> LLMRawResponse {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let prompt = request.responseMode == .jsonObject
            ? "\(privacyGuard.redact(request.prompt))\n\nReturn exactly one valid JSON object and no surrounding prose."
            : privacyGuard.redact(request.prompt)
        let text = try await callChatCompletions(model: prefs.aiConfig.model, prompt: prompt, maxTokens: request.maxOutputTokens)
        return LLMRawResponse(text: text, provider: .perplexity, usedCloud: true)
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let prompt = privacyGuard.redact(PromptBuilder().summaryPrompt(meeting: meeting, transcript: transcript))
        let text = try await callChatCompletions(model: prefs.aiConfig.model, prompt: prompt, maxTokens: 900)
        return MeetingSummaryParser.parse(text, meetingId: meeting.id) ?? MeetingSummaryParser.fallback(meetingId: meeting.id, text: text)
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let target = SupportedLanguage.language(for: targetLanguage) ?? .englishUS
        let source = SupportedLanguage.displayName(for: segment.originalLanguage)
        return try await callChatCompletions(
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

    func embed(texts: [String]) async throws -> [[Double]] {
        []
    }

    private func callChatCompletions(model: String, prompt: String, maxTokens: Int) async throws -> String {
        let session = try await authProvider.refreshIfNeeded()
        guard session.provider == .perplexityAPIKey else { throw AuthError.unsupportedAccessMode }
        var request = URLRequest(url: URL(string: "https://api.perplexity.ai/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.addValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": prompt
                ]
            ],
            "max_tokens": maxTokens
        ])
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response)
        let decoded = try JSONDecoder().decode(PerplexityChatResponse.self, from: data)
        let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { throw AIProviderError.invalidResponse }
        return text
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

private struct PerplexityChatResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: Message
    }

    struct Message: Decodable {
        var content: String
    }
}
