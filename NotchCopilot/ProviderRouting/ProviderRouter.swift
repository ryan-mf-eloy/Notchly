import Foundation

@MainActor
struct ProviderRouter {
    private static var cachedAutoLanguageAppleSpeechSupport: Bool?

    var capabilityChecker: CapabilityChecker
    var openAIProvider: OpenAIProvider?
    var legacyOpenAIProvider: OpenAIProvider?
    var codexCLIProvider: CodexCLIAIProvider?
    var geminiAPIKeyProvider: GoogleGeminiProvider?
    var geminiCLIProvider: ProviderCLIAIProvider?
    var anthropicAPIKeyProvider: AnthropicClaudeProvider?
    var anthropicCLIProvider: ProviderCLIAIProvider?
    var perplexityProvider: PerplexityProvider?
    var elevenLabsAPIKeyAuthProvider: (any AuthProvider)?

    init(
        capabilityChecker: CapabilityChecker = CapabilityChecker(),
        openAIProvider: OpenAIProvider? = nil,
        legacyOpenAIProvider: OpenAIProvider? = nil,
        codexCLIProvider: CodexCLIAIProvider? = nil,
        geminiAPIKeyProvider: GoogleGeminiProvider? = nil,
        geminiCLIProvider: ProviderCLIAIProvider? = nil,
        anthropicAPIKeyProvider: AnthropicClaudeProvider? = nil,
        anthropicCLIProvider: ProviderCLIAIProvider? = nil,
        perplexityProvider: PerplexityProvider? = nil,
        elevenLabsAPIKeyAuthProvider: (any AuthProvider)? = nil
    ) {
        self.capabilityChecker = capabilityChecker
        self.openAIProvider = openAIProvider
        self.legacyOpenAIProvider = legacyOpenAIProvider
        self.codexCLIProvider = codexCLIProvider
        self.geminiAPIKeyProvider = geminiAPIKeyProvider
        self.geminiCLIProvider = geminiCLIProvider
        self.anthropicAPIKeyProvider = anthropicAPIKeyProvider
        self.anthropicCLIProvider = anthropicCLIProvider
        self.perplexityProvider = perplexityProvider
        self.elevenLabsAPIKeyAuthProvider = elevenLabsAPIKeyAuthProvider
    }

    func transcriptionService(preferences: AppPreferences) -> any TranscriptionService {
        if let cloudService = cloudRealtimeTranscriptionService(preferences: preferences) {
            return cloudService
        }
        if supportsAutoLanguageAppleSpeech() || capabilityChecker.supportsAppleSpeechRecognition(language: preferences.defaultLanguage) {
            return AppleNativeTranscriptionService(allowsAutomaticLanguageSwitching: true)
        }
        return UnavailableTranscriptionService(error: .recognizerUnavailable)
    }

    func transcriptionService(preferences: AppPreferences, sources: [MultiSourceAutoLanguageTranscriptionService.Source]) -> any TranscriptionService {
        if shouldUseCloudRealtimeTranscription(preferences: preferences) {
            guard let elevenLabsAPIKeyAuthProvider,
                  elevenLabsAPIKeyAuthProvider.isAuthenticated else {
                return UnavailableTranscriptionService(error: .cloudProviderUnavailable("Save an ElevenLabs API key before using realtime transcription."))
            }
            return MultiSourceCloudRealtimeTranscriptionService(
                sources: sources.map {
                    MultiSourceCloudRealtimeTranscriptionService.Source(
                        speakerLabel: $0.speakerLabel,
                        audioSource: $0.audioSource,
                        audioStream: $0.audioStream
                    )
                },
                serviceFactory: {
                    ElevenLabsRealtimeTranscriptionService(
                        authProvider: elevenLabsAPIKeyAuthProvider,
                        modelID: preferences.aiConfig.realtimeTranscriptionModel ?? ElevenLabsRealtimeTranscriptionService.modelID
                    )
                }
            )
        }
        if sources.count > 1 {
            if supportsAutoLanguageAppleSpeech() {
                return MultiSourceAutoLanguageTranscriptionService(sources: sources)
            }
            if capabilityChecker.supportsAppleSpeechRecognition(language: preferences.defaultLanguage) {
                return MultiSourceAppleSpeechTranscriptionService(
                    sources: sources.map {
                        MultiSourceAppleSpeechTranscriptionService.Source(
                            speakerLabel: $0.speakerLabel,
                            audioSource: $0.audioSource,
                            audioStream: $0.audioStream
                        )
                    }
                )
            }
        }
        return transcriptionService(preferences: preferences)
    }

    func meetingTranscriptionService(preferences: AppPreferences, sources: [MultiSourceAutoLanguageTranscriptionService.Source]) -> any TranscriptionService {
        guard !sources.isEmpty else {
            return UnavailableTranscriptionService(error: .recognizerUnavailable)
        }
        if shouldUseCloudRealtimeTranscription(preferences: preferences) {
            guard let elevenLabsAPIKeyAuthProvider,
                  elevenLabsAPIKeyAuthProvider.isAuthenticated else {
                return UnavailableTranscriptionService(error: .cloudProviderUnavailable("Save an ElevenLabs API key before using realtime transcription."))
            }
            return MultiSourceCloudRealtimeTranscriptionService(
                sources: sources.map {
                    MultiSourceCloudRealtimeTranscriptionService.Source(
                        speakerLabel: $0.speakerLabel,
                        audioSource: $0.audioSource,
                        audioStream: $0.audioStream
                    )
                },
                serviceFactory: {
                    ElevenLabsRealtimeTranscriptionService(
                        authProvider: elevenLabsAPIKeyAuthProvider,
                        modelID: preferences.aiConfig.realtimeTranscriptionModel ?? ElevenLabsRealtimeTranscriptionService.modelID
                    )
                }
            )
        }
        if supportsAutoLanguageAppleSpeech() {
            return MultiSourceAutoLanguageTranscriptionService(sources: sources)
        }
        if capabilityChecker.supportsAppleSpeechRecognition(language: preferences.defaultLanguage) {
            return MultiSourceAppleSpeechTranscriptionService(
                sources: sources.map {
                    MultiSourceAppleSpeechTranscriptionService.Source(
                        speakerLabel: $0.speakerLabel,
                        audioSource: $0.audioSource,
                        audioStream: $0.audioStream
                    )
                }
            )
        }
        return UnavailableTranscriptionService(error: .recognizerUnavailable)
    }

    func copilotASRService(preferences: AppPreferences) -> any TranscriptionService {
        transcriptionService(preferences: preferences)
    }

    func shouldUseSourceSeparatedAppleSpeech(preferences: AppPreferences, sourceCount: Int) -> Bool {
        guard sourceCount > 0 else { return false }
        if shouldUseCloudRealtimeTranscription(preferences: preferences) || preferences.sourceSeparatedHighAccuracyEnabled {
            return sourceCount > 1
        }
        return sourceCount > 1 && (supportsAutoLanguageAppleSpeech() || capabilityChecker.supportsAppleSpeechRecognition(language: preferences.defaultLanguage))
    }

    func shouldUseCloudRealtimeTranscription(preferences: AppPreferences) -> Bool {
        guard !preferences.localOnlyMode,
              preferences.aiConfig.realtimeTranscriptionProvider == .elevenLabs else { return false }
        guard preferences.transcriptionEngineMode == .cloudRealtime else { return false }
        return elevenLabsAPIKeyAuthProvider?.isAuthenticated == true
    }

    func supportsAutoLanguageAppleSpeech() -> Bool {
        if let cached = Self.cachedAutoLanguageAppleSpeechSupport {
            return cached
        }
        let supported = SupportedLanguage.allCases.contains { AppleSpeechTranscriptionService.supportsLanguage($0) }
        Self.cachedAutoLanguageAppleSpeechSupport = supported
        return supported
    }

    func aiProvider(preferences: AppPreferences) -> any AIProvider {
        if preferences.localOnlyMode {
            if #available(macOS 26.0, *), capabilityChecker.supportsFoundationModels() {
                return AppleLocalAIProvider()
            }
            return LocalLLMAIProvider(allowModelDownloads: preferences.allowLocalModelDownloads)
        }
        if let cloudProvider = selectedCloudAIProvider(preferences: preferences) {
            return cloudProvider
        }
        return UnavailableAIProvider(reason: "Connect a real AI provider to generate answers.")
    }

    func copilotCloudDecisionProvider(preferences: AppPreferences) -> (any AIProvider)? {
        selectedCloudAIProvider(preferences: preferences)
    }

    func copilotNativeWebProvider(preferences: AppPreferences, primaryProvider: any AIProvider) -> (any AIProvider)? {
        guard preferences.aiConfig.cloudProcessingEnabled, !preferences.localOnlyMode else {
            return nil
        }
        if primaryProvider is OpenAIProvider || primaryProvider is PerplexityProvider || primaryProvider is CodexCLIAIProvider {
            return primaryProvider
        }
        if let codexCLIProvider = selectedCodexCLIProvider(preferences: preferences) {
            return codexCLIProvider
        }
        if let perplexityProvider, perplexityProvider.isConfiguredForCloud {
            return perplexityProvider
        }
        return nil
    }

    func cloudTranslationProvider(preferences: AppPreferences) -> (any AIProvider)? {
        selectedCloudAIProvider(preferences: preferences)
    }

    func semanticTranslationProvider(preferences: AppPreferences) -> (any AIProvider)? {
        if #available(macOS 26.0, *),
           capabilityChecker.supportsFoundationModels(),
           (preferences.localOnlyMode || preferences.aiConfig.provider == .appleLocal || preferences.aiConfig.provider == .appleFoundationModels) {
            return AppleLocalAIProvider()
        }
        return cloudTranslationProvider(preferences: preferences)
    }

    func questionClassifierProvider(preferences: AppPreferences) -> any QuestionClassifierProvider {
        let classifier = QuestionClassifier(
            adaptiveProfile: preferences.questionAnsweringProfile,
            precisionMode: preferences.qaPrecisionMode,
            multimodalMode: preferences.qaMultimodalMode,
            trainedModelRunner: CoreMLQuestionMultiQTModelRunner()
        )
        return classifier
    }

    func meetingAnswerProvider(preferences: AppPreferences) -> any MeetingAnswerProvider {
        if preferences.localOnlyMode {
            if #available(macOS 26.0, *), capabilityChecker.supportsFoundationModels() {
                return AnswerGenerationService(provider: AppleLocalAIProvider())
            }
            return AnswerGenerationService(provider: LocalLLMAIProvider(allowModelDownloads: preferences.allowLocalModelDownloads))
        }
        if let openAIProvider = selectedOpenAIHTTPProvider(preferences: preferences) {
            if RealtimeAIService().shouldUseRealtimeForQuestionAnswering(preferences: preferences) {
                return OpenAIStreamingMeetingAnswerProvider(provider: openAIProvider)
            }
            return AnswerGenerationService(provider: openAIProvider)
        }
        if let cloudProvider = selectedCloudAIProvider(preferences: preferences) {
            return AnswerGenerationService(provider: cloudProvider)
        }
        return AnswerGenerationService(provider: UnavailableAIProvider(reason: "Connect a real AI provider to generate answers."))
    }

    func prewarmRealtimeQuestionAnswering(preferences: AppPreferences) async {
        guard RealtimeAIService().shouldUseRealtimeForQuestionAnswering(preferences: preferences),
              let openAIProvider = selectedOpenAIHTTPProvider(preferences: preferences)
        else { return }
        _ = try? await openAIProvider.prepareForLowLatencyUse()
    }

    func report(preferences: AppPreferences) -> LocalCapabilityReport {
        var report = capabilityChecker.localReport(preferences: preferences)
        if shouldUseCloudRealtimeTranscription(preferences: preferences) {
            report.transcriptionEngine = elevenLabsAPIKeyAuthProvider?.isAuthenticated == true ? .elevenLabs : .unavailable
            report.transcriptionMode = report.transcriptionEngine == .elevenLabs ? .cloud : .unavailable
        }
        return report
    }

    private func cloudRealtimeTranscriptionService(preferences: AppPreferences) -> (any TranscriptionService)? {
        guard !preferences.localOnlyMode else { return nil }
        guard preferences.transcriptionEngineMode == .cloudRealtime else { return nil }
        switch preferences.aiConfig.realtimeTranscriptionProvider {
        case .elevenLabs:
            guard let elevenLabsAPIKeyAuthProvider,
                  elevenLabsAPIKeyAuthProvider.isAuthenticated else {
                return UnavailableTranscriptionService(error: .cloudProviderUnavailable("Save an ElevenLabs API key before using realtime transcription."))
            }
            return ElevenLabsRealtimeTranscriptionService(
                authProvider: elevenLabsAPIKeyAuthProvider,
                modelID: preferences.aiConfig.realtimeTranscriptionModel ?? ElevenLabsRealtimeTranscriptionService.modelID
            )
        case .none:
            return nil
        }
    }

    private func selectedOpenAIHTTPProvider(preferences: AppPreferences) -> OpenAIProvider? {
        guard preferences.aiConfig.provider == .openAI,
              preferences.aiConfig.cloudProcessingEnabled,
              !preferences.localOnlyMode else {
            return nil
        }

        let provider: OpenAIProvider?
        if preferences.aiConfig.authMode == .apiKeyLegacy && preferences.aiConfig.legacyAPIKeyAccessEnabled {
            provider = legacyOpenAIProvider
        } else if preferences.aiConfig.authMode == .openAIAccountOAuth {
            provider = openAIProvider
        } else {
            provider = nil
        }

        guard let provider, provider.isConfiguredForCloud else { return nil }
        return provider
    }

    private func selectedCloudAIProvider(preferences: AppPreferences) -> (any AIProvider)? {
        guard preferences.aiConfig.cloudProcessingEnabled, !preferences.localOnlyMode else {
            return nil
        }

        switch preferences.aiConfig.provider {
        case .openAI:
            if let codexCLIProvider = selectedCodexCLIProvider(preferences: preferences) {
                return codexCLIProvider
            }
            return selectedOpenAIHTTPProvider(preferences: preferences)
        case .googleGemini:
            if preferences.aiConfig.authMode == .googleGeminiOAuth,
               let provider = geminiCLIProvider,
               provider.isConfiguredForCloud {
                return provider
            }
            if preferences.aiConfig.authMode == .googleGeminiAPIKey,
               let provider = geminiAPIKeyProvider,
               provider.isConfiguredForCloud {
                return provider
            }
            return nil
        case .anthropicClaude:
            if preferences.aiConfig.authMode == .anthropicClaudeOAuth,
               let provider = anthropicCLIProvider,
               provider.isConfiguredForCloud {
                return provider
            }
            if preferences.aiConfig.authMode == .anthropicClaudeAPIKey,
               let provider = anthropicAPIKeyProvider,
               provider.isConfiguredForCloud {
                return provider
            }
            return nil
        case .perplexity:
            guard preferences.aiConfig.authMode == .perplexityAPIKey,
                  let provider = perplexityProvider,
                  provider.isConfiguredForCloud else {
                return nil
            }
            return provider
        case .appleLocal, .appleFoundationModels:
            return nil
        }
    }

    private func selectedCodexCLIProvider(preferences: AppPreferences) -> CodexCLIAIProvider? {
        guard preferences.aiConfig.provider == .openAI,
              preferences.aiConfig.authMode == .openAICodexCLI,
              preferences.aiConfig.cloudProcessingEnabled,
              !preferences.localOnlyMode,
              let provider = codexCLIProvider,
              provider.isConfiguredForCloud else {
            return nil
        }
        return provider
    }
}

enum CopilotProviderReadinessStatus: Equatable, Sendable {
    case ready(provider: EngineName)
    case missing(String)
    case invalid(String)

    var healthState: CopilotHealthState {
        switch self {
        case .ready:
            return .ready
        case .missing:
            return .llmProviderMissing
        case .invalid:
            return .llmProviderInvalid
        }
    }

    var message: String {
        switch self {
        case .ready(let provider):
            return "\(provider.rawValue) ready"
        case .missing(let reason), .invalid(let reason):
            return reason
        }
    }
}

@MainActor
struct CopilotProviderReadinessCheck {
    var router: ProviderRouter
    var timeoutSeconds: TimeInterval = 4

    func validate(preferences: AppPreferences) async -> CopilotProviderReadinessStatus {
        guard preferences.aiConfig.cloudProcessingEnabled, !preferences.localOnlyMode else {
            return .missing("AI provider required")
        }
        guard let provider = router.copilotCloudDecisionProvider(preferences: preferences) else {
            return .missing("AI provider required")
        }

        do {
            let probeTask = Task { @MainActor in
                try await provider.generateRaw(request: LLMRawRequest(
                    prompt: #"Return exactly this JSON object and nothing else: {"ok":true}"#,
                    maxOutputTokens: 32,
                    responseMode: .jsonObject,
                    enableWebSearch: false
                ))
            }
            let timeoutTask = Task {
                let nanoseconds = UInt64(max(timeoutSeconds, 0.1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                probeTask.cancel()
            }
            let response = try await probeTask.value
            timeoutTask.cancel()
            guard response.usedCloud else {
                return .invalid("Cloud AI provider required")
            }
            let data = Data(response.text.utf8)
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any],
                  dictionary["ok"] as? Bool == true else {
                return .invalid("AI provider JSON mode failed")
            }
            return .ready(provider: response.provider)
        } catch {
            if error is CancellationError {
                return .invalid("AI provider readiness timed out.")
            }
            return .invalid(error.localizedDescription)
        }
    }
}
