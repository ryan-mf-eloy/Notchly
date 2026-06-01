import Foundation

@MainActor
struct ProviderCLIAIProvider: AIProvider {
    let configuration: ProviderCLIConfiguration
    var name: EngineName {
        switch configuration {
        case .gemini: .googleGemini
        case .claude: .anthropicClaude
        }
    }

    private let authProvider: ProviderCLIAuthProvider
    private let runner: ProviderCLICommandRunning
    private let privacyGuard: PrivacyGuard
    private let preferences: () -> AppPreferences

    init(
        configuration: ProviderCLIConfiguration,
        authProvider: ProviderCLIAuthProvider,
        runner: ProviderCLICommandRunning,
        privacyGuard: PrivacyGuard = PrivacyGuard(),
        preferences: @escaping () -> AppPreferences
    ) {
        self.configuration = configuration
        self.authProvider = authProvider
        self.runner = runner
        self.privacyGuard = privacyGuard
        self.preferences = preferences
    }

    var isConfiguredForCloud: Bool {
        let prefs = preferences()
        return prefs.aiConfig.cloudProcessingEnabled && !prefs.localOnlyMode && authProvider.isAuthenticated
    }

    func availableModelCatalog() -> AIModelCatalog {
        switch configuration {
        case .gemini: return .geminiFallback
        case .claude: return .anthropicFallback
        }
    }

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let prompt = PromptBuilder().suggestedAnswerPrompt(context: context, question: privacyGuard.redact(question), options: options)
        let text = try await runPrompt(prompt, model: prefs.aiConfig.model)
        return GeneratedAnswer(text: text, provider: name, usedCloud: true, usedRAG: !context.ragContext.isEmpty)
    }

    func generateRaw(request: LLMRawRequest) async throws -> LLMRawResponse {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let prompt = request.responseMode == .jsonObject
            ? "\(privacyGuard.redact(request.prompt))\n\nReturn exactly one valid JSON object and no surrounding prose."
            : privacyGuard.redact(request.prompt)
        let text = try await runPrompt(prompt, model: prefs.aiConfig.model, responseMode: request.responseMode)
        return LLMRawResponse(text: text, provider: name, usedCloud: true)
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let prompt = privacyGuard.redact(PromptBuilder().summaryPrompt(meeting: meeting, transcript: transcript))
        let text = try await runPrompt(prompt, model: prefs.aiConfig.model)
        return MeetingSummaryParser.parse(text, meetingId: meeting.id) ?? MeetingSummaryParser.fallback(meetingId: meeting.id, text: text)
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let target = SupportedLanguage.language(for: targetLanguage) ?? .englishUS
        let source = SupportedLanguage.displayName(for: segment.originalLanguage)
        return try await runPrompt(
            "Translate from \(source) to \(target.promptName). Return only the translation, no commentary:\n\(privacyGuard.redact(segment.text))",
            model: prefs.aiConfig.model(for: .translation)
        )
    }

    func extractActionItems(transcript: [TranscriptSegment]) async throws -> [ActionItem] {
        []
    }

    func generateInsights(transcriptWindow: [TranscriptSegment]) async throws -> [Insight] {
        []
    }

    private func runPrompt(_ prompt: String, model: String, responseMode: LLMRawResponseMode = .plainText) async throws -> String {
        _ = try await authProvider.refreshIfNeeded()
        let result = try await runner.runProviderCLI(
            arguments: promptArguments(prompt: prompt, model: model, responseMode: responseMode),
            standardInput: nil,
            timeout: 120,
            outputHandler: nil
        )
        guard result.exitCode == 0 else {
            let lower = result.output.lowercased()
            if lower.contains("auth") || lower.contains("login") || lower.contains("unauthorized") {
                throw AuthError.notAuthenticated
            }
            throw AIProviderError.invalidResponse
        }
        let text = Self.extractText(from: result.output)
        guard !text.isEmpty else { throw AIProviderError.invalidResponse }
        return text
    }

    private func promptArguments(prompt: String, model: String, responseMode: LLMRawResponseMode = .plainText) -> [String] {
        switch configuration {
        case .gemini:
            return [
                "--model", model,
                "--output-format", responseMode == .jsonObject ? "json" : "text",
                "--prompt", prompt
            ]
        case .claude:
            return [
                "-p", prompt,
                "--model", model,
                "--output-format", "text"
            ]
        }
    }

    static func extractText(from output: String) -> String {
        let sanitized = ProviderCLIAuthProvider.sanitizedTerminalText(output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return "" }
        if let data = sanitized.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) {
            let text = extractText(fromJSON: payload).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        let lines = sanitized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !($0.lowercased().contains("opening authentication")) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractText(fromJSON value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let array = value as? [Any] {
            return array.map { extractText(fromJSON: $0) }.joined()
        }
        guard let object = value as? [String: Any] else { return "" }
        for key in ["text", "content", "message", "response", "output_text", "result"] {
            if let value = object[key] {
                let text = extractText(fromJSON: value)
                if !text.isEmpty { return text }
            }
        }
        return ""
    }
}
