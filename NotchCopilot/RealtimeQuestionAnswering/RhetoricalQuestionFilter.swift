import Foundation
import NaturalLanguage

struct QuestionIntentSignalLabels: Codable, Hashable, Sendable {
    var empty: String
    var smallTalk: String
    var operationalCheck: String
    var reportedQuestion: String
    var rhetorical: String
    var selfAnswered: String
    var fragment: String
    var nounPhraseOrTitle: String
    var adaptiveSuppressed: String
    var declarativeWithoutInterrogativeSyntax: String

    static let fallback = QuestionIntentSignalLabels(
        empty: "empty",
        smallTalk: "small_talk",
        operationalCheck: "operational_check",
        reportedQuestion: "reported_question",
        rhetorical: "rhetorical",
        selfAnswered: "self_answered",
        fragment: "fragment",
        nounPhraseOrTitle: "noun_phrase_or_title",
        adaptiveSuppressed: "adaptive_suppressed",
        declarativeWithoutInterrogativeSyntax: "declarative_without_interrogative_syntax"
    )
}

struct QuestionIntentReasonPolicy: Codable, Hashable, Sendable {
    var fragmentIncomplete: String
    var rhetorical: String
    var quotedPastQuestion: String
    var selfAnswered: String
    var answerable: String
    var adaptivePromoted: String
    var insufficientIntentObject: String
    var clearIntentObject: String
    var fragmentNoObject: String
    var smallTalk: String
    var quotedOrExplaining: String
    var adaptiveSuppressed: String
    var highPrecisionInsufficient: String
    var localAnswerableTemplate: String
    var operationalCheck: String
    var titleOrStatement: String
    var ambiguous: String
    var surfaceBelowCandidateThreshold: String

    static let fallback = QuestionIntentReasonPolicy(
        fragmentIncomplete: "Question fragment is incomplete.",
        rhetorical: "Question is likely rhetorical.",
        quotedPastQuestion: "Question is being reported rather than asked.",
        selfAnswered: "Speaker answered their own question.",
        answerable: "Question appears answerable.",
        adaptivePromoted: "User feedback promoted this kind of question.",
        insufficientIntentObject: "Question lacks enough intent and object signal to answer confidently.",
        clearIntentObject: "Question has clear intent and an answerable object.",
        fragmentNoObject: "Question-like fragment has no answerable object.",
        smallTalk: "Small talk greeting does not need a meeting answer.",
        quotedOrExplaining: "Question-like text is quoted, reported, or part of an explanation.",
        adaptiveSuppressed: "Similar questions were repeatedly dismissed by the user.",
        highPrecisionInsufficient: "Utterance does not have enough interrogative structure for high-precision Notchly activation.",
        localAnswerableTemplate: "Local detector found a complete answerable question with {strongSignalCount} strong signals.",
        operationalCheck: "Operational audio or screen check should not trigger Notchly.",
        titleOrStatement: "Statement or title-like utterance is not an answerable question.",
        ambiguous: "Question signal is ambiguous below the local precision threshold.",
        surfaceBelowCandidateThreshold: "surface_below_candidate_threshold"
    )
}

struct QuestionSurfaceScoringPolicy: Codable, Hashable, Sendable {
    var answerableObjectFocusThreshold: Double
    var questionLikeThreshold: Double
    var rejectedConfidence: Double
    var confidenceBase: Double
    var questionPunctuationConfidence: Double
    var interrogativeConfidence: Double
    var modalConfidence: Double
    var indirectConfidence: Double
    var actionConfidence: Double
    var directedUserConfidence: Double
    var directedGroupConfidence: Double
    var concreteObjectConfidence: Double
    var domainObjectConfidence: Double
    var semanticShapeConfidenceMax: Double
    var semanticShapeConfidenceWeight: Double
    var answerableFocusConfidenceMax: Double
    var answerableFocusConfidenceWeight: Double
    var adaptivePromotionConfidence: Double
    var contextualCarryoverConfidence: Double
    var finalUtteranceConfidence: Double
    var weakQuestionWordPenalty: Double
    var partialHighPrecisionPenalty: Double
    var partialStandardPenalty: Double
    var minConfidence: Double
    var maxConfidence: Double
    var insufficientSurfaceConfidenceCeiling: Double
    var adaptiveCandidateObjectThreshold: Double
    var semanticCandidateQuestionThreshold: Double
    var objectMeaningfulTokenWeight: Double
    var objectMeaningfulTokenMax: Double
    var objectDensityWeight: Double
    var objectDensityMax: Double
    var objectNumericPayloadBonus: Double
    var objectDomainBonus: Double
    var objectContextOverlapBonus: Double
    var objectNamedEntityBonus: Double
    var objectCJKBonus: Double
    var questionPunctuationScore: Double
    var questionInterrogativeScore: Double
    var questionModalScore: Double
    var questionIndirectScore: Double
    var questionActionScore: Double
    var questionCueNearLeadScore: Double
    var questionCompactUtteranceScore: Double
    var questionCompactObjectThreshold: Double
    var questionContextOverlapScore: Double
    var questionNamedEntityScore: Double
    var questionCJKScore: Double
    var questionCJKObjectThreshold: Double
    var questionFinalUtteranceScore: Double
    var compactUtteranceMinTokens: Int
    var compactUtteranceMaxTokens: Int
    var cjkMinimumCharacters: Int
    var contextOverlapMaximumRequiredMatches: Int
    var contextualCarryoverMinimumRecentTerms: Int

    static let fallback = QuestionSurfaceScoringPolicy(
        answerableObjectFocusThreshold: 0.34,
        questionLikeThreshold: 0.58,
        rejectedConfidence: 0.12,
        confidenceBase: 0.50,
        questionPunctuationConfidence: 0.18,
        interrogativeConfidence: 0.22,
        modalConfidence: 0.24,
        indirectConfidence: 0.24,
        actionConfidence: 0.24,
        directedUserConfidence: 0.11,
        directedGroupConfidence: 0.07,
        concreteObjectConfidence: 0.12,
        domainObjectConfidence: 0.05,
        semanticShapeConfidenceMax: 0.12,
        semanticShapeConfidenceWeight: 0.12,
        answerableFocusConfidenceMax: 0.08,
        answerableFocusConfidenceWeight: 0.08,
        adaptivePromotionConfidence: 0.10,
        contextualCarryoverConfidence: 0.04,
        finalUtteranceConfidence: 0.04,
        weakQuestionWordPenalty: 0.24,
        partialHighPrecisionPenalty: 0.12,
        partialStandardPenalty: 0.06,
        minConfidence: 0.05,
        maxConfidence: 0.98,
        insufficientSurfaceConfidenceCeiling: 0.48,
        adaptiveCandidateObjectThreshold: 0.35,
        semanticCandidateQuestionThreshold: 0.74,
        objectMeaningfulTokenWeight: 0.18,
        objectMeaningfulTokenMax: 0.55,
        objectDensityWeight: 0.30,
        objectDensityMax: 0.22,
        objectNumericPayloadBonus: 0.22,
        objectDomainBonus: 0.18,
        objectContextOverlapBonus: 0.16,
        objectNamedEntityBonus: 0.10,
        objectCJKBonus: 0.20,
        questionPunctuationScore: 0.34,
        questionInterrogativeScore: 0.40,
        questionModalScore: 0.36,
        questionIndirectScore: 0.36,
        questionActionScore: 0.34,
        questionCueNearLeadScore: 0.18,
        questionCompactUtteranceScore: 0.12,
        questionCompactObjectThreshold: 0.42,
        questionContextOverlapScore: 0.08,
        questionNamedEntityScore: 0.05,
        questionCJKScore: 0.18,
        questionCJKObjectThreshold: 0.34,
        questionFinalUtteranceScore: 0.04,
        compactUtteranceMinTokens: 2,
        compactUtteranceMaxTokens: 12,
        cjkMinimumCharacters: 5,
        contextOverlapMaximumRequiredMatches: 2,
        contextualCarryoverMinimumRecentTerms: 5
    )
}

struct QuestionSignalGroupPolicy: Codable, Hashable, Sendable {
    var all: Set<QuestionUnderstandingSignal>
    var any: Set<QuestionUnderstandingSignal>
    var minStructuralQuestionScore: Double?
    var minObjectFocusScore: Double?
    var requiresInterrogativeObject: Bool

    init(
        all: Set<QuestionUnderstandingSignal> = [],
        any: Set<QuestionUnderstandingSignal> = [],
        minStructuralQuestionScore: Double? = nil,
        minObjectFocusScore: Double? = nil,
        requiresInterrogativeObject: Bool = false
    ) {
        self.all = all
        self.any = any
        self.minStructuralQuestionScore = minStructuralQuestionScore
        self.minObjectFocusScore = minObjectFocusScore
        self.requiresInterrogativeObject = requiresInterrogativeObject
    }

    private enum CodingKeys: String, CodingKey {
        case all
        case any
        case minStructuralQuestionScore
        case minObjectFocusScore
        case requiresInterrogativeObject
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        all = try container.decodeIfPresent(Set<QuestionUnderstandingSignal>.self, forKey: .all) ?? []
        any = try container.decodeIfPresent(Set<QuestionUnderstandingSignal>.self, forKey: .any) ?? []
        minStructuralQuestionScore = try container.decodeIfPresent(Double.self, forKey: .minStructuralQuestionScore)
        minObjectFocusScore = try container.decodeIfPresent(Double.self, forKey: .minObjectFocusScore)
        requiresInterrogativeObject = try container.decodeIfPresent(Bool.self, forKey: .requiresInterrogativeObject) ?? false
    }
}

struct QuestionSurfaceCandidatePolicy: Codable, Hashable, Sendable {
    var punctuatedAnySignals: Set<QuestionUnderstandingSignal>
    var unpunctuatedGroups: [QuestionSignalGroupPolicy]
    var weakQuestionWordOnlySignals: Set<QuestionUnderstandingSignal>

    init(
        punctuatedAnySignals: Set<QuestionUnderstandingSignal>,
        unpunctuatedGroups: [QuestionSignalGroupPolicy],
        weakQuestionWordOnlySignals: Set<QuestionUnderstandingSignal>
    ) {
        self.punctuatedAnySignals = punctuatedAnySignals
        self.unpunctuatedGroups = unpunctuatedGroups
        self.weakQuestionWordOnlySignals = weakQuestionWordOnlySignals
    }

    private enum CodingKeys: String, CodingKey {
        case punctuatedAnySignals
        case unpunctuatedGroups
        case weakQuestionWordOnlySignals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        punctuatedAnySignals = try container.decodeIfPresent(Set<QuestionUnderstandingSignal>.self, forKey: .punctuatedAnySignals) ?? []
        unpunctuatedGroups = try container.decodeIfPresent([QuestionSignalGroupPolicy].self, forKey: .unpunctuatedGroups) ?? []
        weakQuestionWordOnlySignals = try container.decodeIfPresent(Set<QuestionUnderstandingSignal>.self, forKey: .weakQuestionWordOnlySignals) ?? []
    }

    static let fallback = QuestionSurfaceCandidatePolicy(
        punctuatedAnySignals: [
            .interrogativeStarter,
            .modalQuestionFrame,
            .indirectQuestionFrame,
            .actionRequestFrame,
            .directedToUser,
            .directedToGroup,
            .domainObject,
            .concreteObject
        ],
        unpunctuatedGroups: [
            QuestionSignalGroupPolicy(
                all: [.indirectQuestionFrame],
                any: [.concreteObject, .domainObject]
            ),
            QuestionSignalGroupPolicy(
                all: [.actionRequestFrame],
                any: [.directedToUser, .directedToGroup, .concreteObject]
            ),
            QuestionSignalGroupPolicy(
                all: [.modalQuestionFrame],
                any: [.concreteObject, .domainObject]
            ),
            QuestionSignalGroupPolicy(
                all: [.contextualQuestionLead],
                any: [.concreteObject, .answerableObjectFocus]
            ),
            QuestionSignalGroupPolicy(
                all: [.interrogativeStarter],
                requiresInterrogativeObject: true
            ),
            QuestionSignalGroupPolicy(
                all: [.adaptivePromotion],
                any: [.answerableObjectFocus, .concreteObject],
                minObjectFocusScore: QuestionSurfaceScoringPolicy.fallback.adaptiveCandidateObjectThreshold
            ),
            QuestionSignalGroupPolicy(
                all: [.semanticQuestionShape, .answerableObjectFocus],
                any: [.contextualCarryover, .domainObject, .concreteObject],
                minStructuralQuestionScore: QuestionSurfaceScoringPolicy.fallback.semanticCandidateQuestionThreshold
            )
        ],
        weakQuestionWordOnlySignals: [.interrogativeStarter, .concreteObject, .finalUtterance]
    )
}

struct QuestionContextualCuePolicy: Codable, Hashable, Sendable {
    var maximumQuestionExamples: Int
    var minimumLeadTokenLength: Int
    var maximumLeadTokenCount: Int
    var minimumMultiTokenObservations: Int
    var minimumSingleTokenObservations: Int
    var compactSuffixMinimumCharacters: Int
    var compactSuffixMaximumCharacters: Int
    var compactSuffixMinimumObservations: Int

    init(
        maximumQuestionExamples: Int,
        minimumLeadTokenLength: Int,
        maximumLeadTokenCount: Int,
        minimumMultiTokenObservations: Int,
        minimumSingleTokenObservations: Int,
        compactSuffixMinimumCharacters: Int,
        compactSuffixMaximumCharacters: Int,
        compactSuffixMinimumObservations: Int
    ) {
        self.maximumQuestionExamples = maximumQuestionExamples
        self.minimumLeadTokenLength = minimumLeadTokenLength
        self.maximumLeadTokenCount = maximumLeadTokenCount
        self.minimumMultiTokenObservations = minimumMultiTokenObservations
        self.minimumSingleTokenObservations = minimumSingleTokenObservations
        self.compactSuffixMinimumCharacters = compactSuffixMinimumCharacters
        self.compactSuffixMaximumCharacters = compactSuffixMaximumCharacters
        self.compactSuffixMinimumObservations = compactSuffixMinimumObservations
    }

    private enum CodingKeys: String, CodingKey {
        case maximumQuestionExamples
        case minimumLeadTokenLength
        case maximumLeadTokenCount
        case minimumMultiTokenObservations
        case minimumSingleTokenObservations
        case compactSuffixMinimumCharacters
        case compactSuffixMaximumCharacters
        case compactSuffixMinimumObservations
    }

    init(from decoder: Decoder) throws {
        let fallback = QuestionContextualCuePolicy.fallback
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maximumQuestionExamples: try container.decodeIfPresent(Int.self, forKey: .maximumQuestionExamples) ?? fallback.maximumQuestionExamples,
            minimumLeadTokenLength: try container.decodeIfPresent(Int.self, forKey: .minimumLeadTokenLength) ?? fallback.minimumLeadTokenLength,
            maximumLeadTokenCount: try container.decodeIfPresent(Int.self, forKey: .maximumLeadTokenCount) ?? fallback.maximumLeadTokenCount,
            minimumMultiTokenObservations: try container.decodeIfPresent(Int.self, forKey: .minimumMultiTokenObservations) ?? fallback.minimumMultiTokenObservations,
            minimumSingleTokenObservations: try container.decodeIfPresent(Int.self, forKey: .minimumSingleTokenObservations) ?? fallback.minimumSingleTokenObservations,
            compactSuffixMinimumCharacters: try container.decodeIfPresent(Int.self, forKey: .compactSuffixMinimumCharacters) ?? fallback.compactSuffixMinimumCharacters,
            compactSuffixMaximumCharacters: try container.decodeIfPresent(Int.self, forKey: .compactSuffixMaximumCharacters) ?? fallback.compactSuffixMaximumCharacters,
            compactSuffixMinimumObservations: try container.decodeIfPresent(Int.self, forKey: .compactSuffixMinimumObservations) ?? fallback.compactSuffixMinimumObservations
        )
    }

    static let fallback = QuestionContextualCuePolicy(
        maximumQuestionExamples: 24,
        minimumLeadTokenLength: 2,
        maximumLeadTokenCount: 3,
        minimumMultiTokenObservations: 1,
        minimumSingleTokenObservations: 2,
        compactSuffixMinimumCharacters: 1,
        compactSuffixMaximumCharacters: 3,
        compactSuffixMinimumObservations: 2
    )
}

struct QuestionIntentGateScoringPolicy: Codable, Hashable, Sendable {
    var adaptivePromotedConfidence: Double
    var insufficientMinimumConfidence: Double
    var insufficientMaximumConfidence: Double
    var acceptedConfidenceBase: Double
    var acceptedConfidenceDeltaWeight: Double
    var acceptedMinimumConfidence: Double
    var acceptedMaximumConfidence: Double
    var fragmentSuppressionConfidence: Double
    var smallTalkSuppressionConfidence: Double
    var quotedSuppressionConfidence: Double
    var selfAnsweredSuppressionConfidence: Double
    var rhetoricalSuppressionConfidence: Double
    var adaptiveSuppressedConfidence: Double
    var embeddedQuestionRecoveryBonus: Double
    var answerableThresholdMinimum: Double
    var answerableThresholdMaximum: Double
    var questionPunctuationWeight: Double
    var directQuestionMarkerWeight: Double
    var indirectQuestionMarkerWeight: Double
    var actionRequestMarkerWeight: Double
    var modalQuestionStarterWeight: Double
    var domainHintWeight: Double
    var numericPayloadWeight: Double
    var meaningfulTokenWeight: Double
    var meaningfulTokenMaximum: Double
    var codeIdentifierWeight: Double
    var cjkWeight: Double
    var cjkMinimumCharacters: Int
    var contextualCarryoverWeight: Double
    var surfaceSemanticShapeBonus: Double
    var surfaceAnswerableObjectBonus: Double
    var surfaceAdaptivePromotionBonus: Double
    var concreteObjectCJKMinimumCharacters: Int
    var contextualCarryoverMinimumRecentTerms: Int

    static let fallback = QuestionIntentGateScoringPolicy(
        adaptivePromotedConfidence: 0.90,
        insufficientMinimumConfidence: 0.08,
        insufficientMaximumConfidence: 0.42,
        acceptedConfidenceBase: 0.58,
        acceptedConfidenceDeltaWeight: 0.16,
        acceptedMinimumConfidence: 0.56,
        acceptedMaximumConfidence: 0.94,
        fragmentSuppressionConfidence: 0.12,
        smallTalkSuppressionConfidence: 0.18,
        quotedSuppressionConfidence: 0.22,
        selfAnsweredSuppressionConfidence: 0.22,
        rhetoricalSuppressionConfidence: 0.26,
        adaptiveSuppressedConfidence: 0.30,
        embeddedQuestionRecoveryBonus: 0.25,
        answerableThresholdMinimum: 1.10,
        answerableThresholdMaximum: 1.90,
        questionPunctuationWeight: 0.50,
        directQuestionMarkerWeight: 0.80,
        indirectQuestionMarkerWeight: 1.00,
        actionRequestMarkerWeight: 0.85,
        modalQuestionStarterWeight: 0.65,
        domainHintWeight: 0.55,
        numericPayloadWeight: 0.95,
        meaningfulTokenWeight: 0.38,
        meaningfulTokenMaximum: 1.35,
        codeIdentifierWeight: 0.45,
        cjkWeight: 0.55,
        cjkMinimumCharacters: 5,
        contextualCarryoverWeight: 0.35,
        surfaceSemanticShapeBonus: 0.36,
        surfaceAnswerableObjectBonus: 0.24,
        surfaceAdaptivePromotionBonus: 0.70,
        concreteObjectCJKMinimumCharacters: 4,
        contextualCarryoverMinimumRecentTerms: 5
    )
}

struct QuestionUnicodeScalarRangePolicy: Codable, Hashable, Sendable {
    var lowerBound: UInt32
    var upperBound: UInt32

    func contains(_ scalar: Unicode.Scalar) -> Bool {
        lowerBound <= scalar.value && scalar.value <= upperBound
    }

    func normalized() -> QuestionUnicodeScalarRangePolicy? {
        guard lowerBound <= upperBound else { return nil }
        return self
    }
}

enum QuestionTextTokenizationStrategy: String, Codable, Hashable, Sendable {
    case scalarSplit
    case naturalLanguage
    case automatic
}

enum QuestionNamedEntityRecognitionStrategy: String, Codable, Hashable, Sendable {
    case heuristic
    case naturalLanguage
    case automatic
}

struct QuestionTextSegmentationPolicy: Codable, Hashable, Sendable {
    var minimumFrameCharacters: Int
    var minimumMeaningfulTokenLength: Int
    var minimumNamedEntityTokenLength: Int
    var minimumNamedEntityLetterCount: Int
    var namedEntityUppercaseMinimum: Int
    var leadAddressMinimumTokens: Int
    var leadAddressMinimumTokenLength: Int
    var questionCueLeadTokenLimit: Int
    var fragmentEllipsisMaximumTokens: Int
    var fragmentTerminalMarkers: [String]
    var titleMinimumTokens: Int
    var declarativeMinimumTokens: Int
    var numericPayloadMinimumCount: Int
    var questionPunctuationCharacters: String
    var lineBoundaryCharacters: String
    var sentenceBoundaryCharacters: String
    var namedEntitySeparatorCharacters: String
    var spanTrailingTrimCharacters: String
    var addressSeparatorTrimCharacters: String
    var codeIdentifierCharacters: String
    var codeIdentifierPatterns: [String]
    var plainTextSeparatorCharacters: String
    var compactScriptScalarRanges: [QuestionUnicodeScalarRangePolicy]
    var tokenizationStrategy: QuestionTextTokenizationStrategy
    var compactScriptMinimumMeaningfulTokenLength: Int
    var namedEntityRecognitionStrategy: QuestionNamedEntityRecognitionStrategy

    static let fallback = QuestionTextSegmentationPolicy(
        minimumFrameCharacters: 4,
        minimumMeaningfulTokenLength: 3,
        minimumNamedEntityTokenLength: 2,
        minimumNamedEntityLetterCount: 2,
        namedEntityUppercaseMinimum: 2,
        leadAddressMinimumTokens: 3,
        leadAddressMinimumTokenLength: 2,
        questionCueLeadTokenLimit: 6,
        fragmentEllipsisMaximumTokens: 5,
        fragmentTerminalMarkers: ["...", "…", "⋯", "……", "。。。"],
        titleMinimumTokens: 5,
        declarativeMinimumTokens: 8,
        numericPayloadMinimumCount: 2,
        questionPunctuationCharacters: "?？¿؟",
        lineBoundaryCharacters: "\n\r\u{2028}\u{2029}",
        sentenceBoundaryCharacters: ".!?؟。;；",
        namedEntitySeparatorCharacters: ",.;:!?¿؟()[]{}<>\"“”'`",
        spanTrailingTrimCharacters: " ,.;:",
        addressSeparatorTrimCharacters: ",:;-",
        codeIdentifierCharacters: "_`/#",
        codeIdentifierPatterns: [#"[A-Za-z]+[A-Z0-9][A-Za-z0-9]*"#],
        plainTextSeparatorCharacters: "¿?؟？!！.,;:。、「」()[]\"“”",
        compactScriptScalarRanges: [
            QuestionUnicodeScalarRangePolicy(lowerBound: 0x0E00, upperBound: 0x0E7F),
            QuestionUnicodeScalarRangePolicy(lowerBound: 0x0E80, upperBound: 0x0EFF),
            QuestionUnicodeScalarRangePolicy(lowerBound: 0x1000, upperBound: 0x109F),
            QuestionUnicodeScalarRangePolicy(lowerBound: 0x1100, upperBound: 0x11FF),
            QuestionUnicodeScalarRangePolicy(lowerBound: 0x1780, upperBound: 0x17FF),
            QuestionUnicodeScalarRangePolicy(lowerBound: 0x3040, upperBound: 0x30FF),
            QuestionUnicodeScalarRangePolicy(lowerBound: 0x31F0, upperBound: 0x31FF),
            QuestionUnicodeScalarRangePolicy(lowerBound: 0x3400, upperBound: 0x4DBF),
            QuestionUnicodeScalarRangePolicy(lowerBound: 0x4E00, upperBound: 0x9FFF),
            QuestionUnicodeScalarRangePolicy(lowerBound: 0xAC00, upperBound: 0xD7AF)
        ],
        tokenizationStrategy: .automatic,
        compactScriptMinimumMeaningfulTokenLength: 2,
        namedEntityRecognitionStrategy: .automatic
    )

    init(
        minimumFrameCharacters: Int,
        minimumMeaningfulTokenLength: Int,
        minimumNamedEntityTokenLength: Int,
        minimumNamedEntityLetterCount: Int,
        namedEntityUppercaseMinimum: Int,
        leadAddressMinimumTokens: Int,
        leadAddressMinimumTokenLength: Int,
        questionCueLeadTokenLimit: Int,
        fragmentEllipsisMaximumTokens: Int,
        fragmentTerminalMarkers: [String] = ["..."],
        titleMinimumTokens: Int,
        declarativeMinimumTokens: Int,
        numericPayloadMinimumCount: Int,
        questionPunctuationCharacters: String,
        lineBoundaryCharacters: String,
        sentenceBoundaryCharacters: String,
        namedEntitySeparatorCharacters: String,
        spanTrailingTrimCharacters: String,
        addressSeparatorTrimCharacters: String,
        codeIdentifierCharacters: String,
        codeIdentifierPatterns: [String] = [],
        plainTextSeparatorCharacters: String,
        compactScriptScalarRanges: [QuestionUnicodeScalarRangePolicy] = [],
        tokenizationStrategy: QuestionTextTokenizationStrategy = .scalarSplit,
        compactScriptMinimumMeaningfulTokenLength: Int = 2,
        namedEntityRecognitionStrategy: QuestionNamedEntityRecognitionStrategy = .automatic
    ) {
        self.minimumFrameCharacters = minimumFrameCharacters
        self.minimumMeaningfulTokenLength = minimumMeaningfulTokenLength
        self.minimumNamedEntityTokenLength = minimumNamedEntityTokenLength
        self.minimumNamedEntityLetterCount = minimumNamedEntityLetterCount
        self.namedEntityUppercaseMinimum = namedEntityUppercaseMinimum
        self.leadAddressMinimumTokens = leadAddressMinimumTokens
        self.leadAddressMinimumTokenLength = leadAddressMinimumTokenLength
        self.questionCueLeadTokenLimit = questionCueLeadTokenLimit
        self.fragmentEllipsisMaximumTokens = fragmentEllipsisMaximumTokens
        self.fragmentTerminalMarkers = fragmentTerminalMarkers
        self.titleMinimumTokens = titleMinimumTokens
        self.declarativeMinimumTokens = declarativeMinimumTokens
        self.numericPayloadMinimumCount = numericPayloadMinimumCount
        self.questionPunctuationCharacters = questionPunctuationCharacters
        self.lineBoundaryCharacters = lineBoundaryCharacters
        self.sentenceBoundaryCharacters = sentenceBoundaryCharacters
        self.namedEntitySeparatorCharacters = namedEntitySeparatorCharacters
        self.spanTrailingTrimCharacters = spanTrailingTrimCharacters
        self.addressSeparatorTrimCharacters = addressSeparatorTrimCharacters
        self.codeIdentifierCharacters = codeIdentifierCharacters
        self.codeIdentifierPatterns = codeIdentifierPatterns
        self.plainTextSeparatorCharacters = plainTextSeparatorCharacters
        self.compactScriptScalarRanges = compactScriptScalarRanges
        self.tokenizationStrategy = tokenizationStrategy
        self.compactScriptMinimumMeaningfulTokenLength = compactScriptMinimumMeaningfulTokenLength
        self.namedEntityRecognitionStrategy = namedEntityRecognitionStrategy
    }

    private enum CodingKeys: String, CodingKey {
        case minimumFrameCharacters
        case minimumMeaningfulTokenLength
        case minimumNamedEntityTokenLength
        case minimumNamedEntityLetterCount
        case namedEntityUppercaseMinimum
        case leadAddressMinimumTokens
        case leadAddressMinimumTokenLength
        case questionCueLeadTokenLimit
        case fragmentEllipsisMaximumTokens
        case fragmentTerminalMarkers
        case titleMinimumTokens
        case declarativeMinimumTokens
        case numericPayloadMinimumCount
        case questionPunctuationCharacters
        case lineBoundaryCharacters
        case sentenceBoundaryCharacters
        case namedEntitySeparatorCharacters
        case spanTrailingTrimCharacters
        case addressSeparatorTrimCharacters
        case codeIdentifierCharacters
        case codeIdentifierPatterns
        case plainTextSeparatorCharacters
        case compactScriptScalarRanges
        case tokenizationStrategy
        case compactScriptMinimumMeaningfulTokenLength
        case namedEntityRecognitionStrategy
    }

    init(from decoder: Decoder) throws {
        let fallback = QuestionTextSegmentationPolicy.fallback
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            minimumFrameCharacters: try container.decodeIfPresent(Int.self, forKey: .minimumFrameCharacters) ?? fallback.minimumFrameCharacters,
            minimumMeaningfulTokenLength: try container.decodeIfPresent(Int.self, forKey: .minimumMeaningfulTokenLength) ?? fallback.minimumMeaningfulTokenLength,
            minimumNamedEntityTokenLength: try container.decodeIfPresent(Int.self, forKey: .minimumNamedEntityTokenLength) ?? fallback.minimumNamedEntityTokenLength,
            minimumNamedEntityLetterCount: try container.decodeIfPresent(Int.self, forKey: .minimumNamedEntityLetterCount) ?? fallback.minimumNamedEntityLetterCount,
            namedEntityUppercaseMinimum: try container.decodeIfPresent(Int.self, forKey: .namedEntityUppercaseMinimum) ?? fallback.namedEntityUppercaseMinimum,
            leadAddressMinimumTokens: try container.decodeIfPresent(Int.self, forKey: .leadAddressMinimumTokens) ?? fallback.leadAddressMinimumTokens,
            leadAddressMinimumTokenLength: try container.decodeIfPresent(Int.self, forKey: .leadAddressMinimumTokenLength) ?? fallback.leadAddressMinimumTokenLength,
            questionCueLeadTokenLimit: try container.decodeIfPresent(Int.self, forKey: .questionCueLeadTokenLimit) ?? fallback.questionCueLeadTokenLimit,
            fragmentEllipsisMaximumTokens: try container.decodeIfPresent(Int.self, forKey: .fragmentEllipsisMaximumTokens) ?? fallback.fragmentEllipsisMaximumTokens,
            fragmentTerminalMarkers: try container.decodeIfPresent([String].self, forKey: .fragmentTerminalMarkers) ?? fallback.fragmentTerminalMarkers,
            titleMinimumTokens: try container.decodeIfPresent(Int.self, forKey: .titleMinimumTokens) ?? fallback.titleMinimumTokens,
            declarativeMinimumTokens: try container.decodeIfPresent(Int.self, forKey: .declarativeMinimumTokens) ?? fallback.declarativeMinimumTokens,
            numericPayloadMinimumCount: try container.decodeIfPresent(Int.self, forKey: .numericPayloadMinimumCount) ?? fallback.numericPayloadMinimumCount,
            questionPunctuationCharacters: try container.decodeIfPresent(String.self, forKey: .questionPunctuationCharacters) ?? fallback.questionPunctuationCharacters,
            lineBoundaryCharacters: try container.decodeIfPresent(String.self, forKey: .lineBoundaryCharacters) ?? fallback.lineBoundaryCharacters,
            sentenceBoundaryCharacters: try container.decodeIfPresent(String.self, forKey: .sentenceBoundaryCharacters) ?? fallback.sentenceBoundaryCharacters,
            namedEntitySeparatorCharacters: try container.decodeIfPresent(String.self, forKey: .namedEntitySeparatorCharacters) ?? fallback.namedEntitySeparatorCharacters,
            spanTrailingTrimCharacters: try container.decodeIfPresent(String.self, forKey: .spanTrailingTrimCharacters) ?? fallback.spanTrailingTrimCharacters,
            addressSeparatorTrimCharacters: try container.decodeIfPresent(String.self, forKey: .addressSeparatorTrimCharacters) ?? fallback.addressSeparatorTrimCharacters,
            codeIdentifierCharacters: try container.decodeIfPresent(String.self, forKey: .codeIdentifierCharacters) ?? fallback.codeIdentifierCharacters,
            codeIdentifierPatterns: try container.decodeIfPresent([String].self, forKey: .codeIdentifierPatterns) ?? [],
            plainTextSeparatorCharacters: try container.decodeIfPresent(String.self, forKey: .plainTextSeparatorCharacters) ?? fallback.plainTextSeparatorCharacters,
            compactScriptScalarRanges: try container.decodeIfPresent([QuestionUnicodeScalarRangePolicy].self, forKey: .compactScriptScalarRanges) ?? fallback.compactScriptScalarRanges,
            tokenizationStrategy: try container.decodeIfPresent(QuestionTextTokenizationStrategy.self, forKey: .tokenizationStrategy) ?? fallback.tokenizationStrategy,
            compactScriptMinimumMeaningfulTokenLength: try container.decodeIfPresent(Int.self, forKey: .compactScriptMinimumMeaningfulTokenLength) ?? fallback.compactScriptMinimumMeaningfulTokenLength,
            namedEntityRecognitionStrategy: try container.decodeIfPresent(QuestionNamedEntityRecognitionStrategy.self, forKey: .namedEntityRecognitionStrategy) ?? fallback.namedEntityRecognitionStrategy
        )
    }

    func containsQuestionPunctuation(in text: String) -> Bool {
        text.contains { questionPunctuationCharacters.contains($0) }
    }

    func isLineBoundary(_ character: Character) -> Bool {
        lineBoundaryCharacters.contains(character)
    }

    func isSentenceBoundary(_ character: Character) -> Bool {
        sentenceBoundaryCharacters.contains(character)
    }

    func isNamedEntitySeparator(_ character: Character) -> Bool {
        character.isWhitespace || namedEntitySeparatorCharacters.contains(character)
    }

    func containsCodeIdentifierCharacter(in text: String) -> Bool {
        text.contains { codeIdentifierCharacters.contains($0) }
    }

    func containsCodeIdentifierPattern(in text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return codeIdentifierPatterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            return regex.firstMatch(in: text, range: range) != nil
        }
    }

    func containsCompactScript(in text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            compactScriptScalarRanges.contains { $0.contains(scalar) }
        }
    }

    func compactScriptCharacterCount(in text: String) -> Int {
        text.unicodeScalars.filter { scalar in
            compactScriptScalarRanges.contains { $0.contains(scalar) }
        }.count
    }

    func lexicalTokens(in text: String) -> [String] {
        let normalized = QuestionDetectionService.normalize(text)
        switch effectiveTokenizationStrategy(for: normalized) {
        case .naturalLanguage:
            let tokens = naturalLanguageTokens(in: normalized)
            return tokens.isEmpty ? scalarTokens(in: normalized) : tokens
        case .scalarSplit, .automatic:
            return scalarTokens(in: normalized)
        }
    }

    func lexicalTokenCount(in text: String) -> Int {
        lexicalTokens(in: text).count
    }

    func hasFragmentTerminalMarker(in text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return fragmentTerminalMarkers.contains { marker in
            let trimmedMarker = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmedMarker.isEmpty && trimmed.hasSuffix(trimmedMarker)
        }
    }

    func meaningfulTokenMinimumLength(for token: String) -> Int {
        containsCompactScript(in: token)
            ? min(minimumMeaningfulTokenLength, compactScriptMinimumMeaningfulTokenLength)
            : minimumMeaningfulTokenLength
    }

    func plainTextSeparatorPattern() -> String? {
        let escapedCharacters = plainTextSeparatorCharacters.map {
            NSRegularExpression.escapedPattern(for: String($0))
        }
        guard !escapedCharacters.isEmpty else { return nil }
        return "(?:\(escapedCharacters.joined(separator: "|")))+"
    }

    func containsMarker(_ marker: String, in normalizedText: String) -> Bool {
        let normalized = QuestionDetectionService.normalize(marker)
        let text = QuestionDetectionService.normalize(normalizedText)
        guard !normalized.isEmpty else { return false }
        if !containsTokenCharacter(in: normalized) {
            return text.contains(normalized)
        }
        if normalized.contains(" ") || containsCompactScript(in: normalized) {
            return text.contains(normalized)
        }
        return containsToken(normalized, in: text)
    }

    func containsBoundedMarker(_ marker: String, in normalizedText: String) -> Bool {
        let normalized = QuestionDetectionService.normalize(marker)
        let text = QuestionDetectionService.normalize(normalizedText)
        guard !normalized.isEmpty else { return false }
        if !containsTokenCharacter(in: normalized) || containsCompactScript(in: normalized) {
            return text.contains(normalized)
        }
        return containsBoundedText(normalized, in: text)
    }

    func matchesLeadMarker(_ marker: String, in normalizedText: String) -> Bool {
        let normalized = QuestionDetectionService.normalize(marker)
        guard !normalized.isEmpty else { return false }
        let text = QuestionDetectionService.normalize(normalizedText)
        guard text.hasPrefix(normalized) else { return false }
        guard let end = text.index(text.startIndex, offsetBy: normalized.count, limitedBy: text.endIndex) else {
            return false
        }
        guard end < text.endIndex else { return true }
        if !containsTokenCharacter(in: normalized) || !containsTokenCharacter(in: String(normalized.suffix(1))) {
            return true
        }
        return hasTokenBoundary(after: end, in: text)
    }

    func matchesLeadOrCompactMarker(_ marker: String, in normalizedText: String) -> Bool {
        let normalized = QuestionDetectionService.normalize(marker)
        guard !normalized.isEmpty else { return false }
        if containsCompactScript(in: normalized) {
            return containsMarker(normalized, in: normalizedText)
        }
        return matchesLeadMarker(normalized, in: normalizedText)
    }

    private func containsToken(_ token: String, in text: String) -> Bool {
        containsBoundedText(token, in: text)
    }

    private func containsBoundedText(_ token: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: token, range: searchStart..<text.endIndex) {
            if hasTokenBoundary(before: range.lowerBound, in: text)
                && hasTokenBoundary(after: range.upperBound, in: text) {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private func hasTokenBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        return !isTokenCharacter(text[text.index(before: index)])
    }

    private func hasTokenBoundary(after index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return true }
        return !isTokenCharacter(text[index])
    }

    private func containsTokenCharacter(in text: String) -> Bool {
        text.contains(where: isTokenCharacter)
    }

    private func isTokenCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
        }
    }

    private func effectiveTokenizationStrategy(for text: String) -> QuestionTextTokenizationStrategy {
        switch tokenizationStrategy {
        case .automatic:
            containsCompactScript(in: text) ? .naturalLanguage : .scalarSplit
        case .naturalLanguage, .scalarSplit:
            tokenizationStrategy
        }
    }

    private func scalarTokens(in normalizedText: String) -> [String] {
        normalizedText
            .split { character in
                !character.isLetter
                    && !character.isNumber
                    && !containsCodeIdentifierCharacter(in: String(character))
            }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func naturalLanguageTokens(in normalizedText: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalizedText
        let fullRange = normalizedText.startIndex..<normalizedText.endIndex
        return tokenizer.tokens(for: fullRange)
            .map { String(normalizedText[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                !token.isEmpty
                    && token.unicodeScalars.contains {
                        CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                    }
            }
    }
}

struct QuestionIntentRulePack: Codable, Hashable, Sendable {
    var directQuestionMarkers: [String]
    var indirectQuestionMarkers: [String]
    var actionRequestMarkers: [String]
    var modalQuestionStarters: [String]
    var rhetoricalMarkers: [String]
    var rhetoricalSuffixes: [String]
    var rhetoricalSuffixLeadSeparators: [String]
    var rhetoricalSuffixMinimumLeadTokens: Int
    var fragmentPhrases: Set<String>
    var fragmentPrefixes: Set<String>
    var exactSmallTalkPhrases: Set<String>
    var operationalNoAnswerPhrases: Set<String>
    var smallTalkContinuationWords: Set<String>
    var quotedOrExplainingMarkers: [String]
    var selfAnsweredMarkers: [String]
    var selfAnswerSuffixMarkers: [String]
    var lowInformationWords: Set<String>
    var stopWords: Set<String>
    var contextualPronouns: Set<String>
    var domainHintMarkers: [String]
    var discourseLeadPhrases: [String]
    var groupAddressMarkers: [String]
    var nonAddressLeadTokens: Set<String>
    var modalQuestionRejectPrefixes: [String]
    var modalQuestionConditionalPrefixes: [String]
    var modalQuestionConditionalObjectMarkers: [String]
    var nonQuestionTitleMarkers: [String]
    var declarativeBridgeMarkers: [String]
    var numericWords: Set<String>
    var numericOperatorMarkers: [String]
    var embeddedQuestionSplitMarkers: [String]
    var embeddedQuestionSplitPreambleMarkers: [String]
    var embeddedQuestionSplitContinuationLeadMarkers: [String]
    var embeddedQuestionSplitMaximumPreambleTokens: Int
    var hardSuppressionSignals: Set<String>
    var signalLabels: QuestionIntentSignalLabels
    var reasons: QuestionIntentReasonPolicy
    var surfaceScoring: QuestionSurfaceScoringPolicy?
    var surfaceCandidate: QuestionSurfaceCandidatePolicy?
    var gateScoring: QuestionIntentGateScoringPolicy?
    var textSegmentation: QuestionTextSegmentationPolicy?
    var contextualCue: QuestionContextualCuePolicy?
    var answerableScoreThreshold: Double
    var partialQuestionPenalty: Double

    static let `default` = QuestionIntentRulePackStore.current
}

enum QuestionIntentRulePackStore {
    static let current: QuestionIntentRulePack = load()

    private static func load() -> QuestionIntentRulePack {
        let decoder = JSONDecoder()
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let policy = try? decoder.decode(QuestionIntentRulePack.self, from: data) else {
                continue
            }
            return policy.normalized()
        }
        return fallbackRulePack()
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let bundles = [Bundle.main, Bundle(for: QuestionIntentRulePackBundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "question-intent-rulepack",
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
                .appendingPathComponent("Resources/CopilotIntentPolicy/question-intent-rulepack.json")
        )
        return urls
    }

    private static func fallbackRulePack() -> QuestionIntentRulePack {
        QuestionIntentRulePack(
            directQuestionMarkers: [],
            indirectQuestionMarkers: [],
            actionRequestMarkers: [],
            modalQuestionStarters: [],
            rhetoricalMarkers: [],
            rhetoricalSuffixes: [],
            rhetoricalSuffixLeadSeparators: [],
            rhetoricalSuffixMinimumLeadTokens: 3,
            fragmentPhrases: [],
            fragmentPrefixes: [],
            exactSmallTalkPhrases: [],
            operationalNoAnswerPhrases: [],
            smallTalkContinuationWords: [],
            quotedOrExplainingMarkers: [],
            selfAnsweredMarkers: [],
            selfAnswerSuffixMarkers: [],
            lowInformationWords: [],
            stopWords: [],
            contextualPronouns: [],
            domainHintMarkers: [],
            discourseLeadPhrases: [],
            groupAddressMarkers: [],
            nonAddressLeadTokens: [],
            modalQuestionRejectPrefixes: [],
            modalQuestionConditionalPrefixes: [],
            modalQuestionConditionalObjectMarkers: [],
            nonQuestionTitleMarkers: [],
            declarativeBridgeMarkers: [],
            numericWords: [],
            numericOperatorMarkers: [],
            embeddedQuestionSplitMarkers: [],
            embeddedQuestionSplitPreambleMarkers: [],
            embeddedQuestionSplitContinuationLeadMarkers: [],
            embeddedQuestionSplitMaximumPreambleTokens: 0,
            hardSuppressionSignals: QuestionIntentSignalLabels.fallback.hardSuppressionSignals,
            signalLabels: .fallback,
            reasons: .fallback,
            surfaceScoring: .fallback,
            surfaceCandidate: .fallback,
            gateScoring: .fallback,
            textSegmentation: .fallback,
            contextualCue: .fallback,
            answerableScoreThreshold: 1.45,
            partialQuestionPenalty: 0.2
        )
    }
}

private final class QuestionIntentRulePackBundleMarker {}

private struct QuestionIntentPolicyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private extension KeyedDecodingContainer where Key == QuestionIntentPolicyCodingKey {
    func decodePolicyValue<T: Decodable>(
        _ type: T.Type,
        _ key: String,
        default defaultValue: @autoclosure () -> T
    ) throws -> T {
        try decodeIfPresent(type, key) ?? defaultValue()
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        guard let codingKey = QuestionIntentPolicyCodingKey(stringValue: key) else { return nil }
        return try decodeIfPresent(type, forKey: codingKey)
    }
}

extension QuestionIntentSignalLabels {
    init(from decoder: Decoder) throws {
        let fallback = QuestionIntentSignalLabels.fallback
        let container = try decoder.container(keyedBy: QuestionIntentPolicyCodingKey.self)
        self.init(
            empty: try container.decodePolicyValue(String.self, "empty", default: fallback.empty),
            smallTalk: try container.decodePolicyValue(String.self, "smallTalk", default: fallback.smallTalk),
            operationalCheck: try container.decodePolicyValue(String.self, "operationalCheck", default: fallback.operationalCheck),
            reportedQuestion: try container.decodePolicyValue(String.self, "reportedQuestion", default: fallback.reportedQuestion),
            rhetorical: try container.decodePolicyValue(String.self, "rhetorical", default: fallback.rhetorical),
            selfAnswered: try container.decodePolicyValue(String.self, "selfAnswered", default: fallback.selfAnswered),
            fragment: try container.decodePolicyValue(String.self, "fragment", default: fallback.fragment),
            nounPhraseOrTitle: try container.decodePolicyValue(String.self, "nounPhraseOrTitle", default: fallback.nounPhraseOrTitle),
            adaptiveSuppressed: try container.decodePolicyValue(String.self, "adaptiveSuppressed", default: fallback.adaptiveSuppressed),
            declarativeWithoutInterrogativeSyntax: try container.decodePolicyValue(
                String.self,
                "declarativeWithoutInterrogativeSyntax",
                default: fallback.declarativeWithoutInterrogativeSyntax
            )
        )
    }
}

extension QuestionIntentReasonPolicy {
    init(from decoder: Decoder) throws {
        let fallback = QuestionIntentReasonPolicy.fallback
        let container = try decoder.container(keyedBy: QuestionIntentPolicyCodingKey.self)
        self.init(
            fragmentIncomplete: try container.decodePolicyValue(String.self, "fragmentIncomplete", default: fallback.fragmentIncomplete),
            rhetorical: try container.decodePolicyValue(String.self, "rhetorical", default: fallback.rhetorical),
            quotedPastQuestion: try container.decodePolicyValue(String.self, "quotedPastQuestion", default: fallback.quotedPastQuestion),
            selfAnswered: try container.decodePolicyValue(String.self, "selfAnswered", default: fallback.selfAnswered),
            answerable: try container.decodePolicyValue(String.self, "answerable", default: fallback.answerable),
            adaptivePromoted: try container.decodePolicyValue(String.self, "adaptivePromoted", default: fallback.adaptivePromoted),
            insufficientIntentObject: try container.decodePolicyValue(String.self, "insufficientIntentObject", default: fallback.insufficientIntentObject),
            clearIntentObject: try container.decodePolicyValue(String.self, "clearIntentObject", default: fallback.clearIntentObject),
            fragmentNoObject: try container.decodePolicyValue(String.self, "fragmentNoObject", default: fallback.fragmentNoObject),
            smallTalk: try container.decodePolicyValue(String.self, "smallTalk", default: fallback.smallTalk),
            quotedOrExplaining: try container.decodePolicyValue(String.self, "quotedOrExplaining", default: fallback.quotedOrExplaining),
            adaptiveSuppressed: try container.decodePolicyValue(String.self, "adaptiveSuppressed", default: fallback.adaptiveSuppressed),
            highPrecisionInsufficient: try container.decodePolicyValue(String.self, "highPrecisionInsufficient", default: fallback.highPrecisionInsufficient),
            localAnswerableTemplate: try container.decodePolicyValue(String.self, "localAnswerableTemplate", default: fallback.localAnswerableTemplate),
            operationalCheck: try container.decodePolicyValue(String.self, "operationalCheck", default: fallback.operationalCheck),
            titleOrStatement: try container.decodePolicyValue(String.self, "titleOrStatement", default: fallback.titleOrStatement),
            ambiguous: try container.decodePolicyValue(String.self, "ambiguous", default: fallback.ambiguous),
            surfaceBelowCandidateThreshold: try container.decodePolicyValue(String.self, "surfaceBelowCandidateThreshold", default: fallback.surfaceBelowCandidateThreshold)
        )
    }
}

extension QuestionSurfaceScoringPolicy {
    init(from decoder: Decoder) throws {
        let fallback = QuestionSurfaceScoringPolicy.fallback
        let container = try decoder.container(keyedBy: QuestionIntentPolicyCodingKey.self)
        self.init(
            answerableObjectFocusThreshold: try container.decodePolicyValue(Double.self, "answerableObjectFocusThreshold", default: fallback.answerableObjectFocusThreshold),
            questionLikeThreshold: try container.decodePolicyValue(Double.self, "questionLikeThreshold", default: fallback.questionLikeThreshold),
            rejectedConfidence: try container.decodePolicyValue(Double.self, "rejectedConfidence", default: fallback.rejectedConfidence),
            confidenceBase: try container.decodePolicyValue(Double.self, "confidenceBase", default: fallback.confidenceBase),
            questionPunctuationConfidence: try container.decodePolicyValue(Double.self, "questionPunctuationConfidence", default: fallback.questionPunctuationConfidence),
            interrogativeConfidence: try container.decodePolicyValue(Double.self, "interrogativeConfidence", default: fallback.interrogativeConfidence),
            modalConfidence: try container.decodePolicyValue(Double.self, "modalConfidence", default: fallback.modalConfidence),
            indirectConfidence: try container.decodePolicyValue(Double.self, "indirectConfidence", default: fallback.indirectConfidence),
            actionConfidence: try container.decodePolicyValue(Double.self, "actionConfidence", default: fallback.actionConfidence),
            directedUserConfidence: try container.decodePolicyValue(Double.self, "directedUserConfidence", default: fallback.directedUserConfidence),
            directedGroupConfidence: try container.decodePolicyValue(Double.self, "directedGroupConfidence", default: fallback.directedGroupConfidence),
            concreteObjectConfidence: try container.decodePolicyValue(Double.self, "concreteObjectConfidence", default: fallback.concreteObjectConfidence),
            domainObjectConfidence: try container.decodePolicyValue(Double.self, "domainObjectConfidence", default: fallback.domainObjectConfidence),
            semanticShapeConfidenceMax: try container.decodePolicyValue(Double.self, "semanticShapeConfidenceMax", default: fallback.semanticShapeConfidenceMax),
            semanticShapeConfidenceWeight: try container.decodePolicyValue(Double.self, "semanticShapeConfidenceWeight", default: fallback.semanticShapeConfidenceWeight),
            answerableFocusConfidenceMax: try container.decodePolicyValue(Double.self, "answerableFocusConfidenceMax", default: fallback.answerableFocusConfidenceMax),
            answerableFocusConfidenceWeight: try container.decodePolicyValue(Double.self, "answerableFocusConfidenceWeight", default: fallback.answerableFocusConfidenceWeight),
            adaptivePromotionConfidence: try container.decodePolicyValue(Double.self, "adaptivePromotionConfidence", default: fallback.adaptivePromotionConfidence),
            contextualCarryoverConfidence: try container.decodePolicyValue(Double.self, "contextualCarryoverConfidence", default: fallback.contextualCarryoverConfidence),
            finalUtteranceConfidence: try container.decodePolicyValue(Double.self, "finalUtteranceConfidence", default: fallback.finalUtteranceConfidence),
            weakQuestionWordPenalty: try container.decodePolicyValue(Double.self, "weakQuestionWordPenalty", default: fallback.weakQuestionWordPenalty),
            partialHighPrecisionPenalty: try container.decodePolicyValue(Double.self, "partialHighPrecisionPenalty", default: fallback.partialHighPrecisionPenalty),
            partialStandardPenalty: try container.decodePolicyValue(Double.self, "partialStandardPenalty", default: fallback.partialStandardPenalty),
            minConfidence: try container.decodePolicyValue(Double.self, "minConfidence", default: fallback.minConfidence),
            maxConfidence: try container.decodePolicyValue(Double.self, "maxConfidence", default: fallback.maxConfidence),
            insufficientSurfaceConfidenceCeiling: try container.decodePolicyValue(
                Double.self,
                "insufficientSurfaceConfidenceCeiling",
                default: fallback.insufficientSurfaceConfidenceCeiling
            ),
            adaptiveCandidateObjectThreshold: try container.decodePolicyValue(Double.self, "adaptiveCandidateObjectThreshold", default: fallback.adaptiveCandidateObjectThreshold),
            semanticCandidateQuestionThreshold: try container.decodePolicyValue(Double.self, "semanticCandidateQuestionThreshold", default: fallback.semanticCandidateQuestionThreshold),
            objectMeaningfulTokenWeight: try container.decodePolicyValue(Double.self, "objectMeaningfulTokenWeight", default: fallback.objectMeaningfulTokenWeight),
            objectMeaningfulTokenMax: try container.decodePolicyValue(Double.self, "objectMeaningfulTokenMax", default: fallback.objectMeaningfulTokenMax),
            objectDensityWeight: try container.decodePolicyValue(Double.self, "objectDensityWeight", default: fallback.objectDensityWeight),
            objectDensityMax: try container.decodePolicyValue(Double.self, "objectDensityMax", default: fallback.objectDensityMax),
            objectNumericPayloadBonus: try container.decodePolicyValue(Double.self, "objectNumericPayloadBonus", default: fallback.objectNumericPayloadBonus),
            objectDomainBonus: try container.decodePolicyValue(Double.self, "objectDomainBonus", default: fallback.objectDomainBonus),
            objectContextOverlapBonus: try container.decodePolicyValue(Double.self, "objectContextOverlapBonus", default: fallback.objectContextOverlapBonus),
            objectNamedEntityBonus: try container.decodePolicyValue(Double.self, "objectNamedEntityBonus", default: fallback.objectNamedEntityBonus),
            objectCJKBonus: try container.decodePolicyValue(Double.self, "objectCJKBonus", default: fallback.objectCJKBonus),
            questionPunctuationScore: try container.decodePolicyValue(Double.self, "questionPunctuationScore", default: fallback.questionPunctuationScore),
            questionInterrogativeScore: try container.decodePolicyValue(Double.self, "questionInterrogativeScore", default: fallback.questionInterrogativeScore),
            questionModalScore: try container.decodePolicyValue(Double.self, "questionModalScore", default: fallback.questionModalScore),
            questionIndirectScore: try container.decodePolicyValue(Double.self, "questionIndirectScore", default: fallback.questionIndirectScore),
            questionActionScore: try container.decodePolicyValue(Double.self, "questionActionScore", default: fallback.questionActionScore),
            questionCueNearLeadScore: try container.decodePolicyValue(Double.self, "questionCueNearLeadScore", default: fallback.questionCueNearLeadScore),
            questionCompactUtteranceScore: try container.decodePolicyValue(Double.self, "questionCompactUtteranceScore", default: fallback.questionCompactUtteranceScore),
            questionCompactObjectThreshold: try container.decodePolicyValue(Double.self, "questionCompactObjectThreshold", default: fallback.questionCompactObjectThreshold),
            questionContextOverlapScore: try container.decodePolicyValue(Double.self, "questionContextOverlapScore", default: fallback.questionContextOverlapScore),
            questionNamedEntityScore: try container.decodePolicyValue(Double.self, "questionNamedEntityScore", default: fallback.questionNamedEntityScore),
            questionCJKScore: try container.decodePolicyValue(Double.self, "questionCJKScore", default: fallback.questionCJKScore),
            questionCJKObjectThreshold: try container.decodePolicyValue(Double.self, "questionCJKObjectThreshold", default: fallback.questionCJKObjectThreshold),
            questionFinalUtteranceScore: try container.decodePolicyValue(Double.self, "questionFinalUtteranceScore", default: fallback.questionFinalUtteranceScore),
            compactUtteranceMinTokens: try container.decodePolicyValue(Int.self, "compactUtteranceMinTokens", default: fallback.compactUtteranceMinTokens),
            compactUtteranceMaxTokens: try container.decodePolicyValue(Int.self, "compactUtteranceMaxTokens", default: fallback.compactUtteranceMaxTokens),
            cjkMinimumCharacters: try container.decodePolicyValue(Int.self, "cjkMinimumCharacters", default: fallback.cjkMinimumCharacters),
            contextOverlapMaximumRequiredMatches: try container.decodePolicyValue(Int.self, "contextOverlapMaximumRequiredMatches", default: fallback.contextOverlapMaximumRequiredMatches),
            contextualCarryoverMinimumRecentTerms: try container.decodePolicyValue(Int.self, "contextualCarryoverMinimumRecentTerms", default: fallback.contextualCarryoverMinimumRecentTerms)
        )
    }
}

extension QuestionIntentGateScoringPolicy {
    init(from decoder: Decoder) throws {
        let fallback = QuestionIntentGateScoringPolicy.fallback
        let container = try decoder.container(keyedBy: QuestionIntentPolicyCodingKey.self)
        self.init(
            adaptivePromotedConfidence: try container.decodePolicyValue(Double.self, "adaptivePromotedConfidence", default: fallback.adaptivePromotedConfidence),
            insufficientMinimumConfidence: try container.decodePolicyValue(Double.self, "insufficientMinimumConfidence", default: fallback.insufficientMinimumConfidence),
            insufficientMaximumConfidence: try container.decodePolicyValue(Double.self, "insufficientMaximumConfidence", default: fallback.insufficientMaximumConfidence),
            acceptedConfidenceBase: try container.decodePolicyValue(Double.self, "acceptedConfidenceBase", default: fallback.acceptedConfidenceBase),
            acceptedConfidenceDeltaWeight: try container.decodePolicyValue(Double.self, "acceptedConfidenceDeltaWeight", default: fallback.acceptedConfidenceDeltaWeight),
            acceptedMinimumConfidence: try container.decodePolicyValue(Double.self, "acceptedMinimumConfidence", default: fallback.acceptedMinimumConfidence),
            acceptedMaximumConfidence: try container.decodePolicyValue(Double.self, "acceptedMaximumConfidence", default: fallback.acceptedMaximumConfidence),
            fragmentSuppressionConfidence: try container.decodePolicyValue(Double.self, "fragmentSuppressionConfidence", default: fallback.fragmentSuppressionConfidence),
            smallTalkSuppressionConfidence: try container.decodePolicyValue(Double.self, "smallTalkSuppressionConfidence", default: fallback.smallTalkSuppressionConfidence),
            quotedSuppressionConfidence: try container.decodePolicyValue(Double.self, "quotedSuppressionConfidence", default: fallback.quotedSuppressionConfidence),
            selfAnsweredSuppressionConfidence: try container.decodePolicyValue(Double.self, "selfAnsweredSuppressionConfidence", default: fallback.selfAnsweredSuppressionConfidence),
            rhetoricalSuppressionConfidence: try container.decodePolicyValue(Double.self, "rhetoricalSuppressionConfidence", default: fallback.rhetoricalSuppressionConfidence),
            adaptiveSuppressedConfidence: try container.decodePolicyValue(Double.self, "adaptiveSuppressedConfidence", default: fallback.adaptiveSuppressedConfidence),
            embeddedQuestionRecoveryBonus: try container.decodePolicyValue(Double.self, "embeddedQuestionRecoveryBonus", default: fallback.embeddedQuestionRecoveryBonus),
            answerableThresholdMinimum: try container.decodePolicyValue(Double.self, "answerableThresholdMinimum", default: fallback.answerableThresholdMinimum),
            answerableThresholdMaximum: try container.decodePolicyValue(Double.self, "answerableThresholdMaximum", default: fallback.answerableThresholdMaximum),
            questionPunctuationWeight: try container.decodePolicyValue(Double.self, "questionPunctuationWeight", default: fallback.questionPunctuationWeight),
            directQuestionMarkerWeight: try container.decodePolicyValue(Double.self, "directQuestionMarkerWeight", default: fallback.directQuestionMarkerWeight),
            indirectQuestionMarkerWeight: try container.decodePolicyValue(Double.self, "indirectQuestionMarkerWeight", default: fallback.indirectQuestionMarkerWeight),
            actionRequestMarkerWeight: try container.decodePolicyValue(Double.self, "actionRequestMarkerWeight", default: fallback.actionRequestMarkerWeight),
            modalQuestionStarterWeight: try container.decodePolicyValue(Double.self, "modalQuestionStarterWeight", default: fallback.modalQuestionStarterWeight),
            domainHintWeight: try container.decodePolicyValue(Double.self, "domainHintWeight", default: fallback.domainHintWeight),
            numericPayloadWeight: try container.decodePolicyValue(Double.self, "numericPayloadWeight", default: fallback.numericPayloadWeight),
            meaningfulTokenWeight: try container.decodePolicyValue(Double.self, "meaningfulTokenWeight", default: fallback.meaningfulTokenWeight),
            meaningfulTokenMaximum: try container.decodePolicyValue(Double.self, "meaningfulTokenMaximum", default: fallback.meaningfulTokenMaximum),
            codeIdentifierWeight: try container.decodePolicyValue(Double.self, "codeIdentifierWeight", default: fallback.codeIdentifierWeight),
            cjkWeight: try container.decodePolicyValue(Double.self, "cjkWeight", default: fallback.cjkWeight),
            cjkMinimumCharacters: try container.decodePolicyValue(Int.self, "cjkMinimumCharacters", default: fallback.cjkMinimumCharacters),
            contextualCarryoverWeight: try container.decodePolicyValue(Double.self, "contextualCarryoverWeight", default: fallback.contextualCarryoverWeight),
            surfaceSemanticShapeBonus: try container.decodePolicyValue(Double.self, "surfaceSemanticShapeBonus", default: fallback.surfaceSemanticShapeBonus),
            surfaceAnswerableObjectBonus: try container.decodePolicyValue(Double.self, "surfaceAnswerableObjectBonus", default: fallback.surfaceAnswerableObjectBonus),
            surfaceAdaptivePromotionBonus: try container.decodePolicyValue(Double.self, "surfaceAdaptivePromotionBonus", default: fallback.surfaceAdaptivePromotionBonus),
            concreteObjectCJKMinimumCharacters: try container.decodePolicyValue(Int.self, "concreteObjectCJKMinimumCharacters", default: fallback.concreteObjectCJKMinimumCharacters),
            contextualCarryoverMinimumRecentTerms: try container.decodePolicyValue(Int.self, "contextualCarryoverMinimumRecentTerms", default: fallback.contextualCarryoverMinimumRecentTerms)
        )
    }
}

extension QuestionIntentRulePack {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: QuestionIntentPolicyCodingKey.self)
        self.init(
            directQuestionMarkers: try container.decodePolicyValue([String].self, "directQuestionMarkers", default: []),
            indirectQuestionMarkers: try container.decodePolicyValue([String].self, "indirectQuestionMarkers", default: []),
            actionRequestMarkers: try container.decodePolicyValue([String].self, "actionRequestMarkers", default: []),
            modalQuestionStarters: try container.decodePolicyValue([String].self, "modalQuestionStarters", default: []),
            rhetoricalMarkers: try container.decodePolicyValue([String].self, "rhetoricalMarkers", default: []),
            rhetoricalSuffixes: try container.decodePolicyValue([String].self, "rhetoricalSuffixes", default: []),
            rhetoricalSuffixLeadSeparators: try container.decodePolicyValue([String].self, "rhetoricalSuffixLeadSeparators", default: []),
            rhetoricalSuffixMinimumLeadTokens: try container.decodePolicyValue(Int.self, "rhetoricalSuffixMinimumLeadTokens", default: 3),
            fragmentPhrases: try container.decodePolicyValue(Set<String>.self, "fragmentPhrases", default: []),
            fragmentPrefixes: try container.decodePolicyValue(Set<String>.self, "fragmentPrefixes", default: []),
            exactSmallTalkPhrases: try container.decodePolicyValue(Set<String>.self, "exactSmallTalkPhrases", default: []),
            operationalNoAnswerPhrases: try container.decodePolicyValue(Set<String>.self, "operationalNoAnswerPhrases", default: []),
            smallTalkContinuationWords: try container.decodePolicyValue(Set<String>.self, "smallTalkContinuationWords", default: []),
            quotedOrExplainingMarkers: try container.decodePolicyValue([String].self, "quotedOrExplainingMarkers", default: []),
            selfAnsweredMarkers: try container.decodePolicyValue([String].self, "selfAnsweredMarkers", default: []),
            selfAnswerSuffixMarkers: try container.decodePolicyValue([String].self, "selfAnswerSuffixMarkers", default: []),
            lowInformationWords: try container.decodePolicyValue(Set<String>.self, "lowInformationWords", default: []),
            stopWords: try container.decodePolicyValue(Set<String>.self, "stopWords", default: []),
            contextualPronouns: try container.decodePolicyValue(Set<String>.self, "contextualPronouns", default: []),
            domainHintMarkers: try container.decodePolicyValue([String].self, "domainHintMarkers", default: []),
            discourseLeadPhrases: try container.decodePolicyValue([String].self, "discourseLeadPhrases", default: []),
            groupAddressMarkers: try container.decodePolicyValue([String].self, "groupAddressMarkers", default: []),
            nonAddressLeadTokens: try container.decodePolicyValue(Set<String>.self, "nonAddressLeadTokens", default: []),
            modalQuestionRejectPrefixes: try container.decodePolicyValue([String].self, "modalQuestionRejectPrefixes", default: []),
            modalQuestionConditionalPrefixes: try container.decodePolicyValue([String].self, "modalQuestionConditionalPrefixes", default: []),
            modalQuestionConditionalObjectMarkers: try container.decodePolicyValue([String].self, "modalQuestionConditionalObjectMarkers", default: []),
            nonQuestionTitleMarkers: try container.decodePolicyValue([String].self, "nonQuestionTitleMarkers", default: []),
            declarativeBridgeMarkers: try container.decodePolicyValue([String].self, "declarativeBridgeMarkers", default: []),
            numericWords: try container.decodePolicyValue(Set<String>.self, "numericWords", default: []),
            numericOperatorMarkers: try container.decodePolicyValue([String].self, "numericOperatorMarkers", default: []),
            embeddedQuestionSplitMarkers: try container.decodePolicyValue([String].self, "embeddedQuestionSplitMarkers", default: []),
            embeddedQuestionSplitPreambleMarkers: try container.decodePolicyValue([String].self, "embeddedQuestionSplitPreambleMarkers", default: []),
            embeddedQuestionSplitContinuationLeadMarkers: try container.decodePolicyValue([String].self, "embeddedQuestionSplitContinuationLeadMarkers", default: []),
            embeddedQuestionSplitMaximumPreambleTokens: try container.decodePolicyValue(Int.self, "embeddedQuestionSplitMaximumPreambleTokens", default: 0),
            hardSuppressionSignals: try container.decodePolicyValue(Set<String>.self, "hardSuppressionSignals", default: []),
            signalLabels: try container.decodePolicyValue(QuestionIntentSignalLabels.self, "signalLabels", default: .fallback),
            reasons: try container.decodePolicyValue(QuestionIntentReasonPolicy.self, "reasons", default: .fallback),
            surfaceScoring: try container.decodeIfPresent(QuestionSurfaceScoringPolicy.self, "surfaceScoring"),
            surfaceCandidate: try container.decodeIfPresent(QuestionSurfaceCandidatePolicy.self, "surfaceCandidate"),
            gateScoring: try container.decodeIfPresent(QuestionIntentGateScoringPolicy.self, "gateScoring"),
            textSegmentation: try container.decodeIfPresent(QuestionTextSegmentationPolicy.self, "textSegmentation"),
            contextualCue: try container.decodeIfPresent(QuestionContextualCuePolicy.self, "contextualCue"),
            answerableScoreThreshold: try container.decodePolicyValue(Double.self, "answerableScoreThreshold", default: 1.45),
            partialQuestionPenalty: try container.decodePolicyValue(Double.self, "partialQuestionPenalty", default: 0.2)
        )
    }
}

private extension QuestionIntentRulePack {
    func normalized() -> QuestionIntentRulePack {
        QuestionIntentRulePack(
            directQuestionMarkers: directQuestionMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            indirectQuestionMarkers: indirectQuestionMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            actionRequestMarkers: actionRequestMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            modalQuestionStarters: modalQuestionStarters.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            rhetoricalMarkers: rhetoricalMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            rhetoricalSuffixes: rhetoricalSuffixes.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            rhetoricalSuffixLeadSeparators: rhetoricalSuffixLeadSeparators
                .map(\.trimmedQuestionIntentPolicy)
                .filter { !$0.isEmpty },
            rhetoricalSuffixMinimumLeadTokens: max(1, rhetoricalSuffixMinimumLeadTokens),
            fragmentPhrases: Set(fragmentPhrases.map(QuestionDetectionService.normalize).filter { !$0.isEmpty }),
            fragmentPrefixes: Set(fragmentPrefixes.map(QuestionDetectionService.normalize).filter { !$0.isEmpty }),
            exactSmallTalkPhrases: Set(exactSmallTalkPhrases.map(QuestionDetectionService.normalize).filter { !$0.isEmpty }),
            operationalNoAnswerPhrases: Set(operationalNoAnswerPhrases.map(QuestionDetectionService.normalize).filter { !$0.isEmpty }),
            smallTalkContinuationWords: Set(smallTalkContinuationWords.map(QuestionDetectionService.normalize).filter { !$0.isEmpty }),
            quotedOrExplainingMarkers: quotedOrExplainingMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            selfAnsweredMarkers: selfAnsweredMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            selfAnswerSuffixMarkers: selfAnswerSuffixMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            lowInformationWords: Set(lowInformationWords.map(QuestionDetectionService.normalize).filter { !$0.isEmpty }),
            stopWords: Set(stopWords.map(QuestionDetectionService.normalize).filter { !$0.isEmpty }),
            contextualPronouns: Set(contextualPronouns.map(QuestionDetectionService.normalize).filter { !$0.isEmpty }),
            domainHintMarkers: domainHintMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            discourseLeadPhrases: discourseLeadPhrases.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            groupAddressMarkers: groupAddressMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            nonAddressLeadTokens: Set(nonAddressLeadTokens.map(QuestionDetectionService.normalize).filter { !$0.isEmpty }),
            modalQuestionRejectPrefixes: modalQuestionRejectPrefixes.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            modalQuestionConditionalPrefixes: modalQuestionConditionalPrefixes.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            modalQuestionConditionalObjectMarkers: modalQuestionConditionalObjectMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            nonQuestionTitleMarkers: nonQuestionTitleMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            declarativeBridgeMarkers: declarativeBridgeMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            numericWords: Set(numericWords.map(QuestionDetectionService.normalize).filter { !$0.isEmpty }),
            numericOperatorMarkers: numericOperatorMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            embeddedQuestionSplitMarkers: embeddedQuestionSplitMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            embeddedQuestionSplitPreambleMarkers: embeddedQuestionSplitPreambleMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            embeddedQuestionSplitContinuationLeadMarkers: embeddedQuestionSplitContinuationLeadMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            embeddedQuestionSplitMaximumPreambleTokens: max(0, embeddedQuestionSplitMaximumPreambleTokens),
            hardSuppressionSignals: Set(hardSuppressionSignals.map(\.trimmedQuestionIntentPolicy).filter { !$0.isEmpty }),
            signalLabels: signalLabels.normalized(),
            reasons: reasons.normalized(),
            surfaceScoring: surfaceScoring?.normalized() ?? .fallback,
            surfaceCandidate: surfaceCandidate?.normalized() ?? .fallback,
            gateScoring: gateScoring?.normalized() ?? .fallback,
            textSegmentation: textSegmentation?.normalized() ?? .fallback,
            contextualCue: contextualCue?.normalized() ?? .fallback,
            answerableScoreThreshold: answerableScoreThreshold,
            partialQuestionPenalty: partialQuestionPenalty
        )
    }
}

extension QuestionIntentRulePack {
    var surfaceScoringPolicy: QuestionSurfaceScoringPolicy {
        surfaceScoring ?? .fallback
    }

    var surfaceCandidatePolicy: QuestionSurfaceCandidatePolicy {
        surfaceCandidate ?? .fallback
    }

    var gateScoringPolicy: QuestionIntentGateScoringPolicy {
        gateScoring ?? .fallback
    }

    var textSegmentationPolicy: QuestionTextSegmentationPolicy {
        textSegmentation ?? .fallback
    }

    var contextualCuePolicy: QuestionContextualCuePolicy {
        contextualCue ?? .fallback
    }
}

private extension QuestionTextSegmentationPolicy {
    func normalized() -> QuestionTextSegmentationPolicy {
        let fallback = QuestionTextSegmentationPolicy.fallback
        let compactScriptRanges = compactScriptScalarRanges.compactMap { $0.normalized() }
        let terminalMarkers = fragmentTerminalMarkers
            .map(\.trimmedQuestionIntentPolicy)
            .filter { !$0.isEmpty }
        return QuestionTextSegmentationPolicy(
            minimumFrameCharacters: max(1, minimumFrameCharacters),
            minimumMeaningfulTokenLength: max(1, minimumMeaningfulTokenLength),
            minimumNamedEntityTokenLength: max(1, minimumNamedEntityTokenLength),
            minimumNamedEntityLetterCount: max(1, minimumNamedEntityLetterCount),
            namedEntityUppercaseMinimum: max(1, namedEntityUppercaseMinimum),
            leadAddressMinimumTokens: max(1, leadAddressMinimumTokens),
            leadAddressMinimumTokenLength: max(1, leadAddressMinimumTokenLength),
            questionCueLeadTokenLimit: max(1, questionCueLeadTokenLimit),
            fragmentEllipsisMaximumTokens: max(1, fragmentEllipsisMaximumTokens),
            fragmentTerminalMarkers: terminalMarkers.isEmpty ? fallback.fragmentTerminalMarkers : terminalMarkers,
            titleMinimumTokens: max(1, titleMinimumTokens),
            declarativeMinimumTokens: max(1, declarativeMinimumTokens),
            numericPayloadMinimumCount: max(1, numericPayloadMinimumCount),
            questionPunctuationCharacters: questionPunctuationCharacters.nilIfEmptyPolicy ?? fallback.questionPunctuationCharacters,
            lineBoundaryCharacters: lineBoundaryCharacters.nilIfEmptyPolicy ?? fallback.lineBoundaryCharacters,
            sentenceBoundaryCharacters: sentenceBoundaryCharacters.nilIfEmptyPolicy ?? fallback.sentenceBoundaryCharacters,
            namedEntitySeparatorCharacters: namedEntitySeparatorCharacters.nilIfEmptyPolicy ?? fallback.namedEntitySeparatorCharacters,
            spanTrailingTrimCharacters: spanTrailingTrimCharacters.nilIfEmptyPolicy ?? fallback.spanTrailingTrimCharacters,
            addressSeparatorTrimCharacters: addressSeparatorTrimCharacters.nilIfEmptyPolicy ?? fallback.addressSeparatorTrimCharacters,
            codeIdentifierCharacters: codeIdentifierCharacters.nilIfEmptyPolicy ?? fallback.codeIdentifierCharacters,
            codeIdentifierPatterns: codeIdentifierPatterns
                .map(\.trimmedQuestionIntentPolicy)
                .filter { !$0.isEmpty },
            plainTextSeparatorCharacters: plainTextSeparatorCharacters.nilIfEmptyPolicy ?? fallback.plainTextSeparatorCharacters,
            compactScriptScalarRanges: compactScriptRanges.isEmpty ? fallback.compactScriptScalarRanges : compactScriptRanges,
            tokenizationStrategy: tokenizationStrategy,
            compactScriptMinimumMeaningfulTokenLength: max(1, compactScriptMinimumMeaningfulTokenLength),
            namedEntityRecognitionStrategy: namedEntityRecognitionStrategy
        )
    }
}

private extension QuestionSurfaceCandidatePolicy {
    func normalized() -> QuestionSurfaceCandidatePolicy {
        let groups = unpunctuatedGroups
            .map { $0.normalized() }
            .filter { !$0.all.isEmpty || !$0.any.isEmpty || $0.hasScoreThreshold || $0.requiresInterrogativeObject }
        return QuestionSurfaceCandidatePolicy(
            punctuatedAnySignals: punctuatedAnySignals,
            unpunctuatedGroups: groups,
            weakQuestionWordOnlySignals: weakQuestionWordOnlySignals
        )
    }
}

private extension QuestionContextualCuePolicy {
    func normalized() -> QuestionContextualCuePolicy {
        let normalizedMinimumSuffix = max(1, compactSuffixMinimumCharacters)
        let normalizedMaximumSuffix = max(normalizedMinimumSuffix, compactSuffixMaximumCharacters)
        return QuestionContextualCuePolicy(
            maximumQuestionExamples: max(1, maximumQuestionExamples),
            minimumLeadTokenLength: max(1, minimumLeadTokenLength),
            maximumLeadTokenCount: max(1, maximumLeadTokenCount),
            minimumMultiTokenObservations: max(1, minimumMultiTokenObservations),
            minimumSingleTokenObservations: max(1, minimumSingleTokenObservations),
            compactSuffixMinimumCharacters: normalizedMinimumSuffix,
            compactSuffixMaximumCharacters: normalizedMaximumSuffix,
            compactSuffixMinimumObservations: max(1, compactSuffixMinimumObservations)
        )
    }
}

private extension QuestionSignalGroupPolicy {
    var hasScoreThreshold: Bool {
        minStructuralQuestionScore != nil || minObjectFocusScore != nil
    }

    func normalized() -> QuestionSignalGroupPolicy {
        QuestionSignalGroupPolicy(
            all: all,
            any: any,
            minStructuralQuestionScore: minStructuralQuestionScore.map(clampedUnit),
            minObjectFocusScore: minObjectFocusScore.map(clampedUnit),
            requiresInterrogativeObject: requiresInterrogativeObject
        )
    }

    private func clampedUnit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private extension QuestionSurfaceScoringPolicy {
    func normalized() -> QuestionSurfaceScoringPolicy {
        let normalizedCompactMinimum = max(1, compactUtteranceMinTokens)
        let normalizedMinConfidence = clampedUnit(minConfidence)
        let normalizedMaxConfidence = max(normalizedMinConfidence, clampedUnit(maxConfidence))
        return QuestionSurfaceScoringPolicy(
            answerableObjectFocusThreshold: clampedUnit(answerableObjectFocusThreshold),
            questionLikeThreshold: clampedUnit(questionLikeThreshold),
            rejectedConfidence: clampedUnit(rejectedConfidence),
            confidenceBase: clampedUnit(confidenceBase),
            questionPunctuationConfidence: nonNegative(questionPunctuationConfidence),
            interrogativeConfidence: nonNegative(interrogativeConfidence),
            modalConfidence: nonNegative(modalConfidence),
            indirectConfidence: nonNegative(indirectConfidence),
            actionConfidence: nonNegative(actionConfidence),
            directedUserConfidence: nonNegative(directedUserConfidence),
            directedGroupConfidence: nonNegative(directedGroupConfidence),
            concreteObjectConfidence: nonNegative(concreteObjectConfidence),
            domainObjectConfidence: nonNegative(domainObjectConfidence),
            semanticShapeConfidenceMax: nonNegative(semanticShapeConfidenceMax),
            semanticShapeConfidenceWeight: nonNegative(semanticShapeConfidenceWeight),
            answerableFocusConfidenceMax: nonNegative(answerableFocusConfidenceMax),
            answerableFocusConfidenceWeight: nonNegative(answerableFocusConfidenceWeight),
            adaptivePromotionConfidence: nonNegative(adaptivePromotionConfidence),
            contextualCarryoverConfidence: nonNegative(contextualCarryoverConfidence),
            finalUtteranceConfidence: nonNegative(finalUtteranceConfidence),
            weakQuestionWordPenalty: nonNegative(weakQuestionWordPenalty),
            partialHighPrecisionPenalty: nonNegative(partialHighPrecisionPenalty),
            partialStandardPenalty: nonNegative(partialStandardPenalty),
            minConfidence: normalizedMinConfidence,
            maxConfidence: normalizedMaxConfidence,
            insufficientSurfaceConfidenceCeiling: min(
                max(insufficientSurfaceConfidenceCeiling, normalizedMinConfidence),
                normalizedMaxConfidence
            ),
            adaptiveCandidateObjectThreshold: clampedUnit(adaptiveCandidateObjectThreshold),
            semanticCandidateQuestionThreshold: clampedUnit(semanticCandidateQuestionThreshold),
            objectMeaningfulTokenWeight: nonNegative(objectMeaningfulTokenWeight),
            objectMeaningfulTokenMax: nonNegative(objectMeaningfulTokenMax),
            objectDensityWeight: nonNegative(objectDensityWeight),
            objectDensityMax: nonNegative(objectDensityMax),
            objectNumericPayloadBonus: nonNegative(objectNumericPayloadBonus),
            objectDomainBonus: nonNegative(objectDomainBonus),
            objectContextOverlapBonus: nonNegative(objectContextOverlapBonus),
            objectNamedEntityBonus: nonNegative(objectNamedEntityBonus),
            objectCJKBonus: nonNegative(objectCJKBonus),
            questionPunctuationScore: nonNegative(questionPunctuationScore),
            questionInterrogativeScore: nonNegative(questionInterrogativeScore),
            questionModalScore: nonNegative(questionModalScore),
            questionIndirectScore: nonNegative(questionIndirectScore),
            questionActionScore: nonNegative(questionActionScore),
            questionCueNearLeadScore: nonNegative(questionCueNearLeadScore),
            questionCompactUtteranceScore: nonNegative(questionCompactUtteranceScore),
            questionCompactObjectThreshold: clampedUnit(questionCompactObjectThreshold),
            questionContextOverlapScore: nonNegative(questionContextOverlapScore),
            questionNamedEntityScore: nonNegative(questionNamedEntityScore),
            questionCJKScore: nonNegative(questionCJKScore),
            questionCJKObjectThreshold: clampedUnit(questionCJKObjectThreshold),
            questionFinalUtteranceScore: nonNegative(questionFinalUtteranceScore),
            compactUtteranceMinTokens: normalizedCompactMinimum,
            compactUtteranceMaxTokens: max(normalizedCompactMinimum, compactUtteranceMaxTokens),
            cjkMinimumCharacters: max(1, cjkMinimumCharacters),
            contextOverlapMaximumRequiredMatches: max(1, contextOverlapMaximumRequiredMatches),
            contextualCarryoverMinimumRecentTerms: max(1, contextualCarryoverMinimumRecentTerms)
        )
    }

    private func clampedUnit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func nonNegative(_ value: Double) -> Double {
        max(value, 0)
    }
}

private extension QuestionIntentGateScoringPolicy {
    func normalized() -> QuestionIntentGateScoringPolicy {
        let normalizedThresholdMinimum = nonNegative(answerableThresholdMinimum)
        return QuestionIntentGateScoringPolicy(
            adaptivePromotedConfidence: clampedUnit(adaptivePromotedConfidence),
            insufficientMinimumConfidence: clampedUnit(insufficientMinimumConfidence),
            insufficientMaximumConfidence: clampedUnit(insufficientMaximumConfidence),
            acceptedConfidenceBase: clampedUnit(acceptedConfidenceBase),
            acceptedConfidenceDeltaWeight: nonNegative(acceptedConfidenceDeltaWeight),
            acceptedMinimumConfidence: clampedUnit(acceptedMinimumConfidence),
            acceptedMaximumConfidence: clampedUnit(acceptedMaximumConfidence),
            fragmentSuppressionConfidence: clampedUnit(fragmentSuppressionConfidence),
            smallTalkSuppressionConfidence: clampedUnit(smallTalkSuppressionConfidence),
            quotedSuppressionConfidence: clampedUnit(quotedSuppressionConfidence),
            selfAnsweredSuppressionConfidence: clampedUnit(selfAnsweredSuppressionConfidence),
            rhetoricalSuppressionConfidence: clampedUnit(rhetoricalSuppressionConfidence),
            adaptiveSuppressedConfidence: clampedUnit(adaptiveSuppressedConfidence),
            embeddedQuestionRecoveryBonus: nonNegative(embeddedQuestionRecoveryBonus),
            answerableThresholdMinimum: normalizedThresholdMinimum,
            answerableThresholdMaximum: max(normalizedThresholdMinimum, answerableThresholdMaximum),
            questionPunctuationWeight: nonNegative(questionPunctuationWeight),
            directQuestionMarkerWeight: nonNegative(directQuestionMarkerWeight),
            indirectQuestionMarkerWeight: nonNegative(indirectQuestionMarkerWeight),
            actionRequestMarkerWeight: nonNegative(actionRequestMarkerWeight),
            modalQuestionStarterWeight: nonNegative(modalQuestionStarterWeight),
            domainHintWeight: nonNegative(domainHintWeight),
            numericPayloadWeight: nonNegative(numericPayloadWeight),
            meaningfulTokenWeight: nonNegative(meaningfulTokenWeight),
            meaningfulTokenMaximum: nonNegative(meaningfulTokenMaximum),
            codeIdentifierWeight: nonNegative(codeIdentifierWeight),
            cjkWeight: nonNegative(cjkWeight),
            cjkMinimumCharacters: max(1, cjkMinimumCharacters),
            contextualCarryoverWeight: nonNegative(contextualCarryoverWeight),
            surfaceSemanticShapeBonus: nonNegative(surfaceSemanticShapeBonus),
            surfaceAnswerableObjectBonus: nonNegative(surfaceAnswerableObjectBonus),
            surfaceAdaptivePromotionBonus: nonNegative(surfaceAdaptivePromotionBonus),
            concreteObjectCJKMinimumCharacters: max(1, concreteObjectCJKMinimumCharacters),
            contextualCarryoverMinimumRecentTerms: max(1, contextualCarryoverMinimumRecentTerms)
        )
    }

    private func clampedUnit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func nonNegative(_ value: Double) -> Double {
        max(value, 0)
    }
}

private extension QuestionIntentSignalLabels {
    var hardSuppressionSignals: Set<String> {
        [
            empty,
            smallTalk,
            operationalCheck,
            reportedQuestion,
            rhetorical,
            selfAnswered,
            fragment,
            nounPhraseOrTitle,
            adaptiveSuppressed
        ]
    }

    func normalized() -> QuestionIntentSignalLabels {
        QuestionIntentSignalLabels(
            empty: empty.trimmedQuestionIntentPolicy,
            smallTalk: smallTalk.trimmedQuestionIntentPolicy,
            operationalCheck: operationalCheck.trimmedQuestionIntentPolicy,
            reportedQuestion: reportedQuestion.trimmedQuestionIntentPolicy,
            rhetorical: rhetorical.trimmedQuestionIntentPolicy,
            selfAnswered: selfAnswered.trimmedQuestionIntentPolicy,
            fragment: fragment.trimmedQuestionIntentPolicy,
            nounPhraseOrTitle: nounPhraseOrTitle.trimmedQuestionIntentPolicy,
            adaptiveSuppressed: adaptiveSuppressed.trimmedQuestionIntentPolicy,
            declarativeWithoutInterrogativeSyntax: declarativeWithoutInterrogativeSyntax.trimmedQuestionIntentPolicy
        )
    }
}

private extension QuestionIntentReasonPolicy {
    func normalized() -> QuestionIntentReasonPolicy {
        QuestionIntentReasonPolicy(
            fragmentIncomplete: fragmentIncomplete.trimmedQuestionIntentPolicy,
            rhetorical: rhetorical.trimmedQuestionIntentPolicy,
            quotedPastQuestion: quotedPastQuestion.trimmedQuestionIntentPolicy,
            selfAnswered: selfAnswered.trimmedQuestionIntentPolicy,
            answerable: answerable.trimmedQuestionIntentPolicy,
            adaptivePromoted: adaptivePromoted.trimmedQuestionIntentPolicy,
            insufficientIntentObject: insufficientIntentObject.trimmedQuestionIntentPolicy,
            clearIntentObject: clearIntentObject.trimmedQuestionIntentPolicy,
            fragmentNoObject: fragmentNoObject.trimmedQuestionIntentPolicy,
            smallTalk: smallTalk.trimmedQuestionIntentPolicy,
            quotedOrExplaining: quotedOrExplaining.trimmedQuestionIntentPolicy,
            adaptiveSuppressed: adaptiveSuppressed.trimmedQuestionIntentPolicy,
            highPrecisionInsufficient: highPrecisionInsufficient.trimmedQuestionIntentPolicy,
            localAnswerableTemplate: localAnswerableTemplate.trimmedQuestionIntentPolicy,
            operationalCheck: operationalCheck.trimmedQuestionIntentPolicy,
            titleOrStatement: titleOrStatement.trimmedQuestionIntentPolicy,
            ambiguous: ambiguous.trimmedQuestionIntentPolicy,
            surfaceBelowCandidateThreshold: surfaceBelowCandidateThreshold.trimmedQuestionIntentPolicy
        )
    }
}

private extension String {
    var trimmedQuestionIntentPolicy: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmptyPolicy: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}

struct RhetoricalQuestionFilter {
    var rulePack: QuestionIntentRulePack = .default

    func evaluation(
        for candidate: QuestionCandidate,
        context: TranscriptContext,
        profile: UserMeetingProfile? = nil
    ) -> (ignore: Bool, rhetorical: Bool, complete: Bool, responseNeeded: Bool, reason: String) {
        let text = QuestionDetectionService.normalize(
            QuestionSpanExtractor(rulePack: rulePack).extractedQuestion(
                from: candidate.rawText,
                language: candidate.language,
                profile: profile
            )
        )
        if isIncomplete(text) {
            return (true, false, false, false, rulePack.reasons.fragmentIncomplete)
        }
        if isRhetorical(text) {
            return (true, true, true, false, rulePack.reasons.rhetorical)
        }
        if isQuotedPastQuestion(text) {
            return (true, false, true, false, rulePack.reasons.quotedPastQuestion)
        }
        if isSelfAnswered(candidate.rawText) {
            return (true, false, true, false, rulePack.reasons.selfAnswered)
        }
        return (false, false, true, true, rulePack.reasons.answerable)
    }

    func isRhetorical(_ text: String) -> Bool {
        rulePack.rhetoricalMarkers.contains { rulePack.textSegmentationPolicy.containsBoundedMarker($0, in: text) }
            || rulePack.rhetoricalSuffixes.contains { hasRhetoricalSuffix($0, in: text) }
    }

    private func hasRhetoricalSuffix(_ suffix: String, in text: String) -> Bool {
        let normalizedText = QuestionDetectionService.normalize(text)
        let normalizedSuffix = QuestionDetectionService.normalize(suffix)
        guard !normalizedText.isEmpty,
              !normalizedSuffix.isEmpty,
              normalizedText.hasSuffix(normalizedSuffix),
              let suffixStart = normalizedText.index(
                normalizedText.endIndex,
                offsetBy: -normalizedSuffix.count,
                limitedBy: normalizedText.startIndex
              ) else {
            return false
        }

        let lead = String(normalizedText[..<suffixStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lead.isEmpty else { return false }

        if rulePack.rhetoricalSuffixLeadSeparators.contains(where: { separator in
            let trimmed = separator.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && lead.hasSuffix(trimmed)
        }) {
            return true
        }

        return rulePack.textSegmentationPolicy.lexicalTokenCount(in: lead) >= rulePack.rhetoricalSuffixMinimumLeadTokens
    }

    func isIncomplete(_ text: String) -> Bool {
        let plain = QuestionIntentGate.plainQuestionText(text, textPolicy: rulePack.textSegmentationPolicy)
        if rulePack.fragmentPhrases.contains(plain) {
            return true
        }
        return rulePack.textSegmentationPolicy.hasFragmentTerminalMarker(in: text)
            && rulePack.textSegmentationPolicy.lexicalTokenCount(in: plain) <= rulePack.textSegmentationPolicy.fragmentEllipsisMaximumTokens
    }

    func isSelfAnswered(_ text: String) -> Bool {
        let normalized = QuestionDetectionService.normalize(text)
        return rulePack.selfAnsweredMarkers.contains { normalized.contains($0) }
    }

    func isQuotedPastQuestion(_ text: String) -> Bool {
        rulePack.quotedOrExplainingMarkers.contains {
            rulePack.textSegmentationPolicy.containsBoundedMarker($0, in: text)
        }
    }
}

struct QuestionIntentEvaluation: Hashable, Sendable {
    let isAnswerableQuestion: Bool
    let isFragment: Bool
    let isSmallTalk: Bool
    let isQuotedOrExplaining: Bool
    let isRhetorical: Bool
    let reason: String
    let confidence: Double
}

struct QuestionHardSuppression: Hashable, Sendable {
    var isFragment: Bool
    var isSmallTalk: Bool
    var isQuotedOrExplaining: Bool
    var isRhetorical: Bool
    var reason: String
    var confidence: Double
    var signals: [String]

    var evaluation: QuestionIntentEvaluation {
        QuestionIntentEvaluation(
            isAnswerableQuestion: false,
            isFragment: isFragment,
            isSmallTalk: isSmallTalk,
            isQuotedOrExplaining: isQuotedOrExplaining,
            isRhetorical: isRhetorical,
            reason: reason,
            confidence: confidence
        )
    }
}

struct QuestionIntentGate {
    var rulePack: QuestionIntentRulePack = .default
    var adaptiveProfile: QuestionAnsweringAdaptiveProfile = QuestionAnsweringAdaptiveProfile()

    func evaluate(
        candidate: QuestionCandidate,
        context: TranscriptContext,
        profile: UserMeetingProfile? = nil
    ) -> QuestionIntentEvaluation {
        let scoring = rulePack.gateScoringPolicy
        let gateText = intentText(for: candidate, profile: profile)
        let plain = gateText.plain

        if let suppression = hardSuppression(candidate: candidate, context: context, profile: profile) {
            return suppression.evaluation
        }

        if adaptiveProfile.isPromoted(plain) {
            return QuestionIntentEvaluation(
                isAnswerableQuestion: true,
                isFragment: false,
                isSmallTalk: false,
                isQuotedOrExplaining: false,
                isRhetorical: false,
                reason: rulePack.reasons.adaptivePromoted,
                confidence: scoring.adaptivePromotedConfidence
            )
        }

        let score = answerabilityScore(plain: plain, rawText: gateText.raw, context: context)
            + surfaceAnswerabilityBonus(from: candidate.discovery)
        let threshold = answerableThreshold(for: candidate)
        if score < threshold {
            return QuestionIntentEvaluation(
                isAnswerableQuestion: false,
                isFragment: true,
                isSmallTalk: false,
                isQuotedOrExplaining: false,
                isRhetorical: false,
                reason: rulePack.reasons.insufficientIntentObject,
                confidence: min(
                    max(score / max(threshold, .ulpOfOne), scoring.insufficientMinimumConfidence),
                    scoring.insufficientMaximumConfidence
                )
            )
        }

        return QuestionIntentEvaluation(
            isAnswerableQuestion: true,
            isFragment: false,
            isSmallTalk: false,
            isQuotedOrExplaining: false,
            isRhetorical: false,
            reason: rulePack.reasons.clearIntentObject,
            confidence: min(
                max(
                    scoring.acceptedConfidenceBase + ((score - threshold) * scoring.acceptedConfidenceDeltaWeight),
                    scoring.acceptedMinimumConfidence
                ),
                scoring.acceptedMaximumConfidence
            )
        )
    }

    func hardSuppression(
        candidate: QuestionCandidate,
        context: TranscriptContext,
        profile: UserMeetingProfile? = nil
    ) -> QuestionHardSuppression? {
        let scoring = rulePack.gateScoringPolicy
        let gateText = intentText(for: candidate, profile: profile)
        let plain = gateText.plain

        if plain.isEmpty || isFragment(plain, context: context) {
            return QuestionHardSuppression(
                isFragment: true,
                isSmallTalk: false,
                isQuotedOrExplaining: false,
                isRhetorical: false,
                reason: rulePack.reasons.fragmentNoObject,
                confidence: scoring.fragmentSuppressionConfidence,
                signals: [rulePack.signalLabels.fragment]
            )
        }

        if isSmallTalk(plain) {
            return QuestionHardSuppression(
                isFragment: false,
                isSmallTalk: true,
                isQuotedOrExplaining: false,
                isRhetorical: false,
                reason: rulePack.reasons.smallTalk,
                confidence: scoring.smallTalkSuppressionConfidence,
                signals: [rulePack.signalLabels.smallTalk]
            )
        }

        if isQuotedOrExplaining(plain) && !hasRecoverableEmbeddedQuestion(plain, rawText: candidate.rawText, context: context) {
            return QuestionHardSuppression(
                isFragment: false,
                isSmallTalk: false,
                isQuotedOrExplaining: true,
                isRhetorical: false,
                reason: rulePack.reasons.quotedOrExplaining,
                confidence: scoring.quotedSuppressionConfidence,
                signals: [rulePack.signalLabels.reportedQuestion]
            )
        }

        if RhetoricalQuestionFilter(rulePack: rulePack).isSelfAnswered(candidate.rawText) {
            return QuestionHardSuppression(
                isFragment: false,
                isSmallTalk: false,
                isQuotedOrExplaining: false,
                isRhetorical: false,
                reason: rulePack.reasons.selfAnswered,
                confidence: scoring.selfAnsweredSuppressionConfidence,
                signals: [rulePack.signalLabels.selfAnswered]
            )
        }

        if RhetoricalQuestionFilter(rulePack: rulePack).isRhetorical(gateText.normalized) {
            return QuestionHardSuppression(
                isFragment: false,
                isSmallTalk: false,
                isQuotedOrExplaining: false,
                isRhetorical: true,
                reason: rulePack.reasons.rhetorical,
                confidence: scoring.rhetoricalSuppressionConfidence,
                signals: [rulePack.signalLabels.rhetorical]
            )
        }

        if adaptiveProfile.isSuppressed(plain) {
            return QuestionHardSuppression(
                isFragment: false,
                isSmallTalk: false,
                isQuotedOrExplaining: false,
                isRhetorical: false,
                reason: rulePack.reasons.adaptiveSuppressed,
                confidence: scoring.adaptiveSuppressedConfidence,
                signals: [rulePack.signalLabels.adaptiveSuppressed]
            )
        }

        return nil
    }

    private func intentText(
        for candidate: QuestionCandidate,
        profile: UserMeetingProfile?
    ) -> (raw: String, normalized: String, plain: String) {
        let extracted = QuestionSpanExtractor(rulePack: rulePack).extractedQuestion(
            from: candidate.rawText,
            language: candidate.language,
            profile: profile
        )
        let normalized = QuestionDetectionService.normalize(extracted)
        let plain = Self.plainQuestionText(normalized, textPolicy: rulePack.textSegmentationPolicy)
        return (extracted, normalized, plain)
    }

    static func plainQuestionText(_ text: String, textPolicy: QuestionTextSegmentationPolicy = .fallback) -> String {
        let textWithoutSeparators: String
        if let separatorPattern = textPolicy.plainTextSeparatorPattern() {
            textWithoutSeparators = text.replacingOccurrences(of: separatorPattern, with: " ", options: .regularExpression)
        } else {
            textWithoutSeparators = text
        }
        return textWithoutSeparators
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isFragment(_ plain: String) -> Bool {
        QuestionIntentGate().isFragment(plain, context: nil)
    }

    static func isSmallTalk(_ plain: String) -> Bool {
        QuestionIntentGate().isSmallTalk(plain)
    }

    static func isQuotedOrExplaining(_ plain: String) -> Bool {
        QuestionIntentGate().isQuotedOrExplaining(plain)
    }

    func isFragment(_ plain: String, context: TranscriptContext?) -> Bool {
        if rulePack.fragmentPhrases.contains(plain) { return true }
        for prefix in rulePack.fragmentPhrases where rulePack.textSegmentationPolicy.matchesLeadMarker(prefix, in: plain) {
            let remainder = plain.removingPrefix(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
            if meaningfulTokens(in: remainder).isEmpty
                && !hasNumericQuestionPayload(remainder)
                && !containsAny(remainder, rulePack.domainHintMarkers) {
                return true
            }
        }
        for prefix in rulePack.fragmentPrefixes where rulePack.textSegmentationPolicy.matchesLeadMarker(prefix, in: plain) {
            let remainder = plain.removingPrefix(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty { return true }
            if wordCount(remainder) <= 1 && !hasConcreteObject(remainder, context: context) {
                return true
            }
        }
        return false
    }

    func isSmallTalk(_ plain: String) -> Bool {
        if rulePack.exactSmallTalkPhrases.contains(plain) { return true }
        if isOperationalNoAnswerCheck(plain) { return true }
        for phrase in rulePack.exactSmallTalkPhrases where rulePack.textSegmentationPolicy.matchesLeadMarker(phrase, in: plain) {
            let remainder = plain.removingPrefix(phrase).trimmingCharacters(in: .whitespacesAndNewlines)
            let words = rulePack.textSegmentationPolicy.lexicalTokens(in: remainder)
            if !words.isEmpty && words.allSatisfy({ isSmallTalkContinuationToken($0) }) {
                return true
            }
        }
        return false
    }

    private func isSmallTalkContinuationToken(_ token: String) -> Bool {
        if rulePack.smallTalkContinuationWords.contains(token) { return true }
        let scalars = token.unicodeScalars
        let digitScalars = scalars.filter { CharacterSet.decimalDigits.contains($0) }
        guard !digitScalars.isEmpty else { return false }
        return scalars.allSatisfy {
            CharacterSet.decimalDigits.contains($0)
                || CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0)
        }
    }

    private func isOperationalNoAnswerCheck(_ plain: String) -> Bool {
        guard rulePack.operationalNoAnswerPhrases.contains(where: { phrase in
            rulePack.textSegmentationPolicy.containsBoundedMarker(phrase, in: plain)
        }) else {
            return false
        }
        return !containsAny(plain, rulePack.domainHintMarkers)
    }

    func isQuotedOrExplaining(_ plain: String) -> Bool {
        rulePack.quotedOrExplainingMarkers.contains {
            rulePack.textSegmentationPolicy.containsBoundedMarker($0, in: plain)
        }
    }

    func isLowSubstanceQuestion(_ plain: String, rawText: String, context: TranscriptContext?) -> Bool {
        guard rulePack.textSegmentationPolicy.containsQuestionPunctuation(in: rawText) else { return false }
        return answerabilityScore(plain: plain, rawText: rawText, context: context) < answerableThreshold(for: nil)
    }

    private func hasRecoverableEmbeddedQuestion(_ plain: String, rawText: String, context: TranscriptContext) -> Bool {
        guard rulePack.textSegmentationPolicy.containsQuestionPunctuation(in: rawText) else { return false }
        let clauses = embeddedQuestionClauses(in: plain)
        return clauses.contains { clause in
            answerabilityScore(plain: clause, rawText: rawText, context: context)
                >= answerableThreshold(for: nil) + rulePack.gateScoringPolicy.embeddedQuestionRecoveryBonus
        }
    }

    private func embeddedQuestionClauses(in plain: String) -> [String] {
        var clauses = [plain]
        let padded = " \(plain) "
        for marker in rulePack.embeddedQuestionSplitMarkers {
            let normalized = QuestionDetectionService.normalize(marker)
            guard !normalized.isEmpty else { continue }
            if containsCompactScript(normalized) {
                if let range = plain.range(of: normalized) {
                    clauses.append(String(plain[range.lowerBound...]))
                }
                continue
            }
            var searchStart = padded.startIndex
            let needle = " \(normalized) "
            while let range = padded.range(of: needle, range: searchStart..<padded.endIndex) {
                let clauseStart = padded.index(after: range.lowerBound)
                clauses.append(
                    String(padded[clauseStart...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
                searchStart = range.upperBound
            }
        }
        var seen: Set<String> = []
        return clauses.filter { seen.insert($0).inserted && !$0.isEmpty }
    }

    private func answerabilityScore(plain: String, rawText: String, context: TranscriptContext?) -> Double {
        let scoring = rulePack.gateScoringPolicy
        var score = 0.0
        if rulePack.textSegmentationPolicy.containsQuestionPunctuation(in: rawText) {
            score += scoring.questionPunctuationWeight
        }
        if containsAny(plain, rulePack.directQuestionMarkers) {
            score += scoring.directQuestionMarkerWeight
        }
        if containsAny(plain, rulePack.indirectQuestionMarkers) {
            score += scoring.indirectQuestionMarkerWeight
        }
        if containsAny(plain, rulePack.actionRequestMarkers) {
            score += scoring.actionRequestMarkerWeight
        }
        if startsWithAnyToken(plain, rulePack.modalQuestionStarters) {
            score += scoring.modalQuestionStarterWeight
        }
        if containsAny(plain, rulePack.domainHintMarkers) {
            score += scoring.domainHintWeight
        }
        if hasNumericQuestionPayload(plain) {
            score += scoring.numericPayloadWeight
        }
        score += min(
            Double(meaningfulTokens(in: plain).count) * scoring.meaningfulTokenWeight,
            scoring.meaningfulTokenMaximum
        )
        if hasCodeOrIdentifierSignal(rawText) {
            score += scoring.codeIdentifierWeight
        }
        if containsCompactScript(plain), plain.count >= scoring.cjkMinimumCharacters {
            score += scoring.cjkWeight
        }
        if hasContextualCarryover(plain: plain, context: context) {
            score += scoring.contextualCarryoverWeight
        }
        return score
    }

    private func surfaceAnswerabilityBonus(from discovery: QuestionCandidateDiscovery) -> Double {
        let scoring = rulePack.gateScoringPolicy
        let signals = Set(discovery.surfaceSignals)
        var bonus = 0.0
        if signals.contains(QuestionUnderstandingSignal.semanticQuestionShape.rawValue) {
            bonus += scoring.surfaceSemanticShapeBonus
        }
        if signals.contains(QuestionUnderstandingSignal.answerableObjectFocus.rawValue) {
            bonus += scoring.surfaceAnswerableObjectBonus
        }
        if signals.contains(QuestionUnderstandingSignal.adaptivePromotion.rawValue) {
            bonus += scoring.surfaceAdaptivePromotionBonus
        }
        return bonus
    }

    private func answerableThreshold(for candidate: QuestionCandidate?) -> Double {
        let scoring = rulePack.gateScoringPolicy
        var threshold = rulePack.answerableScoreThreshold + adaptiveProfile.strictnessAdjustment
        if candidate?.isPartial == true {
            threshold += rulePack.partialQuestionPenalty
        }
        return min(
            max(threshold, scoring.answerableThresholdMinimum),
            scoring.answerableThresholdMaximum
        )
    }

    private func hasConcreteObject(_ plain: String, context: TranscriptContext?) -> Bool {
        !meaningfulTokens(in: plain).isEmpty
            || hasNumericQuestionPayload(plain)
            || containsAny(plain, rulePack.domainHintMarkers)
            || containsCompactScript(plain) && plain.count >= rulePack.gateScoringPolicy.concreteObjectCJKMinimumCharacters
            || hasContextualCarryover(plain: plain, context: context)
    }

    private func hasContextualCarryover(plain: String, context: TranscriptContext?) -> Bool {
        guard let context else { return false }
        let hasPronoun = rulePack.textSegmentationPolicy.lexicalTokens(in: plain).contains { rulePack.contextualPronouns.contains($0) }
        guard hasPronoun else { return false }
        let recent = QuestionDetectionService.normalize(context.recentTranscript + " " + context.mediumTranscript)
        return containsAny(recent, rulePack.domainHintMarkers)
            || meaningfulTokens(in: recent).count >= rulePack.gateScoringPolicy.contextualCarryoverMinimumRecentTerms
    }

    private func meaningfulTokens(in plain: String) -> [String] {
        rulePack.textSegmentationPolicy
            .lexicalTokens(in: plain)
            .filter { token in
                token.count >= rulePack.textSegmentationPolicy.meaningfulTokenMinimumLength(for: token)
                    && token.unicodeScalars.contains { CharacterSet.letters.contains($0) }
                    && !rulePack.stopWords.contains(token)
                    && !rulePack.lowInformationWords.contains(token)
            }
    }

    private func containsAny(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { pattern in
            let normalized = QuestionDetectionService.normalize(pattern)
            return patternMatches(text, normalized)
        }
    }

    private func startsWithAnyToken(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { pattern in
            rulePack.textSegmentationPolicy.matchesLeadOrCompactMarker(pattern, in: text)
        }
    }

    private func hasCodeOrIdentifierSignal(_ text: String) -> Bool {
        rulePack.textSegmentationPolicy.containsCodeIdentifierCharacter(in: text)
            || rulePack.textSegmentationPolicy.containsCodeIdentifierPattern(in: text)
    }

    private func hasNumericQuestionPayload(_ text: String) -> Bool {
        QuestionDetectionService.hasNumericQuestionPayload(text, rulePack: rulePack)
    }

    private func containsCompactScript(_ text: String) -> Bool {
        rulePack.textSegmentationPolicy.containsCompactScript(in: text)
    }

    private func patternMatches(_ text: String, _ pattern: String) -> Bool {
        rulePack.textSegmentationPolicy.containsBoundedMarker(pattern, in: text)
    }

    private func wordCount(_ value: String) -> Int {
        rulePack.textSegmentationPolicy.lexicalTokenCount(in: value)
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}

extension QuestionClassification {
    init(ignoredBy intent: QuestionIntentEvaluation, candidate: QuestionCandidate) {
        self.init(
            isQuestion: false,
            rhetorical: intent.isRhetorical,
            complete: !intent.isFragment,
            actionable: false,
            responseNeeded: false,
            userAttentionNeeded: false,
            directedToUser: false,
            directedToGroup: false,
            questionType: .generalQuestion,
            priority: .low,
            confidence: intent.confidence,
            reason: intent.reason,
            extractedQuestion: candidate.rawText,
            expectedAnswerStyle: intent.isFragment ? .askForClarification : .concise
        )
    }
}
