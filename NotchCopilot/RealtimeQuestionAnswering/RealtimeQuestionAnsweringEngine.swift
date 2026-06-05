import Foundation

struct QuestionShadowDecisionRecord: Codable, Hashable, Sendable {
    var candidateId: UUID
    var meetingId: UUID
    var rawText: String
    var language: String?
    var decision: String
    var reason: String
    var confidence: Double
    var responseNeeded: Bool
    var priority: QuestionPriority
    var textualConfidence: Double?
    var multimodalConfidence: Double?
    var decisionScore: Double?
    var decisionSignals: [String]?
    var suppressionSignals: [String]?
    var discoverySource: QuestionCandidateDiscoverySource?
    var surfaceSignals: [String]?
    var surfaceSuppressionSignals: [String]?
    var modelLabel: String?
    var modelThreshold: Double?
    var createdAt: Date = Date()
}

struct QuestionShadowLogger {
    var fileManager: FileManager = .default

    func record(candidate: QuestionCandidate, classification: QuestionClassification, decision: String) {
        let record = QuestionShadowDecisionRecord(
            candidateId: candidate.id,
            meetingId: candidate.meetingId,
            rawText: PrivacyGuard().redact(candidate.rawText),
            language: candidate.language,
            decision: decision,
            reason: classification.reason,
            confidence: classification.confidence,
            responseNeeded: classification.responseNeeded,
            priority: classification.priority,
            textualConfidence: classification.textualConfidence,
            multimodalConfidence: classification.multimodalConfidence,
            decisionScore: classification.decisionScore,
            decisionSignals: classification.decisionSignals,
            suppressionSignals: classification.suppressionSignals,
            discoverySource: candidate.discovery.source,
            surfaceSignals: candidate.discovery.surfaceSignals,
            surfaceSuppressionSignals: candidate.discovery.surfaceSuppressionSignals,
            modelLabel: candidate.discovery.modelLabel,
            modelThreshold: candidate.discovery.modelThreshold
        )
        append(record)
    }

    func record(rejectedFrame: QuestionRejectedFrame, prediction: QuestionTrainedMultimodalPrediction?, decision: String) {
        let record = QuestionShadowDecisionRecord(
            candidateId: rejectedFrame.frame.id,
            meetingId: rejectedFrame.frame.meetingId,
            rawText: PrivacyGuard().redact(rejectedFrame.frame.rawText),
            language: rejectedFrame.frame.language ?? rejectedFrame.frame.multimodalSignal?.language,
            decision: decision,
            reason: rejectedFrame.reason,
            confidence: prediction?.responseScore ?? 0,
            responseNeeded: prediction?.shouldAllow ?? false,
            priority: .low,
            textualConfidence: nil,
            multimodalConfidence: prediction?.responseScore,
            decisionScore: prediction?.candidateScore ?? prediction?.responseScore,
            decisionSignals: prediction?.decisionSignals,
            suppressionSignals: prediction?.suppressionSignals,
            discoverySource: .shadowRescue,
            surfaceSignals: rejectedFrame.surfaceSignals,
            surfaceSuppressionSignals: rejectedFrame.suppressionSignals,
            modelLabel: prediction?.label,
            modelThreshold: prediction?.threshold
        )
        append(record)
    }

    private func append(_ record: QuestionShadowDecisionRecord) {
        guard let data = try? JSONEncoder().encode(record),
              let line = String(data: data, encoding: .utf8)
        else { return }
        do {
            let url = try logURL()
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            if let lineData = (line + "\n").data(using: .utf8) {
                handle.write(lineData)
            }
            try handle.close()
        } catch {
            AppLog.ai.debug("Notchly shadow logging skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func logURL() throws -> URL {
        let directory = try FileStorageService.applicationSupportDirectory()
            .appendingPathComponent("qa-shadow", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("qa_decisions.jsonl")
    }
}

struct RealtimePartialStabilityPolicy: Codable, Hashable, Sendable {
    var similarityStableThreshold: Double
    var finalStableCount: Int
    var stableRevisionCount: Int
    var stableScoreFloor: Double
    var unstableScoreFloor: Double
    var stableMinimumTokens: Int
    var prefixSimilarityFloor: Double

    static let fallback = RealtimePartialStabilityPolicy(
        similarityStableThreshold: 0.72,
        finalStableCount: 2,
        stableRevisionCount: 2,
        stableScoreFloor: 0.84,
        unstableScoreFloor: 0.32,
        stableMinimumTokens: 4,
        prefixSimilarityFloor: 0.72
    )

    init(
        similarityStableThreshold: Double = Self.fallback.similarityStableThreshold,
        finalStableCount: Int = Self.fallback.finalStableCount,
        stableRevisionCount: Int = Self.fallback.stableRevisionCount,
        stableScoreFloor: Double = Self.fallback.stableScoreFloor,
        unstableScoreFloor: Double = Self.fallback.unstableScoreFloor,
        stableMinimumTokens: Int = Self.fallback.stableMinimumTokens,
        prefixSimilarityFloor: Double = Self.fallback.prefixSimilarityFloor
    ) {
        self.similarityStableThreshold = similarityStableThreshold
        self.finalStableCount = finalStableCount
        self.stableRevisionCount = stableRevisionCount
        self.stableScoreFloor = stableScoreFloor
        self.unstableScoreFloor = unstableScoreFloor
        self.stableMinimumTokens = stableMinimumTokens
        self.prefixSimilarityFloor = prefixSimilarityFloor
    }

    private enum CodingKeys: String, CodingKey {
        case similarityStableThreshold
        case finalStableCount
        case stableRevisionCount
        case stableScoreFloor
        case unstableScoreFloor
        case stableMinimumTokens
        case prefixSimilarityFloor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            similarityStableThreshold: try container.decodeIfPresent(Double.self, forKey: .similarityStableThreshold) ?? Self.fallback.similarityStableThreshold,
            finalStableCount: try container.decodeIfPresent(Int.self, forKey: .finalStableCount) ?? Self.fallback.finalStableCount,
            stableRevisionCount: try container.decodeIfPresent(Int.self, forKey: .stableRevisionCount) ?? Self.fallback.stableRevisionCount,
            stableScoreFloor: try container.decodeIfPresent(Double.self, forKey: .stableScoreFloor) ?? Self.fallback.stableScoreFloor,
            unstableScoreFloor: try container.decodeIfPresent(Double.self, forKey: .unstableScoreFloor) ?? Self.fallback.unstableScoreFloor,
            stableMinimumTokens: try container.decodeIfPresent(Int.self, forKey: .stableMinimumTokens) ?? Self.fallback.stableMinimumTokens,
            prefixSimilarityFloor: try container.decodeIfPresent(Double.self, forKey: .prefixSimilarityFloor) ?? Self.fallback.prefixSimilarityFloor
        )
    }
}

struct RealtimeDeferredPartialDetectionPolicy: Codable, Hashable, Sendable {
    var stableCandidateDelayMilliseconds: Int
    var deferredDetectionDelayMilliseconds: Int
    var forcedPartialStability: Double
    var forcedRevisionCount: Int
    var minimumTokenCount: Int
    var minimumCJKCharacterCount: Int
    var minimumConfidence: Double
    var completeMinimumTokenCount: Int
    var completeMinimumCJKCharacterCount: Int
    var allowModelRescuePrefilter: Bool
    var modelRescuePrefilterRequiresSurfaceEvidence: Bool

    static let fallback = RealtimeDeferredPartialDetectionPolicy(
        stableCandidateDelayMilliseconds: 750,
        deferredDetectionDelayMilliseconds: 950,
        forcedPartialStability: 0.84,
        forcedRevisionCount: 1,
        minimumTokenCount: 4,
        minimumCJKCharacterCount: 4,
        minimumConfidence: 0.45,
        completeMinimumTokenCount: 5,
        completeMinimumCJKCharacterCount: 8,
        allowModelRescuePrefilter: true,
        modelRescuePrefilterRequiresSurfaceEvidence: false
    )

    init(
        stableCandidateDelayMilliseconds: Int = Self.fallback.stableCandidateDelayMilliseconds,
        deferredDetectionDelayMilliseconds: Int = Self.fallback.deferredDetectionDelayMilliseconds,
        forcedPartialStability: Double = Self.fallback.forcedPartialStability,
        forcedRevisionCount: Int = Self.fallback.forcedRevisionCount,
        minimumTokenCount: Int = Self.fallback.minimumTokenCount,
        minimumCJKCharacterCount: Int = Self.fallback.minimumCJKCharacterCount,
        minimumConfidence: Double = Self.fallback.minimumConfidence,
        completeMinimumTokenCount: Int = Self.fallback.completeMinimumTokenCount,
        completeMinimumCJKCharacterCount: Int = Self.fallback.completeMinimumCJKCharacterCount,
        allowModelRescuePrefilter: Bool = Self.fallback.allowModelRescuePrefilter,
        modelRescuePrefilterRequiresSurfaceEvidence: Bool = Self.fallback.modelRescuePrefilterRequiresSurfaceEvidence
    ) {
        self.stableCandidateDelayMilliseconds = stableCandidateDelayMilliseconds
        self.deferredDetectionDelayMilliseconds = deferredDetectionDelayMilliseconds
        self.forcedPartialStability = forcedPartialStability
        self.forcedRevisionCount = forcedRevisionCount
        self.minimumTokenCount = minimumTokenCount
        self.minimumCJKCharacterCount = minimumCJKCharacterCount
        self.minimumConfidence = minimumConfidence
        self.completeMinimumTokenCount = completeMinimumTokenCount
        self.completeMinimumCJKCharacterCount = completeMinimumCJKCharacterCount
        self.allowModelRescuePrefilter = allowModelRescuePrefilter
        self.modelRescuePrefilterRequiresSurfaceEvidence = modelRescuePrefilterRequiresSurfaceEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case stableCandidateDelayMilliseconds
        case deferredDetectionDelayMilliseconds
        case forcedPartialStability
        case forcedRevisionCount
        case minimumTokenCount
        case minimumCJKCharacterCount
        case minimumConfidence
        case completeMinimumTokenCount
        case completeMinimumCJKCharacterCount
        case allowModelRescuePrefilter
        case modelRescuePrefilterRequiresSurfaceEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            stableCandidateDelayMilliseconds: try container.decodeIfPresent(Int.self, forKey: .stableCandidateDelayMilliseconds) ?? Self.fallback.stableCandidateDelayMilliseconds,
            deferredDetectionDelayMilliseconds: try container.decodeIfPresent(Int.self, forKey: .deferredDetectionDelayMilliseconds) ?? Self.fallback.deferredDetectionDelayMilliseconds,
            forcedPartialStability: try container.decodeIfPresent(Double.self, forKey: .forcedPartialStability) ?? Self.fallback.forcedPartialStability,
            forcedRevisionCount: try container.decodeIfPresent(Int.self, forKey: .forcedRevisionCount) ?? Self.fallback.forcedRevisionCount,
            minimumTokenCount: try container.decodeIfPresent(Int.self, forKey: .minimumTokenCount) ?? Self.fallback.minimumTokenCount,
            minimumCJKCharacterCount: try container.decodeIfPresent(Int.self, forKey: .minimumCJKCharacterCount) ?? Self.fallback.minimumCJKCharacterCount,
            minimumConfidence: try container.decodeIfPresent(Double.self, forKey: .minimumConfidence) ?? Self.fallback.minimumConfidence,
            completeMinimumTokenCount: try container.decodeIfPresent(Int.self, forKey: .completeMinimumTokenCount) ?? Self.fallback.completeMinimumTokenCount,
            completeMinimumCJKCharacterCount: try container.decodeIfPresent(Int.self, forKey: .completeMinimumCJKCharacterCount) ?? Self.fallback.completeMinimumCJKCharacterCount,
            allowModelRescuePrefilter: try container.decodeIfPresent(Bool.self, forKey: .allowModelRescuePrefilter) ?? Self.fallback.allowModelRescuePrefilter,
            modelRescuePrefilterRequiresSurfaceEvidence: try container.decodeIfPresent(Bool.self, forKey: .modelRescuePrefilterRequiresSurfaceEvidence) ?? Self.fallback.modelRescuePrefilterRequiresSurfaceEvidence
        )
    }
}

struct RealtimeMultiQTRescuePolicy: Codable, Hashable, Sendable {
    var minimumResponseMargin: Double
    var minimumCandidateScore: Double
    var partialMinimumStability: Double
    var partialMinimumRevisionCount: Int
    var minimumFrameCharacters: Int

    static let fallback = RealtimeMultiQTRescuePolicy(
        minimumResponseMargin: 0.05,
        minimumCandidateScore: 0.55,
        partialMinimumStability: 0.82,
        partialMinimumRevisionCount: 1,
        minimumFrameCharacters: 4
    )

    init(
        minimumResponseMargin: Double = Self.fallback.minimumResponseMargin,
        minimumCandidateScore: Double = Self.fallback.minimumCandidateScore,
        partialMinimumStability: Double = Self.fallback.partialMinimumStability,
        partialMinimumRevisionCount: Int = Self.fallback.partialMinimumRevisionCount,
        minimumFrameCharacters: Int = Self.fallback.minimumFrameCharacters
    ) {
        self.minimumResponseMargin = minimumResponseMargin
        self.minimumCandidateScore = minimumCandidateScore
        self.partialMinimumStability = partialMinimumStability
        self.partialMinimumRevisionCount = partialMinimumRevisionCount
        self.minimumFrameCharacters = minimumFrameCharacters
    }

    private enum CodingKeys: String, CodingKey {
        case minimumResponseMargin
        case minimumCandidateScore
        case partialMinimumStability
        case partialMinimumRevisionCount
        case minimumFrameCharacters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            minimumResponseMargin: try container.decodeIfPresent(Double.self, forKey: .minimumResponseMargin) ?? Self.fallback.minimumResponseMargin,
            minimumCandidateScore: try container.decodeIfPresent(Double.self, forKey: .minimumCandidateScore) ?? Self.fallback.minimumCandidateScore,
            partialMinimumStability: try container.decodeIfPresent(Double.self, forKey: .partialMinimumStability) ?? Self.fallback.partialMinimumStability,
            partialMinimumRevisionCount: try container.decodeIfPresent(Int.self, forKey: .partialMinimumRevisionCount) ?? Self.fallback.partialMinimumRevisionCount,
            minimumFrameCharacters: try container.decodeIfPresent(Int.self, forKey: .minimumFrameCharacters) ?? Self.fallback.minimumFrameCharacters
        )
    }
}

struct RealtimeAnswerGenerationGatePolicy: Codable, Hashable, Sendable {
    var requiresResponseNeeded: Bool
    var requiresComplete: Bool
    var suppressesRhetorical: Bool
    var allowedPriorities: Set<QuestionPriority>

    static let fallback = RealtimeAnswerGenerationGatePolicy(
        requiresResponseNeeded: true,
        requiresComplete: true,
        suppressesRhetorical: true,
        allowedPriorities: [.medium, .high, .urgent]
    )

    init(
        requiresResponseNeeded: Bool = Self.fallback.requiresResponseNeeded,
        requiresComplete: Bool = Self.fallback.requiresComplete,
        suppressesRhetorical: Bool = Self.fallback.suppressesRhetorical,
        allowedPriorities: Set<QuestionPriority> = Self.fallback.allowedPriorities
    ) {
        self.requiresResponseNeeded = requiresResponseNeeded
        self.requiresComplete = requiresComplete
        self.suppressesRhetorical = suppressesRhetorical
        self.allowedPriorities = allowedPriorities
    }

    private enum CodingKeys: String, CodingKey {
        case requiresResponseNeeded
        case requiresComplete
        case suppressesRhetorical
        case allowedPriorities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            requiresResponseNeeded: try container.decodeIfPresent(Bool.self, forKey: .requiresResponseNeeded) ?? Self.fallback.requiresResponseNeeded,
            requiresComplete: try container.decodeIfPresent(Bool.self, forKey: .requiresComplete) ?? Self.fallback.requiresComplete,
            suppressesRhetorical: try container.decodeIfPresent(Bool.self, forKey: .suppressesRhetorical) ?? Self.fallback.suppressesRhetorical,
            allowedPriorities: try container.decodeIfPresent(Set<QuestionPriority>.self, forKey: .allowedPriorities) ?? Self.fallback.allowedPriorities
        )
    }
}

struct RealtimeQuestionRuntimeLabelsPolicy: Codable, Hashable, Sendable {
    var questionDismissedMessage: String
    var urgentQuestionSupersededMessage: String
    var cloudDisabledFailureMessage: String
    var localAnswerFailureMessage: String
    var selfAnsweredCancellationMessage: String
    var shadowIgnoredHardSuppression: String
    var shadowIgnoredIntentGate: String
    var shadowAccepted: String
    var shadowIgnoredClassifier: String

    static let empty = RealtimeQuestionRuntimeLabelsPolicy()

    init(
        questionDismissedMessage: String = "",
        urgentQuestionSupersededMessage: String = "",
        cloudDisabledFailureMessage: String = "",
        localAnswerFailureMessage: String = "",
        selfAnsweredCancellationMessage: String = "",
        shadowIgnoredHardSuppression: String = "",
        shadowIgnoredIntentGate: String = "",
        shadowAccepted: String = "",
        shadowIgnoredClassifier: String = ""
    ) {
        self.questionDismissedMessage = questionDismissedMessage
        self.urgentQuestionSupersededMessage = urgentQuestionSupersededMessage
        self.cloudDisabledFailureMessage = cloudDisabledFailureMessage
        self.localAnswerFailureMessage = localAnswerFailureMessage
        self.selfAnsweredCancellationMessage = selfAnsweredCancellationMessage
        self.shadowIgnoredHardSuppression = shadowIgnoredHardSuppression
        self.shadowIgnoredIntentGate = shadowIgnoredIntentGate
        self.shadowAccepted = shadowAccepted
        self.shadowIgnoredClassifier = shadowIgnoredClassifier
    }

    private enum CodingKeys: String, CodingKey {
        case questionDismissedMessage
        case urgentQuestionSupersededMessage
        case cloudDisabledFailureMessage
        case localAnswerFailureMessage
        case selfAnsweredCancellationMessage
        case shadowIgnoredHardSuppression
        case shadowIgnoredIntentGate
        case shadowAccepted
        case shadowIgnoredClassifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            questionDismissedMessage: try container.decodeIfPresent(String.self, forKey: .questionDismissedMessage) ?? "",
            urgentQuestionSupersededMessage: try container.decodeIfPresent(String.self, forKey: .urgentQuestionSupersededMessage) ?? "",
            cloudDisabledFailureMessage: try container.decodeIfPresent(String.self, forKey: .cloudDisabledFailureMessage) ?? "",
            localAnswerFailureMessage: try container.decodeIfPresent(String.self, forKey: .localAnswerFailureMessage) ?? "",
            selfAnsweredCancellationMessage: try container.decodeIfPresent(String.self, forKey: .selfAnsweredCancellationMessage) ?? "",
            shadowIgnoredHardSuppression: try container.decodeIfPresent(String.self, forKey: .shadowIgnoredHardSuppression) ?? "",
            shadowIgnoredIntentGate: try container.decodeIfPresent(String.self, forKey: .shadowIgnoredIntentGate) ?? "",
            shadowAccepted: try container.decodeIfPresent(String.self, forKey: .shadowAccepted) ?? "",
            shadowIgnoredClassifier: try container.decodeIfPresent(String.self, forKey: .shadowIgnoredClassifier) ?? ""
        )
    }
}

struct RealtimeQuestionAnsweringPolicy: Codable, Hashable, Sendable {
    var answerResolutionMarkers: [String]
    var incompleteActionFrames: [String]
    var danglingPartialTokens: Set<String>
    var selfAnswerWindowSeconds: TimeInterval
    var answerMaxSentences: Int
    var answerAllowCommitments: Bool
    var partialStability: RealtimePartialStabilityPolicy?
    var deferredPartialDetection: RealtimeDeferredPartialDetectionPolicy?
    var multiqtRescue: RealtimeMultiQTRescuePolicy?
    var answerGenerationGate: RealtimeAnswerGenerationGatePolicy?
    var runtimeLabels: RealtimeQuestionRuntimeLabelsPolicy

    init(
        answerResolutionMarkers: [String],
        incompleteActionFrames: [String],
        danglingPartialTokens: Set<String>,
        selfAnswerWindowSeconds: TimeInterval,
        answerMaxSentences: Int = 3,
        answerAllowCommitments: Bool = false,
        partialStability: RealtimePartialStabilityPolicy? = nil,
        deferredPartialDetection: RealtimeDeferredPartialDetectionPolicy? = nil,
        multiqtRescue: RealtimeMultiQTRescuePolicy? = nil,
        answerGenerationGate: RealtimeAnswerGenerationGatePolicy? = nil,
        runtimeLabels: RealtimeQuestionRuntimeLabelsPolicy = .empty
    ) {
        self.answerResolutionMarkers = answerResolutionMarkers
        self.incompleteActionFrames = incompleteActionFrames
        self.danglingPartialTokens = danglingPartialTokens
        self.selfAnswerWindowSeconds = selfAnswerWindowSeconds
        self.answerMaxSentences = answerMaxSentences
        self.answerAllowCommitments = answerAllowCommitments
        self.partialStability = partialStability
        self.deferredPartialDetection = deferredPartialDetection
        self.multiqtRescue = multiqtRescue
        self.answerGenerationGate = answerGenerationGate
        self.runtimeLabels = runtimeLabels
    }

    private enum CodingKeys: String, CodingKey {
        case answerResolutionMarkers
        case incompleteActionFrames
        case danglingPartialTokens
        case selfAnswerWindowSeconds
        case answerMaxSentences
        case answerAllowCommitments
        case partialStability
        case deferredPartialDetection
        case multiqtRescue
        case answerGenerationGate
        case runtimeLabels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            answerResolutionMarkers: try container.decodeIfPresent([String].self, forKey: .answerResolutionMarkers) ?? [],
            incompleteActionFrames: try container.decodeIfPresent([String].self, forKey: .incompleteActionFrames) ?? [],
            danglingPartialTokens: try container.decodeIfPresent(Set<String>.self, forKey: .danglingPartialTokens) ?? [],
            selfAnswerWindowSeconds: try container.decodeIfPresent(TimeInterval.self, forKey: .selfAnswerWindowSeconds) ?? 20,
            answerMaxSentences: try container.decodeIfPresent(Int.self, forKey: .answerMaxSentences) ?? 3,
            answerAllowCommitments: try container.decodeIfPresent(Bool.self, forKey: .answerAllowCommitments) ?? false,
            partialStability: try container.decodeIfPresent(RealtimePartialStabilityPolicy.self, forKey: .partialStability),
            deferredPartialDetection: try container.decodeIfPresent(RealtimeDeferredPartialDetectionPolicy.self, forKey: .deferredPartialDetection),
            multiqtRescue: try container.decodeIfPresent(RealtimeMultiQTRescuePolicy.self, forKey: .multiqtRescue),
            answerGenerationGate: try container.decodeIfPresent(RealtimeAnswerGenerationGatePolicy.self, forKey: .answerGenerationGate),
            runtimeLabels: try container.decodeIfPresent(RealtimeQuestionRuntimeLabelsPolicy.self, forKey: .runtimeLabels) ?? .empty
        )
    }

    var partialStabilityPolicy: RealtimePartialStabilityPolicy {
        partialStability ?? .fallback
    }

    var deferredPartialDetectionPolicy: RealtimeDeferredPartialDetectionPolicy {
        deferredPartialDetection ?? .fallback
    }

    var multiqtRescuePolicy: RealtimeMultiQTRescuePolicy {
        multiqtRescue ?? .fallback
    }

    var answerGenerationGatePolicy: RealtimeAnswerGenerationGatePolicy {
        answerGenerationGate ?? .fallback
    }

    static let `default` = RealtimeQuestionAnsweringPolicyStore.current
}

enum RealtimeQuestionAnsweringPolicyStore {
    static let current: RealtimeQuestionAnsweringPolicy = load()

    private static func load() -> RealtimeQuestionAnsweringPolicy {
        let decoder = JSONDecoder()
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let policy = try? decoder.decode(RealtimeQuestionAnsweringPolicy.self, from: data) else {
                continue
            }
            return policy.normalized()
        }
        return fallbackPolicy()
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let bundles = [Bundle.main, Bundle(for: RealtimeQuestionAnsweringPolicyBundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "question-realtime-policy",
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
                .appendingPathComponent("Resources/CopilotIntentPolicy/question-realtime-policy.json")
        )
        return urls
    }

    private static func fallbackPolicy() -> RealtimeQuestionAnsweringPolicy {
        RealtimeQuestionAnsweringPolicy(
            answerResolutionMarkers: [],
            incompleteActionFrames: [],
            danglingPartialTokens: [],
            selfAnswerWindowSeconds: 20,
            partialStability: .fallback,
            deferredPartialDetection: .fallback,
            multiqtRescue: .fallback,
            runtimeLabels: .empty
        )
    }
}

private final class RealtimeQuestionAnsweringPolicyBundleMarker {}

private extension RealtimeQuestionAnsweringPolicy {
    func normalized() -> RealtimeQuestionAnsweringPolicy {
        RealtimeQuestionAnsweringPolicy(
            answerResolutionMarkers: answerResolutionMarkers
                .map(QuestionDetectionService.normalize)
                .filter { !$0.isEmpty },
            incompleteActionFrames: incompleteActionFrames
                .map(QuestionDetectionService.normalize)
                .filter { !$0.isEmpty },
            danglingPartialTokens: Set(
                danglingPartialTokens
                    .map(QuestionDetectionService.normalize)
                    .filter { !$0.isEmpty }
            ),
            selfAnswerWindowSeconds: min(120, max(1, selfAnswerWindowSeconds)),
            answerMaxSentences: min(8, max(1, answerMaxSentences)),
            answerAllowCommitments: answerAllowCommitments,
            partialStability: partialStabilityPolicy.normalized(),
            deferredPartialDetection: deferredPartialDetectionPolicy.normalized(),
            multiqtRescue: multiqtRescuePolicy.normalized(),
            answerGenerationGate: answerGenerationGatePolicy.normalized(),
            runtimeLabels: runtimeLabels.normalized()
        )
    }
}

private extension RealtimeQuestionRuntimeLabelsPolicy {
    func normalized() -> RealtimeQuestionRuntimeLabelsPolicy {
        RealtimeQuestionRuntimeLabelsPolicy(
            questionDismissedMessage: normalizedRuntimeLabel(questionDismissedMessage),
            urgentQuestionSupersededMessage: normalizedRuntimeLabel(urgentQuestionSupersededMessage),
            cloudDisabledFailureMessage: normalizedRuntimeLabel(cloudDisabledFailureMessage),
            localAnswerFailureMessage: normalizedRuntimeLabel(localAnswerFailureMessage),
            selfAnsweredCancellationMessage: normalizedRuntimeLabel(selfAnsweredCancellationMessage),
            shadowIgnoredHardSuppression: normalizedRuntimeLabel(shadowIgnoredHardSuppression),
            shadowIgnoredIntentGate: normalizedRuntimeLabel(shadowIgnoredIntentGate),
            shadowAccepted: normalizedRuntimeLabel(shadowAccepted),
            shadowIgnoredClassifier: normalizedRuntimeLabel(shadowIgnoredClassifier)
        )
    }

    private func normalizedRuntimeLabel(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmptyRealtimePolicy: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension RealtimePartialStabilityPolicy {
    func normalized() -> RealtimePartialStabilityPolicy {
        RealtimePartialStabilityPolicy(
            similarityStableThreshold: clampedUnit(similarityStableThreshold),
            finalStableCount: max(1, finalStableCount),
            stableRevisionCount: max(1, stableRevisionCount),
            stableScoreFloor: clampedUnit(stableScoreFloor),
            unstableScoreFloor: clampedUnit(unstableScoreFloor),
            stableMinimumTokens: max(1, stableMinimumTokens),
            prefixSimilarityFloor: clampedUnit(prefixSimilarityFloor)
        )
    }
}

private extension RealtimeDeferredPartialDetectionPolicy {
    func normalized() -> RealtimeDeferredPartialDetectionPolicy {
        RealtimeDeferredPartialDetectionPolicy(
            stableCandidateDelayMilliseconds: max(0, stableCandidateDelayMilliseconds),
            deferredDetectionDelayMilliseconds: max(0, deferredDetectionDelayMilliseconds),
            forcedPartialStability: clampedUnit(forcedPartialStability),
            forcedRevisionCount: max(0, forcedRevisionCount),
            minimumTokenCount: max(1, minimumTokenCount),
            minimumCJKCharacterCount: max(1, minimumCJKCharacterCount),
            minimumConfidence: clampedUnit(minimumConfidence),
            completeMinimumTokenCount: max(1, completeMinimumTokenCount),
            completeMinimumCJKCharacterCount: max(1, completeMinimumCJKCharacterCount),
            allowModelRescuePrefilter: allowModelRescuePrefilter,
            modelRescuePrefilterRequiresSurfaceEvidence: modelRescuePrefilterRequiresSurfaceEvidence
        )
    }
}

private extension RealtimeMultiQTRescuePolicy {
    func normalized() -> RealtimeMultiQTRescuePolicy {
        RealtimeMultiQTRescuePolicy(
            minimumResponseMargin: clampedUnit(minimumResponseMargin),
            minimumCandidateScore: clampedUnit(minimumCandidateScore),
            partialMinimumStability: clampedUnit(partialMinimumStability),
            partialMinimumRevisionCount: max(0, partialMinimumRevisionCount),
            minimumFrameCharacters: max(1, minimumFrameCharacters)
        )
    }
}

private extension RealtimeAnswerGenerationGatePolicy {
    func normalized() -> RealtimeAnswerGenerationGatePolicy {
        RealtimeAnswerGenerationGatePolicy(
            requiresResponseNeeded: requiresResponseNeeded,
            requiresComplete: requiresComplete,
            suppressesRhetorical: suppressesRhetorical,
            allowedPriorities: allowedPriorities
        )
    }
}

private func clampedUnit(_ value: Double) -> Double {
    min(1, max(0, value))
}

struct QuestionPartialStability: Hashable, Sendable {
    var score: Double
    var revisionCount: Int
    var isStable: Bool
}

struct QuestionPartialStabilityTracker {
    private struct State {
        var normalizedText: String
        var stableCount: Int
    }

    private var policy: RealtimePartialStabilityPolicy
    private var textPolicy: QuestionTextSegmentationPolicy
    private var states: [String: State] = [:]

    init(
        policy: RealtimePartialStabilityPolicy = .fallback,
        textPolicy: QuestionTextSegmentationPolicy = QuestionIntentRulePack.default.textSegmentationPolicy
    ) {
        self.policy = policy.normalized()
        self.textPolicy = textPolicy
    }

    mutating func reset() {
        states = [:]
    }

    mutating func observe(segment: TranscriptSegment) -> QuestionPartialStability {
        let normalized = QuestionDetectionService.normalize(segment.text)
        guard !normalized.isEmpty else {
            return QuestionPartialStability(score: 0, revisionCount: 0, isStable: false)
        }
        guard !segment.isFinal else {
            states[key(for: segment)] = State(normalizedText: normalized, stableCount: policy.finalStableCount)
            return QuestionPartialStability(score: 1, revisionCount: max(segment.revisionNumber, 1), isStable: true)
        }

        let key = key(for: segment)
        let previous = states[key]
        let similarity = previous.map { textSimilarity($0.normalizedText, normalized) } ?? 0
        let stableCount = similarity >= policy.similarityStableThreshold ? (previous?.stableCount ?? 0) + 1 : 1
        states[key] = State(normalizedText: normalized, stableCount: stableCount)

        let tokenCount = textPolicy.lexicalTokenCount(in: normalized)
        let score = min(1, max(similarity, stableCount >= policy.stableRevisionCount ? policy.stableScoreFloor : policy.unstableScoreFloor))
        let isStable = stableCount >= policy.stableRevisionCount && tokenCount >= policy.stableMinimumTokens
        return QuestionPartialStability(score: score, revisionCount: max(stableCount - 1, segment.revisionNumber), isStable: isStable)
    }

    private func key(for segment: TranscriptSegment) -> String {
        [
            segment.meetingId.uuidString,
            segment.speakerId?.uuidString ?? segment.speakerLabel,
            segment.audioSource.rawValue
        ].joined(separator: "|")
    }

    private func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) {
            let shorter = Double(min(lhs.count, rhs.count))
            let longer = Double(max(lhs.count, rhs.count))
            return max(policy.prefixSimilarityFloor, shorter / max(longer, 1))
        }
        let leftTokens = Set(textPolicy.lexicalTokens(in: lhs))
        let rightTokens = Set(textPolicy.lexicalTokens(in: rhs))
        guard !leftTokens.isEmpty || !rightTokens.isEmpty else { return 0 }
        return Double(leftTokens.intersection(rightTokens).count) / Double(max(leftTokens.union(rightTokens).count, 1))
    }
}

@MainActor
class RealtimeQuestionAnsweringEngine {
    let eventBus: RealtimeQuestionEventBus

    private var buffer = TranscriptWindowBuffer()
    private var candidateStore = QuestionCandidateStore()
    private var partialStabilityTracker = QuestionPartialStabilityTracker()
    private var pendingDetectionTasks: [String: Task<Void, Never>] = [:]
    private var generationTasks: [UUID: Task<Void, Never>] = [:]

    private let detectionService: QuestionDetectionService
    private let classifierProvider: any QuestionClassifierProvider
    private let contextRetriever: any ContextRetrievalProvider
    private let answerProvider: any MeetingAnswerProvider
    private let deduplicator: QuestionDeduplicator
    private let intentGate: QuestionIntentGate
    private let multiqtRescuer: QuestionMultiQTCandidateRescuer?
    private let shadowLogger: QuestionShadowLogger?
    private let realtimePolicy: RealtimeQuestionAnsweringPolicy

    init(
        eventBus: RealtimeQuestionEventBus = RealtimeQuestionEventBus(),
        detectionService: QuestionDetectionService = QuestionDetectionService(),
        classifierProvider: any QuestionClassifierProvider,
        contextRetriever: any ContextRetrievalProvider,
        answerProvider: any MeetingAnswerProvider,
        deduplicator: QuestionDeduplicator = QuestionDeduplicator(),
        intentGate: QuestionIntentGate = QuestionIntentGate(),
        multiqtRescuer: QuestionMultiQTCandidateRescuer? = nil,
        shadowLogger: QuestionShadowLogger? = nil,
        realtimePolicy: RealtimeQuestionAnsweringPolicy = .default
    ) {
        let normalizedRealtimePolicy = realtimePolicy.normalized()
        var normalizedRescuer = multiqtRescuer
        normalizedRescuer?.rescuePolicy = normalizedRealtimePolicy.multiqtRescuePolicy
        self.eventBus = eventBus
        self.detectionService = detectionService
        self.classifierProvider = classifierProvider
        self.contextRetriever = contextRetriever
        self.answerProvider = answerProvider
        self.deduplicator = deduplicator
        self.intentGate = intentGate
        self.multiqtRescuer = normalizedRescuer
        self.shadowLogger = shadowLogger
        self.realtimePolicy = normalizedRealtimePolicy
        self.partialStabilityTracker = QuestionPartialStabilityTracker(
            policy: normalizedRealtimePolicy.partialStabilityPolicy,
            textPolicy: intentGate.rulePack.textSegmentationPolicy
        )
    }

    func reset() {
        pendingDetectionTasks.values.forEach { $0.cancel() }
        generationTasks.values.forEach { $0.cancel() }
        pendingDetectionTasks = [:]
        generationTasks = [:]
        buffer.reset()
        partialStabilityTracker.reset()
        candidateStore = QuestionCandidateStore()
    }

    func stop() {
        reset()
        eventBus.finish()
    }

    func ingest(
        segment: TranscriptSegment,
        meeting: MeetingSession,
        preferences: AppPreferences,
        multimodalSignal incomingSignal: QuestionMultimodalSignal? = nil
    ) async {
        buffer.append(segment)
        let context = buffer.transcriptContext(currentSegment: segment)
        let profile = UserMeetingProfile(preferences: preferences, meeting: meeting)
        let stability = partialStabilityTracker.observe(segment: segment)
        let signal = (incomingSignal ?? QuestionMultimodalSignal(segment: segment))
            .withPartialStability(stability.score, revisionCount: stability.revisionCount)
        let detectionKey = pendingDetectionKey(for: segment)

        if segment.isFinal {
            pendingDetectionTasks[detectionKey]?.cancel()
            pendingDetectionTasks[detectionKey] = nil
        }

        if !segment.isFinal, !stability.isStable {
            scheduleDeferredPartialDetection(
                segment: segment,
                meeting: meeting,
                preferences: preferences,
                signal: signal,
                context: context,
                profile: profile,
                detectionKey: detectionKey
            )
            detectAnsweredQuestions(segment: segment)
            return
        }

        let detection = detectionService.detect(from: segment, context: context, signal: signal, profile: profile)
        let candidates = await candidatesWithMultiQTRescue(
            detection: detection,
            context: context,
            preferences: preferences,
            profile: profile
        )
        guard !candidates.isEmpty else {
            detectAnsweredQuestions(segment: segment)
            return
        }

        for candidate in candidates {
            if segment.isFinal {
                await process(candidate: candidate, meeting: meeting, preferences: preferences)
            } else {
                pendingDetectionTasks[detectionKey]?.cancel()
                let delayMilliseconds = realtimePolicy.deferredPartialDetectionPolicy.stableCandidateDelayMilliseconds
                pendingDetectionTasks[detectionKey] = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(Int64(delayMilliseconds)))
                    guard !Task.isCancelled else { return }
                    await self?.process(candidate: candidate, meeting: meeting, preferences: preferences)
                }
            }
        }
    }

    private func scheduleDeferredPartialDetection(
        segment: TranscriptSegment,
        meeting: MeetingSession,
        preferences: AppPreferences,
        signal: QuestionMultimodalSignal,
        context: TranscriptContext,
        profile: UserMeetingProfile,
        detectionKey: String
    ) {
        pendingDetectionTasks[detectionKey]?.cancel()
        guard shouldScheduleDeferredPartialDetection(
            for: segment,
            context: context,
            profile: profile,
            preferences: preferences,
            signal: signal
        ) else { return }

        let partialPolicy = realtimePolicy.deferredPartialDetectionPolicy
        let delayedSignal = signal.withPartialStability(
            max(signal.partialStability, partialPolicy.forcedPartialStability),
            revisionCount: max(signal.partialRevisionCount, partialPolicy.forcedRevisionCount)
        )
        pendingDetectionTasks[detectionKey] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int64(partialPolicy.deferredDetectionDelayMilliseconds)))
            guard !Task.isCancelled, let self else { return }

            let detection = self.detectionService.detect(
                from: segment,
                context: context,
                signal: delayedSignal,
                profile: profile
            )
            let candidates = await self.candidatesWithMultiQTRescue(
                detection: detection,
                context: context,
                preferences: preferences,
                profile: profile
            )
            guard !candidates.isEmpty else {
                self.pendingDetectionTasks[detectionKey] = nil
                self.detectAnsweredQuestions(segment: segment)
                return
            }

            for candidate in candidates {
                guard !Task.isCancelled else { return }
                await self.process(candidate: candidate, meeting: meeting, preferences: preferences)
            }
            if !Task.isCancelled {
                self.pendingDetectionTasks[detectionKey] = nil
            }
        }
    }

    private func shouldScheduleDeferredPartialDetection(
        for segment: TranscriptSegment,
        context: TranscriptContext,
        profile: UserMeetingProfile,
        preferences: AppPreferences,
        signal: QuestionMultimodalSignal
    ) -> Bool {
        let partialPolicy = realtimePolicy.deferredPartialDetectionPolicy
        let normalized = QuestionDetectionService.normalize(segment.text)
        guard !normalized.isEmpty else { return false }
        let textPolicy = intentGate.rulePack.textSegmentationPolicy
        let tokenCount = textPolicy.lexicalTokenCount(in: normalized)
        let cjkCount = textPolicy.compactScriptCharacterCount(in: normalized)
        guard tokenCount >= partialPolicy.minimumTokenCount || cjkCount >= partialPolicy.minimumCJKCharacterCount else { return false }
        let confidence = segment.engineConfidence ?? segment.confidence
        if confidence < partialPolicy.minimumConfidence {
            return false
        }
        guard looksCompleteEnoughForDeferredPartial(normalized) else { return false }
        if detectionService.isLikelyQuestion(normalized, profile: profile) {
            return true
        }
        guard partialPolicy.allowModelRescuePrefilter,
              preferences.qaMultimodalMode != .off,
              multiqtRescuer != nil else {
            return false
        }
        let detection = detectionService.detect(
            from: segment,
            context: context,
            signal: signal,
            profile: profile
        )
        return detection.rejectedFrames.contains { rejected in
            guard !rejected.hasModelRescueBlockingSuppression(rulePack: intentGate.rulePack) else { return false }
            guard partialPolicy.modelRescuePrefilterRequiresSurfaceEvidence else { return true }
            return !rejected.surfaceSignals.isEmpty
        }
    }

    private func pendingDetectionKey(for segment: TranscriptSegment) -> String {
        [
            segment.meetingId.uuidString,
            segment.speakerId?.uuidString ?? segment.speakerLabel,
            segment.audioSource.rawValue
        ].joined(separator: "|")
    }

    private func candidatesWithMultiQTRescue(
        detection: QuestionDetectionResult,
        context: TranscriptContext,
        preferences: AppPreferences,
        profile: UserMeetingProfile
    ) async -> [QuestionCandidate] {
        guard let multiqtRescuer, preferences.qaMultimodalMode != .off else {
            return detection.surfaceCandidates
        }
        let surfaceCandidates = await multiqtRescuer.refineSurfaceCandidates(
            detection.surfaceCandidates,
            context: context,
            mode: preferences.qaMultimodalMode,
            profile: profile
        )
        let rescued = await multiqtRescuer.rescueCandidates(
            from: detection.rejectedFrames,
            context: context,
            mode: preferences.qaMultimodalMode,
            profile: profile,
            shadowLogger: shadowLogger
        )
        return surfaceCandidates + rescued
    }

    private func looksCompleteEnoughForDeferredPartial(_ normalized: String) -> Bool {
        let textPolicy = intentGate.rulePack.textSegmentationPolicy
        if textPolicy.containsQuestionPunctuation(in: normalized) {
            return true
        }
        if QuestionDetectionService.hasNumericQuestionPayload(normalized, rulePack: intentGate.rulePack) {
            return true
        }

        let plain = QuestionIntentGate.plainQuestionText(normalized, textPolicy: textPolicy)
        let variants = partialAddressVariants(for: plain)
        if variants.contains(where: isIncompleteActionPartial) {
            return false
        }

        return variants.contains { variant in
            let tokens = textPolicy.lexicalTokens(in: variant)
            guard tokens.count >= realtimePolicy.deferredPartialDetectionPolicy.completeMinimumTokenCount ||
                textPolicy.compactScriptCharacterCount(in: variant) >= realtimePolicy.deferredPartialDetectionPolicy.completeMinimumCJKCharacterCount else {
                return false
            }
            if let last = tokens.last, isDanglingPartialToken(last) {
                return false
            }
            return true
        }
    }

    private func partialAddressVariants(for plain: String) -> [String] {
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        let textPolicy = intentGate.rulePack.textSegmentationPolicy
        let tokens = textPolicy.lexicalTokens(in: trimmed)
        guard !textPolicy.containsCompactScript(in: trimmed),
              tokens.count >= textPolicy.leadAddressMinimumTokens else {
            return [trimmed]
        }
        let withoutFirst = tokens.dropFirst().joined(separator: " ")
        return [trimmed, withoutFirst]
    }

    private func isIncompleteActionPartial(_ text: String) -> Bool {
        realtimePolicy.incompleteActionFrames.contains(text)
    }

    private func isDanglingPartialToken(_ token: String) -> Bool {
        realtimePolicy.danglingPartialTokens.contains(token)
    }

    func dismiss(questionId: UUID) {
        generationTasks[questionId]?.cancel()
        generationTasks[questionId] = nil
        candidateStore.mark(questionId, status: .dismissed)
        eventBus.send(.questionCancelled(questionId, realtimePolicy.runtimeLabels.questionDismissedMessage))
    }

    func candidate(for id: UUID) -> QuestionCandidate? {
        candidateStore.candidates[id]
    }

    func removeTranscriptSegment(_ segment: TranscriptSegment) {
        pendingDetectionTasks[pendingDetectionKey(for: segment)]?.cancel()
        pendingDetectionTasks[pendingDetectionKey(for: segment)] = nil
        buffer.remove(segmentId: segment.id)
    }

    private func process(candidate incoming: QuestionCandidate, meeting: MeetingSession, preferences: AppPreferences) async {
        let profile = UserMeetingProfile(preferences: preferences, meeting: meeting)
        let transcriptContext = buffer.transcriptContext(currentSegment: nil)

        var candidate = incoming
        if let duplicate = deduplicator.duplicate(of: incoming, in: Array(candidateStore.candidates.values)) {
            candidate = deduplicator.merged(duplicate, with: incoming)
            eventBus.send(.questionMerged(source: incoming, target: candidate))
        }

        if candidate.discovery.source == .multiqtRescue {
            if let hardSuppression = intentGate.hardSuppression(candidate: candidate, context: transcriptContext, profile: profile) {
                let classification = QuestionClassification(ignoredBy: hardSuppression.evaluation, candidate: candidate)
                candidate.classification = classification
                candidate.status = .ignored
                candidateStore.upsert(candidate)
                shadowLogger?.record(
                    candidate: candidate,
                    classification: classification,
                    decision: realtimePolicy.runtimeLabels.shadowIgnoredHardSuppression
                )
                eventBus.send(.questionIgnored(candidate, classification.reason))
                return
            }
        } else {
            let intent = intentGate.evaluate(candidate: candidate, context: transcriptContext, profile: profile)
            guard intent.isAnswerableQuestion else {
                let classification = QuestionClassification(ignoredBy: intent, candidate: candidate)
                candidate.classification = classification
                candidate.status = .ignored
                candidateStore.upsert(candidate)
                shadowLogger?.record(
                    candidate: candidate,
                    classification: classification,
                    decision: realtimePolicy.runtimeLabels.shadowIgnoredIntentGate
                )
                eventBus.send(.questionIgnored(candidate, classification.reason))
                return
            }
        }

        do {
            let classification = try await classifierProvider.classifyQuestion(
                candidate: candidate,
                context: transcriptContext,
                userProfile: profile
            )
            candidate.classification = classification
            candidate.status = classification.isQuestion && classification.complete && !classification.rhetorical ? .confirmed : .ignored
            candidateStore.upsert(candidate)
            shadowLogger?.record(
                candidate: candidate,
                classification: classification,
                decision: classification.responseNeeded
                    ? realtimePolicy.runtimeLabels.shadowAccepted
                    : realtimePolicy.runtimeLabels.shadowIgnoredClassifier
            )

            guard classification.isQuestion && classification.responseNeeded else {
                eventBus.send(.questionIgnored(candidate, classification.reason))
                return
            }

            eventBus.send(.questionDetected(candidate, classification))

            guard shouldGenerateAnswer(for: classification) else { return }
            startAnswerGeneration(for: candidate, classification: classification, meeting: meeting, preferences: preferences)
        } catch {
            eventBus.send(.questionIgnored(candidate, error.localizedDescription))
        }
    }

    private func shouldGenerateAnswer(for classification: QuestionClassification) -> Bool {
        let gate = realtimePolicy.answerGenerationGatePolicy
        if gate.requiresResponseNeeded && !classification.responseNeeded { return false }
        if gate.requiresComplete && !classification.complete { return false }
        if gate.suppressesRhetorical && classification.rhetorical { return false }
        return gate.allowedPriorities.contains(classification.priority)
    }

    private func startAnswerGeneration(
        for candidate: QuestionCandidate,
        classification: QuestionClassification,
        meeting: MeetingSession,
        preferences: AppPreferences
    ) {
        if classification.priority == .urgent {
            for (questionId, task) in generationTasks where questionId != candidate.id {
                task.cancel()
                generationTasks[questionId] = nil
                eventBus.send(.questionCancelled(questionId, realtimePolicy.runtimeLabels.urgentQuestionSupersededMessage))
            }
        }

        generationTasks[candidate.id]?.cancel()
        generationTasks[candidate.id] = Task { [weak self] in
            guard let self else { return }
            await self.generateAnswer(for: candidate, classification: classification, meeting: meeting, preferences: preferences)
        }
    }

    private func generateAnswer(
        for candidate: QuestionCandidate,
        classification: QuestionClassification,
        meeting: MeetingSession,
        preferences: AppPreferences
    ) async {
        do {
            eventBus.send(.answerGenerating(candidate.id, .classifying))
            let transcriptContext = buffer.transcriptContext(currentSegment: nil)
            let meetingContext = MeetingContext(
                meeting: meeting,
                transcriptContext: transcriptContext,
                shortTermMemory: buffer.shortTermMemory,
                preferences: preferences
            )
            eventBus.send(.answerGenerating(candidate.id, .retrievingContext))
            let answerContext = try await contextRetriever.retrieveContext(
                question: candidate,
                classification: classification,
                meetingContext: meetingContext
            )
            eventBus.send(.answerGenerating(candidate.id, .drafting))
            let stream = try await answerProvider.generateAnswer(
                question: candidate,
                classification: classification,
                context: answerContext,
                options: AnswerGenerationOptions(
                    maxSentences: realtimePolicy.answerMaxSentences,
                    allowCommitments: realtimePolicy.answerAllowCommitments,
                    enableWebSearch: preferences.aiConfig.webSearchEnabled,
                    enableRAG: preferences.aiConfig.ragEnabled,
                    localOnlyMode: preferences.localOnlyMode
                )
            )
            var streamedText = ""
            for try await partial in stream {
                guard !Task.isCancelled else {
                    eventBus.send(.answerGenerating(candidate.id, .cancelled))
                    return
                }
                if !partial.textDelta.isEmpty {
                    streamedText = partial.isFinal ? partial.textDelta : streamedText + partial.textDelta
                    eventBus.send(.partialAnswerUpdated(candidate.id, streamedText))
                }
                if partial.isFinal, let answer = partial.suggestedAnswer {
                    eventBus.send(.answerGenerating(candidate.id, .finalizing))
                    candidateStore.store(answer)
                    eventBus.send(.suggestedAnswerReady(candidate, answer))
                    eventBus.send(.answerGenerating(candidate.id, .ready))
                }
            }
        } catch is CancellationError {
            eventBus.send(.answerGenerating(candidate.id, .cancelled))
        } catch {
            eventBus.send(.answerFailed(candidate.id, failureMessage(for: error)))
        }
    }

    private func failureMessage(for error: Error) -> String {
        if let aiError = error as? AIProviderError,
           let description = aiError.errorDescription {
            if case .cloudDisabled = aiError {
                return realtimePolicy.runtimeLabels.cloudDisabledFailureMessage.nilIfEmptyRealtimePolicy ?? description
            }
            return description
        }
        return realtimePolicy.runtimeLabels.localAnswerFailureMessage.nilIfEmptyRealtimePolicy ?? error.localizedDescription
    }

    private func detectAnsweredQuestions(segment: TranscriptSegment) {
        let text = QuestionDetectionService.normalize(segment.text)
        guard contains(text, realtimePolicy.answerResolutionMarkers) else { return }
        for candidate in candidateStore.candidates.values where candidate.status == .confirmed {
            guard Date().timeIntervalSince(candidate.detectedAt) < realtimePolicy.selfAnswerWindowSeconds else { continue }
            if candidate.speakerId == segment.speakerId || candidate.speakerLabel == segment.speakerLabel {
                generationTasks[candidate.id]?.cancel()
                candidateStore.mark(candidate.id, status: .answered)
                eventBus.send(.questionCancelled(candidate.id, realtimePolicy.runtimeLabels.selfAnsweredCancellationMessage))
            }
        }
    }

    private func contains(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { pattern in
            intentGate.rulePack.textSegmentationPolicy.containsMarker(pattern, in: text)
        }
    }
}

extension RealtimeQuestionAnsweringEngine {
    convenience init(
        providerRouter: ProviderRouter,
        preferences: AppPreferences,
        knowledgeStore: LocalKnowledgeStore?
    ) {
        let classifier = providerRouter.questionClassifierProvider(preferences: preferences)
        let answerProvider = providerRouter.meetingAnswerProvider(preferences: preferences)
        let contextRetriever = MeetingContextRetriever(
            knowledgeStore: knowledgeStore,
            embeddingProvider: LocalEmbeddingProvider(
                tier: preferences.ragLocalEmbeddingTier,
                runtime: preferences.resolvedLocalEmbeddingRuntime,
                allowModelDownloads: preferences.allowLocalModelDownloads,
                allowMetalAcceleration: preferences.ragAppleMetalAccelerationEnabled,
                serverConfiguration: preferences.localEmbeddingServerConfiguration
            )
        )
        self.init(
            detectionService: QuestionDetectionService(
                adaptiveProfile: preferences.questionAnsweringProfile,
                precisionMode: preferences.qaPrecisionMode
            ),
            classifierProvider: classifier,
            contextRetriever: contextRetriever,
            answerProvider: answerProvider,
            intentGate: QuestionIntentGate(adaptiveProfile: preferences.questionAnsweringProfile),
            multiqtRescuer: QuestionMultiQTCandidateRescuer(
                trainedModelRunner: CoreMLQuestionMultiQTModelRunner(),
                intentGate: QuestionIntentGate(adaptiveProfile: preferences.questionAnsweringProfile)
            ),
            shadowLogger: preferences.qaShadowMode ? QuestionShadowLogger() : nil
        )
    }
}

private extension UserMeetingProfile {
    init(preferences: AppPreferences, meeting: MeetingSession) {
        self.init(
            userName: preferences.userDisplayName,
            userAliases: ([preferences.userDisplayName] + preferences.userNicknames.split(separator: ",").map { String($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            userRole: preferences.userRole,
            preferredStyle: .technical,
            preferredLanguages: [preferences.defaultLanguage, meeting.primaryLanguage].compactMap { $0 },
            meetingType: meeting.meetingType
        )
    }
}
