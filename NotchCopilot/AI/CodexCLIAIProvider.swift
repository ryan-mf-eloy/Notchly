import Foundation

@MainActor
struct CodexCLIAIProvider: AIProvider {
    var name: EngineName { .openAI }

    private let authProvider: CodexCLIAuthProvider
    private let runner: CodexCLICommandRunning
    private let privacyGuard: PrivacyGuard
    private let preferences: () -> AppPreferences

    init(
        authProvider: CodexCLIAuthProvider,
        runner: CodexCLICommandRunning,
        privacyGuard: PrivacyGuard = PrivacyGuard(),
        preferences: @escaping () -> AppPreferences
    ) {
        self.authProvider = authProvider
        self.runner = runner
        self.privacyGuard = privacyGuard
        self.preferences = preferences
    }

    var isConfiguredForCloud: Bool {
        let prefs = preferences()
        // Codex CLI account auth lives outside Notchly's keychain. A fresh app launch
        // may not have a cached session yet even though `codex exec` is fully usable.
        // Treat the selected CLI provider as configurable and let the command itself
        // be the source of truth for auth failures.
        return prefs.aiConfig.cloudProcessingEnabled && !prefs.localOnlyMode
    }

    static func availableModelCatalog() -> AIModelCatalog {
        guard let data = try? Data(contentsOf: codexModelsCacheURL()),
              let decoded = try? JSONDecoder().decode(CodexModelsCache.self, from: data) else {
            return .codexFallback
        }
        let models = decoded.models.map {
            AIModelOption(
                id: $0.slug,
                displayName: $0.displayName ?? $0.slug,
                description: $0.description,
                capabilities: [.chat, .webSearch]
            )
        }
        return AIModelCatalog.codex(from: models)
    }

    func generateAnswer(context: AnswerContext, question: String, options: AnswerOptions) async throws -> GeneratedAnswer {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let prompt = PromptBuilder().suggestedAnswerPrompt(context: context, question: privacyGuard.redact(question), options: options)
        let text = try await runCodexPrompt(
            prompt,
            model: prefs.aiConfig.model,
            enableWebSearch: options.enableWebSearch
        )
        return GeneratedAnswer(text: text, provider: .openAI, usedCloud: true, usedRAG: !context.ragContext.isEmpty)
    }

    func generateRaw(request: LLMRawRequest) async throws -> LLMRawResponse {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        var prompt = request.responseMode == .jsonObject
            ? "\(privacyGuard.redact(request.prompt))\n\nReturn exactly one valid JSON object and no surrounding prose."
            : privacyGuard.redact(request.prompt)
        if request.enableWebSearch {
            prompt += "\n\nLive web search is enabled. For current events, news, prices, or other fresh information, search the web and include concise source names and URLs in answerText when relevant."
        }
        let text = try await runCodexPrompt(
            prompt,
            model: prefs.aiConfig.model,
            enableWebSearch: request.enableWebSearch
        )
        return LLMRawResponse(text: text, provider: .openAI, usedCloud: true)
    }

    func summarizeMeeting(meeting: MeetingSession, transcript: [TranscriptSegment], type: MeetingType) async throws -> MeetingSummary {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let prompt = privacyGuard.redact(PromptBuilder().summaryPrompt(meeting: meeting, transcript: transcript))
        let text = try await runCodexPrompt(prompt, model: prefs.aiConfig.model)
        return MeetingSummaryParser.parse(text, meetingId: meeting.id) ?? MeetingSummaryParser.fallback(meetingId: meeting.id, text: text)
    }

    func translateSegment(_ segment: TranscriptSegment, targetLanguage: String) async throws -> String {
        let prefs = preferences()
        guard prefs.aiConfig.cloudProcessingEnabled, !prefs.localOnlyMode else { throw AIProviderError.cloudDisabled }
        let target = SupportedLanguage.language(for: targetLanguage) ?? .englishUS
        let source = SupportedLanguage.displayName(for: segment.originalLanguage)
        return try await runCodexPrompt(
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

    func embed(texts: [String]) async throws -> [[Double]] {
        []
    }

    private func runCodexPrompt(_ prompt: String, model: String, enableWebSearch: Bool = false) async throws -> String {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-copilot-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let commandPrefix = enableWebSearch ? ["--search", "exec"] : ["exec"]
        let result = try await runner.runCodex(
            arguments: commandPrefix + [
                "--skip-git-repo-check",
                "--sandbox",
                "read-only",
                "--ephemeral",
            ] + codexModelArguments(for: model) + [
                "--output-last-message",
                outputURL.path,
                "-"
            ],
            standardInput: prompt,
            timeout: 120,
            outputHandler: nil
        )
        guard result.exitCode == 0 else {
            if result.output.lowercased().contains("login") || result.output.lowercased().contains("auth") {
                throw AuthError.notAuthenticated
            }
            throw AIProviderError.invalidResponse
        }
        let text = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { throw AIProviderError.invalidResponse }
        return text
    }

    private func codexModelArguments(for model: String) -> [String] {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("codex:"), trimmed.count > "codex:".count {
            return ["--model", String(trimmed.dropFirst("codex:".count))]
        }
        if trimmed.localizedCaseInsensitiveContains("codex") {
            return ["--model", trimmed]
        }
        return ["--model", "gpt-5.3-codex"]
    }

    private static func codexModelsCacheURL() -> URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("models_cache.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("models_cache.json")
    }
}

private struct CodexModelsCache: Decodable {
    var models: [CodexCachedModel]
}

private struct CodexCachedModel: Decodable {
    var slug: String
    var displayName: String?
    var description: String?

    enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case description
    }
}
