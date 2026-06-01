import Foundation

@MainActor
struct GoogleGeminiProvider: AIProvider {
    var name: EngineName { .googleGemini }

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
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.addValue(session.accessToken, forHTTPHeaderField: "x-goog-api-key")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response)
        let decoded = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)
        let models = decoded.models.map {
            GeminiModelDescriptor(
                id: $0.normalizedID,
                displayName: $0.displayName ?? $0.normalizedID,
                description: $0.description,
                supportedGenerationMethods: $0.supportedGenerationMethods ?? []
            )
        }
        return AIModelCatalog.gemini(from: models)
    }

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let prompt = PromptBuilder().suggestedAnswerPrompt(context: context, question: privacyGuard.redact(question), options: options)
        let text = try await callGenerateContent(
            model: prefs.aiConfig.model,
            prompt: prompt,
            maxOutputTokens: min(max(options.maxSentences * 90, 220), 520)
        )
        return GeneratedAnswer(text: text, provider: .googleGemini, usedCloud: true, usedRAG: !context.ragContext.isEmpty)
    }

    func generateRaw(request: LLMRawRequest) async throws -> LLMRawResponse {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let text = try await callGenerateContent(
            model: prefs.aiConfig.model,
            prompt: privacyGuard.redact(request.prompt),
            maxOutputTokens: request.maxOutputTokens,
            responseMode: request.responseMode
        )
        return LLMRawResponse(text: text, provider: .googleGemini, usedCloud: true)
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let prompt = privacyGuard.redact(PromptBuilder().summaryPrompt(meeting: meeting, transcript: transcript))
        let text = try await callGenerateContent(model: prefs.aiConfig.model, prompt: prompt, maxOutputTokens: 900)
        return MeetingSummaryParser.parse(text, meetingId: meeting.id) ?? MeetingSummaryParser.fallback(meetingId: meeting.id, text: text)
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let target = SupportedLanguage.language(for: targetLanguage) ?? .englishUS
        let source = SupportedLanguage.displayName(for: segment.originalLanguage)
        return try await callGenerateContent(
            model: prefs.aiConfig.model(for: .translation),
            prompt: "Translate from \(source) to \(target.promptName). Return only the translation, no commentary:\n\(privacyGuard.redact(segment.text))",
            maxOutputTokens: 600
        )
    }

    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem] {
        []
    }

    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight] {
        []
    }

    private func callGenerateContent(model: String, prompt: String, maxOutputTokens: Int, responseMode: LLMRawResponseMode = .plainText) async throws -> String {
        let session = try await authProvider.refreshIfNeeded()
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.normalizedModelPath(model)):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.addValue(session.accessToken, forHTTPHeaderField: "x-goog-api-key")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        var generationConfig: [String: Any] = [
            "maxOutputTokens": maxOutputTokens
        ]
        if responseMode == .jsonObject {
            generationConfig["responseMimeType"] = "application/json"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": prompt]]
                ]
            ],
            "generationConfig": generationConfig
        ])
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response)
        let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
        let text = decoded.candidates?
            .flatMap { $0.content?.parts ?? [] }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func normalizedModelPath(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("models/") ? String(trimmed.dropFirst("models/".count)) : trimmed
    }
}

private struct GeminiModelsResponse: Decodable {
    var models: [GeminiModelRecord]
}

private struct GeminiModelRecord: Decodable {
    var name: String
    var displayName: String?
    var description: String?
    var supportedGenerationMethods: [String]?

    var normalizedID: String {
        name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
    }
}

private struct GeminiGenerateContentResponse: Decodable {
    var candidates: [Candidate]?

    struct Candidate: Decodable {
        var content: Content?
    }

    struct Content: Decodable {
        var parts: [Part]?
    }

    struct Part: Decodable {
        var text: String?
    }
}
