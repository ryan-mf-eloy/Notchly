import Combine
import CoreGraphics
import Foundation
import AppKit
import Speech

private enum ExpandedIslandLayoutProfile {
    case ready
    case liveTranscript
    case translationTranscript
    case question
    case answer
    case copilotHistory
    case summary
}

@MainActor
final class AppState: ObservableObject {
    @Published var preferences: AppPreferences
    @Published var islandMode: NotchIslandMode = .idle
    @Published var currentMeeting: MeetingSession? {
        didSet {
            syncActiveTranscriptPresentationCache(from: currentMeeting)
        }
    }
    @Published var history: [MeetingSession] = []
    @Published var waveformLevels: [CGFloat] = Array(repeating: 0.1, count: 18)
    @Published var meetingWaveformLevels: [CGFloat] = Array(repeating: 0.1, count: 18)
    @Published var copilotWaveformLevels: [CGFloat] = Array(repeating: 0.1, count: 18)
    @Published var meetingTranscriptionStatus: MeetingTranscriptionStatus = .idle
    @Published var copilotASRStatus: CopilotASRStatus = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var detectedQuestion: String?
    @Published var activeQuestion: QuestionCandidate?
    @Published var questionClassification: QuestionClassification?
    @Published var answerStage: AnswerGenerationStage = .idle
    @Published var suggestedAnswer: SuggestedAnswer?
    @Published var streamingAnswerText: String = ""
    @Published var questionAnswerRecords: [QuestionAnswerRecord] = []
    @Published var questionAnswerQueue: [QuestionAnswerQueueItem] = []
    @Published var copilotInteractions: [CopilotInteraction] = []
    @Published var copilotReminders: [CopilotReminder] = []
    @Published var activeCopilotInteraction: CopilotInteraction?
    @Published var isShowingCopilotHistory = false
    @Published var isShowingCopilotAnswerDetail = false
    @Published var copilotRuntimeState: CopilotRuntimeState = .idle
    @Published var copilotLastFailure: CopilotFailureKind?
    @Published var copilotQualitySnapshot: CopilotQualitySnapshot = .empty
    @Published var copilotHealthSnapshot: CopilotHealthSnapshot = .empty
    @Published var latestCopilotActivationTrace: CopilotActivationTrace?
    @Published var isAmbientCopilotListening = false
    @Published var ambientCopilotStatus: String = "Notchly ready"
    @Published var isCopilotPushToTalkActive = false
    @Published var isCopilotPushToTalkProcessing = false
    @Published var copilotPushToTalkTranscript = ""
    @Published var copilotPushToTalkErrorMessage: String?
    @Published var selectedQuestionId: UUID?
    @Published var savedQuestionAnswerIds: Set<UUID> = []
    @Published var questionAnswerPresentationMode: QuestionAnswerPresentationMode = .answer
    @Published var statusMessage: String = "Ready"
    @Published var activeCaptureLabel: String = "Mic + system"
    @Published var speechAudioQualityBySource: [TranscriptAudioSource: SpeechAudioQualitySnapshot] = [:]
    @Published var capabilityReport: LocalCapabilityReport?
    @Published var selectedMeeting: MeetingSession?
    @Published var isPanelExpanded = false
    @Published var isNotchHovered = false
    @Published var compactRecordButtonFeedbackTrigger = 0
    @Published var knowledgeDocumentNames: [String] = []
    @Published var knowledgeSources: [SourceConnectionViewModel] = []
    @Published var retrievalStatus = RetrievalStatusViewModel(title: "Context ready", detail: "Local sources only", quality: "Keyword", isIndexing: false)
    @Published var speechVocabularyTerms: [SpeechVocabularyTerm] = []
    @Published var speechVocabularyStatus: String = "Apple Speech ready"
    @Published var settingsStatus: String = ""
    @Published var openAIConnectionStatus: AIConnectionStatus = .notConnected
    @Published var elevenLabsConnectionStatus: AIConnectionStatus = .notConnected
    @Published var openAICodexLoginSession: CodexCLILoginSessionState?
    @Published var providerConnectionStatuses: [AIProviderKind: AIConnectionStatus] = [:]
    @Published var providerLoginSessions: [AIProviderKind: ProviderCLILoginSessionState] = [:]
    @Published var verifyingProviderLogins: Set<AIProviderKind> = []
    @Published var isVerifyingOpenAICodexLogin = false
    private var openAICodexLoginCompletionTask: Task<Void, Never>?
    private var providerLoginCompletionTasks: [AIProviderKind: Task<Void, Never>] = [:]
    @Published var aiModelCatalog: AIModelCatalog = .local
    @Published var aiModelCatalogStatus: String = ""
    @Published var isRefreshingAIModelCatalog = false
    @Published var translationPreparationStatus: String = ""
    @Published var isPreparingTranslationLanguages = false
    @Published var ignoredDetectionSignature: String?
    @Published var ignoredDetectionSignatures: Set<String> = []
    @Published var ignoredDetectionUntil: Date?
    @Published var copilotMeetingDetectionSuppressedUntil: Date?
    @Published var detectedMeetingOfferStartedAt: Date?
    @Published var detectedMeetingOfferExpiresAt: Date?
    @Published private(set) var activeTranscriptMeetingId: UUID?
    @Published private(set) var activeTranscriptPresentationSegments: [TranscriptSegment] = []
    private var lastPersistedPreferences: AppPreferences?
    private var isPersistingPreferences = false
    private var preferenceAutosaveTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    static let detectedMeetingOfferDuration: TimeInterval = 15
    private static let ignoredDetectionCooldown: TimeInterval = 10 * 60
    private static let copilotMeetingDetectionSuppressionGrace: TimeInterval = 5

    func triggerCompactRecordButtonFeedback() {
        compactRecordButtonFeedbackTrigger += 1
    }

    var sessionManager: MeetingSessionManager?
    var ambientCopilotController: AmbientCopilotController?
    var settingsRepository: SettingsRepository? {
        didSet {
            persistPreferences(refreshConnectionStatus: false)
        }
    }
    var providerRouter: ProviderRouter?
    var keychain: AppleKeychainService?
    var tokenStore: TokenStore?
    var openAIAccountOAuthProvider: OpenAIAccountOAuthProvider?
    var codexCLIAuthProvider: CodexCLIAuthProvider?
    var legacyAPIKeyAuthProvider: OpenAIApiKeyAuthProvider?
    var geminiAPIKeyAuthProvider: ProviderAPIKeyAuthProvider?
    var geminiCLIAuthProvider: ProviderCLIAuthProvider?
    var anthropicAPIKeyAuthProvider: ProviderAPIKeyAuthProvider?
    var anthropicCLIAuthProvider: ProviderCLIAuthProvider?
    var perplexityAPIKeyAuthProvider: ProviderAPIKeyAuthProvider?
    var elevenLabsAPIKeyAuthProvider: ProviderAPIKeyAuthProvider?
    var openAIProvider: OpenAIProvider?
    var legacyOpenAIProvider: OpenAIProvider?
    var geminiAPIKeyProvider: GoogleGeminiProvider?
    var geminiCLIProvider: ProviderCLIAIProvider?
    var anthropicAPIKeyProvider: AnthropicClaudeProvider?
    var anthropicCLIProvider: ProviderCLIAIProvider?
    var perplexityProvider: PerplexityProvider?
    var knowledgeStore: LocalKnowledgeStore? {
        didSet {
            configureKnowledgeStore()
            reloadKnowledgeDocuments()
        }
    }
    var speechVocabularyStore: SpeechVocabularyStore?
    private let knowledgeSourceFileWatcher = KnowledgeSourceFileWatcher()
    private var knowledgeEmbeddingIndexTask: Task<Void, Never>?
    private var knowledgeRetrievalWarmupTask: Task<Void, Never>?
    private var localEmbeddingBenchmarkTask: Task<Void, Never>?

    var realtimeTranscriptionModelOptions: [AIModelOption] {
        switch preferences.aiConfig.realtimeTranscriptionProvider {
        case .elevenLabs:
            return AIModelCatalog.elevenLabsRealtime.transcriptionModels
        case .openAI:
            let options = aiModelCatalog.transcriptionModels.filter { $0.id == RealtimeTranscriptionProvider.openAI.defaultModelID || $0.id.lowercased().contains("transcribe") || $0.id.lowercased().contains("whisper") }
            return options.isEmpty ? AIModelCatalog.openAIRealtimeTranscription.transcriptionModels : options
        case .googleGemini:
            let options = aiModelCatalog.transcriptionModels.filter { $0.id.lowercased().contains("live") }
            return options.isEmpty ? AIModelCatalog.geminiLiveRealtime.transcriptionModels : options
        case .none:
            return []
        }
    }

    var openSettingsHandler: (() -> Void)?
    var openHistoryHandler: (() -> Void)?
    var openSummaryHandler: (() -> Void)?
    var quitHandler: (() -> Void)?

    var notchIslandSize: CGSize {
        if isPanelExpanded {
            return CGSize(width: expandedIslandWidth, height: expandedIslandHeight)
        }
        if isIdleHiddenBehindNotch {
            return NotchIslandChromeMetrics.collapsedNotchFootprintSize
        }
        if shouldShowCopilotPushToTalkListeningIndicator {
            return NotchIslandChromeMetrics.ambientCopilotListeningSize
        }
        if shouldShowCopilotPushToTalkProcessingIndicator || shouldShowAmbientCopilotLoadingIndicator || shouldShowAmbientCopilotMicroState {
            return NotchIslandChromeMetrics.ambientCopilotProcessingSize
        }
        if shouldShowAmbientCopilotIdle {
            return NotchIslandChromeMetrics.compactListeningSize
        }
        if islandMode == .idle && currentMeeting == nil && isNotchHovered {
            return NotchIslandChromeMetrics.compactRecordHoverActionsSize
        }
        if islandMode == .meetingDetected && isNotchHovered {
            return NotchIslandChromeMetrics.compactRecordHoverActionsSize
        }
        if islandMode == .suggestedAnswer {
            return currentMeeting == nil ? NotchIslandMode.questionDetected.preferredSize : NotchIslandMode.listening.preferredSize
        }
        return islandMode.preferredSize
    }

    var notchIslandCanvasSize: CGSize {
        if isIdleHiddenBehindNotch {
            return NotchIslandChromeMetrics.compactRecordHoverActionsSize
        }

        if shouldShowCopilotPushToTalkCompactIndicator || shouldShowAmbientCopilotLoadingIndicator || shouldShowAmbientCopilotMicroState {
            return notchIslandSize
        }

        if (islandMode == .meetingDetected || (islandMode == .idle && isNotchHovered && currentMeeting == nil)) && !isPanelExpanded {
            return notchIslandSize
        }

        if isPanelExpanded {
            return CGSize(
                width: expandedIslandWidth + 40,
                height: expandedIslandHeight + 16
            )
        }

        return CGSize(
            width: notchIslandSize.width + 28,
            height: notchIslandSize.height + 12
        )
    }

    var notchCornerRadius: CGFloat {
        NotchIslandMode.chromeCornerRadius
    }

    var isIdleHiddenBehindNotch: Bool {
        islandMode == .idle &&
            !isPanelExpanded &&
            currentMeeting == nil &&
            !isNotchHovered &&
            !shouldShowAmbientCopilotIdle &&
            !shouldShowCopilotPushToTalkCompactIndicator &&
            !shouldShowAmbientCopilotMicroState
    }

    var shouldShowAmbientCopilotIdle: Bool {
        false
    }

    var shouldShowAmbientCopilotMicroState: Bool {
        currentMeeting == nil &&
            !isPanelExpanded &&
            islandMode == .idle &&
            preferences.copilotHotkeyEnabled &&
            copilotHealthSnapshot.state.showsMicroState
    }

    var shouldShowAmbientCopilotLoadingIndicator: Bool {
        currentMeeting == nil &&
            !isPanelExpanded &&
            islandMode == .thinking &&
            activeQuestion != nil &&
            answerStage.isInProgress
    }

    var shouldShowCopilotPushToTalkListeningIndicator: Bool {
        currentMeeting == nil &&
            !isPanelExpanded &&
            isCopilotPushToTalkActive
    }

    var shouldShowCopilotPushToTalkProcessingIndicator: Bool {
        currentMeeting == nil &&
            !isPanelExpanded &&
            !isCopilotPushToTalkActive &&
            isCopilotPushToTalkProcessing
    }

    var shouldShowCopilotPushToTalkCompactIndicator: Bool {
        shouldShowCopilotPushToTalkListeningIndicator || shouldShowCopilotPushToTalkProcessingIndicator
    }

    var shouldAnchorCompactIslandToNotchRightEdge: Bool {
        false
    }

    var ambientCopilotDisplayStatus: String {
        if isAmbientCopilotListening {
            return copilotRuntimeState.displayText
        }
        return ambientCopilotStatus
    }

    var copilotFailureMessage: String? {
        copilotLastFailure?.userMessage
    }

    var presentationTranscriptSegments: [TranscriptSegment] {
        guard let currentMeeting else { return [] }
        if !currentMeeting.transcriptSegments.isEmpty {
            return currentMeeting.transcriptSegments
        }
        guard activeTranscriptMeetingId == currentMeeting.id else { return [] }
        return activeTranscriptPresentationSegments
    }

    var expandedIslandWidth: CGFloat {
        switch expandedLayoutProfile {
        case .ready:
            return 500
        case .liveTranscript:
            return dynamicTranscriptWidth(minWidth: 500, maxWidth: 540)
        case .translationTranscript:
            return dynamicTranscriptWidth(minWidth: 540, maxWidth: 580)
        case .question:
            return dynamicQuestionWidth
        case .answer:
            return answerLayoutSizingText.containsCodeBlock ? dynamicCodeAnswerWidth : dynamicAnswerWidth
        case .copilotHistory:
            return dynamicCopilotHistoryWidth
        case .summary:
            return 520
        }
    }

    var expandedIslandHeight: CGFloat {
        switch expandedLayoutProfile {
        case .ready:
            return 220
        case .liveTranscript:
            return presentationTranscriptSegments.isEmpty ? 248 : 330
        case .translationTranscript:
            return presentationTranscriptSegments.isEmpty ? 274 : 372
        case .question:
            let questionText = questionClassification?.extractedQuestion ?? detectedQuestion ?? activeQuestion?.rawText ?? ""
            let lineBias = min(CGFloat(estimatedLineCount(for: questionText, charactersPerLine: 60)) * 10, 44)
            return clamped(298 + lineBias, min: 312, max: 376)
        case .answer:
            return dynamicAnswerHeight
        case .copilotHistory:
            return dynamicCopilotHistoryHeight
        case .summary:
            return currentMeeting?.status == .summarizing || islandMode == .summarizing ? 210 : 236
        }
    }

    var expandedPanelContentWidth: CGFloat {
        expandedIslandWidth - expandedHorizontalContentInset * 2
    }

    var expandedPanelContentHeight: CGFloat {
        max(154, expandedIslandHeight - NotchIslandChromeMetrics.expandedBodyChromeHeight)
    }

    var expandedHorizontalContentInset: CGFloat {
        switch expandedLayoutProfile {
        case .ready, .summary:
            return 16
        case .liveTranscript, .translationTranscript:
            return 16
        case .question, .answer:
            return 18
        case .copilotHistory:
            return 16
        }
    }

    var selectedAnswerPresentationText: String {
        if let answer = suggestedAnswer {
            return answer.shortAnswer.isEmpty ? answer.answerText : answer.shortAnswer
        }
        if !streamingAnswerText.isEmpty {
            return streamingAnswerText
        }
        if isShowingCopilotAnswerDetail,
           let response = activeCopilotInteraction?.response.trimmingCharacters(in: .whitespacesAndNewlines),
           !response.isEmpty {
            return response
        }
        return questionClassification?.extractedQuestion ?? detectedQuestion ?? activeQuestion?.rawText ?? ""
    }

    var visibleAnswerText: String {
        if let answer = suggestedAnswer {
            let candidates = [
                answer.answerText,
                answer.expandedAnswer,
                answer.shortAnswer
            ]
            for candidate in candidates {
                if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        let streamingText = streamingAnswerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !streamingText.isEmpty {
            return streamingText
        }

        if isShowingCopilotAnswerDetail,
           activeQuestion == nil,
           detectedQuestion == nil,
           let response = activeCopilotInteraction?.response.trimmingCharacters(in: .whitespacesAndNewlines),
           !response.isEmpty {
            return response
        }

        return ""
    }

    var hasQuestionAnswerContext: Bool {
        activeQuestion != nil ||
            suggestedAnswer != nil ||
            !streamingAnswerText.isEmpty ||
            !questionAnswerQueue.isEmpty ||
            (isShowingCopilotAnswerDetail && activeCopilotInteraction != nil)
    }

    var shouldPreserveTranscriptForIncomingQuestion: Bool {
        currentMeeting != nil && isPanelExpanded && (questionAnswerPresentationMode == .transcript || !hasQuestionAnswerContext)
    }

    var questionLoadingPresentationMode: QuestionAnswerPresentationMode {
        currentMeeting != nil && isPanelExpanded && questionAnswerPresentationMode == .transcript ? .transcript : .answer
    }

    var shouldShowTranscriptQuestionLoadingIndicator: Bool {
        currentMeeting != nil &&
            questionAnswerPresentationMode == .transcript &&
            activeQuestion != nil &&
            answerStage.isInProgress
    }

    private var answerLayoutSizingText: String {
        var parts: [String] = []
        if let questionText = questionClassification?.extractedQuestion ?? detectedQuestion ?? activeQuestion?.rawText ?? (isShowingCopilotAnswerDetail ? activeCopilotInteraction?.prompt : nil) {
            parts.append(questionText)
        }
        parts.append(visibleAnswerText)
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var selectedAnswerFormat: CopilotAnswerFormat? {
        if let format = suggestedAnswer?.answerFormat {
            return format
        }
        guard isShowingCopilotAnswerDetail,
              let interaction = activeCopilotInteraction
        else { return nil }
        return inferredCopilotAnswerFormat(tool: interaction.tool, intent: interaction.intent)
    }

    private func inferredCopilotAnswerFormat(tool: CopilotToolKind, intent: CopilotIntentKind) -> CopilotAnswerFormat? {
        if intent == .newsSearch { return .newsWithSources }
        switch tool {
        case .calculator:
            return .calculation
        case .reminder:
            return .reminderConfirmation
        case .localMemory:
            return .memoryResults
        case .webSearch:
            return .bullets
        case .unavailable:
            return .errorState
        case .answerSynthesis:
            return nil
        }
    }

    private var answerLayoutSizingParts: (prose: String, code: String) {
        var proseLines: [String] = []
        var codeLines: [String] = []
        var isCodeBlock = false

        for line in answerLayoutSizingText.split(separator: "\n", omittingEmptySubsequences: false) {
            let rawLine = String(line)
            if rawLine.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                isCodeBlock.toggle()
                continue
            }
            if isCodeBlock {
                codeLines.append(rawLine)
            } else {
                proseLines.append(rawLine)
            }
        }

        return (
            proseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            codeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var transcriptLayoutSizingText: String {
        presentationTranscriptSegments
            .suffix(6)
            .flatMap { segment -> [String] in
                var lines = [segment.text]
                if preferences.showTranslatedText {
                    if let translated = segment.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !translated.isEmpty {
                        lines.append(translated)
                    } else if let draft = segment.draftTranslatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !draft.isEmpty {
                        lines.append(draft)
                    }
                }
                return lines
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func estimatedLineCount(for text: String, charactersPerLine: Int) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 1 }
        let explicitLines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
        let wrappedLines = Int(ceil(Double(trimmed.count) / Double(max(charactersPerLine, 1))))
        return max(explicitLines, wrappedLines)
    }

    private var expandedLayoutProfile: ExpandedIslandLayoutProfile {
        if islandMode == .summarizing || islandMode == .summaryReady || currentMeeting?.status == .summarizing {
            return .summary
        }

        if isPanelExpanded && isShowingCopilotHistory {
            return .copilotHistory
        }

        if currentMeeting == nil, isPanelExpanded {
            if activeQuestion != nil ||
                suggestedAnswer != nil ||
                !streamingAnswerText.isEmpty ||
                answerStage.isInProgress ||
                (isShowingCopilotAnswerDetail && activeCopilotInteraction != nil) {
                return .answer
            }
            return .copilotHistory
        }

        if activeQuestion != nil ||
            suggestedAnswer != nil ||
            !streamingAnswerText.isEmpty ||
            (isShowingCopilotAnswerDetail && activeCopilotInteraction != nil) ||
            islandMode == .questionDetected ||
            islandMode == .thinking {
            if questionAnswerPresentationMode == .transcript, currentMeeting != nil {
                return preferences.liveTranslationEnabled ? .translationTranscript : .liveTranscript
            }
            if answerLayoutSizingText.containsCodeBlock ||
                suggestedAnswer != nil ||
                !streamingAnswerText.isEmpty ||
                (isShowingCopilotAnswerDetail && activeCopilotInteraction != nil) ||
                islandMode == .suggestedAnswer {
                return .answer
            }
            return .question
        }

        if currentMeeting != nil {
            return preferences.liveTranslationEnabled ? .translationTranscript : .liveTranscript
        }

        return .ready
    }

    private func dynamicTranscriptWidth(minWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let text = transcriptLayoutSizingText
        guard !text.isEmpty else { return minWidth }
        let longestLine = CGFloat(min(maxLineLength(for: text), 76))
        let lineCount = estimatedLineCount(for: text, charactersPerLine: 76)
        let textWidth = longestLine * 6.3 + 76
        let densityBias = CGFloat(min(lineCount, 4)) * 5
        return clamped(textWidth + densityBias, min: minWidth, max: maxWidth)
    }

    private var dynamicQuestionWidth: CGFloat {
        let text = (activeQuestion?.rawText ?? detectedQuestion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 500 }
        let longestLine = CGFloat(min(maxLineLength(for: text), 68))
        let lineCount = estimatedLineCount(for: text, charactersPerLine: 62)
        let textWidth = longestLine * 7.1 + 80
        let lineBias = CGFloat(min(lineCount, 4)) * 6
        return clamped(max(textWidth, 500 + lineBias), min: 500, max: 600)
    }

    private var dynamicAnswerWidth: CGFloat {
        if selectedAnswerFormat?.prefersCompactLayout == true {
            let text = answerLayoutSizingText
            let longestLine = CGFloat(min(maxLineLength(for: text), 58))
            let textWidth = longestLine * 7.0 + 78
            return clamped(textWidth, min: 500, max: 580)
        }
        let text = answerLayoutSizingText
        let lines = estimatedLineCount(for: text, charactersPerLine: 66)
        let longestLine = CGFloat(min(maxLineLength(for: text), 72))
        let textWidth = longestLine * 7.0 + 78
        let lineWidth = 500 + CGFloat(min(lines, 7)) * 7
        return clamped(max(textWidth, lineWidth), min: 500, max: 640)
    }

    private var dynamicCodeAnswerWidth: CGFloat {
        let parts = answerLayoutSizingParts
        let proseLines = estimatedLineCount(for: parts.prose, charactersPerLine: 64)
        let proseWidth = CGFloat(min(maxLineLength(for: parts.prose), 72)) * 7.0 + 78
        let codeWidth = CGFloat(min(maxLineLength(for: parts.code), 96)) * 7.2 + 118
        let lineWidth = 510 + CGFloat(min(proseLines + codeLineCount(for: parts.code), 7)) * 6
        return clamped(max(proseWidth, codeWidth, lineWidth), min: 520, max: 760)
    }

    private var dynamicAnswerHeight: CGFloat {
        let parts = answerLayoutSizingParts
        let hasCode = answerLayoutSizingText.containsCodeBlock
        if selectedAnswerFormat?.prefersCompactLayout == true && !hasCode {
            let proseLines = estimatedLineCount(for: parts.prose, charactersPerLine: 64)
            let proseBias = min(CGFloat(proseLines) * 12, 74)
            return clamped(236 + proseBias, min: 274, max: 360)
        }
        let proseLineWidth = hasCode ? 62 : 64
        let proseLines = estimatedLineCount(for: parts.prose, charactersPerLine: proseLineWidth)
        let proseBias = min(CGFloat(proseLines) * 11, hasCode ? 104 : 92)
        let codeLines = codeLineCount(for: parts.code)
        let codeBias: CGFloat = hasCode ? 42 + min(CGFloat(codeLines) * 13, 118) : 0
        return clamped(284 + proseBias + codeBias, min: hasCode ? 372 : 344, max: hasCode ? 548 : 500)
    }

    private var copilotHistorySizingText: String {
        var parts: [String] = []
        if let activeCopilotInteraction {
            parts.append(activeCopilotInteraction.prompt)
            parts.append(activeCopilotInteraction.response)
        } else {
            if let questionText = activeQuestion?.rawText ?? detectedQuestion {
                parts.append(questionText)
            }
            parts.append(visibleAnswerText)
        }
        parts.append(contentsOf: copilotInteractions.prefix(4).flatMap { [$0.prompt, $0.response] })
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var dynamicCopilotHistoryWidth: CGFloat {
        let text = copilotHistorySizingText
        guard !text.isEmpty else { return 520 }
        let longestLine = CGFloat(min(maxLineLength(for: text), 72))
        let textWidth = longestLine * 6.7 + 118
        return clamped(textWidth, min: 520, max: 640)
    }

    private var dynamicCopilotHistoryHeight: CGFloat {
        let hasTransientEntry = activeQuestion != nil || suggestedAnswer != nil || !streamingAnswerText.isEmpty || activeCopilotInteraction != nil
        let visibleCount = max(copilotInteractions.count + (hasTransientEntry ? 1 : 0), hasTransientEntry ? 1 : 0)
        guard visibleCount > 0 else { return 248 }
        let previewLines = estimatedLineCount(for: copilotHistorySizingText, charactersPerLine: 78)
        let detailBias = min(CGFloat(previewLines) * 8, 92)
        let rowBias = CGFloat(min(visibleCount, 4)) * 36
        let codeBias: CGFloat = copilotHistorySizingText.containsCodeBlock ? 118 : 0
        return clamped(218 + rowBias + detailBias + codeBias, min: 318, max: 520)
    }

    private func codeLineCount(for text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private func maxLineLength(for text: String) -> Int {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.count)
            .max() ?? 0
    }

    private func clamped(_ value: CGFloat, min lowerBound: CGFloat, max upperBound: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        configurePreferenceAutosave()
    }

    private func configurePreferenceAutosave() {
        $preferences
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.schedulePreferenceAutosave()
                }
            }
            .store(in: &cancellables)
    }

    private func schedulePreferenceAutosave() {
        preferenceAutosaveTask?.cancel()
        preferenceAutosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.autosavePreferences()
        }
    }

    private func autosavePreferences() {
        persistPreferences(refreshConnectionStatus: false)
    }

    private func syncActiveTranscriptPresentationCache(from meeting: MeetingSession?) {
        guard let meeting else {
            activeTranscriptMeetingId = nil
            activeTranscriptPresentationSegments = []
            return
        }

        if activeTranscriptMeetingId != meeting.id {
            activeTranscriptMeetingId = meeting.id
            activeTranscriptPresentationSegments = meeting.transcriptSegments
            return
        }

        if !meeting.transcriptSegments.isEmpty {
            activeTranscriptPresentationSegments = meeting.transcriptSegments
        }
    }

    var selectedQuestionQueueItem: QuestionAnswerQueueItem? {
        guard let selectedQuestionId else { return nil }
        return questionAnswerQueue.first { $0.id == selectedQuestionId }
    }

    var selectedQuestionIndex: Int? {
        guard let selectedQuestionId else { return nil }
        return questionAnswerQueue.firstIndex { $0.id == selectedQuestionId }
    }

    var selectedQuestionPositionText: String? {
        guard let selectedQuestionIndex, questionAnswerQueue.count > 1 else { return nil }
        return "\(selectedQuestionIndex + 1)/\(questionAnswerQueue.count)"
    }

    var selectedQuestionIsMostRecent: Bool {
        selectedQuestionIndex == 0
    }

    var isSelectedQuestionSaved: Bool {
        guard let selectedQuestionId else { return false }
        return savedQuestionAnswerIds.contains(selectedQuestionId)
    }

    var selectedFollowUpQuestion: String {
        if let clarifyingQuestion = suggestedAnswer?.clarifyingQuestion,
           !clarifyingQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return clarifyingQuestion
        }

        switch questionClassification?.questionType {
        case .deadlineOrEstimate:
            return "What would block this timeline?"
        case .riskAssessment:
            return "What mitigation or rollback path do we want?"
        case .technicalDecision:
            return "What trade-off matters most for this decision?"
        case .statusCheck:
            return "What source should we verify before calling this done?"
        default:
            return "What context should I verify before answering?"
        }
    }

    func resetQuestionAnswerFlow() {
        detectedQuestion = nil
        activeQuestion = nil
        questionClassification = nil
        answerStage = .idle
        suggestedAnswer = nil
        streamingAnswerText = ""
        questionAnswerQueue = []
        selectedQuestionId = nil
        savedQuestionAnswerIds = []
        questionAnswerPresentationMode = .answer
        activeCopilotInteraction = nil
        isShowingCopilotHistory = false
        isShowingCopilotAnswerDetail = false
        copilotLastFailure = nil
    }

    func upsertQuestionInQueue(
        candidate: QuestionCandidate,
        classification: QuestionClassification?,
        stage: AnswerGenerationStage = .classifying,
        decision: String = "detected",
        select: Bool = false
    ) {
        if let index = questionAnswerQueue.firstIndex(where: { $0.id == candidate.id }) {
            questionAnswerQueue[index].candidate = candidate
            questionAnswerQueue[index].classification = classification ?? questionAnswerQueue[index].classification
            questionAnswerQueue[index].stage = stage
            questionAnswerQueue[index].decision = decision
            questionAnswerQueue[index].updatedAt = Date()
        } else {
            questionAnswerQueue.append(QuestionAnswerQueueItem(
                candidate: candidate,
                classification: classification,
                stage: stage,
                decision: decision
            ))
        }
        sortQuestionAnswerQueue()

        if selectedQuestionId == nil || select {
            selectQuestion(candidate.id)
        } else {
            syncSelectedQuestionPresentation()
        }
    }

    func updateQueuedQuestionStage(questionId: UUID, stage: AnswerGenerationStage) {
        guard let index = questionAnswerQueue.firstIndex(where: { $0.id == questionId }) else { return }
        questionAnswerQueue[index].stage = stage
        questionAnswerQueue[index].updatedAt = Date()
        sortQuestionAnswerQueue()
        if selectedQuestionId == questionId {
            syncSelectedQuestionPresentation()
        }
    }

    func updateQueuedQuestionStreamingText(questionId: UUID, text: String) {
        guard let index = questionAnswerQueue.firstIndex(where: { $0.id == questionId }) else { return }
        questionAnswerQueue[index].streamingText = text
        questionAnswerQueue[index].stage = .drafting
        questionAnswerQueue[index].updatedAt = Date()
        sortQuestionAnswerQueue()
        if selectedQuestionId == questionId {
            syncSelectedQuestionPresentation()
        }
    }

    func updateQueuedQuestionAnswer(candidate: QuestionCandidate, answer: SuggestedAnswer) {
        if let index = questionAnswerQueue.firstIndex(where: { $0.id == candidate.id }) {
            questionAnswerQueue[index].candidate = candidate
            questionAnswerQueue[index].classification = candidate.classification ?? questionAnswerQueue[index].classification
            questionAnswerQueue[index].answer = answer
            questionAnswerQueue[index].streamingText = answer.shortAnswer
            questionAnswerQueue[index].stage = .ready
            questionAnswerQueue[index].decision = "suggested_answer_ready"
            questionAnswerQueue[index].updatedAt = Date()
        } else {
            questionAnswerQueue.append(QuestionAnswerQueueItem(
                candidate: candidate,
                classification: candidate.classification,
                stage: .ready,
                streamingText: answer.shortAnswer,
                answer: answer,
                decision: "suggested_answer_ready"
            ))
        }
        sortQuestionAnswerQueue()

        if selectedQuestionId == nil || selectedQuestionId == candidate.id {
            selectQuestion(candidate.id)
        }
    }

    func mergeQuestionInQueue(source: QuestionCandidate, target: QuestionCandidate) {
        let sourceIndex = questionAnswerQueue.firstIndex(where: { $0.id == source.id })
        let targetIndex = questionAnswerQueue.firstIndex(where: { $0.id == target.id })

        if let targetIndex {
            questionAnswerQueue[targetIndex].candidate = target
            questionAnswerQueue[targetIndex].classification = target.classification ?? questionAnswerQueue[targetIndex].classification
            questionAnswerQueue[targetIndex].updatedAt = Date()
            if let sourceIndex, sourceIndex != targetIndex {
                let sourceItem = questionAnswerQueue[sourceIndex]
                if questionAnswerQueue[targetIndex].streamingText.isEmpty {
                    questionAnswerQueue[targetIndex].streamingText = sourceItem.streamingText
                }
                questionAnswerQueue.remove(at: sourceIndex)
            }
        } else if let sourceIndex {
            questionAnswerQueue[sourceIndex].candidate = target
            questionAnswerQueue[sourceIndex].classification = target.classification ?? questionAnswerQueue[sourceIndex].classification
            questionAnswerQueue[sourceIndex].updatedAt = Date()
        }

        if selectedQuestionId == source.id {
            selectedQuestionId = target.id
        }
        sortQuestionAnswerQueue()
        syncSelectedQuestionPresentation()
    }

    func selectQuestion(_ id: UUID) {
        guard questionAnswerQueue.contains(where: { $0.id == id }) else { return }
        selectedQuestionId = id
        syncSelectedQuestionPresentation()
    }

    private func sortQuestionAnswerQueue() {
        questionAnswerQueue.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            if lhs.candidate.detectedAt != rhs.candidate.detectedAt {
                return lhs.candidate.detectedAt > rhs.candidate.detectedAt
            }
            return lhs.candidate.startTime > rhs.candidate.startTime
        }
    }

    func selectPreviousQuestion() {
        guard !questionAnswerQueue.isEmpty else { return }
        let current = selectedQuestionIndex ?? 0
        let next = current == 0 ? questionAnswerQueue.count - 1 : current - 1
        selectQuestion(questionAnswerQueue[next].id)
    }

    func selectNextQuestion() {
        guard !questionAnswerQueue.isEmpty else { return }
        let current = selectedQuestionIndex ?? -1
        let next = (current + 1) % questionAnswerQueue.count
        selectQuestion(questionAnswerQueue[next].id)
    }

    func selectPresentationMode(_ mode: QuestionAnswerPresentationMode) {
        if mode == .transcript {
            sessionManager?.hydrateActiveTranscriptForPresentation()
            isShowingCopilotAnswerDetail = false
        }
        isShowingCopilotHistory = false
        questionAnswerPresentationMode = mode
    }

    func removeSelectedQuestionFromQueue() -> UUID? {
        guard let selectedQuestionId,
              let index = questionAnswerQueue.firstIndex(where: { $0.id == selectedQuestionId })
        else { return nil }
        let removed = selectedQuestionId
        questionAnswerQueue.remove(at: index)

        if questionAnswerQueue.isEmpty {
            self.selectedQuestionId = nil
            activeQuestion = nil
            questionClassification = nil
            detectedQuestion = nil
            answerStage = .idle
            suggestedAnswer = nil
            streamingAnswerText = ""
        } else {
            let nextIndex = min(index, questionAnswerQueue.count - 1)
            selectQuestion(questionAnswerQueue[nextIndex].id)
        }
        savedQuestionAnswerIds.remove(removed)
        return removed
    }

    func syncSelectedQuestionPresentation(preferredMode: NotchIslandMode? = nil) {
        guard let item = selectedQuestionQueueItem else { return }
        activeQuestion = item.candidate
        questionClassification = item.classification
        detectedQuestion = item.classification?.extractedQuestion ?? item.candidate.rawText
        answerStage = item.stage
        suggestedAnswer = item.answer
        streamingAnswerText = item.answer?.shortAnswer ?? item.streamingText

        if let preferredMode {
            islandMode = preferredMode
        } else if shouldKeepAmbientCopilotHidden(for: item) {
            islandMode = .idle
        } else if isPanelExpanded {
            islandMode = currentMeeting == nil ? .questionDetected : .listening
        } else if item.answer != nil && item.stage == .ready {
            islandMode = currentMeeting == nil ? .questionDetected : .listening
        } else if !item.streamingText.isEmpty {
            islandMode = currentMeeting == nil ? .questionDetected : .listening
        } else if [.classifying, .retrievingContext, .drafting, .finalizing].contains(item.stage) {
            islandMode = .thinking
        } else {
            islandMode = .questionDetected
        }
    }

    private func shouldKeepAmbientCopilotHidden(for _: QuestionAnswerQueueItem) -> Bool {
        guard currentMeeting == nil, !isPanelExpanded else { return false }
        guard let selectedQuestionQueueItem else { return false }
        if [.classifying, .retrievingContext, .drafting, .finalizing].contains(selectedQuestionQueueItem.stage) {
            return false
        }
        return true
    }

    func showQuestionAnswerPanel(mode: QuestionAnswerPresentationMode = .answer, selecting questionId: UUID? = nil) {
        let shouldPreserveCopilotAnswerDetail = mode == .answer &&
            questionId == nil &&
            isShowingCopilotAnswerDetail &&
            activeCopilotInteraction != nil &&
            activeQuestion == nil &&
            detectedQuestion == nil &&
            suggestedAnswer == nil &&
            streamingAnswerText.isEmpty
        if let questionId {
            selectQuestion(questionId)
        } else {
            syncSelectedQuestionPresentation()
        }
        questionAnswerPresentationMode = mode
        sessionManager?.hydrateActiveTranscriptForPresentation()
        isNotchHovered = false
        isShowingCopilotHistory = false
        isShowingCopilotAnswerDetail = shouldPreserveCopilotAnswerDetail
        isPanelExpanded = true
        islandMode = currentMeeting == nil ? .questionDetected : .listening
    }

    func showCopilotHistoryPanel() {
        reloadCopilotHistory()
        isNotchHovered = false
        isShowingCopilotHistory = true
        isShowingCopilotAnswerDetail = false
        isPanelExpanded = true
        islandMode = .questionDetected
        questionAnswerPresentationMode = .answer
        ambientCopilotStatus = "Hold to talk"
        copilotLastFailure = nil
    }

    func showSelectedCopilotAnswerPanel() {
        isNotchHovered = false
        isShowingCopilotHistory = false
        isShowingCopilotAnswerDetail = true
        isPanelExpanded = true
        questionAnswerPresentationMode = .answer
        copilotLastFailure = nil
        if currentMeeting != nil {
            sessionManager?.hydrateActiveTranscriptForPresentation()
            islandMode = .listening
        } else {
            islandMode = .questionDetected
        }
    }

    func startManualMeeting() {
        Task { await sessionManager?.startManualMeeting() }
    }

    func stopMeeting(autoEnded: Bool = false) {
        Task { await sessionManager?.stopMeeting(autoEnded: autoEnded) }
    }

    func pauseOrResume() {
        Task { await sessionManager?.pauseOrResume() }
    }

    func draftAnswer() {
        guard let detectedQuestion else { return }
        Task { await sessionManager?.draftAnswer(for: detectedQuestion) }
    }

    func regenerateSelectedAnswer(style: AnswerRefinementStyle) {
        guard let question = activeQuestion?.rawText ?? detectedQuestion else { return }
        answerStage = .drafting
        statusMessage = style.statusText
        showQuestionAnswerPanel(mode: .answer)
        Task { await sessionManager?.draftAnswer(for: question, refinementStyle: style) }
    }

    func saveSelectedQuestionAnswer() {
        guard let selectedQuestionId else { return }
        savedQuestionAnswerIds.insert(selectedQuestionId)
        statusMessage = suggestedAnswer == nil ? "Question saved" : "Answer saved"
        guard !ProcessInfo.processInfo.isQuestionAnsweringUITestHarness else { return }
        recordAnswerFeedback(.usedInMeeting, note: suggestedAnswer == nil ? "Question saved" : "Answer saved")
    }

    func applyEditedSuggestedAnswer(_ editedText: String) {
        let trimmed = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let question = activeQuestion ?? selectedQuestionQueueItem?.candidate
        else { return }

        let updated = updatedSuggestedAnswer(text: trimmed, questionId: question.id)
        updateQueuedQuestionAnswer(candidate: question, answer: updated)
        suggestedAnswer = updated
        streamingAnswerText = updated.shortAnswer
        statusMessage = "Answer edited"
        sessionManager?.replaceActiveSuggestedAnswer(updated, feedbackKind: .edited, note: "Edited answer")
    }

    func copySelectedAnswerToPasteboard() {
        let text = suggestedAnswer?.answerText ?? (streamingAnswerText.isEmpty ? activeCopilotInteraction?.response ?? "" : streamingAnswerText)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !ProcessInfo.processInfo.isQuestionAnsweringUITestHarness {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        statusMessage = "Answer copied"
        guard !ProcessInfo.processInfo.isQuestionAnsweringUITestHarness else { return }
        recordAnswerFeedback(.copied)
        recordCopilotFeedback(.copied)
    }

    func copySelectedFollowUpToPasteboard() {
        let text = selectedFollowUpQuestion
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Follow-up copied"
        recordAnswerFeedback(.regenerated, note: "Follow-up copied: \(text)")
    }

    func copyTranscriptSegmentToPasteboard(_ segment: TranscriptSegment, text overrideText: String? = nil) {
        let text = (overrideText ?? transcriptClipboardText(for: segment)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !ProcessInfo.processInfo.isQuestionAnsweringUITestHarness {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        statusMessage = "Transcript copied"
    }

    func deleteTranscriptSegment(_ segment: TranscriptSegment) {
        sessionManager?.deleteTranscriptSegment(segment.id, meetingId: segment.meetingId)
    }

    private func transcriptClipboardText(for segment: TranscriptSegment) -> String {
        let original = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = segment.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = segment.draftTranslatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTranslation = (translated?.isEmpty == false ? translated : draft) ?? ""

        if preferences.showTranslatedText, !displayTranslation.isEmpty {
            if preferences.showOriginalText, !original.isEmpty {
                return "\(displayTranslation)\n\(original)"
            }
            return displayTranslation
        }
        return original
    }

    func collapsePanelPreservingContext() {
        isShowingCopilotHistory = false
        if currentMeeting != nil {
            islandMode = .listening
        } else if activeQuestion != nil || suggestedAnswer != nil || !streamingAnswerText.isEmpty {
            islandMode = .idle
        }
        isPanelExpanded = false
    }

    func openCopilotFromHotkey() {
        isNotchHovered = false
        if currentMeeting != nil {
            sessionManager?.hydrateActiveTranscriptForPresentation()
            isShowingCopilotHistory = false
            isPanelExpanded.toggle()
            islandMode = .listening
            return
        }

        if isPanelExpanded {
            collapsePanelPreservingContext()
            islandMode = .idle
            return
        }

        showCopilotHistoryPanel()
    }

    func expandPanelPreservingContext() {
        sessionManager?.hydrateActiveTranscriptForPresentation()
        isNotchHovered = false
        isShowingCopilotHistory = false
        isPanelExpanded = true
        if activeQuestion != nil || suggestedAnswer != nil || !streamingAnswerText.isEmpty {
            islandMode = currentMeeting == nil ? .questionDetected : .listening
        }
    }

    func togglePanelExpansionPreservingContext() {
        if isPanelExpanded {
            collapsePanelPreservingContext()
        } else {
            expandPanelPreservingContext()
        }
    }

    func dismissActiveQuestion() {
        statusMessage = "Question dismissed"
        if let sessionManager {
            sessionManager.dismissActiveQuestion()
        } else {
            _ = removeSelectedQuestionFromQueue()
        }
    }

    func recordAnswerFeedback(_ kind: QuestionAnswerFeedbackKind, note: String? = nil) {
        guard !ProcessInfo.processInfo.isQuestionAnsweringUITestHarness else { return }
        sessionManager?.recordAnswerFeedback(kind, note: note)
    }

    private func updatedSuggestedAnswer(text: String, questionId: UUID) -> SuggestedAnswer {
        if let current = suggestedAnswer {
            return SuggestedAnswer(
                id: current.id,
                questionId: current.questionId,
                answerText: text,
                shortAnswer: text,
                confidence: current.confidence,
                riskLevel: current.riskLevel,
                usedSources: current.usedSources,
                assumptions: current.assumptions,
                caveats: current.caveats,
                generatedAt: Date(),
                latencyMs: current.latencyMs,
                expandedAnswer: text,
                suggestedTone: current.suggestedTone,
                shouldAskClarification: current.shouldAskClarification,
                clarifyingQuestion: current.clarifyingQuestion,
                language: current.language,
                provider: current.provider,
                usedCloud: current.usedCloud,
                usedRAG: current.usedRAG,
                answerFormat: current.answerFormat,
                richAnswer: RichAnswerFallbackBuilder.payload(
                    text: text,
                    format: current.answerFormat,
                    sources: current.usedSources,
                    confidence: current.confidence,
                    riskLevel: current.riskLevel,
                    tone: current.suggestedTone,
                    caveats: current.caveats
                )
            )
        }

        return SuggestedAnswer(
            questionId: questionId,
            answerText: text,
            shortAnswer: text,
            confidence: 0.65,
            riskLevel: .moderate,
            usedSources: [],
            assumptions: [],
            caveats: ["Edited manually by the user."],
            latencyMs: 0,
            expandedAnswer: text,
            richAnswer: RichAnswerFallbackBuilder.payload(text: text, format: .paragraph, sources: [], riskLevel: .moderate)
        )
    }

    func summarizeSoFar() {
        Task { await sessionManager?.summarizeCurrentMeeting(markEnded: false) }
    }

    func savePreferences() {
        persistPreferences(refreshConnectionStatus: true)
        ambientCopilotController?.evaluateRunningState()
    }

    func updateTranscriptionLanguage(_ language: String) {
        let normalizedLanguage = SupportedLanguage.normalizedCode(language)
        if currentMeeting != nil, let sessionManager {
            Task { await sessionManager.updateActiveTranscriptionLanguage(normalizedLanguage) }
            return
        }
        if currentMeeting != nil {
            currentMeeting?.primaryLanguage = normalizedLanguage
            return
        }
        preferences.defaultLanguage = normalizedLanguage
        savePreferences()
    }

    func updateTranscriptionMeetingType(_ meetingType: MeetingType) {
        if currentMeeting != nil, let sessionManager {
            Task { await sessionManager.updateActiveMeetingType(meetingType) }
            return
        }
        if currentMeeting != nil {
            currentMeeting?.meetingType = meetingType
            return
        }
        preferences.defaultMeetingType = meetingType
        savePreferences()
    }

    private func savePreferencesWithoutConnectionRefresh() {
        persistPreferences(refreshConnectionStatus: false)
    }

    private func persistPreferences(refreshConnectionStatus: Bool) {
        guard !isPersistingPreferences else { return }
        isPersistingPreferences = true
        let normalizedPreferences = preferences.normalizedForPersistence()
        if preferences != normalizedPreferences {
            preferences = normalizedPreferences
        }
        if let settingsRepository, lastPersistedPreferences != normalizedPreferences {
            settingsRepository.save(normalizedPreferences)
            lastPersistedPreferences = normalizedPreferences
        }
        isPersistingPreferences = false
        configureKnowledgeStore()
        capabilityReport = providerRouter?.report(preferences: preferences)
        if refreshConnectionStatus {
            refreshProviderConnectionStatuses()
        }
    }

    func setAmbientCopilotListening(_ isListening: Bool, status: String? = nil) {
        isAmbientCopilotListening = isListening
        if status?.localizedCaseInsensitiveContains("paused during") == true {
            copilotASRStatus = .pausedDuringMeeting
        } else {
            copilotASRStatus = isListening ? .listening : .idle
        }
        if let status {
            ambientCopilotStatus = status
        } else if isListening {
            ambientCopilotStatus = "Listening"
        }
    }

    func setCopilotRuntimeState(_ state: CopilotRuntimeState, failure: CopilotFailureKind? = nil, status: String? = nil) {
        copilotRuntimeState = state
        copilotLastFailure = failure
        ambientCopilotStatus = status ?? state.displayText
        if state.answerStage != .idle,
           let selectedQuestionId,
           questionAnswerQueue.contains(where: { $0.id == selectedQuestionId }) {
            updateQueuedQuestionStage(questionId: selectedQuestionId, stage: state.answerStage)
        }
    }

    func applyCopilotQualitySnapshot(_ snapshot: CopilotQualitySnapshot) {
        copilotQualitySnapshot = snapshot
    }

    func applyCopilotHealthSnapshot(_ snapshot: CopilotHealthSnapshot) {
        copilotHealthSnapshot = snapshot
        ambientCopilotStatus = snapshot.state.displayText
        if snapshot.state.isReady {
            isAmbientCopilotListening = false
            copilotASRStatus = .idle
        } else if snapshot.state == .meetingModePaused || snapshot.state == .llmProviderMissing || snapshot.state == .llmProviderInvalid || snapshot.state == .micPermissionBlocked {
            isAmbientCopilotListening = false
            copilotASRStatus = snapshot.state == .meetingModePaused ? .pausedDuringMeeting : .failed
        }
    }

    func applyCopilotActivationTrace(_ trace: CopilotActivationTrace) {
        latestCopilotActivationTrace = trace
    }

    func setCopilotAlwaysOnEnabled(_ isEnabled: Bool) {
        preferences.copilotHotkeyEnabled = isEnabled
        ambientCopilotStatus = isEnabled ? "Hotkey ready" : "Hotkey disabled"
        savePreferences()
    }

    func pauseCopilot() {
        setCopilotAlwaysOnEnabled(false)
    }

    func resumeCopilot() {
        setCopilotAlwaysOnEnabled(true)
    }

    func beginCopilotPushToTalk() {
        guard currentMeeting == nil else { return }
        guard !isCopilotPushToTalkProcessing else { return }
        suppressMeetingDetectionForCopilot()
        isNotchHovered = false
        isPanelExpanded = false
        islandMode = .idle
        isCopilotPushToTalkProcessing = false
        copilotPushToTalkErrorMessage = nil
        ambientCopilotStatus = "Listening"
        ambientCopilotController?.beginPushToTalk()
    }

    func endCopilotPushToTalk() {
        suppressMeetingDetectionForCopilot()
        ambientCopilotController?.endPushToTalk()
    }

    func updateCopilotPushToTalkTranscript(_ text: String) {
        copilotPushToTalkTranscript = text
        copilotPushToTalkErrorMessage = nil
    }

    func finishCopilotPushToTalk(status: String? = nil, errorMessage: String? = nil) {
        suppressMeetingDetectionForCopilot()
        isCopilotPushToTalkActive = false
        isCopilotPushToTalkProcessing = false
        if let status {
            ambientCopilotStatus = status
        }
        copilotPushToTalkErrorMessage = errorMessage
    }

    func setCopilotPushToTalkProcessing(_ isProcessing: Bool, status: String? = nil) {
        suppressMeetingDetectionForCopilot()
        isCopilotPushToTalkProcessing = isProcessing
        if isProcessing {
            isCopilotPushToTalkActive = false
        }
        if let status {
            ambientCopilotStatus = status
        }
    }

    func suppressMeetingDetectionForCopilot(
        now: Date = Date(),
        grace: TimeInterval = AppState.copilotMeetingDetectionSuppressionGrace
    ) {
        guard currentMeeting == nil else { return }
        let until = now.addingTimeInterval(grace)
        if let current = copilotMeetingDetectionSuppressedUntil, current > until {
            return
        }
        copilotMeetingDetectionSuppressedUntil = until
    }

    func shouldSuppressMeetingDetectionForCopilot(now: Date = Date()) -> Bool {
        guard currentMeeting == nil else { return false }
        if isCopilotPushToTalkActive || isCopilotPushToTalkProcessing || isAmbientCopilotListening {
            return true
        }
        guard let suppressedUntil = copilotMeetingDetectionSuppressedUntil else { return false }
        return suppressedUntil > now
    }

    func clearCopilotHistory() {
        copilotInteractions = []
        copilotReminders = []
        activeCopilotInteraction = nil
        isShowingCopilotAnswerDetail = false
        ambientCopilotController?.clearHistory()
    }

    func reloadCopilotHistory() {
        ambientCopilotController?.reloadStoredHistory()
    }

    func openSelectedAnswerSources() {
        let sources = suggestedAnswer?.usedSources ?? activeCopilotInteraction?.sources ?? []
        openAnswerSources(sources)
    }

    func regenerateSelectedCopilotAnswerWithWeb() {
        guard let question = activeQuestion?.rawText ?? detectedQuestion ?? activeCopilotInteraction?.prompt else { return }
        ambientCopilotController?.answerManually(question, forceWeb: true)
    }

    func selectCopilotInteraction(_ interaction: CopilotInteraction) {
        activeCopilotInteraction = interaction
        statusMessage = "Notchly interaction selected"
    }

    func openCopilotInteractionAnswer(_ interaction: CopilotInteraction) {
        selectCopilotInteraction(interaction)
        showSelectedCopilotAnswerPanel()
    }

    func copyCopilotInteractionToPasteboard(_ interaction: CopilotInteraction) {
        let text = interaction.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Answer copied"
        recordCopilotFeedback(.copied, for: interaction)
    }

    func openCopilotInteractionSources(_ interaction: CopilotInteraction) {
        openAnswerSources(interaction.sources)
    }

    func openAnswerSources(_ sources: [AnswerSource]) {
        for source in sources {
            if openLocalKnowledgeSource(source) {
                return
            }
            if openMeetingSource(source) {
                return
            }
            if let reference = source.reference,
               let url = URL(string: reference),
               ["http", "https"].contains(url.scheme?.lowercased()) {
                NSWorkspace.shared.open(url)
                statusMessage = "Source opened"
                return
            }
        }
        statusMessage = "No source link available"
    }

    private func openLocalKnowledgeSource(_ source: AnswerSource) -> Bool {
        guard let url = try? knowledgeStore?.fileURL(for: source) else { return false }
        if url.isFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
        statusMessage = source.locationLabel.map { "Opened source at \($0)" } ?? "Source opened"
        return true
    }

    private func openMeetingSource(_ source: AnswerSource) -> Bool {
        guard let reference = source.reference,
              let url = URL(string: reference),
              url.scheme == "notchly",
              url.host == "meeting" else {
            return false
        }
        let meetingIdString = url.pathComponents.dropFirst().first
        guard let meetingIdString,
              let meetingId = UUID(uuidString: meetingIdString),
              let meeting = history.first(where: { $0.id == meetingId }) else {
            return false
        }
        selectedMeeting = meeting
        openHistoryHandler?()
        statusMessage = source.locationLabel.map { "Opened meeting source at \($0)" } ?? "Meeting source opened"
        return true
    }

    func regenerateCopilotInteraction(_ interaction: CopilotInteraction, forceWeb: Bool) {
        selectCopilotInteraction(interaction)
        ambientCopilotController?.answerManually(interaction.prompt, forceWeb: forceWeb)
    }

    func analyzeCopilotPrompt(_ prompt: String, forceWeb: Bool) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ambientCopilotController?.answerManually(trimmed, forceWeb: forceWeb)
    }

    func applyCopilotInteraction(_ interaction: CopilotInteraction) {
        activeCopilotInteraction = interaction
        if let index = copilotInteractions.firstIndex(where: { $0.id == interaction.id }) {
            copilotInteractions[index] = interaction
        } else {
            copilotInteractions.insert(interaction, at: 0)
        }
        copilotInteractions.sort { $0.createdAt > $1.createdAt }
    }

    func recordCopilotFeedback(_ kind: QuestionAnswerFeedbackKind, note: String? = nil, for targetInteraction: CopilotInteraction? = nil) {
        guard !ProcessInfo.processInfo.isQuestionAnsweringUITestHarness else { return }
        guard var interaction = targetInteraction ?? activeCopilotInteraction else { return }
        interaction.feedbackEvents.append(QuestionAnswerFeedbackEvent(kind: kind, note: note))
        applyCopilotInteraction(interaction)
        ambientCopilotController?.saveInteraction(interaction)
    }

    func toggleLiveTranslation() {
        setLiveTranslationEnabled(!preferences.liveTranslationEnabled)
    }

    func setLiveTranslationEnabled(_ isEnabled: Bool) {
        preferences.liveTranslationEnabled = isEnabled
        preferences.showOriginalText = true
        preferences.showTranslatedText = isEnabled
        savePreferences()

        if isEnabled {
            prepareTranslationLanguages()
        } else {
            sessionManager?.cancelPendingTranslations()
        }
    }

    func prepareTranslationLanguages() {
        guard !isPreparingTranslationLanguages else { return }

        isPreparingTranslationLanguages = true
        sessionManager?.cancelPendingTranslations()
        translationPreparationStatus = "Preparing Portuguese <-> English..."

        Task {
            let service = AppleTranslationService()
            do {
                try await service.prepareLanguagePair(source: SupportedLanguage.portugueseBR.rawValue, target: SupportedLanguage.englishUS.rawValue)
                try await service.prepareLanguagePair(source: SupportedLanguage.englishUS.rawValue, target: SupportedLanguage.portugueseBR.rawValue)
                translationPreparationStatus = "Portuguese <-> English ready"
                if preferences.liveTranslationEnabled {
                    sessionManager?.refreshTranslationsForCurrentMeeting()
                }
            } catch {
                translationPreparationStatus = "Open the download prompt and keep it open until it finishes."
                AppLog.ai.error("Apple Translation language preparation failed: \(error.localizedDescription, privacy: .public)")
            }
            isPreparingTranslationLanguages = false
        }
    }

    func openTranslationSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func reloadHistory() {
        sessionManager?.reloadHistory()
    }

    func reloadKnowledgeDocuments() {
        configureKnowledgeStore()
        guard let knowledgeStore else {
            knowledgeDocumentNames = []
            knowledgeSources = []
            knowledgeSourceFileWatcher.stopAll()
            return
        }
        let documents = (try? knowledgeStore.documents()) ?? []
        knowledgeDocumentNames = documents.map(\.displayName)
        knowledgeSources = (try? knowledgeStore.sourceConnectionViewModels(workspaceId: preferences.workspaceId)) ?? []
        let totalChunks = knowledgeSources.map(\.chunkCount).reduce(0, +)
        let isIndexing = knowledgeSources.contains { $0.status == .indexing }
        let localProvider = localEmbeddingProvider()
        let healthReport = try? knowledgeStore.indexHealthReport(
            model: localProvider.modelIdentifier,
            workspaceId: preferences.workspaceId,
            latencyTargetMs: preferences.ragRealtimeLatencyTargetMs
        )
        let embeddedChunks = healthReport?.embeddedChunkCount ?? 0
        let indexedChunks = healthReport?.chunkCount ?? totalChunks
        retrievalStatus = RetrievalStatusViewModel(
            title: retrievalTitle(for: healthReport, sourceCount: knowledgeSources.count),
            detail: retrievalDetail(report: healthReport, totalChunks: indexedChunks, embeddedChunks: embeddedChunks),
            quality: "Local \(preferences.ragLocalEmbeddingTier.displayName) / \(localProvider.activeRuntime.displayName)",
            isIndexing: isIndexing || embeddedChunks < indexedChunks
        )
        refreshKnowledgeSourceWatcher()
        scheduleLocalEmbeddingBenchmarkIfNeeded(reason: "knowledge reload")
        if embeddedChunks < indexedChunks {
            scheduleKnowledgeEmbeddingIndexing(reason: "coverage")
        } else if indexedChunks > 0 {
            scheduleKnowledgeRetrievalWarmup(reason: "coverage ready")
        }
    }

    private func configureKnowledgeStore() {
        knowledgeStore?.configure(preferences: preferences)
    }

    private func localEmbeddingProvider() -> LocalEmbeddingProvider {
        LocalEmbeddingProvider(
            tier: preferences.ragLocalEmbeddingTier,
            runtime: preferences.resolvedLocalEmbeddingRuntime,
            allowModelDownloads: preferences.allowLocalModelDownloads,
            allowMetalAcceleration: preferences.ragAppleMetalAccelerationEnabled,
            serverConfiguration: preferences.localEmbeddingServerConfiguration
        )
    }

    private func retrievalDetail(totalChunks: Int, embeddedChunks: Int) -> String {
        let chunkText = totalChunks == 1 ? "1 indexed chunk" : "\(totalChunks) indexed chunks"
        guard totalChunks > 0 else { return chunkText }
        return "\(chunkText) • \(embeddedChunks)/\(totalChunks) local vectors"
    }

    private func retrievalTitle(for report: KnowledgeIndexHealthReport?, sourceCount: Int) -> String {
        guard sourceCount > 0 else { return "No sources connected" }
        guard let report else { return "\(sourceCount) sources connected" }
        if report.failedSourceCount > 0 {
            return "Knowledge needs attention"
        }
        if report.staleChunkCount > 0 {
            return "Preparing local knowledge"
        }
        return report.isReadyForRealtime ? "Local knowledge ready" : "\(sourceCount) sources connected"
    }

    private func retrievalDetail(
        report: KnowledgeIndexHealthReport?,
        totalChunks: Int,
        embeddedChunks: Int
    ) -> String {
        var detail = retrievalDetail(totalChunks: totalChunks, embeddedChunks: embeddedChunks)
        if let latency = report?.slowTraceP95Ms {
            detail += " • p95 \(latency)ms"
        }
        if report?.weakTraceCount ?? 0 > 0 {
            detail += " • \(report?.weakTraceCount ?? 0) weak"
        }
        return detail
    }

    private func scheduleKnowledgeEmbeddingIndexing(reason: String) {
        guard preferences.knowledgeSourcesEnabled, let knowledgeStore else { return }
        let workspaceId = preferences.workspaceId
        let provider = localEmbeddingProvider()
        knowledgeEmbeddingIndexTask?.cancel()
        knowledgeEmbeddingIndexTask = Task { @MainActor in
            await provider.prewarm()
            do {
                var didIndexAnyChunk = false
                while !Task.isCancelled {
                    let indexed = try await knowledgeStore.indexMissingEmbeddings(
                        provider: provider,
                        workspaceId: workspaceId,
                        limit: provider.tier.defaultBatchSize,
                        finalizeVectorShard: false
                    )
                    let coverage = (try? knowledgeStore.embeddingCoverage(model: provider.modelIdentifier, workspaceId: workspaceId)) ?? (embedded: 0, total: 0)
                    retrievalStatus = RetrievalStatusViewModel(
                        title: "Preparing local knowledge",
                        detail: retrievalDetail(totalChunks: coverage.total, embeddedChunks: coverage.embedded),
                        quality: "Local \(provider.tier.displayName) / \(provider.activeRuntime.displayName)",
                        isIndexing: coverage.embedded < coverage.total
                    )
                    if indexed == 0 {
                        if didIndexAnyChunk {
                            try knowledgeStore.finalizeEmbeddingIndex(model: provider.modelIdentifier, workspaceId: workspaceId)
                        }
                        break
                    }
                    didIndexAnyChunk = true
                    await Task.yield()
                }
                reloadKnowledgeDocuments()
            } catch {
                retrievalStatus = RetrievalStatusViewModel(
                    title: "Local knowledge paused",
                    detail: error.localizedDescription,
                    quality: "Local \(provider.tier.displayName) / \(provider.activeRuntime.displayName)",
                    isIndexing: false
                )
                AppLog.persistence.error("Local embedding indexing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func scheduleKnowledgeRetrievalWarmup(reason: String) {
        guard preferences.knowledgeSourcesEnabled, let knowledgeStore else { return }
        guard knowledgeRetrievalWarmupTask == nil else { return }
        let workspaceId = preferences.workspaceId
        let provider = localEmbeddingProvider()
        knowledgeRetrievalWarmupTask = Task { @MainActor in
            defer { knowledgeRetrievalWarmupTask = nil }
            do {
                let maintenance = try knowledgeStore.repairEmbeddingIndex(
                    model: provider.modelIdentifier,
                    workspaceId: workspaceId,
                    rebuildVectorShard: false
                )
                if maintenance.missingEmbeddingCount > 0 {
                    scheduleKnowledgeEmbeddingIndexing(reason: "maintenance")
                    return
                }
                let report = try knowledgeStore.warmRetrievalIndexes(
                    model: provider.modelIdentifier,
                    workspaceId: workspaceId
                )
                guard !Task.isCancelled, report.chunkCount > 0 else { return }
                retrievalStatus = RetrievalStatusViewModel(
                    title: "Local knowledge ready",
                    detail: retrievalDetail(totalChunks: report.chunkCount, embeddedChunks: report.embeddedVectorCount),
                    quality: "Local \(provider.tier.displayName) / \(provider.activeRuntime.displayName)",
                    isIndexing: false
                )
            } catch {
                AppLog.persistence.error("Local retrieval warmup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func runLocalEmbeddingBenchmark() {
        scheduleLocalEmbeddingBenchmark(reason: "manual", force: true)
    }

    private func scheduleLocalEmbeddingBenchmarkIfNeeded(reason: String) {
        guard preferences.ragLocalEmbeddingRuntime == .automatic else { return }
        guard localEmbeddingBenchmarkTask == nil else { return }
        if shouldRefreshLocalEmbeddingBenchmark() {
            scheduleLocalEmbeddingBenchmark(reason: reason, force: false)
        }
    }

    private func shouldRefreshLocalEmbeddingBenchmark() -> Bool {
        guard preferences.ragLocalEmbeddingRuntime == .automatic else { return false }
        guard let benchmark = preferences.ragLocalEmbeddingBenchmark else { return true }
        return benchmark.tier != preferences.ragLocalEmbeddingTier ||
            benchmark.targetModelId != preferences.ragLocalEmbeddingTier.modelProfile.targetModelId ||
            benchmark.targetLatencyMs != preferences.ragRealtimeLatencyTargetMs ||
            benchmark.machineFingerprint != LocalEmbeddingRuntimeSelector.machineFingerprint() ||
            (benchmark.selectedRuntime == .mlx && !preferences.ragAppleMetalAccelerationEnabled) ||
            (benchmark.selectedRuntime == .localServer && !preferences.localEmbeddingServerConfiguration.isUsable)
    }

    private func scheduleLocalEmbeddingBenchmark(reason: String, force: Bool) {
        guard force || shouldRefreshLocalEmbeddingBenchmark() else { return }
        let tier = preferences.ragLocalEmbeddingTier
        let targetLatencyMs = preferences.ragRealtimeLatencyTargetMs
        localEmbeddingBenchmarkTask?.cancel()
        localEmbeddingBenchmarkTask = Task { @MainActor in
            retrievalStatus = RetrievalStatusViewModel(
                title: "Benchmarking local embedding",
                detail: "\(tier.modelProfile.displayName) runtime selection",
                quality: "Local \(tier.displayName)",
                isIndexing: true
            )
            let result = await LocalEmbeddingRuntimeSelector(
                targetLatencyMs: targetLatencyMs,
                allowModelDownloads: preferences.allowLocalModelDownloads,
                allowMetalAcceleration: preferences.ragAppleMetalAccelerationEnabled,
                serverConfiguration: preferences.localEmbeddingServerConfiguration
            ).benchmark(tier: tier)
            guard !Task.isCancelled else { return }
            preferences.ragLocalEmbeddingBenchmark = result
            settingsStatus = "Local embedding: \(result.summary)"
            savePreferencesWithoutConnectionRefresh()
            localEmbeddingBenchmarkTask = nil
            reloadKnowledgeDocuments()
        }
    }

    private func refreshKnowledgeSourceWatcher() {
        guard preferences.knowledgeSourcesEnabled, !knowledgeSources.isEmpty else {
            knowledgeSourceFileWatcher.stopAll()
            return
        }
        knowledgeSourceFileWatcher.update(sources: knowledgeSources) { [weak self] sourceId in
            Task { @MainActor in
                self?.handleKnowledgeSourceDidChange(sourceId)
            }
        }
    }

    private func handleKnowledgeSourceDidChange(_ sourceId: UUID) {
        guard preferences.knowledgeSourcesEnabled else { return }
        guard knowledgeSources.contains(where: { $0.id == sourceId }) else { return }
        retrievalStatus = RetrievalStatusViewModel(
            title: "Syncing source",
            detail: "Reindexing changed files",
            quality: "Local \(preferences.ragLocalEmbeddingTier.displayName)",
            isIndexing: true
        )
        do {
            configureKnowledgeStore()
            _ = try knowledgeStore?.indexSource(sourceId)
            reloadKnowledgeDocuments()
            statusMessage = "Source updated"
        } catch {
            reloadKnowledgeDocuments()
            statusMessage = "Source sync failed"
        }
    }

    func reloadSpeechVocabulary() {
        guard let speechVocabularyStore else {
            speechVocabularyTerms = []
            speechVocabularyStatus = "Apple Speech ready"
            return
        }
        speechVocabularyStore.seedDefaultsIfNeeded(preferences: preferences)
        speechVocabularyTerms = speechVocabularyStore.terms()
        let activeCount = speechVocabularyTerms.filter(\.enabled).count
        let customCount = speechVocabularyTerms.filter { !$0.isSystemSeed }.count
        let backend = Self.nativeSpeechBackendStatus
        speechVocabularyStatus = activeCount == 0
            ? backend
            : "\(backend) • \(activeCount) active terms • \(customCount) custom"
    }

    func saveSpeechVocabularyTerm(_ term: SpeechVocabularyTerm) {
        speechVocabularyStore?.save(term)
        reloadSpeechVocabulary()
        settingsStatus = "Speech vocabulary saved"
    }

    func deleteSpeechVocabularyTerm(_ term: SpeechVocabularyTerm) {
        speechVocabularyStore?.delete(term)
        reloadSpeechVocabulary()
        settingsStatus = "Speech vocabulary term removed"
    }

    func clearUserSpeechVocabulary() {
        speechVocabularyStore?.deleteAllUserTerms()
        reloadSpeechVocabulary()
        settingsStatus = "Custom speech vocabulary cleared"
    }

    func addSpeechVocabularyTermFromText(_ text: String, category: SpeechVocabularyCategory = .custom) {
        let term = SpeechVocabularyTerm(
            text: text,
            locale: preferences.defaultLanguage,
            category: category,
            boost: 1.4,
            scope: .workspace,
            scopeValue: preferences.workspaceId
        )
        saveSpeechVocabularyTerm(term)
    }

    func recordSpeechVocabularyCorrection(original: String, corrected: String) {
        speechVocabularyStore?.recordCorrection(
            original: original,
            corrected: corrected,
            locale: preferences.defaultLanguage
        )
        reloadSpeechVocabulary()
        settingsStatus = "Speech correction learned"
    }

    func importSpeechVocabularyCSV(_ text: String) {
        let count = speechVocabularyStore?.importCSV(text, defaultLocale: preferences.defaultLanguage) ?? 0
        reloadSpeechVocabulary()
        settingsStatus = count == 1 ? "Imported 1 speech term" : "Imported \(count) speech terms"
    }

    func exportSpeechVocabularyCSVToPasteboard() {
        guard let csv = speechVocabularyStore?.exportCSV() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(csv, forType: .string)
        settingsStatus = "Speech vocabulary CSV copied"
    }

    private static var nativeSpeechBackendStatus: String {
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            return "SpeechAnalyzer ready"
        }
        return "Apple Speech ready"
    }

    func addKnowledgeFiles(urls: [URL]) {
        guard let knowledgeStore else { return }
        configureKnowledgeStore()
        let ingestion = DocumentIngestionService()
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            if let text = try? ingestion.readText(from: url) {
                try? knowledgeStore.addDocument(name: url.lastPathComponent, filePath: url.path, content: text)
            }
        }
        reloadKnowledgeDocuments()
    }

    func connectKnowledgeFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Files"
        panel.message = "Choose files Notchly can index for grounded Copilot answers."
        guard panel.runModal() == .OK else { return }
        addKnowledgeFiles(urls: panel.urls)
        statusMessage = panel.urls.count == 1 ? "File added" : "\(panel.urls.count) files added"
    }

    func connectKnowledgeDirectory(kind: KnowledgeSourceKind) {
        guard let knowledgeStore else { return }
        configureKnowledgeStore()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = kind == .obsidian ? "Connect Vault" : "Connect Folder"
        panel.message = kind == .obsidian ? "Choose an Obsidian vault folder." : "Choose a folder Notchly can index for meeting context."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let source = try knowledgeStore.connectDirectory(url, kind: kind, workspaceId: preferences.workspaceId)
            preferences.selectedKnowledgeSourceId = source.id
            preferences.copilotKnowledgeScope = .selectedSource
            savePreferences()
            reloadKnowledgeDocuments()
            statusMessage = "\(source.displayName) connected"
        } catch {
            statusMessage = "Could not connect source"
        }
    }

    func reindexKnowledgeSource(_ sourceId: UUID) {
        guard let knowledgeStore else { return }
        configureKnowledgeStore()
        do {
            _ = try knowledgeStore.indexSource(sourceId)
            reloadKnowledgeDocuments()
            statusMessage = "Source reindexed"
        } catch {
            statusMessage = "Reindex failed"
        }
    }

    func clearKnowledge() {
        try? knowledgeStore?.deleteAll()
        reloadKnowledgeDocuments()
    }

    func connectOpenAIAccount() {
        Task {
            do {
                if let openAIAccountOAuthProvider, openAIAccountOAuthProvider.isOfficialFlowAvailable {
                    let session = try await openAIAccountOAuthProvider.signIn()
                    completeOpenAIConnection(session: session, authMode: .openAIAccountOAuth)
                } else if let codexCLIAuthProvider {
                    preferences.aiConfig.provider = .openAI
                    preferences.aiConfig.authMode = .openAICodexCLI
                    preferences.aiConfig.cloudProcessingEnabled = true
                    preferences.localOnlyMode = false
                    savePreferencesWithoutConnectionRefresh()
                    settingsStatus = "Opening OpenAI approval. Copy the code into the browser page; Notchly will connect automatically."
                    let state = try await codexCLIAuthProvider.startDeviceLogin()
                    handleOpenAICodexLoginState(state)
                    if !state.needsBrowserApproval,
                       state.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        settingsStatus = "OpenAI approval could not start. Confirm the Codex CLI is installed and try again."
                    }
                } else {
                    throw AuthError.unsupportedOAuthFlow
                }
            } catch {
                handleAuthError(error)
            }
        }
    }

    func handleOpenAICodexLoginState(_ state: CodexCLILoginSessionState) {
        if !state.isRunning, state.authURL == nil, state.userCode == nil {
            openAICodexLoginSession = nil
            let output = state.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { return }
            openAIConnectionStatus = .notConnected
            settingsStatus = "OpenAI approval could not start. \(output)"
            return
        }

        if state.needsBrowserApproval {
            openAICodexLoginSession = state
        } else {
            openAICodexLoginSession = nil
        }

        if state.isRunning {
            if let userCode = state.userCode {
                settingsStatus = "OpenAI approval is waiting. Copy code \(userCode) into the browser page."
            } else {
                settingsStatus = "OpenAI approval is waiting in your browser."
            }
            completeOpenAICodexLoginAutomatically()
            return
        }

        guard state.authURL != nil || state.userCode != nil else { return }
        completeOpenAICodexLoginAutomatically()
    }

    private func completeOpenAICodexLoginAutomatically() {
        guard !isVerifyingOpenAICodexLogin,
              openAICodexLoginCompletionTask == nil else { return }
        if case .connected = openAIConnectionStatus { return }
        isVerifyingOpenAICodexLogin = true
        openAICodexLoginCompletionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isVerifyingOpenAICodexLogin = false
                self.openAICodexLoginCompletionTask = nil
            }
            do {
                settingsStatus = "Waiting for OpenAI approval to finish..."
                guard let session = try await codexCLIAuthProvider?.verifyDeviceLogin(maxWait: 10 * 60) else {
                    throw AuthError.notAuthenticated
                }
                completeOpenAIConnection(session: session, authMode: .openAICodexCLI)
                openAICodexLoginSession = nil
                settingsStatus = "Connected with OpenAI via ChatGPT/Codex CLI"
            } catch is CancellationError {
                return
            } catch {
                if case .connected = openAIConnectionStatus {
                    openAICodexLoginSession = nil
                    return
                }
                openAICodexLoginSession = codexCLIAuthProvider?.currentDeviceLoginState()
                openAIConnectionStatus = .notConnected
                if error as? AuthError == .notAuthenticated {
                    settingsStatus = "OpenAI approval is not verified yet. Keep the browser approval open and try again."
                } else {
                    handleAuthError(error)
                }
            }
        }
    }

    func cancelOpenAICodexLogin() {
        openAICodexLoginCompletionTask?.cancel()
        openAICodexLoginCompletionTask = nil
        isVerifyingOpenAICodexLogin = false
        codexCLIAuthProvider?.cancelDeviceLogin()
        openAICodexLoginSession = nil
        settingsStatus = "OpenAI approval cancelled"
    }

    func openOpenAICodexApprovalPage() {
        guard let url = openAICodexLoginSession?.authURL else { return }
        NSWorkspace.shared.open(url)
    }

    func disconnectOpenAIAccount() {
        Task {
            do {
                openAICodexLoginCompletionTask?.cancel()
                openAICodexLoginCompletionTask = nil
                isVerifyingOpenAICodexLogin = false
                openAICodexLoginSession = nil
                if preferences.aiConfig.authMode == .openAICodexCLI {
                    try await codexCLIAuthProvider?.signOut()
                } else if preferences.aiConfig.authMode == .apiKeyLegacy {
                    try await legacyAPIKeyAuthProvider?.signOut()
                } else {
                    try await openAIAccountOAuthProvider?.signOut()
                }
                openAIConnectionStatus = .notConnected
                if preferences.aiConfig.realtimeTranscriptionProvider == .openAI {
                    preferences.transcriptionEngineMode = .appleSpeech
                    savePreferencesWithoutConnectionRefresh()
                }
                settingsStatus = "OpenAI account disconnected"
            } catch {
                settingsStatus = "OpenAI disconnect failed"
            }
        }
    }

    func connectProviderAccount(_ provider: AIProviderKind) {
        let descriptor = ProviderRegistry.descriptor(for: provider)
        guard descriptor.supportedAuthKinds.contains(.accountLogin) else {
            settingsStatus = "\(descriptor.title) does not support account login."
            return
        }
        if let message = descriptor.accountLoginUnsupportedMessage {
            providerConnectionStatuses[descriptor.kind] = .unsupportedOAuthFlow
            settingsStatus = message
            return
        }
        if provider == .openAI {
            connectOpenAIAccount()
            return
        }
        guard let authMode = descriptor.accountAuthMode,
              let cliAuthProvider = cliAuthProvider(for: provider) else {
            providerConnectionStatuses[descriptor.kind] = .unsupportedOAuthFlow
            settingsStatus = AuthError.unsupportedProviderOAuth(descriptor.title).localizedDescription
            return
        }

        Task {
            do {
                preferences.aiConfig.provider = descriptor.kind
                preferences.aiConfig.authMode = authMode
                preferences.aiConfig.cloudProcessingEnabled = true
                preferences.localOnlyMode = false
                savePreferencesWithoutConnectionRefresh()
                settingsStatus = "Opening \(descriptor.title) account approval in your browser."
                let state = try await cliAuthProvider.startAccountLogin()
                handleProviderLoginState(state)
            } catch {
                handleAuthError(error)
            }
        }
    }

    func handleProviderLoginState(_ state: ProviderCLILoginSessionState) {
        if state.needsBrowserApproval {
            providerLoginSessions[state.provider] = state
        } else {
            providerLoginSessions.removeValue(forKey: state.provider)
        }

        let descriptor = ProviderRegistry.descriptor(for: state.provider)
        if state.isRunning {
            if let userCode = state.userCode {
                settingsStatus = "\(descriptor.title) approval is waiting. Copy code \(userCode) into the browser page."
            } else {
                settingsStatus = "\(descriptor.title) approval is waiting in your browser."
            }
            completeProviderLoginAutomatically(provider: state.provider)
            return
        }

        guard state.authURL != nil || state.userCode != nil else { return }
        completeProviderLoginAutomatically(provider: state.provider)
    }

    private func completeProviderLoginAutomatically(provider: AIProviderKind) {
        guard !verifyingProviderLogins.contains(provider),
              providerLoginCompletionTasks[provider] == nil,
              let cliAuthProvider = cliAuthProvider(for: provider) else { return }
        verifyingProviderLogins.insert(provider)
        providerLoginCompletionTasks[provider] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.verifyingProviderLogins.remove(provider)
                self.providerLoginCompletionTasks[provider] = nil
            }
            do {
                let descriptor = ProviderRegistry.descriptor(for: provider)
                settingsStatus = "Waiting for \(descriptor.title) approval to finish..."
                let session = try await cliAuthProvider.verifyAccountLogin(maxWait: 10 * 60)
                completeProviderConnection(provider: provider, session: session, authMode: descriptor.accountAuthMode ?? preferences.aiConfig.authMode)
            } catch is CancellationError {
                return
            } catch {
                providerLoginSessions[provider] = cliAuthProvider.currentAccountLoginState()
                providerConnectionStatuses[provider] = .notConnected
                if error as? AuthError == .notAuthenticated {
                    settingsStatus = "\(ProviderRegistry.descriptor(for: provider).title) approval is not verified yet. Keep the browser approval open and try again."
                } else {
                    handleAuthError(error)
                }
            }
        }
    }

    func submitProviderAccountCode(_ provider: AIProviderKind, code: String) {
        Task {
            do {
                guard let state = try await cliAuthProvider(for: provider)?.submitAccountCode(code) else {
                    throw AuthError.notAuthenticated
                }
                handleProviderLoginState(state)
            } catch {
                handleAuthError(error)
            }
        }
    }

    func cancelProviderAccountLogin(_ provider: AIProviderKind) {
        providerLoginCompletionTasks[provider]?.cancel()
        providerLoginCompletionTasks[provider] = nil
        verifyingProviderLogins.remove(provider)
        cliAuthProvider(for: provider)?.cancelAccountLogin()
        providerLoginSessions.removeValue(forKey: provider)
        settingsStatus = "\(ProviderRegistry.descriptor(for: provider).title) approval cancelled"
    }

    func openProviderApprovalPage(_ provider: AIProviderKind) {
        guard let url = providerLoginSessions[provider]?.authURL else { return }
        NSWorkspace.shared.open(url)
    }

    func saveProviderAPIKey(_ provider: AIProviderKind, value: String) {
        let descriptor = ProviderRegistry.descriptor(for: provider)
        guard descriptor.apiKeyAuthMode != nil else {
            settingsStatus = "\(descriptor.title) does not support API keys."
            return
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                if trimmedValue.isEmpty {
                    try deleteProviderAPIKey(provider)
                    providerConnectionStatuses[provider] = .notConnected
                    if provider == .openAI { openAIConnectionStatus = .notConnected }
                    if let realtimeProvider = realtimeTranscriptionProvider(forLLMProvider: provider) {
                        markRealtimeTranscriptionProviderDisconnected(realtimeProvider)
                        if preferences.aiConfig.realtimeTranscriptionProvider == realtimeProvider {
                            preferences.transcriptionEngineMode = .appleSpeech
                            savePreferencesWithoutConnectionRefresh()
                        }
                    }
                    settingsStatus = "\(descriptor.title) API key removed"
                    refreshAIModelCatalog()
                    return
                }

                settingsStatus = "Testing \(descriptor.title) API key..."
                try await validateProviderAPIKey(provider, value: trimmedValue)
                try saveProviderAPIKeyToKeychain(provider, value: trimmedValue)

                preferences.aiConfig.provider = descriptor.kind
                preferences.aiConfig.authMode = descriptor.apiKeyAuthMode ?? descriptor.defaultAuthMode
                preferences.aiConfig.cloudProcessingEnabled = true
                preferences.localOnlyMode = false
                if provider == .openAI {
                    preferences.aiConfig.legacyAPIKeyAccessEnabled = true
                }
                savePreferencesWithoutConnectionRefresh()
                providerConnectionStatuses[provider] = .connected(email: nil)
                if provider == .openAI { openAIConnectionStatus = .connected(email: nil) }
                if let realtimeProvider = realtimeTranscriptionProvider(forLLMProvider: provider) {
                    markRealtimeTranscriptionProviderConnected(realtimeProvider)
                }
                settingsStatus = "\(descriptor.title) API key saved and verified"
                refreshAIModelCatalog()
            } catch {
                providerConnectionStatuses[provider] = hasProviderAPIKey(provider) ? .connected(email: nil) : .notConnected
                if provider == .openAI {
                    openAIConnectionStatus = hasProviderAPIKey(provider) ? .connected(email: nil) : .notConnected
                }
                if let realtimeProvider = realtimeTranscriptionProvider(forLLMProvider: provider) {
                    refreshRealtimeTranscriptionConnectionStatus(for: realtimeProvider)
                }
                settingsStatus = "\(descriptor.title) API key could not be verified. Existing saved key was kept."
            }
        }
    }

    func hasProviderAPIKey(_ provider: AIProviderKind) -> Bool {
        if provider == .openAI {
            return legacyAPIKeyAuthProvider?.isAuthenticated == true
        }
        return apiKeyAuthProvider(for: provider)?.isAuthenticated == true
    }

    func useProviderAPIKeyMode(_ provider: AIProviderKind) {
        if provider == .openAI {
            preferences.aiConfig.legacyAPIKeyAccessEnabled = true
            enableLegacyOpenAIKeyMode()
            return
        }
        let descriptor = ProviderRegistry.descriptor(for: provider)
        guard let authMode = descriptor.apiKeyAuthMode else {
            settingsStatus = "\(descriptor.title) does not support API keys."
            return
        }
        guard apiKeyAuthProvider(for: provider)?.isAuthenticated == true else {
            settingsStatus = "Save a \(descriptor.title) API key first."
            return
        }
        preferences.aiConfig.provider = descriptor.kind
        preferences.aiConfig.authMode = authMode
        preferences.aiConfig.cloudProcessingEnabled = true
        preferences.localOnlyMode = false
        if provider == .openAI { preferences.aiConfig.legacyAPIKeyAccessEnabled = true }
        savePreferences()
        settingsStatus = "\(descriptor.title) API key mode enabled"
        refreshAIModelCatalog()
    }

    func realtimeTranscriptionConnectionStatus(for provider: RealtimeTranscriptionProvider) -> AIConnectionStatus {
        return hasRealtimeTranscriptionAPIKey(provider) ? .connected(email: nil) : .notConnected
    }

    func hasRealtimeTranscriptionAPIKey(_ provider: RealtimeTranscriptionProvider) -> Bool {
        realtimeTranscriptionAPIKeyAuthProvider(for: provider)?.isAuthenticated == true
    }

    func saveRealtimeTranscriptionAPIKey(_ provider: RealtimeTranscriptionProvider, value: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                if trimmedValue.isEmpty {
                    try deleteRealtimeTranscriptionAPIKey(for: provider)
                    markRealtimeTranscriptionProviderDisconnected(provider)
                    if preferences.aiConfig.realtimeTranscriptionProvider == provider {
                        preferences.transcriptionEngineMode = .appleSpeech
                        savePreferencesWithoutConnectionRefresh()
                    }
                    settingsStatus = "\(provider.displayName) API key removed"
                    refreshAIModelCatalog()
                    return
                }

                settingsStatus = "Testing \(provider.displayName) realtime key..."
                try await validateRealtimeTranscriptionAPIKey(provider, value: trimmedValue)
                try saveRealtimeTranscriptionAPIKeyToKeychain(provider, value: trimmedValue)

                preferences.localOnlyMode = false
                preferences.aiConfig.realtimeTranscriptionProvider = provider
                preferences.aiConfig.realtimeTranscriptionModel = normalizedRealtimeTranscriptionModel(for: provider)
                markSharedLLMAPIKeyAvailableIfNeeded(for: provider)
                savePreferencesWithoutConnectionRefresh()
                markRealtimeTranscriptionProviderConnected(provider)
                settingsStatus = "\(provider.displayName) API key saved and verified"
                refreshAIModelCatalog()
            } catch {
                refreshRealtimeTranscriptionConnectionStatus(for: provider)
                settingsStatus = "\(provider.displayName) API key could not be verified. Existing saved key was kept."
            }
        }
    }

    func useRealtimeTranscriptionProvider(_ provider: RealtimeTranscriptionProvider) {
        guard hasRealtimeTranscriptionAPIKey(provider) else {
            settingsStatus = "Save a \(provider.displayName) API key first."
            return
        }
        preferences.localOnlyMode = false
        preferences.aiConfig.realtimeTranscriptionProvider = provider
        preferences.aiConfig.realtimeTranscriptionModel = normalizedRealtimeTranscriptionModel(for: provider)
        preferences.transcriptionEngineMode = .cloudRealtime
        markSharedLLMAPIKeyAvailableIfNeeded(for: provider)
        savePreferences()
        settingsStatus = "\(provider.displayName) realtime transcription enabled"
        refreshAIModelCatalog()
    }

    func hasElevenLabsAPIKey() -> Bool {
        hasRealtimeTranscriptionAPIKey(.elevenLabs)
    }

    func saveElevenLabsAPIKey(_ value: String) {
        saveRealtimeTranscriptionAPIKey(.elevenLabs, value: value)
    }

    func useElevenLabsRealtimeTranscription() {
        useRealtimeTranscriptionProvider(.elevenLabs)
    }

    private func realtimeTranscriptionAPIKeyAuthProvider(for provider: RealtimeTranscriptionProvider) -> (any AuthProvider)? {
        switch provider {
        case .elevenLabs:
            elevenLabsAPIKeyAuthProvider
        case .openAI:
            legacyAPIKeyAuthProvider
        case .googleGemini:
            geminiAPIKeyAuthProvider
        }
    }

    private func realtimeTranscriptionProvider(forLLMProvider provider: AIProviderKind) -> RealtimeTranscriptionProvider? {
        switch provider {
        case .openAI:
            .openAI
        case .googleGemini:
            .googleGemini
        case .appleLocal, .appleFoundationModels, .anthropicClaude, .perplexity:
            nil
        }
    }

    private func saveRealtimeTranscriptionAPIKeyToKeychain(_ provider: RealtimeTranscriptionProvider, value: String) throws {
        switch provider {
        case .elevenLabs:
            guard let elevenLabsAPIKeyAuthProvider else { throw AuthError.missingConfiguration }
            try elevenLabsAPIKeyAuthProvider.setAPIKey(value)
        case .openAI:
            try saveProviderAPIKeyToKeychain(.openAI, value: value)
        case .googleGemini:
            try saveProviderAPIKeyToKeychain(.googleGemini, value: value)
        }
    }

    private func deleteRealtimeTranscriptionAPIKey(for provider: RealtimeTranscriptionProvider) throws {
        switch provider {
        case .elevenLabs:
            guard let elevenLabsAPIKeyAuthProvider else { throw AuthError.missingConfiguration }
            try elevenLabsAPIKeyAuthProvider.setAPIKey("")
        case .openAI:
            try deleteProviderAPIKey(.openAI)
        case .googleGemini:
            try deleteProviderAPIKey(.googleGemini)
        }
    }

    private func validateRealtimeTranscriptionAPIKey(_ provider: RealtimeTranscriptionProvider, value: String) async throws {
        let modelID = normalizedRealtimeTranscriptionModel(for: provider)
        switch provider {
        case .elevenLabs:
            try await ElevenLabsRealtimeTranscriptionService.validateAPIKey(
                value,
                modelID: modelID,
                languageCode: preferences.defaultLanguage
            )
        case .openAI:
            try await OpenAIRealtimeTranscriptionService.validateAPIKey(
                value,
                modelID: modelID,
                languageCode: preferences.defaultLanguage
            )
        case .googleGemini:
            try await GeminiLiveRealtimeTranscriptionService.validateAPIKey(
                value,
                modelID: modelID,
                languageCode: preferences.defaultLanguage
            )
        }
    }

    private func normalizedRealtimeTranscriptionModel(for provider: RealtimeTranscriptionProvider) -> String {
        let current = preferences.aiConfig.realtimeTranscriptionProvider == provider ? preferences.aiConfig.realtimeTranscriptionModel : nil
        let options: [AIModelOption]
        switch provider {
        case .elevenLabs:
            options = AIModelCatalog.elevenLabsRealtime.transcriptionModels
        case .openAI:
            options = AIModelCatalog.openAIRealtimeTranscription.transcriptionModels
        case .googleGemini:
            options = AIModelCatalog.geminiLiveRealtime.transcriptionModels
        }
        if let current, options.contains(where: { $0.id == current }) {
            return current
        }
        return provider.defaultModelID
    }

    private func markSharedLLMAPIKeyAvailableIfNeeded(for provider: RealtimeTranscriptionProvider) {
        if provider == .openAI {
            preferences.aiConfig.legacyAPIKeyAccessEnabled = true
        }
    }

    private func markRealtimeTranscriptionProviderConnected(_ provider: RealtimeTranscriptionProvider) {
        switch provider {
        case .elevenLabs:
            elevenLabsConnectionStatus = .connected(email: nil)
        case .openAI:
            openAIConnectionStatus = .connected(email: nil)
            providerConnectionStatuses[.openAI] = .connected(email: nil)
        case .googleGemini:
            providerConnectionStatuses[.googleGemini] = .connected(email: nil)
        }
    }

    private func markRealtimeTranscriptionProviderDisconnected(_ provider: RealtimeTranscriptionProvider) {
        switch provider {
        case .elevenLabs:
            elevenLabsConnectionStatus = .notConnected
        case .openAI:
            openAIConnectionStatus = .notConnected
            providerConnectionStatuses[.openAI] = .notConnected
        case .googleGemini:
            providerConnectionStatuses[.googleGemini] = .notConnected
        }
    }

    private func refreshRealtimeTranscriptionConnectionStatus(for provider: RealtimeTranscriptionProvider) {
        if hasRealtimeTranscriptionAPIKey(provider) {
            markRealtimeTranscriptionProviderConnected(provider)
        } else {
            markRealtimeTranscriptionProviderDisconnected(provider)
        }
    }

    func useProviderLocalMode(_ provider: AIProviderKind) {
        guard provider == .appleLocal || provider == .appleFoundationModels else { return }
        useLocalOnlyMode()
    }

    func disconnectProvider(_ provider: AIProviderKind) {
        if provider == .openAI {
            disconnectOpenAIAccount()
            return
        }
        Task {
            do {
                providerLoginCompletionTasks[provider]?.cancel()
                providerLoginCompletionTasks[provider] = nil
                verifyingProviderLogins.remove(provider)
                providerLoginSessions.removeValue(forKey: provider)
                try await cliAuthProvider(for: provider)?.signOut()
                try await apiKeyAuthProvider(for: provider)?.signOut()
                providerConnectionStatuses[provider] = .notConnected
                if preferences.aiConfig.realtimeTranscriptionProvider?.llmProviderKind == provider {
                    preferences.transcriptionEngineMode = .appleSpeech
                    savePreferencesWithoutConnectionRefresh()
                }
                settingsStatus = "\(ProviderRegistry.descriptor(for: provider).title) disconnected"
                refreshAIModelCatalog()
            } catch {
                settingsStatus = "\(ProviderRegistry.descriptor(for: provider).title) disconnect failed"
            }
        }
    }

    func providerConnectionStatus(for provider: AIProviderKind) -> AIConnectionStatus {
        if provider == .openAI {
            if legacyAPIKeyAuthProvider?.isAuthenticated == true {
                return .connected(email: nil)
            }
            return openAIConnectionStatus
        }
        if preferences.localOnlyMode, provider == .appleLocal {
            return .localOnlyMode
        }
        return providerConnectionStatuses[provider] ?? .notConnected
    }

    private func completeProviderConnection(provider: AIProviderKind, session: AuthSession, authMode: AIAuthMode) {
        let descriptor = ProviderRegistry.descriptor(for: provider)
        preferences.aiConfig.provider = descriptor.kind
        preferences.aiConfig.authMode = authMode
        preferences.aiConfig.cloudProcessingEnabled = true
        preferences.localOnlyMode = false
        providerLoginSessions.removeValue(forKey: provider)
        savePreferencesWithoutConnectionRefresh()
        providerConnectionStatuses[provider] = .connected(email: session.accountEmail)
        settingsStatus = session.accountEmail.map { "Connected to \(descriptor.title) as \($0)" } ?? "Connected to \(descriptor.title)"
        refreshAIModelCatalog()
    }

    private func cliAuthProvider(for provider: AIProviderKind) -> ProviderCLIAuthProvider? {
        switch provider {
        case .googleGemini:
            return geminiCLIAuthProvider
        case .anthropicClaude:
            return anthropicCLIAuthProvider
        default:
            return nil
        }
    }

    private func apiKeyAuthProvider(for provider: AIProviderKind) -> ProviderAPIKeyAuthProvider? {
        switch provider {
        case .googleGemini:
            return geminiAPIKeyAuthProvider
        case .anthropicClaude:
            return anthropicAPIKeyAuthProvider
        case .perplexity:
            return perplexityAPIKeyAuthProvider
        default:
            return nil
        }
    }

    private func saveProviderAPIKeyToKeychain(_ provider: AIProviderKind, value: String) throws {
        if provider == .openAI {
            guard let legacyAPIKeyAuthProvider else { throw AuthError.missingConfiguration }
            try legacyAPIKeyAuthProvider.setAPIKey(value)
        } else {
            guard let apiKeyAuthProvider = apiKeyAuthProvider(for: provider) else { throw AuthError.missingConfiguration }
            try apiKeyAuthProvider.setAPIKey(value)
        }
    }

    private func deleteProviderAPIKey(_ provider: AIProviderKind) throws {
        if provider == .openAI {
            guard let legacyAPIKeyAuthProvider else { throw AuthError.missingConfiguration }
            try legacyAPIKeyAuthProvider.setAPIKey("")
        } else {
            guard let apiKeyAuthProvider = apiKeyAuthProvider(for: provider) else { throw AuthError.missingConfiguration }
            try apiKeyAuthProvider.setAPIKey("")
        }
    }

    private func validateProviderAPIKey(_ provider: AIProviderKind, value: String) async throws {
        let descriptor = ProviderRegistry.descriptor(for: provider)
        guard let apiKeyAuthMode = descriptor.apiKeyAuthMode else {
            throw AuthError.unsupportedAccessMode
        }
        var validationPreferences = preferences
        validationPreferences.localOnlyMode = false
        validationPreferences.aiConfig.provider = descriptor.kind
        validationPreferences.aiConfig.authMode = apiKeyAuthMode
        validationPreferences.aiConfig.cloudProcessingEnabled = true
        validationPreferences.aiConfig.legacyAPIKeyAccessEnabled = provider == .openAI
        let authProvider = EphemeralAuthProvider(session: AuthSession(
            provider: ProviderRegistry.authProviderType(for: apiKeyAuthMode),
            accessToken: value,
            refreshToken: nil,
            expiresAt: nil,
            accountEmail: nil,
            accountId: nil,
            scopes: ["api-key"]
        ))

        switch provider {
        case .openAI:
            _ = try await OpenAIProvider(authProvider: authProvider) { validationPreferences }.availableModelCatalog()
        case .googleGemini:
            _ = try await GoogleGeminiProvider(authProvider: authProvider) { validationPreferences }.availableModelCatalog()
        case .anthropicClaude:
            _ = try await AnthropicClaudeProvider(authProvider: authProvider) { validationPreferences }.availableModelCatalog()
        case .perplexity:
            try await PerplexityProvider(authProvider: authProvider) { validationPreferences }.validateConnection()
        default:
            throw AuthError.unsupportedAccessMode
        }
    }

    private func completeOpenAIConnection(session: AuthSession, authMode: AIAuthMode) {
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = authMode
        preferences.aiConfig.cloudProcessingEnabled = true
        preferences.localOnlyMode = false
        openAICodexLoginSession = nil
        if authMode == .openAICodexCLI {
            savePreferencesWithoutConnectionRefresh()
        } else {
            savePreferences()
        }
        openAIConnectionStatus = .connected(email: session.accountEmail)
        if authMode == .openAICodexCLI {
            settingsStatus = "Connected with OpenAI via ChatGPT/Codex CLI"
        } else {
            settingsStatus = session.accountEmail.map { "Connected as \($0)" } ?? "Connected with OpenAI"
        }
        refreshAIModelCatalog()
    }

    func refreshOpenAIConnectionStatus() {
        Task { await updateAllProviderConnectionStatuses() }
    }

    func refreshProviderConnectionStatuses() {
        Task { await updateAllProviderConnectionStatuses() }
    }

    func refreshAIModelCatalog() {
        Task { await updateAIModelCatalog() }
    }

    func selectAIChatModel(_ modelID: String) {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model = aiModelCatalog.chatModels.first(where: { $0.id == trimmedModelID }) else {
            settingsStatus = "Model is not available for the selected provider."
            return
        }
        preferences.aiConfig.model = model.id
        savePreferencesWithoutConnectionRefresh()
        settingsStatus = "Using \(model.displayName)"
    }

    func saveOpenAIKey(_ value: String) {
        saveLegacyOpenAIKey(value)
    }

    func saveLegacyOpenAIKey(_ value: String) {
        do {
            try legacyAPIKeyAuthProvider?.setAPIKey(value)
            settingsStatus = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Legacy API key removed"
                : "Legacy API key saved in Keychain"
            refreshOpenAIConnectionStatus()
        } catch {
            settingsStatus = "Keychain save failed"
        }
    }

    func enableLegacyOpenAIKeyMode() {
        if !preferences.aiConfig.legacyAPIKeyAccessEnabled {
            preferences.aiConfig.legacyAPIKeyAccessEnabled = true
        }
        guard legacyAPIKeyAuthProvider?.isAuthenticated == true else {
            settingsStatus = "Save an OpenAI API key before enabling this mode."
            return
        }
        preferences.aiConfig.provider = .openAI
        preferences.aiConfig.authMode = .apiKeyLegacy
        preferences.aiConfig.cloudProcessingEnabled = true
        preferences.localOnlyMode = false
        savePreferences()
        settingsStatus = "OpenAI API key mode enabled"
        refreshAIModelCatalog()
    }

    func useLocalOnlyMode() {
        codexCLIAuthProvider?.cancelDeviceLogin()
        openAICodexLoginSession = nil
        preferences.localOnlyMode = true
        preferences.aiConfig.provider = .appleLocal
        preferences.aiConfig.authMode = .appleLocal
        preferences.aiConfig.cloudProcessingEnabled = false
        preferences.aiConfig.webSearchEnabled = false
        preferences.transcriptionEngineMode = .appleSpeech
        savePreferences()
        applyAIModelCatalog(.local)
        settingsStatus = "Apple Local enabled"
    }

    func clearAllAuthData() {
        Task {
            try? await openAIAccountOAuthProvider?.signOut()
            try? await codexCLIAuthProvider?.signOut()
            try? await legacyAPIKeyAuthProvider?.signOut()
            try? await geminiCLIAuthProvider?.signOut()
            try? await geminiAPIKeyAuthProvider?.signOut()
            try? await anthropicCLIAuthProvider?.signOut()
            try? await anthropicAPIKeyAuthProvider?.signOut()
            try? await perplexityAPIKeyAuthProvider?.signOut()
            try? await elevenLabsAPIKeyAuthProvider?.signOut()
            try? tokenStore?.deleteAllSessions()
            openAICodexLoginSession = nil
            providerLoginSessions.removeAll()
            providerConnectionStatuses.removeAll()
            openAIConnectionStatus = preferences.localOnlyMode ? .localOnlyMode : .notConnected
            elevenLabsConnectionStatus = preferences.localOnlyMode ? .localOnlyMode : .notConnected
            refreshAIModelCatalog()
            settingsStatus = "All auth data cleared"
        }
    }

    private func updateAIModelCatalog() async {
        isRefreshingAIModelCatalog = true
        defer { isRefreshingAIModelCatalog = false }

        do {
            let catalog = try await loadAIModelCatalog()
            applyAIModelCatalog(catalog)
            aiModelCatalogStatus = catalog.isDynamic
                ? "Models loaded from \(catalog.source)"
                : "Models shown from \(catalog.source)"
        } catch {
            let catalog = fallbackModelCatalogForCurrentMode()
            applyAIModelCatalog(catalog)
            aiModelCatalogStatus = "Could not refresh models. Showing \(catalog.source)."
        }
    }

    private func loadAIModelCatalog() async throws -> AIModelCatalog {
        if preferences.localOnlyMode {
            return .local
        }
        switch preferences.aiConfig.authMode {
        case .appleLocal:
            return .local
        case .openAICodexCLI:
            return CodexCLIAIProvider.availableModelCatalog()
        case .openAIAccountOAuth:
            guard let openAIProvider,
                  openAIAccountOAuthProvider?.isOfficialFlowAvailable == true,
                  openAIAccountOAuthProvider?.hasCachedSession == true,
                  try await openAIAccountOAuthProvider?.currentSession() != nil else {
                return .openAIFallback
            }
            return try await openAIProvider.availableModelCatalog()
        case .apiKeyLegacy:
            guard preferences.aiConfig.legacyAPIKeyAccessEnabled,
                  legacyAPIKeyAuthProvider?.hasCachedCredential == true,
                  let legacyOpenAIProvider else {
                return .openAIFallback
            }
            return try await legacyOpenAIProvider.availableModelCatalog()
        case .googleGeminiOAuth:
            return .geminiFallback
        case .googleGeminiAPIKey:
            guard geminiAPIKeyAuthProvider?.hasCachedCredential == true,
                  let geminiAPIKeyProvider else {
                return .geminiFallback
            }
            return try await geminiAPIKeyProvider.availableModelCatalog()
        case .anthropicClaudeOAuth:
            return .anthropicFallback
        case .anthropicClaudeAPIKey:
            guard anthropicAPIKeyAuthProvider?.hasCachedCredential == true,
                  let anthropicAPIKeyProvider else {
                return .anthropicFallback
            }
            return try await anthropicAPIKeyProvider.availableModelCatalog()
        case .perplexityOAuth:
            return .perplexityFallback
        case .perplexityAPIKey:
            guard perplexityAPIKeyAuthProvider?.hasCachedCredential == true else {
                return .perplexityFallback
            }
            return .perplexityFallback
        }
    }

    private func fallbackModelCatalogForCurrentMode() -> AIModelCatalog {
        if preferences.localOnlyMode { return .local }
        switch preferences.aiConfig.authMode {
        case .appleLocal:
            return .local
        case .openAICodexCLI:
            return .codexFallback
        case .openAIAccountOAuth, .apiKeyLegacy:
            return .openAIFallback
        case .googleGeminiOAuth, .googleGeminiAPIKey:
            return .geminiFallback
        case .anthropicClaudeOAuth, .anthropicClaudeAPIKey:
            return .anthropicFallback
        case .perplexityOAuth, .perplexityAPIKey:
            return .perplexityFallback
        }
    }

    private func applyAIModelCatalog(_ catalog: AIModelCatalog) {
        aiModelCatalog = catalog
        var didChangePreferences = false
        if let chatModel = catalog.chatModels.first,
           !catalog.chatModels.contains(where: { $0.id == preferences.aiConfig.model }) {
            preferences.aiConfig.model = chatModel.id
            didChangePreferences = true
        }
        didChangePreferences = applyOptionalModel(
            options: catalog.translationModels,
            value: \.aiConfig.translationModel
        ) || didChangePreferences
        didChangePreferences = applyOptionalModel(
            options: catalog.realtimeModels,
            value: \.aiConfig.realtimeModel
        ) || didChangePreferences
        didChangePreferences = applyOptionalModel(
            options: catalog.embeddingModels,
            value: \.aiConfig.embeddingModel
        ) || didChangePreferences
        if didChangePreferences {
            savePreferencesWithoutConnectionRefresh()
        }
    }

    private func applyOptionalModel(
        options: [AIModelOption],
        value: WritableKeyPath<AppPreferences, String?>
    ) -> Bool {
        if options.isEmpty {
            guard preferences[keyPath: value] != nil else { return false }
            preferences[keyPath: value] = nil
            return true
        }
        guard let current = preferences[keyPath: value],
              options.contains(where: { $0.id == current }) else {
            preferences[keyPath: value] = options[0].id
            return true
        }
        return false
    }

    private func updateAllProviderConnectionStatuses() async {
        await updateOpenAIConnectionStatus()
        await updateProviderConnectionStatus(.googleGemini)
        await updateProviderConnectionStatus(.anthropicClaude)
        await updateProviderConnectionStatus(.perplexity)
        await updateElevenLabsConnectionStatus()
        providerConnectionStatuses[.appleLocal] = preferences.localOnlyMode ? .localOnlyMode : .notConnected
    }

    private func updateElevenLabsConnectionStatus() async {
        if preferences.localOnlyMode {
            elevenLabsConnectionStatus = .localOnlyMode
            return
        }
        elevenLabsConnectionStatus = elevenLabsAPIKeyAuthProvider?.isAuthenticated == true ? .connected(email: nil) : .notConnected
    }

    private func updateProviderConnectionStatus(_ provider: AIProviderKind) async {
        if preferences.localOnlyMode {
            providerConnectionStatuses[provider] = provider == .appleLocal ? .localOnlyMode : .notConnected
            return
        }
        let descriptor = ProviderRegistry.descriptor(for: provider)
        if preferences.aiConfig.provider == provider,
           preferences.aiConfig.authMode == descriptor.accountAuthMode,
           descriptor.accountLoginUnsupportedMessage != nil {
            providerConnectionStatuses[provider] = .unsupportedOAuthFlow
            return
        }
        do {
            if preferences.aiConfig.provider == provider,
               preferences.aiConfig.authMode == descriptor.accountAuthMode,
               let session = try await cliAuthProvider(for: provider)?.currentSession() {
                providerConnectionStatuses[provider] = .connected(email: session.accountEmail)
                return
            }
            if apiKeyAuthProvider(for: provider)?.isAuthenticated == true {
                providerConnectionStatuses[provider] = .connected(email: nil)
            } else {
                providerConnectionStatuses[provider] = .notConnected
            }
        } catch {
            providerConnectionStatuses[provider] = .notConnected
        }
    }

    private func updateOpenAIConnectionStatus() async {
        if preferences.localOnlyMode {
            openAIConnectionStatus = .localOnlyMode
            return
        }
        if legacyAPIKeyAuthProvider?.isAuthenticated == true {
            openAIConnectionStatus = .connected(email: nil)
            return
        }
        if preferences.aiConfig.authMode == .apiKeyLegacy {
            openAIConnectionStatus = legacyAPIKeyAuthProvider?.isAuthenticated == true ? .connected(email: nil) : .notConnected
            return
        }
        if preferences.aiConfig.authMode == .openAICodexCLI {
            do {
                if let session = try await codexCLIAuthProvider?.currentSession() {
                    openAIConnectionStatus = .connected(email: session.accountEmail)
                } else {
                    openAIConnectionStatus = .notConnected
                }
            } catch {
                openAIConnectionStatus = .notConnected
            }
            return
        }
        guard preferences.aiConfig.authMode == .openAIAccountOAuth else {
            openAIConnectionStatus = .notConnected
            return
        }
        guard let openAIAccountOAuthProvider else {
            openAIConnectionStatus = .unsupportedOAuthFlow
            return
        }
        if !openAIAccountOAuthProvider.isOfficialFlowAvailable {
            openAIConnectionStatus = .unsupportedOAuthFlow
            return
        }
        guard openAIAccountOAuthProvider.isAuthenticated else {
            openAIConnectionStatus = .notConnected
            return
        }
        guard openAIAccountOAuthProvider.hasCachedSession else {
            openAIConnectionStatus = .connected(email: nil)
            return
        }
        do {
            guard let session = try await openAIAccountOAuthProvider.currentSession() else {
                openAIConnectionStatus = .notConnected
                return
            }
            if session.isExpired, session.refreshToken?.isEmpty == false {
                let refreshed = try await openAIAccountOAuthProvider.refreshIfNeeded()
                openAIConnectionStatus = .connected(email: refreshed.accountEmail)
            } else {
                openAIConnectionStatus = session.isExpired ? .tokenExpired : .connected(email: session.accountEmail)
            }
        } catch {
            openAIConnectionStatus = .notConnected
        }
    }

    private func handleAuthError(_ error: Error) {
        if let authError = error as? AuthError {
            if authError == .unsupportedOAuthFlow {
                openAIConnectionStatus = .unsupportedOAuthFlow
            }
            settingsStatus = authError.localizedDescription
        } else {
            settingsStatus = "OpenAI authentication failed"
        }
    }

    func deleteMeeting(_ meeting: MeetingSession) {
        sessionManager?.deleteMeeting(meeting)
    }

    func deleteAllData() {
        sessionManager?.deleteAllData()
    }

    func setMeetingDetected(_ meeting: MeetingSession, now: Date = Date()) {
        guard !shouldIgnoreDetection(meeting, now: now) else { return }
        currentMeeting = meeting
        islandMode = .meetingDetected
        statusMessage = "Meeting detected"
        isPanelExpanded = false
        isNotchHovered = false
        isShowingCopilotHistory = false
        detectedMeetingOfferStartedAt = now
        detectedMeetingOfferExpiresAt = now.addingTimeInterval(Self.detectedMeetingOfferDuration)
    }

    @discardableResult
    func expireDetectedMeetingOfferIfNeeded(now: Date = Date()) -> Bool {
        guard islandMode == .meetingDetected,
              currentMeeting != nil,
              let detectedMeetingOfferExpiresAt,
              now >= detectedMeetingOfferExpiresAt
        else { return false }
        ignoreDetectedMeeting(now: now)
        return true
    }

    func detectedMeetingOfferRemainingSeconds(at now: Date = Date()) -> Int? {
        guard islandMode == .meetingDetected,
              let detectedMeetingOfferExpiresAt
        else { return nil }
        return max(0, Int(ceil(detectedMeetingOfferExpiresAt.timeIntervalSince(now))))
    }

    func clearDetectedMeetingOfferTimer() {
        detectedMeetingOfferStartedAt = nil
        detectedMeetingOfferExpiresAt = nil
    }

    func ignoreDetectedMeeting(now: Date = Date()) {
        guard let currentMeeting else {
            ignoredDetectionSignature = nil
            ignoredDetectionSignatures = []
            islandMode = .idle
            statusMessage = "Ready"
            clearDetectedMeetingOfferTimer()
            isPanelExpanded = false
            isNotchHovered = false
            isShowingCopilotHistory = false
            return
        }
        let signatures = detectionSignatures(for: currentMeeting)
        ignoredDetectionSignature = signatures.first
        ignoredDetectionSignatures = signatures
        ignoredDetectionUntil = now.addingTimeInterval(Self.ignoredDetectionCooldown)
        self.currentMeeting = nil
        islandMode = .idle
        statusMessage = "Ready"
        clearDetectedMeetingOfferTimer()
        isPanelExpanded = false
        isNotchHovered = false
        isShowingCopilotHistory = false
    }

    func shouldIgnoreDetection(_ meeting: MeetingSession, now: Date = Date()) -> Bool {
        guard let ignoredDetectionUntil,
              ignoredDetectionUntil > now
        else { return false }
        let signatures = detectionSignatures(for: meeting)
        if !ignoredDetectionSignatures.isEmpty {
            return !ignoredDetectionSignatures.isDisjoint(with: signatures)
        }
        guard let ignoredDetectionSignature else { return false }
        return signatures.contains(ignoredDetectionSignature)
    }

    func handleNotchRegionClick() {
        switch islandMode {
        case .summaryReady:
            openSummaryHandler?()
        case .summarizing:
            isPanelExpanded = false
        case .meetingDetected:
            isPanelExpanded = false
        case .idle, .listening, .questionDetected, .thinking, .suggestedAnswer:
            sessionManager?.hydrateActiveTranscriptForPresentation()
            isPanelExpanded = true
        }
    }

    private func detectionSignature(for meeting: MeetingSession) -> String {
        detectionSignatures(for: meeting).first ?? meeting.id.uuidString
    }

    private func detectionSignatures(for meeting: MeetingSession) -> Set<String> {
        var signatures = Set<String>()

        if let platform = MeetingWebPlatform.detect(
            url: meeting.meetingURL,
            title: meeting.title,
            appName: meeting.automationSourceAppName ?? meeting.appName
        ) {
            signatures.insert("platform:\(platform.rawValue)")
        }

        if let normalizedURL = normalizedDetectionURL(meeting.meetingURL) {
            signatures.insert("url:\(normalizedURL)")
            if let host = URLComponents(string: normalizedURL)?.host?.lowercased(), !host.isEmpty {
                signatures.insert("host:\(host)")
            }
        }

        [
            meeting.automationSourceBundleId.map { "bundle:\($0)" },
            meeting.automationSourceAppName.map { "sourceApp:\($0)" },
            meeting.appName.map { "app:\($0)" },
            Optional(meeting.title).map { "title:\($0)" }
        ]
            .compactMap { $0 }
            .map(normalizedDetectionSignature)
            .filter { !$0.isEmpty }
            .forEach { signatures.insert($0) }

        return signatures
    }

    private func normalizedDetectionURL(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        guard var components = URLComponents(string: value) else {
            return value.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        let normalized = components.string ?? value
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    private func normalizedDetectionSignature(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private extension String {
    var containsCodeBlock: Bool {
        contains("```")
    }
}
