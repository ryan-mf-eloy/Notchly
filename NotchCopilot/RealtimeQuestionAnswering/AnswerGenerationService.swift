import Foundation

@MainActor
protocol MeetingAnswerProvider {
    func generateAnswer(
        question: QuestionCandidate,
        classification: QuestionClassification,
        context: AnswerContext,
        options: AnswerGenerationOptions
    ) async throws -> AsyncThrowingStream<PartialAnswer, Error>
}

struct AnswerGenerationPolicy: Codable, Hashable, Sendable {
    var noExternalSourceAssumption: String
    var caveatsByQuestionType: [String: [String]]
    var defaultClarifyingQuestion: String
    var copilotIntentByQuestionType: [String: CopilotIntentKind]
    var defaultCopilotIntent: CopilotIntentKind?
    var immediateDraftPriorities: Set<QuestionPriority>
    var emitImmediateDraftWhenRAGAvailable: Bool
    var defaultProvisionalDraft: String
    var provisionalDraftByLanguage: [String: String]

    init(
        noExternalSourceAssumption: String = "",
        caveatsByQuestionType: [String: [String]] = [:],
        defaultClarifyingQuestion: String = "",
        copilotIntentByQuestionType: [String: CopilotIntentKind] = [:],
        defaultCopilotIntent: CopilotIntentKind? = nil,
        immediateDraftPriorities: Set<QuestionPriority> = [],
        emitImmediateDraftWhenRAGAvailable: Bool = false,
        defaultProvisionalDraft: String = "",
        provisionalDraftByLanguage: [String: String] = [:]
    ) {
        self.noExternalSourceAssumption = noExternalSourceAssumption
        self.caveatsByQuestionType = caveatsByQuestionType
        self.defaultClarifyingQuestion = defaultClarifyingQuestion
        self.copilotIntentByQuestionType = copilotIntentByQuestionType
        self.defaultCopilotIntent = defaultCopilotIntent
        self.immediateDraftPriorities = immediateDraftPriorities
        self.emitImmediateDraftWhenRAGAvailable = emitImmediateDraftWhenRAGAvailable
        self.defaultProvisionalDraft = defaultProvisionalDraft
        self.provisionalDraftByLanguage = provisionalDraftByLanguage
    }

    private enum CodingKeys: String, CodingKey {
        case noExternalSourceAssumption
        case caveatsByQuestionType
        case defaultClarifyingQuestion
        case copilotIntentByQuestionType
        case defaultCopilotIntent
        case immediateDraftPriorities
        case emitImmediateDraftWhenRAGAvailable
        case defaultProvisionalDraft
        case provisionalDraftByLanguage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            noExternalSourceAssumption: try container.decodeIfPresent(String.self, forKey: .noExternalSourceAssumption) ?? "",
            caveatsByQuestionType: try container.decodeIfPresent([String: [String]].self, forKey: .caveatsByQuestionType) ?? [:],
            defaultClarifyingQuestion: try container.decodeIfPresent(String.self, forKey: .defaultClarifyingQuestion) ?? "",
            copilotIntentByQuestionType: try container.decodeIfPresent([String: CopilotIntentKind].self, forKey: .copilotIntentByQuestionType) ?? [:],
            defaultCopilotIntent: try container.decodeIfPresent(CopilotIntentKind.self, forKey: .defaultCopilotIntent),
            immediateDraftPriorities: try container.decodeIfPresent(Set<QuestionPriority>.self, forKey: .immediateDraftPriorities) ?? [],
            emitImmediateDraftWhenRAGAvailable: try container.decodeIfPresent(Bool.self, forKey: .emitImmediateDraftWhenRAGAvailable) ?? false,
            defaultProvisionalDraft: try container.decodeIfPresent(String.self, forKey: .defaultProvisionalDraft) ?? "",
            provisionalDraftByLanguage: try container.decodeIfPresent([String: String].self, forKey: .provisionalDraftByLanguage) ?? [:]
        )
    }

    static let `default` = AnswerGenerationPolicyStore.current

    func caveats(for type: QuestionType) -> [String] {
        caveatsByQuestionType[type.rawValue] ?? []
    }

    func copilotIntent(for type: QuestionType) -> CopilotIntentKind {
        copilotIntentByQuestionType[type.rawValue] ?? defaultCopilotIntent ?? .answerableQuestion
    }

    func shouldEmitImmediateDraft(for classification: QuestionClassification, context: AnswerContext) -> Bool {
        immediateDraftPriorities.contains(classification.priority)
            || (emitImmediateDraftWhenRAGAvailable && !context.ragContext.isEmpty)
    }

    func provisionalDraft(for languageCode: String?) -> String? {
        let normalizedLanguage = languageCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedLanguage,
           let localized = provisionalDraftByLanguage[normalizedLanguage]?.nilIfEmptyAnswerGeneration {
            return localized
        }
        return defaultProvisionalDraft.nilIfEmptyAnswerGeneration
    }
}

enum AnswerGenerationPolicyStore {
    static let current: AnswerGenerationPolicy = load()

    private static func load() -> AnswerGenerationPolicy {
        let decoder = JSONDecoder()
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let policy = try? decoder.decode(AnswerGenerationPolicy.self, from: data) else {
                continue
            }
            return policy.normalized()
        }
        return fallbackPolicy()
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let bundles = [Bundle.main, Bundle(for: AnswerGenerationPolicyBundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "answer-generation-policy",
                withExtension: "json",
                subdirectory: "CopilotIntentPolicy"
            ) {
                urls.append(url)
            }
        }
        urls.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/CopilotIntentPolicy/answer-generation-policy.json")
        )
        return urls
    }

    private static func fallbackPolicy() -> AnswerGenerationPolicy {
        AnswerGenerationPolicy(
            noExternalSourceAssumption: "",
            caveatsByQuestionType: [:],
            defaultClarifyingQuestion: "",
            copilotIntentByQuestionType: [:],
            defaultCopilotIntent: nil,
            immediateDraftPriorities: [],
            emitImmediateDraftWhenRAGAvailable: false,
            defaultProvisionalDraft: "",
            provisionalDraftByLanguage: [:]
        )
    }
}

private final class AnswerGenerationPolicyBundleMarker {}

private extension AnswerGenerationPolicy {
    func normalized() -> AnswerGenerationPolicy {
        AnswerGenerationPolicy(
            noExternalSourceAssumption: noExternalSourceAssumption.trimmingCharacters(in: .whitespacesAndNewlines),
            caveatsByQuestionType: caveatsByQuestionType.reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            },
            defaultClarifyingQuestion: defaultClarifyingQuestion.trimmingCharacters(in: .whitespacesAndNewlines),
            copilotIntentByQuestionType: copilotIntentByQuestionType.reduce(into: [:]) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return }
                result[key] = entry.value
            },
            defaultCopilotIntent: defaultCopilotIntent,
            immediateDraftPriorities: immediateDraftPriorities,
            emitImmediateDraftWhenRAGAvailable: emitImmediateDraftWhenRAGAvailable,
            defaultProvisionalDraft: defaultProvisionalDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            provisionalDraftByLanguage: provisionalDraftByLanguage.reduce(into: [:]) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !value.isEmpty else { return }
                result[key] = value
            }
        )
    }
}

@MainActor
struct AnswerGenerationService: MeetingAnswerProvider {
    var provider: any AIProvider
    var safetyGuard = AnswerSafetyGuard()
    var generationPolicy: AnswerGenerationPolicy = .default

    func generateAnswer(
        question: QuestionCandidate,
        classification: QuestionClassification,
        context: AnswerContext,
        options: AnswerGenerationOptions
    ) async throws -> AsyncThrowingStream<PartialAnswer, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                let startedAt = Date()
                do {
                    let generated = try await provider.generateAnswer(
                        context: context,
                        question: question.rawText,
                        options: AnswerOptions(
                            maxSentences: options.maxSentences,
                            allowCommitments: options.allowCommitments,
                            enableWebSearch: options.enableWebSearch && !options.localOnlyMode
                        )
                    )
                    let formattedText = AnswerPresentationFormatter.normalizedGeneratedText(
                        generated.text,
                        question: question,
                        classification: classification
                    )
                    let latency = Int(Date().timeIntervalSince(startedAt) * 1000)
                    let sources = mergedSources(context.retrievedSources, generated.sources)
                    let presentation = try CopilotAnswerPresenter().present(
                        text: formattedText,
                        candidate: question,
                        classification: classification,
                        tool: .answerSynthesis,
                        intent: generationPolicy.copilotIntent(for: classification.questionType),
                        sources: sources
                    )
                    let answer = SuggestedAnswer(
                        questionId: question.id,
                        answerText: presentation.text,
                        shortAnswer: presentation.shortText,
                        confidence: classification.confidence,
                        riskLevel: .safe,
                        usedSources: presentation.sources,
                        assumptions: assumptions(for: classification, context: context),
                        caveats: mergedCaveats(caveats(for: classification, context: context), presentation.caveats),
                        latencyMs: latency,
                        expandedAnswer: presentation.text,
                        suggestedTone: classification.expectedAnswerStyle,
                        shouldAskClarification: classification.expectedAnswerStyle == .askForClarification,
                        clarifyingQuestion: classification.expectedAnswerStyle == .askForClarification ? generationPolicy.defaultClarifyingQuestion.nilIfEmptyAnswerGeneration : nil,
                        language: question.language ?? context.languageCode,
                        provider: generated.provider,
                        usedCloud: generated.usedCloud,
                        usedRAG: generated.usedRAG,
                        answerFormat: presentation.format,
                        richAnswer: presentation.richAnswer
                    )
                    let safeAnswer = safetyGuard.sanitized(answer, classification: classification)
                    continuation.yield(PartialAnswer(textDelta: safeAnswer.shortAnswer, isFinal: true, suggestedAnswer: safeAnswer))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func assumptions(for classification: QuestionClassification, context: AnswerContext) -> [String] {
        guard context.retrievedSources.isEmpty,
              classification.questionType != .generalQuestion,
              let assumption = generationPolicy.noExternalSourceAssumption.nilIfEmptyAnswerGeneration else {
            return []
        }
        return [assumption]
    }

    private func caveats(for classification: QuestionClassification, context: AnswerContext) -> [String] {
        generationPolicy.caveats(for: classification.questionType)
    }

    private func mergedSources(_ contextSources: [AnswerSource], _ generatedSources: [AnswerSource]) -> [AnswerSource] {
        var seen: Set<AnswerSource> = []
        return (contextSources + generatedSources).filter { seen.insert($0).inserted }
    }

    private func mergedCaveats(_ primary: [String], _ secondary: [String]) -> [String] {
        var seen = Set<String>()
        return (primary + secondary).filter { caveat in
            let key = caveat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
    }

}

extension String {
    var nilIfEmptyAnswerGeneration: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AnswerPresentationFormat: String, Sendable, Hashable {
    case plainText
    case bullets
    case numberedSteps
    case code
    case command
    case structuredData
    case mixed
}

struct AnswerPresentationDecision: Sendable, Hashable {
    var format: AnswerPresentationFormat
    var preservesCodeBlocks: Bool
    var reason: String
}

struct AnswerPresentationDecisionReasonPolicy: Codable, Hashable, Sendable {
    var commandOrShellRequest: String
    var structuredDataRequest: String
    var codeRequest: String
    var procedureRequest: String
    var comparisonOrDecision: String
    var shortFact: String
    var defaultMeetingAnswer: String

    static let empty = AnswerPresentationDecisionReasonPolicy()

    init(
        commandOrShellRequest: String = "",
        structuredDataRequest: String = "",
        codeRequest: String = "",
        procedureRequest: String = "",
        comparisonOrDecision: String = "",
        shortFact: String = "",
        defaultMeetingAnswer: String = ""
    ) {
        self.commandOrShellRequest = commandOrShellRequest
        self.structuredDataRequest = structuredDataRequest
        self.codeRequest = codeRequest
        self.procedureRequest = procedureRequest
        self.comparisonOrDecision = comparisonOrDecision
        self.shortFact = shortFact
        self.defaultMeetingAnswer = defaultMeetingAnswer
    }

    private enum CodingKeys: String, CodingKey {
        case commandOrShellRequest
        case structuredDataRequest
        case codeRequest
        case procedureRequest
        case comparisonOrDecision
        case shortFact
        case defaultMeetingAnswer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            commandOrShellRequest: try container.decodeIfPresent(String.self, forKey: .commandOrShellRequest) ?? "",
            structuredDataRequest: try container.decodeIfPresent(String.self, forKey: .structuredDataRequest) ?? "",
            codeRequest: try container.decodeIfPresent(String.self, forKey: .codeRequest) ?? "",
            procedureRequest: try container.decodeIfPresent(String.self, forKey: .procedureRequest) ?? "",
            comparisonOrDecision: try container.decodeIfPresent(String.self, forKey: .comparisonOrDecision) ?? "",
            shortFact: try container.decodeIfPresent(String.self, forKey: .shortFact) ?? "",
            defaultMeetingAnswer: try container.decodeIfPresent(String.self, forKey: .defaultMeetingAnswer) ?? ""
        )
    }
}

struct RichAnswerTitlePolicy: Codable, Hashable, Sendable {
    var steps: String
    var keyPoints: String
    var highlights: String
    var sources: String
    var context: String
    var evidence: String
    var result: String
    var value: String
    var timeline: String
    var couldNotComplete: String
    var toneLabel: String
    var riskLabel: String
    var confidenceLabel: String

    static let empty = RichAnswerTitlePolicy()

    init(
        steps: String = "",
        keyPoints: String = "",
        highlights: String = "",
        sources: String = "",
        context: String = "",
        evidence: String = "",
        result: String = "",
        value: String = "",
        timeline: String = "",
        couldNotComplete: String = "",
        toneLabel: String = "",
        riskLabel: String = "",
        confidenceLabel: String = ""
    ) {
        self.steps = steps
        self.keyPoints = keyPoints
        self.highlights = highlights
        self.sources = sources
        self.context = context
        self.evidence = evidence
        self.result = result
        self.value = value
        self.timeline = timeline
        self.couldNotComplete = couldNotComplete
        self.toneLabel = toneLabel
        self.riskLabel = riskLabel
        self.confidenceLabel = confidenceLabel
    }
}

struct AnswerPresentationPolicy: Codable, Hashable, Sendable {
    var codeQuestionMarkers: [String]
    var commandQuestionMarkers: [String]
    var structuredDataQuestionMarkers: [String]
    var procedureQuestionMarkers: [String]
    var comparisonQuestionMarkers: [String]
    var shortFactQuestionMarkers: [String]
    var comparisonQuestionTypes: Set<QuestionType>
    var shortFactQuestionTypes: Set<QuestionType>
    var decisionReasons: AnswerPresentationDecisionReasonPolicy
    var plainTextLanguages: Set<String>
    var structuredDataLanguages: Set<String>
    var codeLanguages: Set<String>
    var commandLanguages: Set<String>
    var codeLinePattern: String
    var codeSymbolPattern: String
    var commandLinePattern: String
    var structuredDataLinePattern: String
    var codeFenceMarker: String
    var sentenceTerminatorCharacters: String
    var shortAnswerMaximumSentences: Int
    var shortAnswerSentenceSeparator: String
    var shortAnswerDefaultTerminator: String
    var compactScriptShortAnswerDefaultTerminator: String
    var duplicateTokenOverlapThreshold: Double
    var maximumConsecutiveBlankLines: Int
    var literalTermCharacters: String
    var codeSymbolMinimumLineCount: Int
    var codeSymbolInlineMarkers: String
    var structuredDataMinimumCharacters: Int
    var structuredDataMinimumLineCount: Int
    var structuredDataWrapperPairs: [String]
    var timelineQuestionMarkers: [String]
    var freshNewsQuestionMarkers: [String]
    var webSearchQuestionMarkers: [String]
    var arithmeticQuestionPattern: String
    var timelineTitlePattern: String
    var richTimelineMaximumItems: Int
    var richEvidenceMaximumItems: Int
    var richAnswerTitles: RichAnswerTitlePolicy

    init(
        codeQuestionMarkers: [String],
        commandQuestionMarkers: [String],
        structuredDataQuestionMarkers: [String],
        procedureQuestionMarkers: [String],
        comparisonQuestionMarkers: [String],
        shortFactQuestionMarkers: [String],
        comparisonQuestionTypes: Set<QuestionType> = [],
        shortFactQuestionTypes: Set<QuestionType> = [],
        decisionReasons: AnswerPresentationDecisionReasonPolicy = .empty,
        plainTextLanguages: Set<String>,
        structuredDataLanguages: Set<String>,
        codeLanguages: Set<String>,
        commandLanguages: Set<String>,
        codeLinePattern: String,
        codeSymbolPattern: String,
        commandLinePattern: String,
        structuredDataLinePattern: String,
        codeFenceMarker: String = "```",
        sentenceTerminatorCharacters: String = ".!?",
        shortAnswerMaximumSentences: Int = 2,
        shortAnswerSentenceSeparator: String = " ",
        shortAnswerDefaultTerminator: String = ".",
        compactScriptShortAnswerDefaultTerminator: String = "。",
        duplicateTokenOverlapThreshold: Double = 0.85,
        maximumConsecutiveBlankLines: Int = 1,
        literalTermCharacters: String = "/#+-",
        codeSymbolMinimumLineCount: Int = 2,
        codeSymbolInlineMarkers: String = "=",
        structuredDataMinimumCharacters: Int = 3,
        structuredDataMinimumLineCount: Int = 2,
        structuredDataWrapperPairs: [String] = [],
        timelineQuestionMarkers: [String] = [],
        freshNewsQuestionMarkers: [String] = [],
        webSearchQuestionMarkers: [String] = [],
        arithmeticQuestionPattern: String = "",
        timelineTitlePattern: String = "",
        richTimelineMaximumItems: Int = 8,
        richEvidenceMaximumItems: Int = 4,
        richAnswerTitles: RichAnswerTitlePolicy = .empty
    ) {
        self.codeQuestionMarkers = codeQuestionMarkers
        self.commandQuestionMarkers = commandQuestionMarkers
        self.structuredDataQuestionMarkers = structuredDataQuestionMarkers
        self.procedureQuestionMarkers = procedureQuestionMarkers
        self.comparisonQuestionMarkers = comparisonQuestionMarkers
        self.shortFactQuestionMarkers = shortFactQuestionMarkers
        self.comparisonQuestionTypes = comparisonQuestionTypes
        self.shortFactQuestionTypes = shortFactQuestionTypes
        self.decisionReasons = decisionReasons
        self.plainTextLanguages = plainTextLanguages
        self.structuredDataLanguages = structuredDataLanguages
        self.codeLanguages = codeLanguages
        self.commandLanguages = commandLanguages
        self.codeLinePattern = codeLinePattern
        self.codeSymbolPattern = codeSymbolPattern
        self.commandLinePattern = commandLinePattern
        self.structuredDataLinePattern = structuredDataLinePattern
        self.codeFenceMarker = codeFenceMarker
        self.sentenceTerminatorCharacters = sentenceTerminatorCharacters
        self.shortAnswerMaximumSentences = shortAnswerMaximumSentences
        self.shortAnswerSentenceSeparator = shortAnswerSentenceSeparator
        self.shortAnswerDefaultTerminator = shortAnswerDefaultTerminator
        self.compactScriptShortAnswerDefaultTerminator = compactScriptShortAnswerDefaultTerminator
        self.duplicateTokenOverlapThreshold = duplicateTokenOverlapThreshold
        self.maximumConsecutiveBlankLines = maximumConsecutiveBlankLines
        self.literalTermCharacters = literalTermCharacters
        self.codeSymbolMinimumLineCount = codeSymbolMinimumLineCount
        self.codeSymbolInlineMarkers = codeSymbolInlineMarkers
        self.structuredDataMinimumCharacters = structuredDataMinimumCharacters
        self.structuredDataMinimumLineCount = structuredDataMinimumLineCount
        self.structuredDataWrapperPairs = structuredDataWrapperPairs
        self.timelineQuestionMarkers = timelineQuestionMarkers
        self.freshNewsQuestionMarkers = freshNewsQuestionMarkers
        self.webSearchQuestionMarkers = webSearchQuestionMarkers
        self.arithmeticQuestionPattern = arithmeticQuestionPattern
        self.timelineTitlePattern = timelineTitlePattern
        self.richTimelineMaximumItems = richTimelineMaximumItems
        self.richEvidenceMaximumItems = richEvidenceMaximumItems
        self.richAnswerTitles = richAnswerTitles
    }

    private enum CodingKeys: String, CodingKey {
        case codeQuestionMarkers
        case commandQuestionMarkers
        case structuredDataQuestionMarkers
        case procedureQuestionMarkers
        case comparisonQuestionMarkers
        case shortFactQuestionMarkers
        case comparisonQuestionTypes
        case shortFactQuestionTypes
        case decisionReasons
        case plainTextLanguages
        case structuredDataLanguages
        case codeLanguages
        case commandLanguages
        case codeLinePattern
        case codeSymbolPattern
        case commandLinePattern
        case structuredDataLinePattern
        case codeFenceMarker
        case sentenceTerminatorCharacters
        case shortAnswerMaximumSentences
        case shortAnswerSentenceSeparator
        case shortAnswerDefaultTerminator
        case compactScriptShortAnswerDefaultTerminator
        case duplicateTokenOverlapThreshold
        case maximumConsecutiveBlankLines
        case literalTermCharacters
        case codeSymbolMinimumLineCount
        case codeSymbolInlineMarkers
        case structuredDataMinimumCharacters
        case structuredDataMinimumLineCount
        case structuredDataWrapperPairs
        case timelineQuestionMarkers
        case freshNewsQuestionMarkers
        case webSearchQuestionMarkers
        case arithmeticQuestionPattern
        case timelineTitlePattern
        case richTimelineMaximumItems
        case richEvidenceMaximumItems
        case richAnswerTitles
    }

    init(from decoder: Decoder) throws {
        let fallback = AnswerPresentationPolicyStore.fallbackPolicy()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            codeQuestionMarkers: try container.decodeIfPresent([String].self, forKey: .codeQuestionMarkers) ?? fallback.codeQuestionMarkers,
            commandQuestionMarkers: try container.decodeIfPresent([String].self, forKey: .commandQuestionMarkers) ?? fallback.commandQuestionMarkers,
            structuredDataQuestionMarkers: try container.decodeIfPresent([String].self, forKey: .structuredDataQuestionMarkers) ?? fallback.structuredDataQuestionMarkers,
            procedureQuestionMarkers: try container.decodeIfPresent([String].self, forKey: .procedureQuestionMarkers) ?? fallback.procedureQuestionMarkers,
            comparisonQuestionMarkers: try container.decodeIfPresent([String].self, forKey: .comparisonQuestionMarkers) ?? fallback.comparisonQuestionMarkers,
            shortFactQuestionMarkers: try container.decodeIfPresent([String].self, forKey: .shortFactQuestionMarkers) ?? fallback.shortFactQuestionMarkers,
            comparisonQuestionTypes: try container.decodeIfPresent(Set<QuestionType>.self, forKey: .comparisonQuestionTypes) ?? [],
            shortFactQuestionTypes: try container.decodeIfPresent(Set<QuestionType>.self, forKey: .shortFactQuestionTypes) ?? [],
            decisionReasons: try container.decodeIfPresent(AnswerPresentationDecisionReasonPolicy.self, forKey: .decisionReasons) ?? .empty,
            plainTextLanguages: try container.decodeIfPresent(Set<String>.self, forKey: .plainTextLanguages) ?? fallback.plainTextLanguages,
            structuredDataLanguages: try container.decodeIfPresent(Set<String>.self, forKey: .structuredDataLanguages) ?? fallback.structuredDataLanguages,
            codeLanguages: try container.decodeIfPresent(Set<String>.self, forKey: .codeLanguages) ?? fallback.codeLanguages,
            commandLanguages: try container.decodeIfPresent(Set<String>.self, forKey: .commandLanguages) ?? fallback.commandLanguages,
            codeLinePattern: try container.decodeIfPresent(String.self, forKey: .codeLinePattern) ?? fallback.codeLinePattern,
            codeSymbolPattern: try container.decodeIfPresent(String.self, forKey: .codeSymbolPattern) ?? fallback.codeSymbolPattern,
            commandLinePattern: try container.decodeIfPresent(String.self, forKey: .commandLinePattern) ?? fallback.commandLinePattern,
            structuredDataLinePattern: try container.decodeIfPresent(String.self, forKey: .structuredDataLinePattern) ?? fallback.structuredDataLinePattern,
            codeFenceMarker: try container.decodeIfPresent(String.self, forKey: .codeFenceMarker) ?? fallback.codeFenceMarker,
            sentenceTerminatorCharacters: try container.decodeIfPresent(String.self, forKey: .sentenceTerminatorCharacters) ?? fallback.sentenceTerminatorCharacters,
            shortAnswerMaximumSentences: try container.decodeIfPresent(Int.self, forKey: .shortAnswerMaximumSentences) ?? fallback.shortAnswerMaximumSentences,
            shortAnswerSentenceSeparator: try container.decodeIfPresent(String.self, forKey: .shortAnswerSentenceSeparator) ?? fallback.shortAnswerSentenceSeparator,
            shortAnswerDefaultTerminator: try container.decodeIfPresent(String.self, forKey: .shortAnswerDefaultTerminator) ?? fallback.shortAnswerDefaultTerminator,
            compactScriptShortAnswerDefaultTerminator: try container.decodeIfPresent(String.self, forKey: .compactScriptShortAnswerDefaultTerminator) ?? fallback.compactScriptShortAnswerDefaultTerminator,
            duplicateTokenOverlapThreshold: try container.decodeIfPresent(Double.self, forKey: .duplicateTokenOverlapThreshold) ?? fallback.duplicateTokenOverlapThreshold,
            maximumConsecutiveBlankLines: try container.decodeIfPresent(Int.self, forKey: .maximumConsecutiveBlankLines) ?? fallback.maximumConsecutiveBlankLines,
            literalTermCharacters: try container.decodeIfPresent(String.self, forKey: .literalTermCharacters) ?? fallback.literalTermCharacters,
            codeSymbolMinimumLineCount: try container.decodeIfPresent(Int.self, forKey: .codeSymbolMinimumLineCount) ?? fallback.codeSymbolMinimumLineCount,
            codeSymbolInlineMarkers: try container.decodeIfPresent(String.self, forKey: .codeSymbolInlineMarkers) ?? fallback.codeSymbolInlineMarkers,
            structuredDataMinimumCharacters: try container.decodeIfPresent(Int.self, forKey: .structuredDataMinimumCharacters) ?? fallback.structuredDataMinimumCharacters,
            structuredDataMinimumLineCount: try container.decodeIfPresent(Int.self, forKey: .structuredDataMinimumLineCount) ?? fallback.structuredDataMinimumLineCount,
            structuredDataWrapperPairs: try container.decodeIfPresent([String].self, forKey: .structuredDataWrapperPairs) ?? [],
            timelineQuestionMarkers: try container.decodeIfPresent([String].self, forKey: .timelineQuestionMarkers) ?? [],
            freshNewsQuestionMarkers: try container.decodeIfPresent([String].self, forKey: .freshNewsQuestionMarkers) ?? [],
            webSearchQuestionMarkers: try container.decodeIfPresent([String].self, forKey: .webSearchQuestionMarkers) ?? fallback.webSearchQuestionMarkers,
            arithmeticQuestionPattern: try container.decodeIfPresent(String.self, forKey: .arithmeticQuestionPattern) ?? fallback.arithmeticQuestionPattern,
            timelineTitlePattern: try container.decodeIfPresent(String.self, forKey: .timelineTitlePattern) ?? fallback.timelineTitlePattern,
            richTimelineMaximumItems: try container.decodeIfPresent(Int.self, forKey: .richTimelineMaximumItems) ?? fallback.richTimelineMaximumItems,
            richEvidenceMaximumItems: try container.decodeIfPresent(Int.self, forKey: .richEvidenceMaximumItems) ?? fallback.richEvidenceMaximumItems,
            richAnswerTitles: try container.decodeIfPresent(RichAnswerTitlePolicy.self, forKey: .richAnswerTitles) ?? .empty
        )
    }

    static let `default` = AnswerPresentationPolicyStore.current
}

enum AnswerPresentationPolicyStore {
    static let current: AnswerPresentationPolicy = load()

    private static func load() -> AnswerPresentationPolicy {
        let decoder = JSONDecoder()
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let policy = try? decoder.decode(AnswerPresentationPolicy.self, from: data) else {
                continue
            }
            return policy.normalized()
        }
        return fallbackPolicy()
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let bundles = [Bundle.main, Bundle(for: AnswerPresentationPolicyBundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "answer-presentation-policy",
                withExtension: "json",
                subdirectory: "CopilotIntentPolicy"
            ) {
                urls.append(url)
            }
        }
        urls.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/CopilotIntentPolicy/answer-presentation-policy.json")
        )
        return urls
    }

    fileprivate static func fallbackPolicy() -> AnswerPresentationPolicy {
        AnswerPresentationPolicy(
            codeQuestionMarkers: [],
            commandQuestionMarkers: [],
            structuredDataQuestionMarkers: [],
            procedureQuestionMarkers: [],
            comparisonQuestionMarkers: [],
            shortFactQuestionMarkers: [],
            comparisonQuestionTypes: [],
            shortFactQuestionTypes: [],
            decisionReasons: .empty,
            plainTextLanguages: [],
            structuredDataLanguages: [],
            codeLanguages: [],
            commandLanguages: [],
            codeLinePattern: "",
            codeSymbolPattern: "",
            commandLinePattern: "",
            structuredDataLinePattern: "",
            codeFenceMarker: "```",
            sentenceTerminatorCharacters: ".!?؟。",
            shortAnswerMaximumSentences: 2,
            shortAnswerSentenceSeparator: " ",
            shortAnswerDefaultTerminator: ".",
            compactScriptShortAnswerDefaultTerminator: "。",
            duplicateTokenOverlapThreshold: 0.85,
            maximumConsecutiveBlankLines: 1,
            literalTermCharacters: "/#+-",
            codeSymbolMinimumLineCount: 2,
            codeSymbolInlineMarkers: "=",
            structuredDataMinimumCharacters: 3,
            structuredDataMinimumLineCount: 2,
            structuredDataWrapperPairs: [],
            timelineQuestionMarkers: [],
            freshNewsQuestionMarkers: [],
            webSearchQuestionMarkers: [],
            arithmeticQuestionPattern: "",
            timelineTitlePattern: "",
            richTimelineMaximumItems: 8,
            richEvidenceMaximumItems: 4,
            richAnswerTitles: .empty
        )
    }
}

private final class AnswerPresentationPolicyBundleMarker {}

extension AnswerPresentationPolicy {
    func normalized() -> AnswerPresentationPolicy {
        AnswerPresentationPolicy(
            codeQuestionMarkers: codeQuestionMarkers.map(Self.normalizedText).filter { !$0.isEmpty },
            commandQuestionMarkers: commandQuestionMarkers.map(Self.normalizedText).filter { !$0.isEmpty },
            structuredDataQuestionMarkers: structuredDataQuestionMarkers.map(Self.normalizedText).filter { !$0.isEmpty },
            procedureQuestionMarkers: procedureQuestionMarkers.map(Self.normalizedText).filter { !$0.isEmpty },
            comparisonQuestionMarkers: comparisonQuestionMarkers.map(Self.normalizedText).filter { !$0.isEmpty },
            shortFactQuestionMarkers: shortFactQuestionMarkers.map(Self.normalizedText).filter { !$0.isEmpty },
            comparisonQuestionTypes: comparisonQuestionTypes,
            shortFactQuestionTypes: shortFactQuestionTypes,
            decisionReasons: decisionReasons.normalized(),
            plainTextLanguages: Set(plainTextLanguages.map(Self.normalizedLanguage)),
            structuredDataLanguages: Set(structuredDataLanguages.map(Self.normalizedLanguage).filter { !$0.isEmpty }),
            codeLanguages: Set(codeLanguages.map(Self.normalizedLanguage).filter { !$0.isEmpty }),
            commandLanguages: Set(commandLanguages.map(Self.normalizedLanguage).filter { !$0.isEmpty }),
            codeLinePattern: codeLinePattern,
            codeSymbolPattern: codeSymbolPattern,
            commandLinePattern: commandLinePattern,
            structuredDataLinePattern: structuredDataLinePattern,
            codeFenceMarker: codeFenceMarker.nilIfEmptyAnswerGeneration ?? "```",
            sentenceTerminatorCharacters: sentenceTerminatorCharacters.nilIfEmptyAnswerGeneration ?? ".!?؟。",
            shortAnswerMaximumSentences: max(1, shortAnswerMaximumSentences),
            shortAnswerSentenceSeparator: shortAnswerSentenceSeparator,
            shortAnswerDefaultTerminator: shortAnswerDefaultTerminator,
            compactScriptShortAnswerDefaultTerminator: compactScriptShortAnswerDefaultTerminator.nilIfEmptyAnswerGeneration ?? shortAnswerDefaultTerminator,
            duplicateTokenOverlapThreshold: min(max(duplicateTokenOverlapThreshold, 0), 1),
            maximumConsecutiveBlankLines: max(0, maximumConsecutiveBlankLines),
            literalTermCharacters: literalTermCharacters,
            codeSymbolMinimumLineCount: max(1, codeSymbolMinimumLineCount),
            codeSymbolInlineMarkers: codeSymbolInlineMarkers,
            structuredDataMinimumCharacters: max(1, structuredDataMinimumCharacters),
            structuredDataMinimumLineCount: max(1, structuredDataMinimumLineCount),
            structuredDataWrapperPairs: structuredDataWrapperPairs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 },
            timelineQuestionMarkers: timelineQuestionMarkers.map(Self.normalizedText).filter { !$0.isEmpty },
            freshNewsQuestionMarkers: freshNewsQuestionMarkers.map(Self.normalizedText).filter { !$0.isEmpty },
            webSearchQuestionMarkers: webSearchQuestionMarkers.map(Self.normalizedText).filter { !$0.isEmpty },
            arithmeticQuestionPattern: arithmeticQuestionPattern.trimmingCharacters(in: .whitespacesAndNewlines),
            timelineTitlePattern: timelineTitlePattern.trimmingCharacters(in: .whitespacesAndNewlines),
            richTimelineMaximumItems: max(1, richTimelineMaximumItems),
            richEvidenceMaximumItems: max(0, richEvidenceMaximumItems),
            richAnswerTitles: richAnswerTitles.normalized()
        )
    }

    private static func normalizedText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[^\\p{L}\\p{N}_/#.\\-+]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedLanguage(_ text: String) -> String {
        CodeLanguageRegistry.normalizedAlias(text)
    }
}

private extension RichAnswerTitlePolicy {
    func normalized() -> RichAnswerTitlePolicy {
        RichAnswerTitlePolicy(
            steps: normalized(steps),
            keyPoints: normalized(keyPoints),
            highlights: normalized(highlights),
            sources: normalized(sources),
            context: normalized(context),
            evidence: normalized(evidence),
            result: normalized(result),
            value: normalized(value),
            timeline: normalized(timeline),
            couldNotComplete: normalized(couldNotComplete),
            toneLabel: normalized(toneLabel),
            riskLabel: normalized(riskLabel),
            confidenceLabel: normalized(confidenceLabel)
        )
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension AnswerPresentationDecisionReasonPolicy {
    func normalized() -> AnswerPresentationDecisionReasonPolicy {
        AnswerPresentationDecisionReasonPolicy(
            commandOrShellRequest: normalized(commandOrShellRequest),
            structuredDataRequest: normalized(structuredDataRequest),
            codeRequest: normalized(codeRequest),
            procedureRequest: normalized(procedureRequest),
            comparisonOrDecision: normalized(comparisonOrDecision),
            shortFact: normalized(shortFact),
            defaultMeetingAnswer: normalized(defaultMeetingAnswer)
        )
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AnswerPresentationFormatter {
    private struct FencedBlock: Hashable {
        var language: String?
        var code: String

        var markdown: String {
            let header = "```" + (language ?? "")
            let formattedCode = CodeBlockFormatter.formatted(code, language: language)
            return [header, formattedCode.isEmpty ? code : formattedCode, "```"].joined(separator: "\n")
        }
    }

    private enum Segment: Hashable {
        case text(String)
        case fenced(FencedBlock)
    }

    static func normalizedGeneratedText(
        _ text: String,
        question: QuestionCandidate,
        classification: QuestionClassification,
        policy: AnswerPresentationPolicy = .default
    ) -> String {
        let policy = policy.normalized()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(policy.codeFenceMarker) else { return trimmed }

        let decision = presentationDecision(for: question, classification: classification, generatedText: trimmed, policy: policy)
        let segments = parseSegments(trimmed, policy: policy)
        let outsideText = segments.compactMap { segment -> String? in
            if case let .text(value) = segment { return value }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        let rendered = segments.map { segment -> String in
            switch segment {
            case .text(let value):
                return value
            case .fenced(let block):
                if shouldPreserve(block: block, question: question.rawText, decision: decision, policy: policy) {
                    return block.markdown
                }

                let blockText = block.code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !blockText.isEmpty else { return "" }
                if isDuplicate(blockText, in: outsideText, policy: policy) {
                    return ""
                }
                return blockText
            }
        }
        .joined(separator: "\n")

        return collapseBlankLines(rendered, policy: policy)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shortAnswer(from text: String, policy: AnswerPresentationPolicy = .default) -> String {
        let policy = policy.normalized()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(policy.codeFenceMarker) {
            return trimmed
        }
        let sentences = sentenceFragments(in: trimmed, policy: policy)
        let selectedSentences = sentences.prefix(policy.shortAnswerMaximumSentences).joined(separator: policy.shortAnswerSentenceSeparator)
        if selectedSentences.isEmpty { return trimmed }
        return ensureShortAnswerTerminated(selectedSentences, policy: policy)
    }

    static func presentationDecision(
        for question: QuestionCandidate,
        classification: QuestionClassification,
        generatedText: String,
        policy: AnswerPresentationPolicy = .default
    ) -> AnswerPresentationDecision {
        let policy = policy.normalized()
        let questionText = normalized(question.rawText)

        if asksForCommand(questionText, policy: policy) || containsFenceLanguage(in: generatedText, languages: policy.commandLanguages, policy: policy) {
            return AnswerPresentationDecision(format: .command, preservesCodeBlocks: true, reason: policy.decisionReasons.commandOrShellRequest)
        }
        if asksForStructuredData(questionText, policy: policy) || containsFenceLanguage(in: generatedText, languages: policy.structuredDataLanguages, policy: policy) {
            return AnswerPresentationDecision(format: .structuredData, preservesCodeBlocks: true, reason: policy.decisionReasons.structuredDataRequest)
        }
        if asksForCode(questionText, policy: policy) || containsFencedCode(in: generatedText, policy: policy) {
            return AnswerPresentationDecision(format: .code, preservesCodeBlocks: true, reason: policy.decisionReasons.codeRequest)
        }
        if asksForProcedure(questionText, policy: policy) {
            return AnswerPresentationDecision(format: .numberedSteps, preservesCodeBlocks: false, reason: policy.decisionReasons.procedureRequest)
        }
        if asksForComparison(questionText, policy: policy) || policy.comparisonQuestionTypes.contains(classification.questionType) {
            return AnswerPresentationDecision(format: .bullets, preservesCodeBlocks: false, reason: policy.decisionReasons.comparisonOrDecision)
        }
        if isShortFactQuestion(questionText, classification: classification, policy: policy) {
            return AnswerPresentationDecision(format: .plainText, preservesCodeBlocks: false, reason: policy.decisionReasons.shortFact)
        }
        return AnswerPresentationDecision(format: .mixed, preservesCodeBlocks: false, reason: policy.decisionReasons.defaultMeetingAnswer)
    }

    private static func parseSegments(_ text: String, policy: AnswerPresentationPolicy) -> [Segment] {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedText.components(separatedBy: "\n")
        var segments: [Segment] = []
        var textLines: [String] = []
        var codeLines: [String] = []
        var language: String?
        var isInCodeBlock = false

        func flushText() {
            guard !textLines.isEmpty else { return }
            segments.append(.text(textLines.joined(separator: "\n")))
            textLines.removeAll()
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(policy.codeFenceMarker) {
                if isInCodeBlock {
                    segments.append(.fenced(FencedBlock(
                        language: language,
                        code: codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    )))
                    codeLines.removeAll()
                    language = nil
                    isInCodeBlock = false
                } else {
                    flushText()
                    let rawLanguage = String(trimmed.dropFirst(policy.codeFenceMarker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    language = rawLanguage.isEmpty ? nil : rawLanguage
                    isInCodeBlock = true
                }
                continue
            }

            if isInCodeBlock {
                codeLines.append(rawLine)
            } else {
                textLines.append(rawLine)
            }
        }

        if isInCodeBlock {
            segments.append(.fenced(FencedBlock(
                language: language,
                code: codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            )))
        }
        flushText()
        return segments
    }

    private static func sentenceFragments(in text: String, policy: AnswerPresentationPolicy) -> [String] {
        var fragments: [String] = []
        var buffer = ""

        for character in text {
            buffer.append(character)
            if policy.sentenceTerminatorCharacters.contains(character) {
                let fragment = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !fragment.isEmpty {
                    fragments.append(fragment)
                }
                buffer = ""
            }
        }

        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            fragments.append(remainder)
        }

        return fragments
    }

    private static func ensureShortAnswerTerminated(_ text: String, policy: AnswerPresentationPolicy) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastCharacter = trimmed.last else { return trimmed }
        if policy.sentenceTerminatorCharacters.contains(lastCharacter) {
            return trimmed
        }

        let terminator = QuestionDetectionService.containsCompactScript(trimmed)
            ? policy.compactScriptShortAnswerDefaultTerminator
            : policy.shortAnswerDefaultTerminator
        return trimmed + terminator
    }

    private static func shouldPreserve(
        block: FencedBlock,
        question: String,
        decision: AnswerPresentationDecision,
        policy: AnswerPresentationPolicy
    ) -> Bool {
        let language = CodeLanguageRegistry.normalizedAlias(block.language)
        let code = block.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return false }
        if policy.plainTextLanguages.contains(language),
           !looksLikeCode(code, policy: policy),
           !looksLikeCommand(code, policy: policy),
           !looksLikeStructuredData(code, policy: policy) {
            return false
        }

        let normalizedQuestion = normalized(question)
        if decision.preservesCodeBlocks {
            switch decision.format {
            case .command:
                return looksLikeCommand(code, policy: policy) || policy.commandLanguages.contains(language)
            case .structuredData:
                return looksLikeStructuredData(code, policy: policy) || policy.structuredDataLanguages.contains(language)
            case .code:
                return looksLikeCode(code, policy: policy) || policy.codeLanguages.contains(language)
            default:
                return false
            }
        }

        return (
            asksForCode(normalizedQuestion, policy: policy)
                || asksForCommand(normalizedQuestion, policy: policy)
                || asksForStructuredData(normalizedQuestion, policy: policy)
        )
            && (
                looksLikeCode(code, policy: policy)
                    || looksLikeCommand(code, policy: policy)
                    || looksLikeStructuredData(code, policy: policy)
            )
    }

    private static func isDuplicate(_ blockText: String, in outsideText: String, policy: AnswerPresentationPolicy) -> Bool {
        let normalizedBlock = normalized(blockText)
        let normalizedOutside = normalized(outsideText)
        guard !normalizedBlock.isEmpty, !normalizedOutside.isEmpty else { return false }
        if normalizedOutside.contains(normalizedBlock) { return true }
        let textPolicy = QuestionIntentRulePack.default.textSegmentationPolicy
        let blockTokens = Set(textPolicy.lexicalTokens(in: normalizedBlock))
        guard !blockTokens.isEmpty else { return false }
        let outsideTokens = Set(textPolicy.lexicalTokens(in: normalizedOutside))
        let overlap = blockTokens.filter { outsideTokens.contains($0) }.count
        return Double(overlap) / Double(blockTokens.count) >= policy.duplicateTokenOverlapThreshold
    }

    private static func collapseBlankLines(_ text: String, policy: AnswerPresentationPolicy) -> String {
        var output: [String] = []
        var blankCount = 0
        var isInCodeFence = false
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(policy.codeFenceMarker) {
                blankCount = 0
                isInCodeFence.toggle()
                output.append(trimmed)
            } else if isInCodeFence {
                output.append(trimTrailingWhitespace(line))
            } else if trimmed.isEmpty {
                blankCount += 1
                if blankCount <= policy.maximumConsecutiveBlankLines {
                    output.append("")
                }
            } else {
                blankCount = 0
                output.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        return output.joined(separator: "\n")
    }

    private static func trimTrailingWhitespace(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let previous = line.index(before: end)
            guard line[previous] == " " || line[previous] == "\t" else { break }
            end = previous
        }
        return String(line[..<end])
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[^\\p{L}\\p{N}_/#.\\-+]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAny(_ text: String, _ terms: [String], policy: AnswerPresentationPolicy) -> Bool {
        terms.contains { term in
            QuestionIntentRulePack.default.textSegmentationPolicy.containsMarker(term, in: text)
        }
    }

    private static func containsFenceLanguage(in text: String, languages: Set<String>, policy: AnswerPresentationPolicy) -> Bool {
        guard !languages.isEmpty else { return false }
        return parseSegments(text, policy: policy).contains { segment in
            guard case let .fenced(block) = segment else { return false }
            return languages.contains(CodeLanguageRegistry.normalizedAlias(block.language))
        }
    }

    private static func containsFencedCode(in text: String, policy: AnswerPresentationPolicy) -> Bool {
        parseSegments(text, policy: policy).contains { segment in
            guard case let .fenced(block) = segment else { return false }
            let language = CodeLanguageRegistry.normalizedAlias(block.language)
            let code = block.code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { return false }
            if policy.codeLanguages.contains(language) {
                return true
            }
            if policy.plainTextLanguages.contains(language), !looksLikeCode(code, policy: policy) {
                return false
            }
            return looksLikeCode(code, policy: policy)
        }
    }

    private static func asksForCode(_ question: String, policy: AnswerPresentationPolicy) -> Bool {
        containsAny(question, policy.codeQuestionMarkers, policy: policy)
    }

    private static func asksForCommand(_ question: String, policy: AnswerPresentationPolicy) -> Bool {
        containsAny(question, policy.commandQuestionMarkers, policy: policy)
    }

    private static func asksForStructuredData(_ question: String, policy: AnswerPresentationPolicy) -> Bool {
        containsAny(question, policy.structuredDataQuestionMarkers, policy: policy)
    }

    private static func asksForProcedure(_ question: String, policy: AnswerPresentationPolicy) -> Bool {
        containsAny(question, policy.procedureQuestionMarkers, policy: policy)
    }

    private static func asksForComparison(_ question: String, policy: AnswerPresentationPolicy) -> Bool {
        containsAny(question, policy.comparisonQuestionMarkers, policy: policy)
    }

    private static func isShortFactQuestion(_ question: String, classification: QuestionClassification, policy: AnswerPresentationPolicy) -> Bool {
        guard !asksForCode(question, policy: policy),
              !asksForCommand(question, policy: policy),
              !asksForStructuredData(question, policy: policy) else { return false }
        if policy.shortFactQuestionTypes.contains(classification.questionType) {
            return containsAny(question, policy.shortFactQuestionMarkers, policy: policy)
        }
        return false
    }

    private static func looksLikeCode(_ text: String, policy: AnswerPresentationPolicy) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if matches(trimmed, pattern: policy.codeLinePattern) {
            return true
        }
        if matches(trimmed, pattern: policy.codeSymbolPattern),
           trimmed.split(separator: "\n").count >= policy.codeSymbolMinimumLineCount || trimmed.contains(where: { policy.codeSymbolInlineMarkers.contains($0) }) {
            return true
        }
        return false
    }

    private static func looksLikeCommand(_ text: String, policy: AnswerPresentationPolicy) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return matches(trimmed, pattern: policy.commandLinePattern)
    }

    private static func looksLikeStructuredData(_ text: String, policy: AnswerPresentationPolicy) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= policy.structuredDataMinimumCharacters else { return false }
        if hasStructuredDataWrapper(trimmed, policy: policy) {
            return true
        }
        return matches(trimmed, pattern: policy.structuredDataLinePattern)
            && trimmed.split(separator: "\n").count >= policy.structuredDataMinimumLineCount
    }

    private static func hasStructuredDataWrapper(_ text: String, policy: AnswerPresentationPolicy) -> Bool {
        policy.structuredDataWrapperPairs.contains { pair in
            guard let opening = pair.first, let closing = pair.last else { return false }
            return text.hasPrefix(String(opening)) && text.hasSuffix(String(closing))
        }
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
