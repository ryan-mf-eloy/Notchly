import Foundation

@MainActor
protocol QuestionClassifierProvider {
    func classifyQuestion(
        candidate: QuestionCandidate,
        context: TranscriptContext,
        userProfile: UserMeetingProfile
    ) async throws -> QuestionClassification
}

struct QuestionMultimodalSignalLabels: Codable, Hashable, Sendable {
    var textOnly: String
    var final: String
    var partialStable: String
    var partialUnstable: String
    var asrConfident: String
    var lowASRConfidence: String
    var terminalPause: String
    var durationPlausible: String
    var tooShortAudio: String
    var tooLongAudio: String
    var energyPresent: String
    var nearSilence: String
    var silence: String
    var tooQuiet: String
    var clipping: String
    var audioGaps: String
    var neutral: String

    static let fallback = QuestionMultimodalSignalLabels(
        textOnly: "text_only",
        final: "final",
        partialStable: "partial_stable",
        partialUnstable: "partial_unstable",
        asrConfident: "asr_confident",
        lowASRConfidence: "low_asr_confidence",
        terminalPause: "terminal_pause",
        durationPlausible: "duration_plausible",
        tooShortAudio: "too_short_audio",
        tooLongAudio: "too_long_audio",
        energyPresent: "energy_present",
        nearSilence: "near_silence",
        silence: "silence",
        tooQuiet: "too_quiet",
        clipping: "clipping",
        audioGaps: "audio_gaps",
        neutral: "multimodal_neutral"
    )

    init(
        textOnly: String,
        final: String,
        partialStable: String,
        partialUnstable: String,
        asrConfident: String,
        lowASRConfidence: String,
        terminalPause: String,
        durationPlausible: String,
        tooShortAudio: String,
        tooLongAudio: String,
        energyPresent: String,
        nearSilence: String,
        silence: String,
        tooQuiet: String,
        clipping: String,
        audioGaps: String,
        neutral: String
    ) {
        self.textOnly = textOnly
        self.final = final
        self.partialStable = partialStable
        self.partialUnstable = partialUnstable
        self.asrConfident = asrConfident
        self.lowASRConfidence = lowASRConfidence
        self.terminalPause = terminalPause
        self.durationPlausible = durationPlausible
        self.tooShortAudio = tooShortAudio
        self.tooLongAudio = tooLongAudio
        self.energyPresent = energyPresent
        self.nearSilence = nearSilence
        self.silence = silence
        self.tooQuiet = tooQuiet
        self.clipping = clipping
        self.audioGaps = audioGaps
        self.neutral = neutral
    }
}

enum QuestionMultimodalSignalKey: String, Codable, Hashable, Sendable {
    case textOnly
    case final
    case partialStable
    case partialUnstable
    case asrConfident
    case lowASRConfidence
    case terminalPause
    case durationPlausible
    case tooShortAudio
    case tooLongAudio
    case energyPresent
    case nearSilence
    case silence
    case tooQuiet
    case clipping
    case audioGaps
    case neutral

    func resolvedLabel(in labels: QuestionMultimodalSignalLabels) -> String {
        switch self {
        case .textOnly:
            labels.textOnly
        case .final:
            labels.final
        case .partialStable:
            labels.partialStable
        case .partialUnstable:
            labels.partialUnstable
        case .asrConfident:
            labels.asrConfident
        case .lowASRConfidence:
            labels.lowASRConfidence
        case .terminalPause:
            labels.terminalPause
        case .durationPlausible:
            labels.durationPlausible
        case .tooShortAudio:
            labels.tooShortAudio
        case .tooLongAudio:
            labels.tooLongAudio
        case .energyPresent:
            labels.energyPresent
        case .nearSilence:
            labels.nearSilence
        case .silence:
            labels.silence
        case .tooQuiet:
            labels.tooQuiet
        case .clipping:
            labels.clipping
        case .audioGaps:
            labels.audioGaps
        case .neutral:
            labels.neutral
        }
    }
}

struct QuestionMultimodalPolicy: Codable, Hashable, Sendable {
    var textualConfidenceFloor: Double
    var textualConfidenceCeiling: Double
    var finalBonus: Double
    var partialStableThreshold: Double
    var partialStableBonus: Double
    var partialUnstablePenalty: Double
    var asrConfidentThreshold: Double
    var asrConfidentBonus: Double
    var lowASRConfidenceThreshold: Double
    var lowASRConfidencePenalty: Double
    var terminalPauseBonus: Double
    var minPlausibleDuration: Double
    var maxPlausibleDuration: Double
    var durationPlausibleBonus: Double
    var tooShortDuration: Double
    var tooShortPenalty: Double
    var tooLongDuration: Double
    var tooLongPenalty: Double
    var minEnergy: Double
    var maxEnergy: Double
    var energyPresentBonus: Double
    var nearSilenceEnergy: Double
    var nearSilencePenalty: Double
    var silencePenalty: Double
    var tooQuietPenalty: Double
    var clippingPenalty: Double
    var audioGapCountThreshold: Int
    var audioGapPenalty: Double
    var textualDecisionWeight: Double
    var multimodalDecisionWeight: Double
    var hardSuppressionSignals: Set<String>
    var hardSuppressionSignalKeys: Set<QuestionMultimodalSignalKey>
    var signalLabels: QuestionMultimodalSignalLabels

    static let fallback = QuestionMultimodalPolicy(
        textualConfidenceFloor: 0.05,
        textualConfidenceCeiling: 0.98,
        finalBonus: 0.05,
        partialStableThreshold: 0.82,
        partialStableBonus: 0.04,
        partialUnstablePenalty: 0.18,
        asrConfidentThreshold: 0.82,
        asrConfidentBonus: 0.03,
        lowASRConfidenceThreshold: 0.45,
        lowASRConfidencePenalty: 0.12,
        terminalPauseBonus: 0.03,
        minPlausibleDuration: 0.45,
        maxPlausibleDuration: 18,
        durationPlausibleBonus: 0.02,
        tooShortDuration: 0.30,
        tooShortPenalty: 0.10,
        tooLongDuration: 30,
        tooLongPenalty: 0.04,
        minEnergy: 0.002,
        maxEnergy: 0.35,
        energyPresentBonus: 0.02,
        nearSilenceEnergy: 0.001,
        nearSilencePenalty: 0.08,
        silencePenalty: 0.10,
        tooQuietPenalty: 0.08,
        clippingPenalty: 0.08,
        audioGapCountThreshold: 2,
        audioGapPenalty: 0.04,
        textualDecisionWeight: 0.65,
        multimodalDecisionWeight: 0.35,
        hardSuppressionSignals: [],
        hardSuppressionSignalKeys: [.partialUnstable, .silence, .nearSilence],
        signalLabels: .fallback
    )

    static let policyOwnedDefault = QuestionMultimodalPolicy(
        textualConfidenceFloor: fallback.textualConfidenceFloor,
        textualConfidenceCeiling: fallback.textualConfidenceCeiling,
        finalBonus: fallback.finalBonus,
        partialStableThreshold: fallback.partialStableThreshold,
        partialStableBonus: fallback.partialStableBonus,
        partialUnstablePenalty: fallback.partialUnstablePenalty,
        asrConfidentThreshold: fallback.asrConfidentThreshold,
        asrConfidentBonus: fallback.asrConfidentBonus,
        lowASRConfidenceThreshold: fallback.lowASRConfidenceThreshold,
        lowASRConfidencePenalty: fallback.lowASRConfidencePenalty,
        terminalPauseBonus: fallback.terminalPauseBonus,
        minPlausibleDuration: fallback.minPlausibleDuration,
        maxPlausibleDuration: fallback.maxPlausibleDuration,
        durationPlausibleBonus: fallback.durationPlausibleBonus,
        tooShortDuration: fallback.tooShortDuration,
        tooShortPenalty: fallback.tooShortPenalty,
        tooLongDuration: fallback.tooLongDuration,
        tooLongPenalty: fallback.tooLongPenalty,
        minEnergy: fallback.minEnergy,
        maxEnergy: fallback.maxEnergy,
        energyPresentBonus: fallback.energyPresentBonus,
        nearSilenceEnergy: fallback.nearSilenceEnergy,
        nearSilencePenalty: fallback.nearSilencePenalty,
        silencePenalty: fallback.silencePenalty,
        tooQuietPenalty: fallback.tooQuietPenalty,
        clippingPenalty: fallback.clippingPenalty,
        audioGapCountThreshold: fallback.audioGapCountThreshold,
        audioGapPenalty: fallback.audioGapPenalty,
        textualDecisionWeight: fallback.textualDecisionWeight,
        multimodalDecisionWeight: fallback.multimodalDecisionWeight,
        hardSuppressionSignals: [],
        hardSuppressionSignalKeys: [],
        signalLabels: .fallback
    )

    var effectiveHardSuppressionSignals: Set<String> {
        var resolved = Set(hardSuppressionSignals.map(\.trimmedQuestionClassificationPolicy).filter { !$0.isEmpty })
        for key in hardSuppressionSignalKeys {
            let label = key.resolvedLabel(in: signalLabels).trimmedQuestionClassificationPolicy
            guard !label.isEmpty else { continue }
            resolved.insert(label)
        }
        return resolved
    }
}

struct QuestionDecisionGateModePolicy: Codable, Hashable, Sendable {
    var confidenceThreshold: Double
    var partialConfidenceThreshold: Double
    var requiredStrongSignalCount: Int

    static let highPrecision = QuestionDecisionGateModePolicy(
        confidenceThreshold: 0.82,
        partialConfidenceThreshold: 0.92,
        requiredStrongSignalCount: 2
    )

    static let balanced = QuestionDecisionGateModePolicy(
        confidenceThreshold: 0.74,
        partialConfidenceThreshold: 0.86,
        requiredStrongSignalCount: 1
    )

    static let highCoverage = QuestionDecisionGateModePolicy(
        confidenceThreshold: 0.66,
        partialConfidenceThreshold: 0.78,
        requiredStrongSignalCount: 1
    )

    init(
        confidenceThreshold: Double,
        partialConfidenceThreshold: Double,
        requiredStrongSignalCount: Int
    ) {
        self.confidenceThreshold = confidenceThreshold
        self.partialConfidenceThreshold = partialConfidenceThreshold
        self.requiredStrongSignalCount = requiredStrongSignalCount
    }
}

struct QuestionDecisionGatePolicy: Codable, Hashable, Sendable {
    var modeThresholds: [String: QuestionDecisionGateModePolicy]
    var ignoredSignals: Set<QuestionUnderstandingSignal>
    var partialStrictSignals: Set<QuestionUnderstandingSignal>
    var partialCompleteShapeSignals: Set<QuestionUnderstandingSignal>
    var partialCompleteShapeConfidenceDelta: Double
    var partialCompleteShapeMinimumConfidence: Double

    static let fallback = QuestionDecisionGatePolicy(
        modeThresholds: [
            QAPrecisionMode.highPrecision.rawValue: .highPrecision,
            QAPrecisionMode.balanced.rawValue: .balanced,
            QAPrecisionMode.highCoverage.rawValue: .highCoverage
        ],
        ignoredSignals: [.finalUtterance],
        partialStrictSignals: [.directedToUser, .actionRequestFrame],
        partialCompleteShapeSignals: [.interrogativeStarter, .concreteObject],
        partialCompleteShapeConfidenceDelta: 0.12,
        partialCompleteShapeMinimumConfidence: 0.70
    )

    static let policyOwnedDefault = QuestionDecisionGatePolicy(
        modeThresholds: [:],
        ignoredSignals: [],
        partialStrictSignals: [],
        partialCompleteShapeSignals: [],
        partialCompleteShapeConfidenceDelta: fallback.partialCompleteShapeConfidenceDelta,
        partialCompleteShapeMinimumConfidence: fallback.partialCompleteShapeMinimumConfidence
    )

    func thresholds(for mode: QAPrecisionMode) -> QuestionDecisionGateModePolicy {
        modeThresholds[mode.rawValue]
            ?? modeThresholds[QAPrecisionMode.highPrecision.rawValue]
            ?? .highPrecision
    }
}

struct QuestionClassificationReasonPolicy: Codable, Hashable, Sendable {
    var multimodalRejectedTemplate: String
    var localGateRejectedTemplate: String
    var multiQTRescued: String
    var multiQTModelAccepted: String

    static let fallback = QuestionClassificationReasonPolicy(
        multimodalRejectedTemplate: "Rejected by multimodal stability gate: {suppressionSignals}",
        localGateRejectedTemplate: "Rejected by high-precision local decision gate: {understandingReason}",
        multiQTRescued: "MultiQT rescued a model-positive question that the surface detector rejected.",
        multiQTModelAccepted: "MultiQT accepted a model-positive question without relying on fixed lexical rules."
    )

    init(
        multimodalRejectedTemplate: String,
        localGateRejectedTemplate: String,
        multiQTRescued: String,
        multiQTModelAccepted: String
    ) {
        self.multimodalRejectedTemplate = multimodalRejectedTemplate
        self.localGateRejectedTemplate = localGateRejectedTemplate
        self.multiQTRescued = multiQTRescued
        self.multiQTModelAccepted = multiQTModelAccepted
    }
}

struct QuestionMultimodalDecision: Hashable, Sendable {
    var textualConfidence: Double
    var multimodalConfidence: Double
    var decisionScore: Double
    var shouldAllow: Bool
    var decisionSignals: [String]
    var suppressionSignals: [String]

    init(
        textualConfidence: Double,
        multimodalConfidence: Double,
        decisionScore: Double,
        shouldAllow: Bool,
        decisionSignals: [String],
        suppressionSignals: [String]
    ) {
        self.textualConfidence = textualConfidence
        self.multimodalConfidence = multimodalConfidence
        self.decisionScore = decisionScore
        self.shouldAllow = shouldAllow
        self.decisionSignals = decisionSignals
        self.suppressionSignals = suppressionSignals
    }

    init(trainedPrediction: QuestionTrainedMultimodalPrediction, textualConfidence: Double) {
        self.textualConfidence = textualConfidence
        self.multimodalConfidence = trainedPrediction.responseScore
        self.decisionScore = trainedPrediction.responseScore
        self.shouldAllow = trainedPrediction.shouldAllow
        self.decisionSignals = trainedPrediction.decisionSignals
        self.suppressionSignals = trainedPrediction.suppressionSignals
    }
}

struct QuestionMultimodalScorer: Sendable {
    var policy: QuestionMultimodalPolicy = .fallback
    var decisionGatePolicy: QuestionDecisionGatePolicy = .fallback

    func score(
        understanding: LocalQuestionUnderstanding,
        signal: QuestionMultimodalSignal?,
        precisionMode: QAPrecisionMode,
        isPartial: Bool
    ) -> QuestionMultimodalDecision {
        let textual = min(max(understanding.confidence, policy.textualConfidenceFloor), policy.textualConfidenceCeiling)
        guard let signal else {
            return QuestionMultimodalDecision(
                textualConfidence: textual,
                multimodalConfidence: textual,
                decisionScore: textual,
                shouldAllow: true,
                decisionSignals: [policy.signalLabels.textOnly],
                suppressionSignals: []
            )
        }

        var multimodal = textual
        var decisionSignals: [String] = []
        var suppressionSignals: [String] = []

        if signal.isFinal {
            multimodal += policy.finalBonus
            decisionSignals.append(policy.signalLabels.final)
        } else if signal.partialStability >= policy.partialStableThreshold {
            multimodal += policy.partialStableBonus
            decisionSignals.append(policy.signalLabels.partialStable)
        } else if isPartial {
            multimodal -= policy.partialUnstablePenalty
            suppressionSignals.append(policy.signalLabels.partialUnstable)
        }

        if let asr = signal.asrConfidence {
            if asr >= policy.asrConfidentThreshold {
                multimodal += policy.asrConfidentBonus
                decisionSignals.append(policy.signalLabels.asrConfident)
            } else if asr < policy.lowASRConfidenceThreshold {
                multimodal -= policy.lowASRConfidencePenalty
                suppressionSignals.append(policy.signalLabels.lowASRConfidence)
            }
        }

        if signal.hasTerminalPause {
            multimodal += policy.terminalPauseBonus
            decisionSignals.append(policy.signalLabels.terminalPause)
        }

        if signal.duration >= policy.minPlausibleDuration && signal.duration <= policy.maxPlausibleDuration {
            multimodal += policy.durationPlausibleBonus
            decisionSignals.append(policy.signalLabels.durationPlausible)
        } else if signal.duration > 0 && signal.duration < policy.tooShortDuration {
            multimodal -= policy.tooShortPenalty
            suppressionSignals.append(policy.signalLabels.tooShortAudio)
        } else if signal.duration > policy.tooLongDuration {
            multimodal -= policy.tooLongPenalty
            suppressionSignals.append(policy.signalLabels.tooLongAudio)
        }

        let energy = signal.audioEnergy ?? signal.rms
        if let energy {
            if energy >= policy.minEnergy && energy <= policy.maxEnergy {
                multimodal += policy.energyPresentBonus
                decisionSignals.append(policy.signalLabels.energyPresent)
            } else if energy < policy.nearSilenceEnergy {
                multimodal -= policy.nearSilencePenalty
                suppressionSignals.append(policy.signalLabels.nearSilence)
            }
        }

        if signal.isSilence {
            multimodal -= policy.silencePenalty
            suppressionSignals.append(policy.signalLabels.silence)
        }
        if signal.isTooQuiet {
            multimodal -= policy.tooQuietPenalty
            suppressionSignals.append(policy.signalLabels.tooQuiet)
        }
        if signal.isClipping {
            multimodal -= policy.clippingPenalty
            suppressionSignals.append(policy.signalLabels.clipping)
        }
        if signal.gapCount >= policy.audioGapCountThreshold {
            multimodal -= policy.audioGapPenalty
            suppressionSignals.append(policy.signalLabels.audioGaps)
        }

        multimodal = min(max(multimodal, policy.textualConfidenceFloor), policy.textualConfidenceCeiling)
        let decisionScore = min(
            max(
                (textual * policy.textualDecisionWeight) + (multimodal * policy.multimodalDecisionWeight),
                policy.textualConfidenceFloor
            ),
            policy.textualConfidenceCeiling
        )
        let decisionThresholds = decisionGatePolicy.thresholds(for: precisionMode)
        let threshold = isPartial ? decisionThresholds.partialConfidenceThreshold : decisionThresholds.confidenceThreshold
        let hardSuppressionPolicy = policy.effectiveHardSuppressionSignals
        let hardSuppression = suppressionSignals.contains { hardSuppressionPolicy.contains($0) }
        let shouldAllow = !hardSuppression && decisionScore >= min(threshold, textual)

        return QuestionMultimodalDecision(
            textualConfidence: textual,
            multimodalConfidence: multimodal,
            decisionScore: decisionScore,
            shouldAllow: shouldAllow,
            decisionSignals: decisionSignals.isEmpty ? [policy.signalLabels.neutral] : decisionSignals,
            suppressionSignals: suppressionSignals
        )
    }
}

struct QuestionTypeRule: Codable, Hashable, Sendable {
    var type: QuestionType
    var markers: [String]
    var allSignals: Set<QuestionUnderstandingSignal>
    var anySignals: Set<QuestionUnderstandingSignal>

    init(
        type: QuestionType = .generalQuestion,
        markers: [String] = [],
        allSignals: Set<QuestionUnderstandingSignal> = [],
        anySignals: Set<QuestionUnderstandingSignal> = []
    ) {
        self.type = type
        self.markers = markers
        self.allSignals = allSignals
        self.anySignals = anySignals
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case markers
        case allSignals
        case anySignals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try container.decodeIfPresent(QuestionType.self, forKey: .type) ?? .generalQuestion,
            markers: try container.decodeIfPresent([String].self, forKey: .markers) ?? [],
            allSignals: try container.decodeIfPresent(Set<QuestionUnderstandingSignal>.self, forKey: .allSignals) ?? [],
            anySignals: try container.decodeIfPresent(Set<QuestionUnderstandingSignal>.self, forKey: .anySignals) ?? []
        )
    }
}

struct QuestionResponseJustificationRule: Codable, Hashable, Sendable {
    var id: String
    var questionTypes: Set<QuestionType>
    var anySignals: Set<QuestionUnderstandingSignal>
    var allSignalGroups: [[QuestionUnderstandingSignal]]
    var requiresActionable: Bool?
    var requiresDirectedToUser: Bool?
    var requiresDirectedToGroup: Bool?
    var requiresInformational: Bool?
    var requiresMultiQTRescue: Bool?

    init(
        id: String = "",
        questionTypes: Set<QuestionType> = [],
        anySignals: Set<QuestionUnderstandingSignal> = [],
        allSignalGroups: [[QuestionUnderstandingSignal]] = [],
        requiresActionable: Bool? = nil,
        requiresDirectedToUser: Bool? = nil,
        requiresDirectedToGroup: Bool? = nil,
        requiresInformational: Bool? = nil,
        requiresMultiQTRescue: Bool? = nil
    ) {
        self.id = id
        self.questionTypes = questionTypes
        self.anySignals = anySignals
        self.allSignalGroups = allSignalGroups
        self.requiresActionable = requiresActionable
        self.requiresDirectedToUser = requiresDirectedToUser
        self.requiresDirectedToGroup = requiresDirectedToGroup
        self.requiresInformational = requiresInformational
        self.requiresMultiQTRescue = requiresMultiQTRescue
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case questionTypes
        case anySignals
        case allSignalGroups
        case requiresActionable
        case requiresDirectedToUser
        case requiresDirectedToGroup
        case requiresInformational
        case requiresMultiQTRescue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            questionTypes: try container.decodeIfPresent(Set<QuestionType>.self, forKey: .questionTypes) ?? [],
            anySignals: try container.decodeIfPresent(Set<QuestionUnderstandingSignal>.self, forKey: .anySignals) ?? [],
            allSignalGroups: try container.decodeIfPresent([[QuestionUnderstandingSignal]].self, forKey: .allSignalGroups) ?? [],
            requiresActionable: try container.decodeIfPresent(Bool.self, forKey: .requiresActionable),
            requiresDirectedToUser: try container.decodeIfPresent(Bool.self, forKey: .requiresDirectedToUser),
            requiresDirectedToGroup: try container.decodeIfPresent(Bool.self, forKey: .requiresDirectedToGroup),
            requiresInformational: try container.decodeIfPresent(Bool.self, forKey: .requiresInformational),
            requiresMultiQTRescue: try container.decodeIfPresent(Bool.self, forKey: .requiresMultiQTRescue)
        )
    }
}

struct QuestionAttentionRule: Codable, Hashable, Sendable {
    var id: String
    var priorities: Set<QuestionPriority>
    var questionTypes: Set<QuestionType>
    var anySignals: Set<QuestionUnderstandingSignal>
    var allSignalGroups: [[QuestionUnderstandingSignal]]
    var requiresResponseNeeded: Bool?
    var requiresActionable: Bool?
    var requiresDirectedToUser: Bool?
    var requiresDirectedToGroup: Bool?
    var requiresInformational: Bool?

    init(
        id: String = "",
        priorities: Set<QuestionPriority> = [],
        questionTypes: Set<QuestionType> = [],
        anySignals: Set<QuestionUnderstandingSignal> = [],
        allSignalGroups: [[QuestionUnderstandingSignal]] = [],
        requiresResponseNeeded: Bool? = nil,
        requiresActionable: Bool? = nil,
        requiresDirectedToUser: Bool? = nil,
        requiresDirectedToGroup: Bool? = nil,
        requiresInformational: Bool? = nil
    ) {
        self.id = id
        self.priorities = priorities
        self.questionTypes = questionTypes
        self.anySignals = anySignals
        self.allSignalGroups = allSignalGroups
        self.requiresResponseNeeded = requiresResponseNeeded
        self.requiresActionable = requiresActionable
        self.requiresDirectedToUser = requiresDirectedToUser
        self.requiresDirectedToGroup = requiresDirectedToGroup
        self.requiresInformational = requiresInformational
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case priorities
        case questionTypes
        case anySignals
        case allSignalGroups
        case requiresResponseNeeded
        case requiresActionable
        case requiresDirectedToUser
        case requiresDirectedToGroup
        case requiresInformational
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            priorities: try container.decodeIfPresent(Set<QuestionPriority>.self, forKey: .priorities) ?? [],
            questionTypes: try container.decodeIfPresent(Set<QuestionType>.self, forKey: .questionTypes) ?? [],
            anySignals: try container.decodeIfPresent(Set<QuestionUnderstandingSignal>.self, forKey: .anySignals) ?? [],
            allSignalGroups: try container.decodeIfPresent([[QuestionUnderstandingSignal]].self, forKey: .allSignalGroups) ?? [],
            requiresResponseNeeded: try container.decodeIfPresent(Bool.self, forKey: .requiresResponseNeeded),
            requiresActionable: try container.decodeIfPresent(Bool.self, forKey: .requiresActionable),
            requiresDirectedToUser: try container.decodeIfPresent(Bool.self, forKey: .requiresDirectedToUser),
            requiresDirectedToGroup: try container.decodeIfPresent(Bool.self, forKey: .requiresDirectedToGroup),
            requiresInformational: try container.decodeIfPresent(Bool.self, forKey: .requiresInformational)
        )
    }
}

struct QuestionClassificationConfidencePolicy: Codable, Hashable, Sendable {
    var terminalPunctuationBaseScore: Double
    var semanticShapeBaseScore: Double
    var directedToUserBonus: Double
    var typedQuestionBonus: Double
    var typeBonusTypes: Set<QuestionType>
    var partialPenalty: Double
    var rhetoricalScore: Double
    var minimumScore: Double
    var maximumScore: Double
    var ignoredFilterConfidence: Double
    var rejectedGateConfidenceCeiling: Double

    static let fallback = QuestionClassificationConfidencePolicy(
        terminalPunctuationBaseScore: 0.72,
        semanticShapeBaseScore: 0.58,
        directedToUserBonus: 0.14,
        typedQuestionBonus: 0.08,
        typeBonusTypes: [],
        partialPenalty: 0.08,
        rhetoricalScore: 0.62,
        minimumScore: 0.05,
        maximumScore: 0.98,
        ignoredFilterConfidence: 0.28,
        rejectedGateConfidenceCeiling: 0.72
    )

    static let policyOwnedDefault = QuestionClassificationConfidencePolicy(
        terminalPunctuationBaseScore: fallback.terminalPunctuationBaseScore,
        semanticShapeBaseScore: fallback.semanticShapeBaseScore,
        directedToUserBonus: fallback.directedToUserBonus,
        typedQuestionBonus: fallback.typedQuestionBonus,
        typeBonusTypes: [],
        partialPenalty: fallback.partialPenalty,
        rhetoricalScore: fallback.rhetoricalScore,
        minimumScore: fallback.minimumScore,
        maximumScore: fallback.maximumScore,
        ignoredFilterConfidence: fallback.ignoredFilterConfidence,
        rejectedGateConfidenceCeiling: fallback.rejectedGateConfidenceCeiling
    )

    init(
        terminalPunctuationBaseScore: Double,
        semanticShapeBaseScore: Double,
        directedToUserBonus: Double,
        typedQuestionBonus: Double,
        typeBonusTypes: Set<QuestionType>,
        partialPenalty: Double,
        rhetoricalScore: Double,
        minimumScore: Double,
        maximumScore: Double,
        ignoredFilterConfidence: Double,
        rejectedGateConfidenceCeiling: Double
    ) {
        self.terminalPunctuationBaseScore = terminalPunctuationBaseScore
        self.semanticShapeBaseScore = semanticShapeBaseScore
        self.directedToUserBonus = directedToUserBonus
        self.typedQuestionBonus = typedQuestionBonus
        self.typeBonusTypes = typeBonusTypes
        self.partialPenalty = partialPenalty
        self.rhetoricalScore = rhetoricalScore
        self.minimumScore = minimumScore
        self.maximumScore = maximumScore
        self.ignoredFilterConfidence = ignoredFilterConfidence
        self.rejectedGateConfidenceCeiling = rejectedGateConfidenceCeiling
    }
}

struct QuestionAnswerStylePolicy: Codable, Hashable, Sendable {
    var defaultStyle: AnswerStyle
    var incompleteStyle: AnswerStyle
    var stylesByType: [String: AnswerStyle]

    static let fallback = QuestionAnswerStylePolicy(
        defaultStyle: .concise,
        incompleteStyle: .askForClarification,
        stylesByType: [:]
    )

    static let policyOwnedDefault = QuestionAnswerStylePolicy(
        defaultStyle: fallback.defaultStyle,
        incompleteStyle: fallback.incompleteStyle,
        stylesByType: [:]
    )

    init(
        defaultStyle: AnswerStyle,
        incompleteStyle: AnswerStyle,
        stylesByType: [String: AnswerStyle]
    ) {
        self.defaultStyle = defaultStyle
        self.incompleteStyle = incompleteStyle
        self.stylesByType = stylesByType
    }

    func style(for type: QuestionType, complete: Bool) -> AnswerStyle {
        guard complete else { return incompleteStyle }
        return stylesByType[type.rawValue] ?? defaultStyle
    }
}

struct QuestionTechnicalInferencePolicy: Codable, Hashable, Sendable {
    var appliesToAnyMeeting: Bool
    var appliesToMeetingTypes: Set<MeetingType>
    var decisionType: QuestionType
    var explanationType: QuestionType
    var usesCodeIdentifierCharacters: Bool
    var identifierPatterns: [String]

    static let fallback = QuestionTechnicalInferencePolicy(
        appliesToAnyMeeting: false,
        appliesToMeetingTypes: [],
        decisionType: .technicalDecision,
        explanationType: .technicalExplanation,
        usesCodeIdentifierCharacters: false,
        identifierPatterns: []
    )

    static let policyOwnedDefault = QuestionTechnicalInferencePolicy(
        appliesToAnyMeeting: false,
        appliesToMeetingTypes: [],
        decisionType: .technicalDecision,
        explanationType: .technicalExplanation,
        usesCodeIdentifierCharacters: false,
        identifierPatterns: []
    )

    init(
        appliesToAnyMeeting: Bool,
        appliesToMeetingTypes: Set<MeetingType>,
        decisionType: QuestionType,
        explanationType: QuestionType,
        usesCodeIdentifierCharacters: Bool = true,
        identifierPatterns: [String] = []
    ) {
        self.appliesToAnyMeeting = appliesToAnyMeeting
        self.appliesToMeetingTypes = appliesToMeetingTypes
        self.decisionType = decisionType
        self.explanationType = explanationType
        self.usesCodeIdentifierCharacters = usesCodeIdentifierCharacters
        self.identifierPatterns = identifierPatterns
    }

    private enum CodingKeys: String, CodingKey {
        case appliesToAnyMeeting
        case appliesToMeetingTypes
        case decisionType
        case explanationType
        case usesCodeIdentifierCharacters
        case identifierPatterns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appliesToAnyMeeting = try container.decodeIfPresent(Bool.self, forKey: .appliesToAnyMeeting) ?? Self.policyOwnedDefault.appliesToAnyMeeting
        appliesToMeetingTypes = try container.decodeIfPresent(Set<MeetingType>.self, forKey: .appliesToMeetingTypes) ?? Self.policyOwnedDefault.appliesToMeetingTypes
        decisionType = try container.decodeIfPresent(QuestionType.self, forKey: .decisionType) ?? Self.policyOwnedDefault.decisionType
        explanationType = try container.decodeIfPresent(QuestionType.self, forKey: .explanationType) ?? Self.policyOwnedDefault.explanationType
        usesCodeIdentifierCharacters = try container.decodeIfPresent(Bool.self, forKey: .usesCodeIdentifierCharacters) ?? Self.policyOwnedDefault.usesCodeIdentifierCharacters
        identifierPatterns = try container.decodeIfPresent([String].self, forKey: .identifierPatterns) ?? []
    }

    func applies(to meetingType: MeetingType) -> Bool {
        appliesToAnyMeeting || appliesToMeetingTypes.contains(meetingType)
    }
}

private enum QuestionClassificationRegexCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var values: [String: NSRegularExpression] = [:]

    static func regex(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        if let cached = values[pattern] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        lock.lock()
        values[pattern] = regex
        lock.unlock()
        return regex
    }
}

struct QuestionClassificationRulePack: Codable, Hashable, Sendable {
    var typeRules: [QuestionTypeRule]
    var selfSpeakerLabels: [String]
    var directedToUserMarkers: [String]
    var directedToGroupMarkers: [String]
    var intrinsicallyActionableTypes: Set<QuestionType>
    var responseJustifyingTypes: Set<QuestionType>
    var responseJustifyingSignals: Set<QuestionUnderstandingSignal>
    var responseJustifyingSignalGroups: [[QuestionUnderstandingSignal]]
    var responseJustificationRules: [QuestionResponseJustificationRule]
    var attentionRules: [QuestionAttentionRule]
    var actionableMarkers: [String]
    var informationalMarkers: [String]
    var technicalObjectMarkers: [String]
    var technicalDecisionFrameMarkers: [String]
    var technicalDecisionObjectMarkers: [String]
    var technicalExplanationFrameMarkers: [String]
    var multimodalPolicy: QuestionMultimodalPolicy
    var decisionGatePolicy: QuestionDecisionGatePolicy?
    var confidencePolicy: QuestionClassificationConfidencePolicy
    var answerStylePolicy: QuestionAnswerStylePolicy
    var technicalInferencePolicy: QuestionTechnicalInferencePolicy
    var reasons: QuestionClassificationReasonPolicy

    static let `default` = QuestionClassificationRulePackStore.current

    init(
        typeRules: [QuestionTypeRule],
        selfSpeakerLabels: [String],
        directedToUserMarkers: [String],
        directedToGroupMarkers: [String],
        intrinsicallyActionableTypes: Set<QuestionType> = [],
        responseJustifyingTypes: Set<QuestionType> = [],
        responseJustifyingSignals: Set<QuestionUnderstandingSignal> = [],
        responseJustifyingSignalGroups: [[QuestionUnderstandingSignal]] = [],
        responseJustificationRules: [QuestionResponseJustificationRule] = [],
        attentionRules: [QuestionAttentionRule] = [],
        actionableMarkers: [String],
        informationalMarkers: [String],
        technicalObjectMarkers: [String],
        technicalDecisionFrameMarkers: [String],
        technicalDecisionObjectMarkers: [String],
        technicalExplanationFrameMarkers: [String],
        multimodalPolicy: QuestionMultimodalPolicy,
        decisionGatePolicy: QuestionDecisionGatePolicy?,
        confidencePolicy: QuestionClassificationConfidencePolicy = .fallback,
        answerStylePolicy: QuestionAnswerStylePolicy = .fallback,
        technicalInferencePolicy: QuestionTechnicalInferencePolicy = .fallback,
        reasons: QuestionClassificationReasonPolicy
    ) {
        self.typeRules = typeRules
        self.selfSpeakerLabels = selfSpeakerLabels
        self.directedToUserMarkers = directedToUserMarkers
        self.directedToGroupMarkers = directedToGroupMarkers
        self.intrinsicallyActionableTypes = intrinsicallyActionableTypes
        self.responseJustifyingTypes = responseJustifyingTypes
        self.responseJustifyingSignals = responseJustifyingSignals
        self.responseJustifyingSignalGroups = responseJustifyingSignalGroups
        self.responseJustificationRules = responseJustificationRules
        self.attentionRules = attentionRules
        self.actionableMarkers = actionableMarkers
        self.informationalMarkers = informationalMarkers
        self.technicalObjectMarkers = technicalObjectMarkers
        self.technicalDecisionFrameMarkers = technicalDecisionFrameMarkers
        self.technicalDecisionObjectMarkers = technicalDecisionObjectMarkers
        self.technicalExplanationFrameMarkers = technicalExplanationFrameMarkers
        self.multimodalPolicy = multimodalPolicy
        self.decisionGatePolicy = decisionGatePolicy
        self.confidencePolicy = confidencePolicy
        self.answerStylePolicy = answerStylePolicy
        self.technicalInferencePolicy = technicalInferencePolicy
        self.reasons = reasons
    }

    enum CodingKeys: String, CodingKey {
        case typeRules
        case selfSpeakerLabels
        case directedToUserMarkers
        case directedToGroupMarkers
        case intrinsicallyActionableTypes
        case responseJustifyingTypes
        case responseJustifyingSignals
        case responseJustifyingSignalGroups
        case responseJustificationRules
        case attentionRules
        case actionableMarkers
        case informationalMarkers
        case technicalObjectMarkers
        case technicalDecisionFrameMarkers
        case technicalDecisionObjectMarkers
        case technicalExplanationFrameMarkers
        case multimodalPolicy
        case decisionGatePolicy
        case confidencePolicy
        case answerStylePolicy
        case technicalInferencePolicy
        case reasons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        typeRules = try container.decodeIfPresent([QuestionTypeRule].self, forKey: .typeRules) ?? []
        selfSpeakerLabels = try container.decodeIfPresent([String].self, forKey: .selfSpeakerLabels) ?? []
        directedToUserMarkers = try container.decodeIfPresent([String].self, forKey: .directedToUserMarkers) ?? []
        directedToGroupMarkers = try container.decodeIfPresent([String].self, forKey: .directedToGroupMarkers) ?? []
        intrinsicallyActionableTypes = try container.decodeIfPresent(Set<QuestionType>.self, forKey: .intrinsicallyActionableTypes) ?? []
        responseJustifyingTypes = try container.decodeIfPresent(Set<QuestionType>.self, forKey: .responseJustifyingTypes) ?? []
        responseJustifyingSignals = try container.decodeIfPresent(Set<QuestionUnderstandingSignal>.self, forKey: .responseJustifyingSignals) ?? []
        responseJustifyingSignalGroups = try container.decodeIfPresent([[QuestionUnderstandingSignal]].self, forKey: .responseJustifyingSignalGroups) ?? []
        responseJustificationRules = try container.decodeIfPresent([QuestionResponseJustificationRule].self, forKey: .responseJustificationRules) ?? []
        attentionRules = try container.decodeIfPresent([QuestionAttentionRule].self, forKey: .attentionRules) ?? []
        actionableMarkers = try container.decodeIfPresent([String].self, forKey: .actionableMarkers) ?? []
        informationalMarkers = try container.decodeIfPresent([String].self, forKey: .informationalMarkers) ?? []
        technicalObjectMarkers = try container.decodeIfPresent([String].self, forKey: .technicalObjectMarkers) ?? []
        technicalDecisionFrameMarkers = try container.decodeIfPresent([String].self, forKey: .technicalDecisionFrameMarkers) ?? []
        technicalDecisionObjectMarkers = try container.decodeIfPresent([String].self, forKey: .technicalDecisionObjectMarkers) ?? []
        technicalExplanationFrameMarkers = try container.decodeIfPresent([String].self, forKey: .technicalExplanationFrameMarkers) ?? []
        multimodalPolicy = try container.decodeIfPresent(QuestionMultimodalPolicy.self, forKey: .multimodalPolicy) ?? .policyOwnedDefault
        decisionGatePolicy = try container.decodeIfPresent(QuestionDecisionGatePolicy.self, forKey: .decisionGatePolicy)
        confidencePolicy = try container.decodeIfPresent(QuestionClassificationConfidencePolicy.self, forKey: .confidencePolicy) ?? .policyOwnedDefault
        answerStylePolicy = try container.decodeIfPresent(QuestionAnswerStylePolicy.self, forKey: .answerStylePolicy) ?? .policyOwnedDefault
        technicalInferencePolicy = try container.decodeIfPresent(QuestionTechnicalInferencePolicy.self, forKey: .technicalInferencePolicy) ?? .policyOwnedDefault
        reasons = try container.decodeIfPresent(QuestionClassificationReasonPolicy.self, forKey: .reasons) ?? .fallback
    }
}

enum QuestionClassificationRulePackStore {
    static let current: QuestionClassificationRulePack = load()

    private static func load() -> QuestionClassificationRulePack {
        let decoder = JSONDecoder()
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let policy = try? decoder.decode(QuestionClassificationRulePack.self, from: data) else {
                continue
            }
            return policy.normalized()
        }
        return fallbackRulePack()
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let bundles = [Bundle.main, Bundle(for: QuestionClassificationRulePackBundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "question-classification-rulepack",
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
                .appendingPathComponent("Resources/CopilotIntentPolicy/question-classification-rulepack.json")
        )
        return urls
    }

    private static func fallbackRulePack() -> QuestionClassificationRulePack {
        QuestionClassificationRulePack(
            typeRules: [],
            selfSpeakerLabels: [],
            directedToUserMarkers: [],
            directedToGroupMarkers: [],
            intrinsicallyActionableTypes: [],
            responseJustifyingTypes: [],
            responseJustifyingSignals: [],
            responseJustifyingSignalGroups: [],
            responseJustificationRules: [],
            attentionRules: [],
            actionableMarkers: [],
            informationalMarkers: [],
            technicalObjectMarkers: [],
            technicalDecisionFrameMarkers: [],
            technicalDecisionObjectMarkers: [],
            technicalExplanationFrameMarkers: [],
            multimodalPolicy: .fallback,
            decisionGatePolicy: .fallback,
            confidencePolicy: .fallback,
            answerStylePolicy: .fallback,
            technicalInferencePolicy: .policyOwnedDefault,
            reasons: .fallback
        )
    }
}

private final class QuestionClassificationRulePackBundleMarker {}

private struct QuestionClassificationPolicyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private extension KeyedDecodingContainer where Key == QuestionClassificationPolicyCodingKey {
    func decodePolicyValue<T: Decodable>(
        _ type: T.Type,
        _ key: String,
        default defaultValue: @autoclosure () -> T
    ) throws -> T {
        try decodeIfPresent(type, key) ?? defaultValue()
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        guard let codingKey = QuestionClassificationPolicyCodingKey(stringValue: key) else { return nil }
        return try decodeIfPresent(type, forKey: codingKey)
    }
}

extension QuestionMultimodalSignalLabels {
    init(from decoder: Decoder) throws {
        let fallback = QuestionMultimodalSignalLabels.fallback
        let container = try decoder.container(keyedBy: QuestionClassificationPolicyCodingKey.self)
        self.init(
            textOnly: try container.decodePolicyValue(String.self, "textOnly", default: fallback.textOnly),
            final: try container.decodePolicyValue(String.self, "final", default: fallback.final),
            partialStable: try container.decodePolicyValue(String.self, "partialStable", default: fallback.partialStable),
            partialUnstable: try container.decodePolicyValue(String.self, "partialUnstable", default: fallback.partialUnstable),
            asrConfident: try container.decodePolicyValue(String.self, "asrConfident", default: fallback.asrConfident),
            lowASRConfidence: try container.decodePolicyValue(String.self, "lowASRConfidence", default: fallback.lowASRConfidence),
            terminalPause: try container.decodePolicyValue(String.self, "terminalPause", default: fallback.terminalPause),
            durationPlausible: try container.decodePolicyValue(String.self, "durationPlausible", default: fallback.durationPlausible),
            tooShortAudio: try container.decodePolicyValue(String.self, "tooShortAudio", default: fallback.tooShortAudio),
            tooLongAudio: try container.decodePolicyValue(String.self, "tooLongAudio", default: fallback.tooLongAudio),
            energyPresent: try container.decodePolicyValue(String.self, "energyPresent", default: fallback.energyPresent),
            nearSilence: try container.decodePolicyValue(String.self, "nearSilence", default: fallback.nearSilence),
            silence: try container.decodePolicyValue(String.self, "silence", default: fallback.silence),
            tooQuiet: try container.decodePolicyValue(String.self, "tooQuiet", default: fallback.tooQuiet),
            clipping: try container.decodePolicyValue(String.self, "clipping", default: fallback.clipping),
            audioGaps: try container.decodePolicyValue(String.self, "audioGaps", default: fallback.audioGaps),
            neutral: try container.decodePolicyValue(String.self, "neutral", default: fallback.neutral)
        )
    }
}

extension QuestionMultimodalPolicy {
    init(from decoder: Decoder) throws {
        let fallback = QuestionMultimodalPolicy.policyOwnedDefault
        let container = try decoder.container(keyedBy: QuestionClassificationPolicyCodingKey.self)
        self.init(
            textualConfidenceFloor: try container.decodePolicyValue(Double.self, "textualConfidenceFloor", default: fallback.textualConfidenceFloor),
            textualConfidenceCeiling: try container.decodePolicyValue(Double.self, "textualConfidenceCeiling", default: fallback.textualConfidenceCeiling),
            finalBonus: try container.decodePolicyValue(Double.self, "finalBonus", default: fallback.finalBonus),
            partialStableThreshold: try container.decodePolicyValue(Double.self, "partialStableThreshold", default: fallback.partialStableThreshold),
            partialStableBonus: try container.decodePolicyValue(Double.self, "partialStableBonus", default: fallback.partialStableBonus),
            partialUnstablePenalty: try container.decodePolicyValue(Double.self, "partialUnstablePenalty", default: fallback.partialUnstablePenalty),
            asrConfidentThreshold: try container.decodePolicyValue(Double.self, "asrConfidentThreshold", default: fallback.asrConfidentThreshold),
            asrConfidentBonus: try container.decodePolicyValue(Double.self, "asrConfidentBonus", default: fallback.asrConfidentBonus),
            lowASRConfidenceThreshold: try container.decodePolicyValue(Double.self, "lowASRConfidenceThreshold", default: fallback.lowASRConfidenceThreshold),
            lowASRConfidencePenalty: try container.decodePolicyValue(Double.self, "lowASRConfidencePenalty", default: fallback.lowASRConfidencePenalty),
            terminalPauseBonus: try container.decodePolicyValue(Double.self, "terminalPauseBonus", default: fallback.terminalPauseBonus),
            minPlausibleDuration: try container.decodePolicyValue(Double.self, "minPlausibleDuration", default: fallback.minPlausibleDuration),
            maxPlausibleDuration: try container.decodePolicyValue(Double.self, "maxPlausibleDuration", default: fallback.maxPlausibleDuration),
            durationPlausibleBonus: try container.decodePolicyValue(Double.self, "durationPlausibleBonus", default: fallback.durationPlausibleBonus),
            tooShortDuration: try container.decodePolicyValue(Double.self, "tooShortDuration", default: fallback.tooShortDuration),
            tooShortPenalty: try container.decodePolicyValue(Double.self, "tooShortPenalty", default: fallback.tooShortPenalty),
            tooLongDuration: try container.decodePolicyValue(Double.self, "tooLongDuration", default: fallback.tooLongDuration),
            tooLongPenalty: try container.decodePolicyValue(Double.self, "tooLongPenalty", default: fallback.tooLongPenalty),
            minEnergy: try container.decodePolicyValue(Double.self, "minEnergy", default: fallback.minEnergy),
            maxEnergy: try container.decodePolicyValue(Double.self, "maxEnergy", default: fallback.maxEnergy),
            energyPresentBonus: try container.decodePolicyValue(Double.self, "energyPresentBonus", default: fallback.energyPresentBonus),
            nearSilenceEnergy: try container.decodePolicyValue(Double.self, "nearSilenceEnergy", default: fallback.nearSilenceEnergy),
            nearSilencePenalty: try container.decodePolicyValue(Double.self, "nearSilencePenalty", default: fallback.nearSilencePenalty),
            silencePenalty: try container.decodePolicyValue(Double.self, "silencePenalty", default: fallback.silencePenalty),
            tooQuietPenalty: try container.decodePolicyValue(Double.self, "tooQuietPenalty", default: fallback.tooQuietPenalty),
            clippingPenalty: try container.decodePolicyValue(Double.self, "clippingPenalty", default: fallback.clippingPenalty),
            audioGapCountThreshold: try container.decodePolicyValue(Int.self, "audioGapCountThreshold", default: fallback.audioGapCountThreshold),
            audioGapPenalty: try container.decodePolicyValue(Double.self, "audioGapPenalty", default: fallback.audioGapPenalty),
            textualDecisionWeight: try container.decodePolicyValue(Double.self, "textualDecisionWeight", default: fallback.textualDecisionWeight),
            multimodalDecisionWeight: try container.decodePolicyValue(Double.self, "multimodalDecisionWeight", default: fallback.multimodalDecisionWeight),
            hardSuppressionSignals: try container.decodePolicyValue(Set<String>.self, "hardSuppressionSignals", default: []),
            hardSuppressionSignalKeys: try container.decodePolicyValue(Set<QuestionMultimodalSignalKey>.self, "hardSuppressionSignalKeys", default: []),
            signalLabels: try container.decodePolicyValue(QuestionMultimodalSignalLabels.self, "signalLabels", default: fallback.signalLabels)
        )
    }
}

extension QuestionDecisionGateModePolicy {
    init(from decoder: Decoder) throws {
        let fallback = QuestionDecisionGateModePolicy.highPrecision
        let container = try decoder.container(keyedBy: QuestionClassificationPolicyCodingKey.self)
        self.init(
            confidenceThreshold: try container.decodePolicyValue(Double.self, "confidenceThreshold", default: fallback.confidenceThreshold),
            partialConfidenceThreshold: try container.decodePolicyValue(Double.self, "partialConfidenceThreshold", default: fallback.partialConfidenceThreshold),
            requiredStrongSignalCount: try container.decodePolicyValue(Int.self, "requiredStrongSignalCount", default: fallback.requiredStrongSignalCount)
        )
    }
}

extension QuestionDecisionGatePolicy {
    init(from decoder: Decoder) throws {
        let fallback = QuestionDecisionGatePolicy.policyOwnedDefault
        let container = try decoder.container(keyedBy: QuestionClassificationPolicyCodingKey.self)
        self.init(
            modeThresholds: try container.decodePolicyValue([String: QuestionDecisionGateModePolicy].self, "modeThresholds", default: [:]),
            ignoredSignals: try container.decodePolicyValue(Set<QuestionUnderstandingSignal>.self, "ignoredSignals", default: []),
            partialStrictSignals: try container.decodePolicyValue(Set<QuestionUnderstandingSignal>.self, "partialStrictSignals", default: []),
            partialCompleteShapeSignals: try container.decodePolicyValue(Set<QuestionUnderstandingSignal>.self, "partialCompleteShapeSignals", default: []),
            partialCompleteShapeConfidenceDelta: try container.decodePolicyValue(
                Double.self,
                "partialCompleteShapeConfidenceDelta",
                default: fallback.partialCompleteShapeConfidenceDelta
            ),
            partialCompleteShapeMinimumConfidence: try container.decodePolicyValue(
                Double.self,
                "partialCompleteShapeMinimumConfidence",
                default: fallback.partialCompleteShapeMinimumConfidence
            )
        )
    }
}

extension QuestionClassificationConfidencePolicy {
    init(from decoder: Decoder) throws {
        let fallback = QuestionClassificationConfidencePolicy.policyOwnedDefault
        let container = try decoder.container(keyedBy: QuestionClassificationPolicyCodingKey.self)
        self.init(
            terminalPunctuationBaseScore: try container.decodePolicyValue(Double.self, "terminalPunctuationBaseScore", default: fallback.terminalPunctuationBaseScore),
            semanticShapeBaseScore: try container.decodePolicyValue(Double.self, "semanticShapeBaseScore", default: fallback.semanticShapeBaseScore),
            directedToUserBonus: try container.decodePolicyValue(Double.self, "directedToUserBonus", default: fallback.directedToUserBonus),
            typedQuestionBonus: try container.decodePolicyValue(Double.self, "typedQuestionBonus", default: fallback.typedQuestionBonus),
            typeBonusTypes: try container.decodePolicyValue(Set<QuestionType>.self, "typeBonusTypes", default: []),
            partialPenalty: try container.decodePolicyValue(Double.self, "partialPenalty", default: fallback.partialPenalty),
            rhetoricalScore: try container.decodePolicyValue(Double.self, "rhetoricalScore", default: fallback.rhetoricalScore),
            minimumScore: try container.decodePolicyValue(Double.self, "minimumScore", default: fallback.minimumScore),
            maximumScore: try container.decodePolicyValue(Double.self, "maximumScore", default: fallback.maximumScore),
            ignoredFilterConfidence: try container.decodePolicyValue(
                Double.self,
                "ignoredFilterConfidence",
                default: fallback.ignoredFilterConfidence
            ),
            rejectedGateConfidenceCeiling: try container.decodePolicyValue(
                Double.self,
                "rejectedGateConfidenceCeiling",
                default: fallback.rejectedGateConfidenceCeiling
            )
        )
    }
}

extension QuestionAnswerStylePolicy {
    init(from decoder: Decoder) throws {
        let fallback = QuestionAnswerStylePolicy.policyOwnedDefault
        let container = try decoder.container(keyedBy: QuestionClassificationPolicyCodingKey.self)
        self.init(
            defaultStyle: try container.decodePolicyValue(AnswerStyle.self, "defaultStyle", default: fallback.defaultStyle),
            incompleteStyle: try container.decodePolicyValue(AnswerStyle.self, "incompleteStyle", default: fallback.incompleteStyle),
            stylesByType: try container.decodePolicyValue([String: AnswerStyle].self, "stylesByType", default: [:])
        )
    }
}

extension QuestionClassificationReasonPolicy {
    init(from decoder: Decoder) throws {
        let fallback = QuestionClassificationReasonPolicy.fallback
        let container = try decoder.container(keyedBy: QuestionClassificationPolicyCodingKey.self)
        self.init(
            multimodalRejectedTemplate: try container.decodePolicyValue(String.self, "multimodalRejectedTemplate", default: fallback.multimodalRejectedTemplate),
            localGateRejectedTemplate: try container.decodePolicyValue(String.self, "localGateRejectedTemplate", default: fallback.localGateRejectedTemplate),
            multiQTRescued: try container.decodePolicyValue(String.self, "multiQTRescued", default: fallback.multiQTRescued),
            multiQTModelAccepted: try container.decodePolicyValue(String.self, "multiQTModelAccepted", default: fallback.multiQTModelAccepted)
        )
    }
}

private extension QuestionClassificationRulePack {
    func normalized() -> QuestionClassificationRulePack {
        QuestionClassificationRulePack(
            typeRules: typeRules.map { rule in
                QuestionTypeRule(
                    type: rule.type,
                    markers: rule.markers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
                    allSignals: rule.allSignals,
                    anySignals: rule.anySignals
                )
            }.filter {
                !$0.markers.isEmpty || !$0.allSignals.isEmpty || !$0.anySignals.isEmpty
            },
            selfSpeakerLabels: selfSpeakerLabels.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            directedToUserMarkers: directedToUserMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            directedToGroupMarkers: directedToGroupMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            intrinsicallyActionableTypes: intrinsicallyActionableTypes,
            responseJustifyingTypes: responseJustifyingTypes,
            responseJustifyingSignals: responseJustifyingSignals,
            responseJustifyingSignalGroups: responseJustifyingSignalGroups.compactMap { group in
                let normalizedGroup = group.reduce(into: [QuestionUnderstandingSignal]()) { result, signal in
                    guard !result.contains(signal) else { return }
                    result.append(signal)
                }
                return normalizedGroup.isEmpty ? nil : normalizedGroup
            },
            responseJustificationRules: responseJustificationRules.compactMap(\.normalizedQuestionClassificationRule),
            attentionRules: attentionRules.compactMap(\.normalizedQuestionAttentionRule),
            actionableMarkers: actionableMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            informationalMarkers: informationalMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            technicalObjectMarkers: technicalObjectMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            technicalDecisionFrameMarkers: technicalDecisionFrameMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            technicalDecisionObjectMarkers: technicalDecisionObjectMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            technicalExplanationFrameMarkers: technicalExplanationFrameMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            multimodalPolicy: multimodalPolicy.normalized(),
            decisionGatePolicy: decisionGatePolicy?.normalized(),
            confidencePolicy: confidencePolicy.normalized(),
            answerStylePolicy: answerStylePolicy.normalized(),
            technicalInferencePolicy: technicalInferencePolicy.normalized(),
            reasons: reasons.normalized()
        )
    }
}

private extension QuestionResponseJustificationRule {
    var normalizedQuestionClassificationRule: QuestionResponseJustificationRule? {
        let normalizedGroups = allSignalGroups.compactMap { group -> [QuestionUnderstandingSignal]? in
            let normalizedGroup = group.reduce(into: [QuestionUnderstandingSignal]()) { result, signal in
                guard !result.contains(signal) else { return }
                result.append(signal)
            }
            return normalizedGroup.isEmpty ? nil : normalizedGroup
        }
        let rule = QuestionResponseJustificationRule(
            id: id.trimmingCharacters(in: .whitespacesAndNewlines),
            questionTypes: questionTypes,
            anySignals: anySignals,
            allSignalGroups: normalizedGroups,
            requiresActionable: requiresActionable,
            requiresDirectedToUser: requiresDirectedToUser,
            requiresDirectedToGroup: requiresDirectedToGroup,
            requiresInformational: requiresInformational,
            requiresMultiQTRescue: requiresMultiQTRescue
        )
        let hasCondition = !rule.questionTypes.isEmpty
            || !rule.anySignals.isEmpty
            || !rule.allSignalGroups.isEmpty
            || rule.requiresActionable != nil
            || rule.requiresDirectedToUser != nil
            || rule.requiresDirectedToGroup != nil
            || rule.requiresInformational != nil
            || rule.requiresMultiQTRescue != nil
        return hasCondition ? rule : nil
    }
}

private extension QuestionAttentionRule {
    var normalizedQuestionAttentionRule: QuestionAttentionRule? {
        let normalizedGroups = allSignalGroups.compactMap { group -> [QuestionUnderstandingSignal]? in
            let normalizedGroup = group.reduce(into: [QuestionUnderstandingSignal]()) { result, signal in
                guard !result.contains(signal) else { return }
                result.append(signal)
            }
            return normalizedGroup.isEmpty ? nil : normalizedGroup
        }
        let rule = QuestionAttentionRule(
            id: id.trimmingCharacters(in: .whitespacesAndNewlines),
            priorities: priorities,
            questionTypes: questionTypes,
            anySignals: anySignals,
            allSignalGroups: normalizedGroups,
            requiresResponseNeeded: requiresResponseNeeded,
            requiresActionable: requiresActionable,
            requiresDirectedToUser: requiresDirectedToUser,
            requiresDirectedToGroup: requiresDirectedToGroup,
            requiresInformational: requiresInformational
        )
        let hasCondition = !rule.priorities.isEmpty
            || !rule.questionTypes.isEmpty
            || !rule.anySignals.isEmpty
            || !rule.allSignalGroups.isEmpty
            || rule.requiresResponseNeeded != nil
            || rule.requiresActionable != nil
            || rule.requiresDirectedToUser != nil
            || rule.requiresDirectedToGroup != nil
            || rule.requiresInformational != nil
        return hasCondition ? rule : nil
    }
}

private extension QuestionAnswerStylePolicy {
    func normalized() -> QuestionAnswerStylePolicy {
        let normalizedStyles = stylesByType.reduce(into: [String: AnswerStyle]()) { result, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard QuestionType(rawValue: key) != nil else { return }
            result[key] = entry.value
        }
        return QuestionAnswerStylePolicy(
            defaultStyle: defaultStyle,
            incompleteStyle: incompleteStyle,
            stylesByType: normalizedStyles
        )
    }
}

private extension QuestionTechnicalInferencePolicy {
    func normalized() -> QuestionTechnicalInferencePolicy {
        QuestionTechnicalInferencePolicy(
            appliesToAnyMeeting: appliesToAnyMeeting,
            appliesToMeetingTypes: appliesToMeetingTypes,
            decisionType: decisionType,
            explanationType: explanationType,
            usesCodeIdentifierCharacters: usesCodeIdentifierCharacters,
            identifierPatterns: identifierPatterns.map(\.trimmedQuestionClassificationPolicy).filter { !$0.isEmpty }
        )
    }
}

private extension QuestionClassificationConfidencePolicy {
    func normalized() -> QuestionClassificationConfidencePolicy {
        let minimum = min(max(minimumScore, 0), 1)
        let maximum = max(minimum, min(max(maximumScore, 0), 1))
        return QuestionClassificationConfidencePolicy(
            terminalPunctuationBaseScore: min(max(terminalPunctuationBaseScore, 0), 1),
            semanticShapeBaseScore: min(max(semanticShapeBaseScore, 0), 1),
            directedToUserBonus: max(0, directedToUserBonus),
            typedQuestionBonus: max(0, typedQuestionBonus),
            typeBonusTypes: typeBonusTypes,
            partialPenalty: max(0, partialPenalty),
            rhetoricalScore: min(max(rhetoricalScore, 0), 1),
            minimumScore: minimum,
            maximumScore: maximum,
            ignoredFilterConfidence: min(max(ignoredFilterConfidence, minimum), maximum),
            rejectedGateConfidenceCeiling: min(max(rejectedGateConfidenceCeiling, minimum), maximum)
        )
    }
}

private extension QuestionDecisionGateModePolicy {
    func normalized() -> QuestionDecisionGateModePolicy {
        QuestionDecisionGateModePolicy(
            confidenceThreshold: min(max(confidenceThreshold, 0), 1),
            partialConfidenceThreshold: min(max(partialConfidenceThreshold, 0), 1),
            requiredStrongSignalCount: max(0, requiredStrongSignalCount)
        )
    }
}

private extension QuestionDecisionGatePolicy {
    func normalized() -> QuestionDecisionGatePolicy {
        var normalized = self
        normalized.modeThresholds = modeThresholds.reduce(into: [:]) { result, entry in
            let mode = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mode.isEmpty else { return }
            result[mode] = entry.value.normalized()
        }
        normalized.ignoredSignals = ignoredSignals
        normalized.partialStrictSignals = partialStrictSignals
        normalized.partialCompleteShapeSignals = partialCompleteShapeSignals
        normalized.partialCompleteShapeConfidenceDelta = max(0, partialCompleteShapeConfidenceDelta)
        normalized.partialCompleteShapeMinimumConfidence = min(max(partialCompleteShapeMinimumConfidence, 0), 1)
        return normalized
    }
}

private extension QuestionMultimodalSignalLabels {
    func normalized() -> QuestionMultimodalSignalLabels {
        QuestionMultimodalSignalLabels(
            textOnly: textOnly.trimmedQuestionClassificationPolicy,
            final: final.trimmedQuestionClassificationPolicy,
            partialStable: partialStable.trimmedQuestionClassificationPolicy,
            partialUnstable: partialUnstable.trimmedQuestionClassificationPolicy,
            asrConfident: asrConfident.trimmedQuestionClassificationPolicy,
            lowASRConfidence: lowASRConfidence.trimmedQuestionClassificationPolicy,
            terminalPause: terminalPause.trimmedQuestionClassificationPolicy,
            durationPlausible: durationPlausible.trimmedQuestionClassificationPolicy,
            tooShortAudio: tooShortAudio.trimmedQuestionClassificationPolicy,
            tooLongAudio: tooLongAudio.trimmedQuestionClassificationPolicy,
            energyPresent: energyPresent.trimmedQuestionClassificationPolicy,
            nearSilence: nearSilence.trimmedQuestionClassificationPolicy,
            silence: silence.trimmedQuestionClassificationPolicy,
            tooQuiet: tooQuiet.trimmedQuestionClassificationPolicy,
            clipping: clipping.trimmedQuestionClassificationPolicy,
            audioGaps: audioGaps.trimmedQuestionClassificationPolicy,
            neutral: neutral.trimmedQuestionClassificationPolicy
        )
    }
}

private extension QuestionMultimodalPolicy {
    func normalized() -> QuestionMultimodalPolicy {
        var normalized = self
        normalized.textualConfidenceFloor = min(max(textualConfidenceFloor, 0.01), 0.95)
        normalized.textualConfidenceCeiling = min(max(textualConfidenceCeiling, normalized.textualConfidenceFloor), 0.99)
        normalized.partialStableThreshold = min(max(partialStableThreshold, 0), 1)
        normalized.asrConfidentThreshold = min(max(asrConfidentThreshold, 0), 1)
        normalized.lowASRConfidenceThreshold = min(max(lowASRConfidenceThreshold, 0), 1)
        normalized.minPlausibleDuration = max(0, minPlausibleDuration)
        normalized.maxPlausibleDuration = max(normalized.minPlausibleDuration, maxPlausibleDuration)
        normalized.tooShortDuration = max(0, tooShortDuration)
        normalized.tooLongDuration = max(normalized.maxPlausibleDuration, tooLongDuration)
        normalized.minEnergy = max(0, minEnergy)
        normalized.maxEnergy = max(normalized.minEnergy, maxEnergy)
        normalized.nearSilenceEnergy = max(0, nearSilenceEnergy)
        normalized.audioGapCountThreshold = max(1, audioGapCountThreshold)
        let totalWeight = textualDecisionWeight + multimodalDecisionWeight
        if totalWeight > 0 {
            normalized.textualDecisionWeight = textualDecisionWeight / totalWeight
            normalized.multimodalDecisionWeight = multimodalDecisionWeight / totalWeight
        } else {
            normalized.textualDecisionWeight = QuestionMultimodalPolicy.fallback.textualDecisionWeight
            normalized.multimodalDecisionWeight = QuestionMultimodalPolicy.fallback.multimodalDecisionWeight
        }
        normalized.signalLabels = signalLabels.normalized()
        normalized.hardSuppressionSignals = Set(hardSuppressionSignals.map(\.trimmedQuestionClassificationPolicy).filter { !$0.isEmpty })
        return normalized
    }
}

private extension QuestionClassificationReasonPolicy {
    func normalized() -> QuestionClassificationReasonPolicy {
        QuestionClassificationReasonPolicy(
            multimodalRejectedTemplate: multimodalRejectedTemplate.trimmedQuestionClassificationPolicy,
            localGateRejectedTemplate: localGateRejectedTemplate.trimmedQuestionClassificationPolicy,
            multiQTRescued: multiQTRescued.trimmedQuestionClassificationPolicy,
            multiQTModelAccepted: multiQTModelAccepted.trimmedQuestionClassificationPolicy
        )
    }
}

private extension String {
    var trimmedQuestionClassificationPolicy: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LocalQuestionUnderstandingProvider {
    var rulePack: QuestionIntentRulePack = .default
    var adaptiveProfile: QuestionAnsweringAdaptiveProfile = QuestionAnsweringAdaptiveProfile()
    var precisionMode: QAPrecisionMode = .highPrecision
    var analyzer: QuestionSurfaceAnalyzer {
        QuestionSurfaceAnalyzer(rulePack: rulePack, adaptiveProfile: adaptiveProfile)
    }

    func understand(
        candidate: QuestionCandidate,
        context: TranscriptContext,
        userProfile: UserMeetingProfile
    ) -> LocalQuestionUnderstanding {
        if let cached = cachedSurfaceUnderstanding(for: candidate) {
            return cached
        }

        let analysis = analyzer.analyze(
            text: candidate.rawText,
            normalized: candidate.normalizedText,
            context: context,
            profile: userProfile,
            isPartial: candidate.isPartial,
            isFinal: !candidate.isPartial
        )

        let confidence = analyzer.confidence(for: analysis, isPartial: candidate.isPartial, precisionMode: precisionMode)
        let negativeIntent = intent(fromNegativeSignals: analysis.negativeSignals)
        if let negativeIntent {
            return LocalQuestionUnderstanding(
                intent: negativeIntent,
                confidence: confidence,
                strongSignals: analysis.strongSignals,
                negativeSignals: analysis.negativeSignals,
                reason: reason(for: negativeIntent, signals: analysis.negativeSignals),
                extractedQuestion: candidate.rawText
            )
        }

        guard analyzer.isCandidateSurface(analysis, precisionMode: precisionMode) else {
            return LocalQuestionUnderstanding(
                intent: analysis.strongSignals.isEmpty ? .statement : .ambiguous,
                confidence: min(confidence, rulePack.surfaceScoringPolicy.insufficientSurfaceConfidenceCeiling),
                strongSignals: analysis.strongSignals,
                negativeSignals: analysis.negativeSignals,
                reason: rulePack.reasons.highPrecisionInsufficient,
                extractedQuestion: candidate.rawText
            )
        }

        let intent: LocalQuestionIntent = analysis.strongSignals.contains(.actionRequestFrame) ? .actionRequest : .answerableQuestion
        return LocalQuestionUnderstanding(
            intent: intent,
            confidence: confidence,
            strongSignals: analysis.strongSignals,
            negativeSignals: [],
            reason: rulePack.reasons.localAnswerableTemplate
                .replacingOccurrences(of: "{strongSignalCount}", with: "\(decisionSignalCount(analysis.strongSignals))"),
            extractedQuestion: candidate.rawText
        )
    }

    private func cachedSurfaceUnderstanding(for candidate: QuestionCandidate) -> LocalQuestionUnderstanding? {
        guard candidate.discovery.source == .surface,
              candidate.discovery.surfaceSuppressionSignals.isEmpty,
              let confidence = candidate.discovery.surfaceConfidence else {
            return nil
        }
        if candidate.discovery.hasTrainedPredictionSignal,
           !candidate.discovery.hasPositiveTrainedQuestionSignal {
            return nil
        }
        let signals = Set(candidate.discovery.surfaceSignals.compactMap(QuestionUnderstandingSignal.init(rawValue:)))
        guard !signals.isEmpty else { return nil }
        let intent: LocalQuestionIntent = signals.contains(.actionRequestFrame) ? .actionRequest : .answerableQuestion
        return LocalQuestionUnderstanding(
            intent: intent,
            confidence: confidence,
            strongSignals: signals,
            negativeSignals: [],
            reason: rulePack.reasons.localAnswerableTemplate
                .replacingOccurrences(of: "{strongSignalCount}", with: "\(decisionSignalCount(signals))"),
            extractedQuestion: candidate.rawText
        )
    }

    private func intent(fromNegativeSignals signals: [String]) -> LocalQuestionIntent? {
        if signals.contains(rulePack.signalLabels.smallTalk) { return .smallTalk }
        if signals.contains(rulePack.signalLabels.operationalCheck) { return .operationalCheck }
        if signals.contains(rulePack.signalLabels.reportedQuestion) { return .reportedQuestion }
        if signals.contains(rulePack.signalLabels.rhetorical) { return .rhetorical }
        if signals.contains(rulePack.signalLabels.fragment) { return .fragment }
        if signals.contains(rulePack.signalLabels.selfAnswered) { return .statement }
        if signals.contains(rulePack.signalLabels.adaptiveSuppressed) { return .statement }
        if signals.contains(rulePack.signalLabels.nounPhraseOrTitle) || signals.contains(rulePack.signalLabels.declarativeWithoutInterrogativeSyntax) {
            return .statement
        }
        return nil
    }

    private func reason(for intent: LocalQuestionIntent, signals: [String]) -> String {
        switch intent {
        case .smallTalk:
            rulePack.reasons.smallTalk
        case .operationalCheck:
            rulePack.reasons.operationalCheck
        case .reportedQuestion:
            rulePack.reasons.quotedPastQuestion
        case .rhetorical:
            rulePack.reasons.rhetorical
        case .fragment:
            rulePack.reasons.fragmentNoObject
        case .statement:
            rulePack.reasons.titleOrStatement
        case .ambiguous:
            rulePack.reasons.ambiguous
        case .answerableQuestion, .actionRequest:
            signals.isEmpty ? rulePack.reasons.answerable : signals.joined(separator: ", ")
        }
    }

    private func decisionSignalCount(_ signals: Set<QuestionUnderstandingSignal>) -> Int {
        signals.subtracting(Set([.finalUtterance])).count
    }
}

struct QuestionDecisionGate {
    var policy: QuestionDecisionGatePolicy = .fallback

    func shouldAccept(
        understanding: LocalQuestionUnderstanding,
        precisionMode: QAPrecisionMode,
        isPartial: Bool
    ) -> Bool {
        guard understanding.responseNeeded else { return false }
        let thresholds = policy.thresholds(for: precisionMode)
        let decisionSignals = understanding.strongSignals.subtracting(policy.ignoredSignals)
        guard decisionSignals.count >= thresholds.requiredStrongSignalCount else { return false }
        if isPartial {
            let meetsPartialThreshold = understanding.confidence >= thresholds.partialConfidenceThreshold
            let completeQuestionShape = policy.partialCompleteShapeSignals.isSubset(of: decisionSignals)
                && understanding.confidence >= max(
                    thresholds.confidenceThreshold - policy.partialCompleteShapeConfidenceDelta,
                    policy.partialCompleteShapeMinimumConfidence
                )
            return (meetsPartialThreshold && !decisionSignals.intersection(policy.partialStrictSignals).isEmpty)
                || completeQuestionShape
        }
        guard understanding.confidence >= thresholds.confidenceThreshold else { return false }
        return true
    }
}

struct QuestionClassifier: QuestionClassifierProvider {
    var rhetoricalFilter: RhetoricalQuestionFilter
    var priorityScorer: QuestionPriorityScorer
    var intentGate: QuestionIntentGate
    var rulePack: QuestionClassificationRulePack
    var understandingProvider: LocalQuestionUnderstandingProvider
    var decisionGate: QuestionDecisionGate
    var multimodalScorer: QuestionMultimodalScorer
    var spanExtractor: QuestionSpanExtractor
    var precisionMode: QAPrecisionMode
    var multimodalMode: QAMultimodalMode
    var trainedModelRunner: (any QuestionTrainedMultimodalModelRunning)?

    init(
        intentRulePack: QuestionIntentRulePack = .default,
        classificationRulePack: QuestionClassificationRulePack = .default,
        adaptiveProfile: QuestionAnsweringAdaptiveProfile = QuestionAnsweringAdaptiveProfile(),
        priorityScorer: QuestionPriorityScorer = QuestionPriorityScorer(),
        precisionMode: QAPrecisionMode = .highPrecision,
        multimodalMode: QAMultimodalMode = .shadow,
        trainedModelRunner: (any QuestionTrainedMultimodalModelRunning)? = nil
    ) {
        self.rhetoricalFilter = RhetoricalQuestionFilter(rulePack: intentRulePack)
        self.intentGate = QuestionIntentGate(rulePack: intentRulePack, adaptiveProfile: adaptiveProfile)
        self.rulePack = classificationRulePack
        self.priorityScorer = priorityScorer
        self.understandingProvider = LocalQuestionUnderstandingProvider(
            rulePack: intentRulePack,
            adaptiveProfile: adaptiveProfile,
            precisionMode: precisionMode
        )
        self.decisionGate = QuestionDecisionGate(policy: classificationRulePack.decisionGatePolicy ?? .fallback)
        self.multimodalScorer = QuestionMultimodalScorer(
            policy: classificationRulePack.multimodalPolicy,
            decisionGatePolicy: classificationRulePack.decisionGatePolicy ?? .fallback
        )
        self.spanExtractor = QuestionSpanExtractor(rulePack: intentRulePack)
        self.precisionMode = precisionMode
        self.multimodalMode = multimodalMode
        self.trainedModelRunner = trainedModelRunner
    }

    func classifyQuestion(
        candidate: QuestionCandidate,
        context: TranscriptContext,
        userProfile: UserMeetingProfile
    ) async throws -> QuestionClassification {
        let understanding = understandingProvider.understand(candidate: candidate, context: context, userProfile: userProfile)
        let isMultiQTRescue = candidate.discovery.source == .multiqtRescue
        let trainedPrediction = await trainedPrediction(for: candidate)
        let fallbackMultimodalDecision = multimodalScorer.score(
            understanding: understanding,
            signal: candidate.multimodalSignal,
            precisionMode: precisionMode,
            isPartial: candidate.isPartial
        )
        let multimodalDecision = trainedPrediction.map {
            QuestionMultimodalDecision(trainedPrediction: $0, textualConfidence: understanding.confidence)
        } ?? fallbackMultimodalDecision
        let trainedAllowsQuestion = trainedPrediction.map { $0.shouldAllow && $0.isPositiveLabel } ?? false
        let modelAcceptedCandidate = isMultiQTRescue && trainedAllowsQuestion

        guard understanding.intent.isQuestionLike || modelAcceptedCandidate else {
            return QuestionClassification(understanding: understanding, candidate: candidate)
        }

        if modelAcceptedCandidate {
            if let hardSuppression = intentGate.hardSuppression(candidate: candidate, context: context, profile: userProfile) {
                return QuestionClassification(ignoredBy: hardSuppression.evaluation, candidate: candidate)
            }
        } else {
            let intent = intentGate.evaluate(candidate: candidate, context: context, profile: userProfile)
            guard intent.isAnswerableQuestion else {
                return QuestionClassification(ignoredBy: intent, candidate: candidate)
            }
        }

        let filter = rhetoricalFilter.evaluation(for: candidate, context: context, profile: userProfile)
        let type = questionType(for: candidate, profile: userProfile, signals: understanding.strongSignals)
        let directedToUser = isDirectedToUser(candidate.normalizedText, speakerLabel: candidate.speakerLabel, profile: userProfile)
        let directedToGroup = !directedToUser && isDirectedToGroup(candidate.normalizedText)
        let actionable = isActionable(candidate.normalizedText, type: type)
        let informational = isInformational(candidate.normalizedText)
        let acceptedByDecisionGate = modelAcceptedCandidate
            ? true
            : decisionGate.shouldAccept(
                understanding: understanding,
                precisionMode: precisionMode,
                isPartial: candidate.isPartial
            )
        let acceptedByMultimodalGate = multimodalMode == .enforced ? multimodalDecision.shouldAllow : true
        let semanticallyResponseNeeded = understanding.responseNeeded || modelAcceptedCandidate
        let contentJustification = isResponseJustified(
            type: type,
            signals: understanding.strongSignals,
            actionable: actionable,
            directedToUser: directedToUser,
            directedToGroup: directedToGroup,
            informational: informational,
            multiQTRescued: modelAcceptedCandidate
        )
        let responseNeeded = acceptedByDecisionGate
            && acceptedByMultimodalGate
            && semanticallyResponseNeeded
            && !filter.rhetorical
            && filter.complete
            && contentJustification
        let priority = priorityScorer.priority(
            for: candidate,
            type: type,
            directedToUser: directedToUser,
            directedToGroup: directedToGroup,
            actionable: actionable,
            signals: understanding.strongSignals,
            responseNeeded: responseNeeded
        )
        let confidence = min(
            max(confidence(for: candidate, filter: filter, directedToUser: directedToUser, type: type), multimodalMode == .enforced ? multimodalDecision.decisionScore : understanding.confidence),
            rulePack.confidencePolicy.maximumScore
        )
        let extractedQuestion = spanExtractor.extractedQuestion(
            from: understanding.extractedQuestion,
            language: candidate.language,
            profile: userProfile
        )
        let userAttentionNeeded = isUserAttentionNeeded(
            responseNeeded: responseNeeded,
            priority: priority,
            type: type,
            signals: understanding.strongSignals,
            actionable: actionable,
            directedToUser: directedToUser,
            directedToGroup: directedToGroup,
            informational: informational
        )

        if !acceptedByDecisionGate || !acceptedByMultimodalGate {
            return QuestionClassification(
                isQuestion: false,
                rhetorical: filter.rhetorical || understanding.intent == .rhetorical,
                complete: filter.complete && understanding.intent != .fragment,
                actionable: actionable,
                responseNeeded: false,
                userAttentionNeeded: false,
                directedToUser: directedToUser,
                directedToGroup: directedToGroup,
                questionType: type,
                priority: .low,
                confidence: min(confidence, rulePack.confidencePolicy.rejectedGateConfidenceCeiling),
                reason: !acceptedByMultimodalGate
                    ? renderedReason(
                        rulePack.reasons.multimodalRejectedTemplate,
                        values: ["suppressionSignals": multimodalDecision.suppressionSignals.joined(separator: ", ")]
                    )
                    : renderedReason(
                        rulePack.reasons.localGateRejectedTemplate,
                        values: ["understandingReason": understanding.reason]
                    ),
                extractedQuestion: extractedQuestion,
                expectedAnswerStyle: .concise,
                textualConfidence: multimodalDecision.textualConfidence,
                multimodalConfidence: multimodalDecision.multimodalConfidence,
                decisionScore: multimodalDecision.decisionScore,
                decisionSignals: multimodalDecision.decisionSignals,
                suppressionSignals: multimodalDecision.suppressionSignals
            )
        }

        let classificationReason: String
        if isMultiQTRescue {
            classificationReason = rulePack.reasons.multiQTRescued
        } else if modelAcceptedCandidate {
            classificationReason = rulePack.reasons.multiQTModelAccepted
        } else {
            classificationReason = understanding.reason
        }

        return QuestionClassification(
            isQuestion: !filter.ignore || filter.rhetorical,
            rhetorical: filter.rhetorical,
            complete: filter.complete,
            actionable: actionable,
            responseNeeded: responseNeeded,
            userAttentionNeeded: userAttentionNeeded,
            directedToUser: directedToUser,
            directedToGroup: directedToGroup,
            questionType: type,
            priority: priority,
            confidence: confidence,
            reason: classificationReason,
            extractedQuestion: extractedQuestion,
            expectedAnswerStyle: answerStyle(for: type, filter: filter),
            textualConfidence: multimodalDecision.textualConfidence,
            multimodalConfidence: multimodalDecision.multimodalConfidence,
            decisionScore: multimodalDecision.decisionScore,
            decisionSignals: multimodalDecision.decisionSignals,
            suppressionSignals: multimodalDecision.suppressionSignals
        )
    }

    private func trainedPrediction(for candidate: QuestionCandidate) async -> QuestionTrainedMultimodalPrediction? {
        guard multimodalMode != .off else { return nil }
        if let prediction = candidate.discovery.trainedPrediction {
            return prediction
        }
        return await trainedModelRunner?.prediction(for: candidate, signal: candidate.multimodalSignal)
    }

    private func questionType(
        for candidate: QuestionCandidate,
        profile: UserMeetingProfile,
        signals: Set<QuestionUnderstandingSignal>
    ) -> QuestionType {
        let text = candidate.normalizedText
        for rule in rulePack.typeRules where matchesTypeRule(rule, text: text, signals: signals) {
            return rule.type
        }
        guard rulePack.technicalInferencePolicy.applies(to: profile.meetingType) else {
            return .generalQuestion
        }
        if contains(text, rulePack.technicalDecisionFrameMarkers),
           contains(text, rulePack.technicalObjectMarkers + rulePack.technicalDecisionObjectMarkers) {
            return rulePack.technicalInferencePolicy.decisionType
        }
        if contains(text, rulePack.technicalObjectMarkers) || hasTechnicalIdentifierSignal(candidate.rawText),
           contains(text, rulePack.technicalExplanationFrameMarkers) {
            return rulePack.technicalInferencePolicy.explanationType
        }
        return .generalQuestion
    }

    private func matchesTypeRule(
        _ rule: QuestionTypeRule,
        text: String,
        signals: Set<QuestionUnderstandingSignal>
    ) -> Bool {
        let hasMarkers = !rule.markers.isEmpty
        let hasAllSignals = !rule.allSignals.isEmpty
        let hasAnySignals = !rule.anySignals.isEmpty
        guard hasMarkers || hasAllSignals || hasAnySignals else { return false }
        if hasMarkers && !contains(text, rule.markers) { return false }
        if hasAllSignals && !rule.allSignals.isSubset(of: signals) { return false }
        if hasAnySignals && rule.anySignals.isDisjoint(with: signals) { return false }
        return true
    }

    private func answerStyle(for type: QuestionType, filter: (ignore: Bool, rhetorical: Bool, complete: Bool, responseNeeded: Bool, reason: String)) -> AnswerStyle {
        rulePack.answerStylePolicy.style(for: type, complete: filter.complete)
    }

    private func isDirectedToUser(_ text: String, speakerLabel: String?, profile: UserMeetingProfile) -> Bool {
        let aliases = ([profile.userName] + profile.userAliases)
            .map(QuestionDetectionService.normalize)
            .filter { !$0.isEmpty }
        let policy = intentGate.rulePack.textSegmentationPolicy
        if aliases.contains(where: { policy.containsNormalizedMarker($0, inNormalizedText: text) }) {
            return true
        }
        let normalizedSpeaker = speakerLabel.map(QuestionDetectionService.normalize)
        if let normalizedSpeaker,
           rulePack.selfSpeakerLabels.contains(where: { selfLabel in
               let normalizedSelfLabel = QuestionDetectionService.normalize(selfLabel)
               return normalizedSpeaker == normalizedSelfLabel
                   || policy.containsNormalizedMarker(normalizedSelfLabel, inNormalizedText: normalizedSpeaker)
           }) {
            return false
        }
        return contains(text, rulePack.directedToUserMarkers)
    }

    private func isDirectedToGroup(_ text: String) -> Bool {
        contains(text, rulePack.directedToGroupMarkers)
    }

    private func isActionable(_ text: String, type: QuestionType) -> Bool {
        if rulePack.intrinsicallyActionableTypes.contains(type) {
            return true
        }
        return contains(text, rulePack.actionableMarkers)
    }

    private func hasResponseJustifyingSignal(_ signals: Set<QuestionUnderstandingSignal>) -> Bool {
        if !signals.isDisjoint(with: rulePack.responseJustifyingSignals) {
            return true
        }
        return rulePack.responseJustifyingSignalGroups.contains { group in
            group.allSatisfy(signals.contains)
        }
    }

    private func isResponseJustified(
        type: QuestionType,
        signals: Set<QuestionUnderstandingSignal>,
        actionable: Bool,
        directedToUser: Bool,
        directedToGroup: Bool,
        informational: Bool,
        multiQTRescued: Bool
    ) -> Bool {
        if !rulePack.responseJustificationRules.isEmpty {
            return rulePack.responseJustificationRules.contains { rule in
                responseJustificationRuleMatches(
                    rule,
                    type: type,
                    signals: signals,
                    actionable: actionable,
                    directedToUser: directedToUser,
                    directedToGroup: directedToGroup,
                    informational: informational,
                    multiQTRescued: multiQTRescued
                )
            }
        }
        return actionable
            || directedToUser
            || directedToGroup
            || informational
            || hasResponseJustifyingSignal(signals)
            || rulePack.responseJustifyingTypes.contains(type)
            || multiQTRescued
    }

    private func responseJustificationRuleMatches(
        _ rule: QuestionResponseJustificationRule,
        type: QuestionType,
        signals: Set<QuestionUnderstandingSignal>,
        actionable: Bool,
        directedToUser: Bool,
        directedToGroup: Bool,
        informational: Bool,
        multiQTRescued: Bool
    ) -> Bool {
        if let required = rule.requiresActionable, actionable != required { return false }
        if let required = rule.requiresDirectedToUser, directedToUser != required { return false }
        if let required = rule.requiresDirectedToGroup, directedToGroup != required { return false }
        if let required = rule.requiresInformational, informational != required { return false }
        if let required = rule.requiresMultiQTRescue, multiQTRescued != required { return false }
        if !rule.questionTypes.isEmpty, !rule.questionTypes.contains(type) { return false }
        if !rule.anySignals.isEmpty, signals.isDisjoint(with: rule.anySignals) { return false }
        if !rule.allSignalGroups.isEmpty, !rule.allSignalGroups.contains(where: { $0.allSatisfy(signals.contains) }) { return false }
        return true
    }

    private func isUserAttentionNeeded(
        responseNeeded: Bool,
        priority: QuestionPriority,
        type: QuestionType,
        signals: Set<QuestionUnderstandingSignal>,
        actionable: Bool,
        directedToUser: Bool,
        directedToGroup: Bool,
        informational: Bool
    ) -> Bool {
        if !rulePack.attentionRules.isEmpty {
            return rulePack.attentionRules.contains { rule in
                attentionRuleMatches(
                    rule,
                    responseNeeded: responseNeeded,
                    priority: priority,
                    type: type,
                    signals: signals,
                    actionable: actionable,
                    directedToUser: directedToUser,
                    directedToGroup: directedToGroup,
                    informational: informational
                )
            }
        }
        return responseNeeded && (directedToUser || priority == .urgent || priority == .high)
    }

    private func attentionRuleMatches(
        _ rule: QuestionAttentionRule,
        responseNeeded: Bool,
        priority: QuestionPriority,
        type: QuestionType,
        signals: Set<QuestionUnderstandingSignal>,
        actionable: Bool,
        directedToUser: Bool,
        directedToGroup: Bool,
        informational: Bool
    ) -> Bool {
        if let required = rule.requiresResponseNeeded, responseNeeded != required { return false }
        if let required = rule.requiresActionable, actionable != required { return false }
        if let required = rule.requiresDirectedToUser, directedToUser != required { return false }
        if let required = rule.requiresDirectedToGroup, directedToGroup != required { return false }
        if let required = rule.requiresInformational, informational != required { return false }
        if !rule.priorities.isEmpty, !rule.priorities.contains(priority) { return false }
        if !rule.questionTypes.isEmpty, !rule.questionTypes.contains(type) { return false }
        if !rule.anySignals.isEmpty, signals.isDisjoint(with: rule.anySignals) { return false }
        if !rule.allSignalGroups.isEmpty, !rule.allSignalGroups.contains(where: { $0.allSatisfy(signals.contains) }) { return false }
        return true
    }

    private func isInformational(_ text: String) -> Bool {
        contains(text, rulePack.informationalMarkers)
    }

    private func confidence(
        for candidate: QuestionCandidate,
        filter: (ignore: Bool, rhetorical: Bool, complete: Bool, responseNeeded: Bool, reason: String),
        directedToUser: Bool,
        type: QuestionType
    ) -> Double {
        let policy = rulePack.confidencePolicy
        if filter.ignore && !filter.rhetorical { return policy.ignoredFilterConfidence }
        var score = intentGate.rulePack.textSegmentationPolicy.containsQuestionPunctuation(in: candidate.rawText)
            ? policy.terminalPunctuationBaseScore
            : policy.semanticShapeBaseScore
        if directedToUser { score += policy.directedToUserBonus }
        if policy.typeBonusTypes.contains(type) { score += policy.typedQuestionBonus }
        if candidate.isPartial { score -= policy.partialPenalty }
        if filter.rhetorical { score = policy.rhetoricalScore }
        return min(max(score, policy.minimumScore), policy.maximumScore)
    }

    private func contains(_ text: String, _ patterns: [String]) -> Bool {
        let normalizedText = QuestionDetectionService.normalize(text)
        return containsNormalized(normalizedText, patterns)
    }

    private func containsNormalized(_ normalizedText: String, _ patterns: [String]) -> Bool {
        let policy = intentGate.rulePack.textSegmentationPolicy
        return patterns.contains { pattern in
            policy.containsNormalizedMarker(QuestionDetectionService.normalize(pattern), inNormalizedText: normalizedText)
        }
    }

    private func hasTechnicalIdentifierSignal(_ text: String) -> Bool {
        matchesAnyRegex(text, rulePack.technicalInferencePolicy.identifierPatterns)
            || rulePack.technicalInferencePolicy.usesCodeIdentifierCharacters
                && intentGate.rulePack.textSegmentationPolicy.containsCodeIdentifierCharacter(in: text)
    }

    private func matchesAnyRegex(_ text: String, _ patterns: [String]) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return patterns.contains { pattern in
            guard let regex = QuestionClassificationRegexCache.regex(for: pattern) else { return false }
            return regex.firstMatch(in: text, range: range) != nil
        }
    }

    private func renderedReason(_ template: String, values: [String: String]) -> String {
        values.reduce(template) { rendered, entry in
            rendered.replacingOccurrences(of: "{\(entry.key)}", with: entry.value)
        }
    }
}

extension QuestionClassification {
    init(understanding: LocalQuestionUnderstanding, candidate: QuestionCandidate) {
        self.init(
            isQuestion: false,
            rhetorical: understanding.intent == .rhetorical,
            complete: understanding.intent != .fragment,
            actionable: false,
            responseNeeded: false,
            userAttentionNeeded: false,
            directedToUser: understanding.strongSignals.contains(.directedToUser),
            directedToGroup: understanding.strongSignals.contains(.directedToGroup),
            questionType: .generalQuestion,
            priority: .low,
            confidence: understanding.confidence,
            reason: understanding.reason,
            extractedQuestion: candidate.rawText,
            expectedAnswerStyle: understanding.intent == .fragment ? .askForClarification : .concise
        )
    }
}
