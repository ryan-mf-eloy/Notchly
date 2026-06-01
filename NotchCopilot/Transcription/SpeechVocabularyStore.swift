import CryptoKit
import Foundation
import NaturalLanguage
import Speech
import SwiftData

enum SpeechVocabularyTokenizationStrategy: String, Codable, Hashable, Sendable {
    case scalarSplit
    case naturalLanguage
    case automatic
}

enum SpeechVocabularyCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case person
    case company
    case product
    case acronym
    case technicalTerm
    case place
    case shortPhrase
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .person: "Person"
        case .company: "Company"
        case .product: "Product"
        case .acronym: "Acronym"
        case .technicalTerm: "Technical"
        case .place: "Place"
        case .shortPhrase: "Phrase"
        case .custom: "Custom"
        }
    }
}

enum SpeechVocabularyScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case global
    case workspace
    case meetingType
    case meeting

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .global: "Global"
        case .workspace: "Workspace"
        case .meetingType: "Meeting Type"
        case .meeting: "Meeting"
        }
    }
}

struct SpeechVocabularyTerm: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var text: String
    var locale: String?
    var category: SpeechVocabularyCategory
    var aliases: [String]
    var pronunciationXSAMPA: String?
    var boost: Double
    var scope: SpeechVocabularyScope
    var scopeValue: String?
    var enabled: Bool
    var isSystemSeed: Bool
    var notes: String?
    var templatePattern: String?
    var templateSlots: [String]
    var correctionCount: Int
    var lastCorrectionAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int

    init(
        id: UUID = UUID(),
        text: String,
        locale: String? = nil,
        category: SpeechVocabularyCategory = .custom,
        aliases: [String] = [],
        pronunciationXSAMPA: String? = nil,
        boost: Double = 1.0,
        scope: SpeechVocabularyScope = .global,
        scopeValue: String? = nil,
        enabled: Bool = true,
        isSystemSeed: Bool = false,
        notes: String? = nil,
        templatePattern: String? = nil,
        templateSlots: [String] = [],
        correctionCount: Int = 0,
        lastCorrectionAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        useCount: Int = 0
    ) {
        self.id = id
        self.text = Self.cleaned(text)
        self.locale = locale.map(SupportedLanguage.normalizedCode)
        self.category = category
        self.aliases = aliases.map(Self.cleaned).filter { !$0.isEmpty }
        self.pronunciationXSAMPA = Self.cleaned(pronunciationXSAMPA ?? "").nilIfEmpty
        self.boost = min(max(boost, 0.1), 3.0)
        self.scope = scope
        self.scopeValue = Self.cleaned(scopeValue ?? "").nilIfEmpty
        self.enabled = enabled
        self.isSystemSeed = isSystemSeed
        self.notes = Self.cleaned(notes ?? "").nilIfEmpty
        self.templatePattern = Self.cleaned(templatePattern ?? "").nilIfEmpty
        self.templateSlots = templateSlots.map(Self.cleaned).filter { !$0.isEmpty }.uniquedCaseAndDiacriticInsensitive()
        self.correctionCount = max(0, correctionCount)
        self.lastCorrectionAt = lastCorrectionAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.useCount = max(0, useCount)
    }

    var normalizedText: String {
        Self.normalizedKey(text, locale: locale)
    }

    var allSpokenForms: [String] {
        ([text] + aliases)
            .map(Self.cleaned)
            .filter { !$0.isEmpty }
            .uniquedCaseAndDiacriticInsensitive()
    }

    static func cleaned(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func normalizedKey(_ value: String, locale: String? = nil) -> String {
        cleaned(value).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale.map(Locale.init(identifier:)) ?? .current)
    }
}

struct SpeechContextTerm: Hashable, Sendable {
    var text: String
    var locale: String?
    var category: SpeechVocabularyCategory
    var weight: Double
    var pronunciationXSAMPA: String?
    var source: String
    var templatePattern: String?
    var templateSlots: [String]

    init(
        text: String,
        locale: String?,
        category: SpeechVocabularyCategory,
        weight: Double,
        pronunciationXSAMPA: String?,
        source: String,
        templatePattern: String? = nil,
        templateSlots: [String] = []
    ) {
        self.text = SpeechVocabularyTerm.cleaned(text)
        self.locale = locale
        self.category = category
        self.weight = weight
        self.pronunciationXSAMPA = pronunciationXSAMPA
        self.source = source
        self.templatePattern = SpeechVocabularyTerm.cleaned(templatePattern ?? "").nilIfEmpty
        self.templateSlots = templateSlots.map(SpeechVocabularyTerm.cleaned).filter { !$0.isEmpty }.uniquedCaseAndDiacriticInsensitive()
    }

    var normalizedText: String {
        SpeechVocabularyTerm.normalizedKey(text, locale: locale)
    }
}

struct SpeechRecognitionContext: Hashable, Sendable {
    var locale: String?
    var terms: [SpeechContextTerm]
    var customLanguageModelEnabled: Bool
    var status: String
    var runtimePolicy: SpeechVocabularyRuntimePolicy

    init(
        locale: String?,
        terms: [SpeechContextTerm],
        customLanguageModelEnabled: Bool = true,
        status: String = "Apple Speech ready",
        runtimePolicy: SpeechVocabularyRuntimePolicy = .default
    ) {
        self.locale = locale.map(SupportedLanguage.normalizedCode)
        self.terms = terms
        self.customLanguageModelEnabled = customLanguageModelEnabled
        self.status = status
        self.runtimePolicy = runtimePolicy.normalized()
    }

    var contextualStrings: [String] {
        SpeechContextRanker().rank(terms, limit: runtimePolicy.maxContextualStrings, locale: locale)
    }

    var activeTermsForLanguageModel: [SpeechContextTerm] {
        terms
            .filter { term in
                guard let locale, let termLocale = term.locale else { return true }
                return SupportedLanguage.normalizedCode(termLocale) == SupportedLanguage.normalizedCode(locale)
            }
            .filter { !$0.text.isEmpty }
            .sorted {
                if $0.weight == $1.weight { return $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending }
                return $0.weight > $1.weight
            }
            .prefix(runtimePolicy.maxLanguageModelTerms)
            .map { $0 }
    }

    var stableHash: String {
        var hasher = SHA256()
        hasher.update(data: Data((locale ?? "auto").utf8))
        hasher.update(data: Data(runtimePolicy.stableHashComponent.utf8))
        for term in activeTermsForLanguageModel {
            hasher.update(data: Data(term.text.utf8))
            hasher.update(data: Data(term.category.rawValue.utf8))
            hasher.update(data: Data(String(format: "%.2f", term.weight).utf8))
            if let pronunciation = term.pronunciationXSAMPA {
                hasher.update(data: Data(pronunciation.utf8))
            }
            if let templatePattern = term.templatePattern {
                hasher.update(data: Data(templatePattern.utf8))
            }
            for slot in term.templateSlots {
                hasher.update(data: Data(slot.utf8))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct SpeechVocabularyRuntimePolicy: Codable, Hashable, Sendable {
    var maxContextualStrings: Int
    var maxLanguageModelTerms: Int
    var suggestionTokenPreservedCharacters: String
    var suggestedMinimumTokenLength: Int
    var suggestedPreferredMinimumTokenLength: Int
    var suggestedPhraseMinimumTokenCount: Int
    var suggestedPhraseMaximumTokenCount: Int
    var suggestedPhraseMinimumCharacterCount: Int
    var suggestedBoost: Double
    var suggestedNotes: String
    var meetingTitleMinimumTermLength: Int
    var meetingTitleTermWeight: Double
    var scopedTermBoost: Double
    var titleMentionBoost: Double
    var useCountWeightDivisor: Double
    var useCountWeightMaximum: Double
    var correctionCountWeightDivisor: Double
    var correctionCountWeightMaximum: Double
    var minimumTermWeight: Double
    var maximumTermWeight: Double
    var rescoreLowConfidenceThreshold: Double
    var rescoreExistingTermConfidenceFloor: Double
    var languageModelPhraseCountMultiplier: Double
    var languageModelTemplateCountMultiplier: Double
    var tokenizationStrategy: SpeechVocabularyTokenizationStrategy
    var compactScriptMinimumTermLength: Int

    init(
        maxContextualStrings: Int,
        maxLanguageModelTerms: Int,
        suggestionTokenPreservedCharacters: String,
        suggestedMinimumTokenLength: Int,
        suggestedPreferredMinimumTokenLength: Int,
        suggestedPhraseMinimumTokenCount: Int,
        suggestedPhraseMaximumTokenCount: Int,
        suggestedPhraseMinimumCharacterCount: Int,
        suggestedBoost: Double,
        suggestedNotes: String,
        meetingTitleMinimumTermLength: Int,
        meetingTitleTermWeight: Double,
        scopedTermBoost: Double,
        titleMentionBoost: Double,
        useCountWeightDivisor: Double,
        useCountWeightMaximum: Double,
        correctionCountWeightDivisor: Double,
        correctionCountWeightMaximum: Double,
        minimumTermWeight: Double,
        maximumTermWeight: Double,
        rescoreLowConfidenceThreshold: Double,
        rescoreExistingTermConfidenceFloor: Double,
        languageModelPhraseCountMultiplier: Double,
        languageModelTemplateCountMultiplier: Double,
        tokenizationStrategy: SpeechVocabularyTokenizationStrategy,
        compactScriptMinimumTermLength: Int
    ) {
        self.maxContextualStrings = maxContextualStrings
        self.maxLanguageModelTerms = maxLanguageModelTerms
        self.suggestionTokenPreservedCharacters = suggestionTokenPreservedCharacters
        self.suggestedMinimumTokenLength = suggestedMinimumTokenLength
        self.suggestedPreferredMinimumTokenLength = suggestedPreferredMinimumTokenLength
        self.suggestedPhraseMinimumTokenCount = suggestedPhraseMinimumTokenCount
        self.suggestedPhraseMaximumTokenCount = suggestedPhraseMaximumTokenCount
        self.suggestedPhraseMinimumCharacterCount = suggestedPhraseMinimumCharacterCount
        self.suggestedBoost = suggestedBoost
        self.suggestedNotes = suggestedNotes
        self.meetingTitleMinimumTermLength = meetingTitleMinimumTermLength
        self.meetingTitleTermWeight = meetingTitleTermWeight
        self.scopedTermBoost = scopedTermBoost
        self.titleMentionBoost = titleMentionBoost
        self.useCountWeightDivisor = useCountWeightDivisor
        self.useCountWeightMaximum = useCountWeightMaximum
        self.correctionCountWeightDivisor = correctionCountWeightDivisor
        self.correctionCountWeightMaximum = correctionCountWeightMaximum
        self.minimumTermWeight = minimumTermWeight
        self.maximumTermWeight = maximumTermWeight
        self.rescoreLowConfidenceThreshold = rescoreLowConfidenceThreshold
        self.rescoreExistingTermConfidenceFloor = rescoreExistingTermConfidenceFloor
        self.languageModelPhraseCountMultiplier = languageModelPhraseCountMultiplier
        self.languageModelTemplateCountMultiplier = languageModelTemplateCountMultiplier
        self.tokenizationStrategy = tokenizationStrategy
        self.compactScriptMinimumTermLength = compactScriptMinimumTermLength
    }

    static let fallback = SpeechVocabularyRuntimePolicy(
        maxContextualStrings: 100,
        maxLanguageModelTerms: 400,
        suggestionTokenPreservedCharacters: "-",
        suggestedMinimumTokenLength: 3,
        suggestedPreferredMinimumTokenLength: 8,
        suggestedPhraseMinimumTokenCount: 2,
        suggestedPhraseMaximumTokenCount: 4,
        suggestedPhraseMinimumCharacterCount: 8,
        suggestedBoost: 1.2,
        suggestedNotes: "Suggested from transcript",
        meetingTitleMinimumTermLength: 3,
        meetingTitleTermWeight: 1.15,
        scopedTermBoost: 0.35,
        titleMentionBoost: 0.3,
        useCountWeightDivisor: 20,
        useCountWeightMaximum: 0.4,
        correctionCountWeightDivisor: 10,
        correctionCountWeightMaximum: 0.45,
        minimumTermWeight: 0.1,
        maximumTermWeight: 3.0,
        rescoreLowConfidenceThreshold: 0.88,
        rescoreExistingTermConfidenceFloor: 0.54,
        languageModelPhraseCountMultiplier: 8,
        languageModelTemplateCountMultiplier: 60,
        tokenizationStrategy: .scalarSplit,
        compactScriptMinimumTermLength: 2
    )

    private enum CodingKeys: String, CodingKey {
        case maxContextualStrings
        case maxLanguageModelTerms
        case suggestionTokenPreservedCharacters
        case suggestedMinimumTokenLength
        case suggestedPreferredMinimumTokenLength
        case suggestedPhraseMinimumTokenCount
        case suggestedPhraseMaximumTokenCount
        case suggestedPhraseMinimumCharacterCount
        case suggestedBoost
        case suggestedNotes
        case meetingTitleMinimumTermLength
        case meetingTitleTermWeight
        case scopedTermBoost
        case titleMentionBoost
        case useCountWeightDivisor
        case useCountWeightMaximum
        case correctionCountWeightDivisor
        case correctionCountWeightMaximum
        case minimumTermWeight
        case maximumTermWeight
        case rescoreLowConfidenceThreshold
        case rescoreExistingTermConfidenceFloor
        case languageModelPhraseCountMultiplier
        case languageModelTemplateCountMultiplier
        case tokenizationStrategy
        case compactScriptMinimumTermLength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.fallback
        self.init(
            maxContextualStrings: try container.decodeIfPresent(Int.self, forKey: .maxContextualStrings) ?? fallback.maxContextualStrings,
            maxLanguageModelTerms: try container.decodeIfPresent(Int.self, forKey: .maxLanguageModelTerms) ?? fallback.maxLanguageModelTerms,
            suggestionTokenPreservedCharacters: try container.decodeIfPresent(String.self, forKey: .suggestionTokenPreservedCharacters) ?? fallback.suggestionTokenPreservedCharacters,
            suggestedMinimumTokenLength: try container.decodeIfPresent(Int.self, forKey: .suggestedMinimumTokenLength) ?? fallback.suggestedMinimumTokenLength,
            suggestedPreferredMinimumTokenLength: try container.decodeIfPresent(Int.self, forKey: .suggestedPreferredMinimumTokenLength) ?? fallback.suggestedPreferredMinimumTokenLength,
            suggestedPhraseMinimumTokenCount: try container.decodeIfPresent(Int.self, forKey: .suggestedPhraseMinimumTokenCount) ?? fallback.suggestedPhraseMinimumTokenCount,
            suggestedPhraseMaximumTokenCount: try container.decodeIfPresent(Int.self, forKey: .suggestedPhraseMaximumTokenCount) ?? fallback.suggestedPhraseMaximumTokenCount,
            suggestedPhraseMinimumCharacterCount: try container.decodeIfPresent(Int.self, forKey: .suggestedPhraseMinimumCharacterCount) ?? fallback.suggestedPhraseMinimumCharacterCount,
            suggestedBoost: try container.decodeIfPresent(Double.self, forKey: .suggestedBoost) ?? fallback.suggestedBoost,
            suggestedNotes: try container.decodeIfPresent(String.self, forKey: .suggestedNotes) ?? fallback.suggestedNotes,
            meetingTitleMinimumTermLength: try container.decodeIfPresent(Int.self, forKey: .meetingTitleMinimumTermLength) ?? fallback.meetingTitleMinimumTermLength,
            meetingTitleTermWeight: try container.decodeIfPresent(Double.self, forKey: .meetingTitleTermWeight) ?? fallback.meetingTitleTermWeight,
            scopedTermBoost: try container.decodeIfPresent(Double.self, forKey: .scopedTermBoost) ?? fallback.scopedTermBoost,
            titleMentionBoost: try container.decodeIfPresent(Double.self, forKey: .titleMentionBoost) ?? fallback.titleMentionBoost,
            useCountWeightDivisor: try container.decodeIfPresent(Double.self, forKey: .useCountWeightDivisor) ?? fallback.useCountWeightDivisor,
            useCountWeightMaximum: try container.decodeIfPresent(Double.self, forKey: .useCountWeightMaximum) ?? fallback.useCountWeightMaximum,
            correctionCountWeightDivisor: try container.decodeIfPresent(Double.self, forKey: .correctionCountWeightDivisor) ?? fallback.correctionCountWeightDivisor,
            correctionCountWeightMaximum: try container.decodeIfPresent(Double.self, forKey: .correctionCountWeightMaximum) ?? fallback.correctionCountWeightMaximum,
            minimumTermWeight: try container.decodeIfPresent(Double.self, forKey: .minimumTermWeight) ?? fallback.minimumTermWeight,
            maximumTermWeight: try container.decodeIfPresent(Double.self, forKey: .maximumTermWeight) ?? fallback.maximumTermWeight,
            rescoreLowConfidenceThreshold: try container.decodeIfPresent(Double.self, forKey: .rescoreLowConfidenceThreshold) ?? fallback.rescoreLowConfidenceThreshold,
            rescoreExistingTermConfidenceFloor: try container.decodeIfPresent(Double.self, forKey: .rescoreExistingTermConfidenceFloor) ?? fallback.rescoreExistingTermConfidenceFloor,
            languageModelPhraseCountMultiplier: try container.decodeIfPresent(Double.self, forKey: .languageModelPhraseCountMultiplier) ?? fallback.languageModelPhraseCountMultiplier,
            languageModelTemplateCountMultiplier: try container.decodeIfPresent(Double.self, forKey: .languageModelTemplateCountMultiplier) ?? fallback.languageModelTemplateCountMultiplier,
            tokenizationStrategy: try container.decodeIfPresent(SpeechVocabularyTokenizationStrategy.self, forKey: .tokenizationStrategy) ?? fallback.tokenizationStrategy,
            compactScriptMinimumTermLength: try container.decodeIfPresent(Int.self, forKey: .compactScriptMinimumTermLength) ?? fallback.compactScriptMinimumTermLength
        )
    }

    static var `default`: SpeechVocabularyRuntimePolicy {
        SpeechVocabularySeedPolicy.default.runtimePolicy
    }

    func isSuggestionTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || suggestionTokenPreservedCharacters.contains(character)
    }
}

struct SpeechVocabularySeedPolicy: Codable, Hashable, Sendable {
    var ambientSessionTitle: String
    var ambientSystemTerms: [String]
    var technicalTerms: [String]
    var userNameBoost: Double
    var appTermBoost: Double
    var technicalTermBoost: Double
    var runtime: SpeechVocabularyRuntimePolicy?

    init(
        ambientSessionTitle: String = "",
        ambientSystemTerms: [String] = [],
        technicalTerms: [String] = [],
        userNameBoost: Double = 0,
        appTermBoost: Double = 0,
        technicalTermBoost: Double = 0,
        runtime: SpeechVocabularyRuntimePolicy? = nil
    ) {
        self.ambientSessionTitle = ambientSessionTitle
        self.ambientSystemTerms = ambientSystemTerms
        self.technicalTerms = technicalTerms
        self.userNameBoost = userNameBoost
        self.appTermBoost = appTermBoost
        self.technicalTermBoost = technicalTermBoost
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey {
        case ambientSessionTitle
        case ambientSystemTerms
        case technicalTerms
        case userNameBoost
        case appTermBoost
        case technicalTermBoost
        case runtime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ambientSessionTitle: try container.decodeIfPresent(String.self, forKey: .ambientSessionTitle) ?? "",
            ambientSystemTerms: try container.decodeIfPresent([String].self, forKey: .ambientSystemTerms) ?? [],
            technicalTerms: try container.decodeIfPresent([String].self, forKey: .technicalTerms) ?? [],
            userNameBoost: try container.decodeIfPresent(Double.self, forKey: .userNameBoost) ?? 0,
            appTermBoost: try container.decodeIfPresent(Double.self, forKey: .appTermBoost) ?? 0,
            technicalTermBoost: try container.decodeIfPresent(Double.self, forKey: .technicalTermBoost) ?? 0,
            runtime: try container.decodeIfPresent(SpeechVocabularyRuntimePolicy.self, forKey: .runtime)
        )
    }

    static let `default` = SpeechVocabularySeedPolicyStore.current

    var runtimePolicy: SpeechVocabularyRuntimePolicy {
        runtime?.normalized() ?? .fallback
    }
}

enum SpeechVocabularySeedPolicyStore {
    static let current: SpeechVocabularySeedPolicy = load()

    private static func load() -> SpeechVocabularySeedPolicy {
        let decoder = JSONDecoder()
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let policy = try? decoder.decode(SpeechVocabularySeedPolicy.self, from: data) else {
                continue
            }
            return policy.normalized()
        }
        return fallbackPolicy()
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let bundles = [Bundle.main, Bundle(for: SpeechVocabularySeedPolicyBundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "speech-vocabulary-seed",
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
                .appendingPathComponent("Resources/CopilotIntentPolicy/speech-vocabulary-seed.json")
        )
        return urls
    }

    private static func fallbackPolicy() -> SpeechVocabularySeedPolicy {
        SpeechVocabularySeedPolicy(
            ambientSessionTitle: "",
            ambientSystemTerms: [],
            technicalTerms: [],
            userNameBoost: 0,
            appTermBoost: 0,
            technicalTermBoost: 0,
            runtime: .fallback
        )
    }
}

private final class SpeechVocabularySeedPolicyBundleMarker {}

private extension SpeechVocabularySeedPolicy {
    func normalized() -> SpeechVocabularySeedPolicy {
        SpeechVocabularySeedPolicy(
            ambientSessionTitle: SpeechVocabularyTerm.cleaned(ambientSessionTitle),
            ambientSystemTerms: ambientSystemTerms.map(SpeechVocabularyTerm.cleaned).filter { !$0.isEmpty },
            technicalTerms: technicalTerms.map(SpeechVocabularyTerm.cleaned).filter { !$0.isEmpty },
            userNameBoost: min(max(userNameBoost, 0), 3.0),
            appTermBoost: min(max(appTermBoost, 0), 3.0),
            technicalTermBoost: min(max(technicalTermBoost, 0), 3.0),
            runtime: runtimePolicy
        )
    }
}

private extension SpeechVocabularyRuntimePolicy {
    var stableHashComponent: String {
        [
            maxContextualStrings,
            maxLanguageModelTerms,
            suggestionTokenPreservedCharacters,
            suggestedMinimumTokenLength,
            suggestedPreferredMinimumTokenLength,
            suggestedPhraseMinimumTokenCount,
            suggestedPhraseMaximumTokenCount,
            suggestedPhraseMinimumCharacterCount,
            suggestedBoost,
            suggestedNotes,
            meetingTitleMinimumTermLength,
            meetingTitleTermWeight,
            scopedTermBoost,
            titleMentionBoost,
            useCountWeightDivisor,
            useCountWeightMaximum,
            correctionCountWeightDivisor,
            correctionCountWeightMaximum,
            minimumTermWeight,
            maximumTermWeight,
            rescoreLowConfidenceThreshold,
            rescoreExistingTermConfidenceFloor,
            languageModelPhraseCountMultiplier,
            languageModelTemplateCountMultiplier,
            tokenizationStrategy.rawValue,
            compactScriptMinimumTermLength
        ]
        .map(String.init(describing:))
        .joined(separator: "|")
    }

    func normalized() -> SpeechVocabularyRuntimePolicy {
        let fallback = SpeechVocabularyRuntimePolicy.fallback
        let minWeight = min(max(minimumTermWeight, 0), max(maximumTermWeight, fallback.maximumTermWeight))
        let maxWeight = max(minWeight, maximumTermWeight)
        return SpeechVocabularyRuntimePolicy(
            maxContextualStrings: max(1, maxContextualStrings),
            maxLanguageModelTerms: max(1, maxLanguageModelTerms),
            suggestionTokenPreservedCharacters: suggestionTokenPreservedCharacters.nilIfEmpty ?? fallback.suggestionTokenPreservedCharacters,
            suggestedMinimumTokenLength: max(1, suggestedMinimumTokenLength),
            suggestedPreferredMinimumTokenLength: max(suggestedMinimumTokenLength, suggestedPreferredMinimumTokenLength),
            suggestedPhraseMinimumTokenCount: max(2, suggestedPhraseMinimumTokenCount),
            suggestedPhraseMaximumTokenCount: max(max(2, suggestedPhraseMinimumTokenCount), suggestedPhraseMaximumTokenCount),
            suggestedPhraseMinimumCharacterCount: max(1, suggestedPhraseMinimumCharacterCount),
            suggestedBoost: min(max(suggestedBoost, minWeight), maxWeight),
            suggestedNotes: suggestedNotes.nilIfEmpty ?? fallback.suggestedNotes,
            meetingTitleMinimumTermLength: max(1, meetingTitleMinimumTermLength),
            meetingTitleTermWeight: min(max(meetingTitleTermWeight, minWeight), maxWeight),
            scopedTermBoost: max(0, scopedTermBoost),
            titleMentionBoost: max(0, titleMentionBoost),
            useCountWeightDivisor: max(1, useCountWeightDivisor),
            useCountWeightMaximum: max(0, useCountWeightMaximum),
            correctionCountWeightDivisor: max(1, correctionCountWeightDivisor),
            correctionCountWeightMaximum: max(0, correctionCountWeightMaximum),
            minimumTermWeight: minWeight,
            maximumTermWeight: maxWeight,
            rescoreLowConfidenceThreshold: min(max(rescoreLowConfidenceThreshold, 0), 1),
            rescoreExistingTermConfidenceFloor: min(max(rescoreExistingTermConfidenceFloor, 0), 1),
            languageModelPhraseCountMultiplier: max(1, languageModelPhraseCountMultiplier),
            languageModelTemplateCountMultiplier: max(1, languageModelTemplateCountMultiplier),
            tokenizationStrategy: tokenizationStrategy,
            compactScriptMinimumTermLength: max(1, compactScriptMinimumTermLength)
        )
    }
}

@MainActor
final class SpeechVocabularyStore {
    private let context: ModelContext
    private let cryptor: LocalDataCryptor

    init(container: ModelContainer, cryptor: LocalDataCryptor = .defaultOrCrash()) {
        self.context = ModelContext(container)
        self.cryptor = cryptor
    }

    func terms(includeDisabled: Bool = true) -> [SpeechVocabularyTerm] {
        let records = (try? context.fetch(FetchDescriptor<StoredSpeechVocabularyTerm>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))) ?? []
        return records
            .compactMap { try? $0.decrypt(cryptor: cryptor) }
            .filter { includeDisabled || $0.enabled }
    }

    func save(_ term: SpeechVocabularyTerm) {
        var normalized = term
        normalized.text = SpeechVocabularyTerm.cleaned(normalized.text)
        normalized.aliases = normalized.aliases.map(SpeechVocabularyTerm.cleaned).filter { !$0.isEmpty }.uniquedCaseAndDiacriticInsensitive()
        normalized.templatePattern = SpeechVocabularyTerm.cleaned(normalized.templatePattern ?? "").nilIfEmpty
        normalized.templateSlots = normalized.templateSlots.map(SpeechVocabularyTerm.cleaned).filter { !$0.isEmpty }.uniquedCaseAndDiacriticInsensitive()
        normalized.updatedAt = Date()
        guard !normalized.text.isEmpty else { return }

        let records = (try? context.fetch(FetchDescriptor<StoredSpeechVocabularyTerm>())) ?? []
        if let existing = records.first(where: {
            $0.id == normalized.id ||
                ($0.normalizedText == normalized.normalizedText &&
                 $0.locale == normalized.locale &&
                 $0.scopeRaw == normalized.scope.rawValue &&
                 $0.scopeValue == normalized.scopeValue)
        }) {
            try? existing.update(from: normalized, cryptor: cryptor)
        } else if let stored = try? StoredSpeechVocabularyTerm(term: normalized, cryptor: cryptor) {
            context.insert(stored)
        }
        try? context.save()
    }

    func recordCorrection(original: String, corrected: String, locale: String?) {
        let correctedText = SpeechVocabularyTerm.cleaned(corrected)
        guard !correctedText.isEmpty else { return }
        var aliases = [SpeechVocabularyTerm.cleaned(original)].filter { !$0.isEmpty && $0.caseInsensitiveCompare(correctedText) != .orderedSame }
        let records = (try? context.fetch(FetchDescriptor<StoredSpeechVocabularyTerm>())) ?? []
        let correctedKey = SpeechVocabularyTerm.normalizedKey(correctedText, locale: locale)
        if let existing = records.compactMap({ try? $0.decrypt(cryptor: cryptor) }).first(where: {
            SpeechVocabularyTerm.normalizedKey($0.text, locale: locale) == correctedKey ||
                $0.aliases.contains { SpeechVocabularyTerm.normalizedKey($0, locale: locale) == correctedKey }
        }) {
            aliases.append(contentsOf: existing.aliases)
            var updated = existing
            updated.aliases = aliases.uniquedCaseAndDiacriticInsensitive()
            updated.correctionCount += 1
            updated.useCount += 1
            updated.lastCorrectionAt = Date()
            updated.lastUsedAt = Date()
            save(updated)
        } else {
            save(SpeechVocabularyTerm(
                text: correctedText,
                locale: locale,
                category: .custom,
                aliases: aliases.uniquedCaseAndDiacriticInsensitive(),
                boost: 1.6,
                scope: .workspace,
                correctionCount: 1,
                lastCorrectionAt: Date(),
                lastUsedAt: Date(),
                useCount: 1
            ))
        }
    }

    func delete(_ term: SpeechVocabularyTerm) {
        let records = (try? context.fetch(FetchDescriptor<StoredSpeechVocabularyTerm>())) ?? []
        for record in records where record.id == term.id {
            context.delete(record)
        }
        try? context.save()
    }

    func deleteAllUserTerms() {
        let records = (try? context.fetch(FetchDescriptor<StoredSpeechVocabularyTerm>())) ?? []
        for record in records {
            if let term = try? record.decrypt(cryptor: cryptor), !term.isSystemSeed {
                context.delete(record)
            }
        }
        try? context.save()
    }

    func seedDefaultsIfNeeded(preferences: AppPreferences) {
        let existing = terms()
        let existingKeys = Set(existing.map(\.normalizedText))
        let seedTerms = Self.defaultSeedTerms(preferences: preferences)
        for term in seedTerms where !existingKeys.contains(term.normalizedText) {
            save(term)
        }
    }

    func speechContext(for session: MeetingSession, preferences: AppPreferences) -> SpeechRecognitionContext {
        seedDefaultsIfNeeded(preferences: preferences)
        return SpeechVocabularyContextBuilder().build(
            terms: terms(includeDisabled: false),
            session: session,
            preferences: preferences
        )
    }

    func ambientSpeechContext(preferences: AppPreferences) -> SpeechRecognitionContext {
        seedDefaultsIfNeeded(preferences: preferences)
        let seedPolicy = Self.seedPolicy
        let pseudoSession = MeetingSession(
            title: seedPolicy.ambientSessionTitle.nilIfEmpty ?? seedPolicy.ambientSystemTerms.first ?? "",
            source: .manual,
            primaryLanguage: SupportedLanguage.normalizedCode(preferences.defaultLanguage),
            meetingType: preferences.defaultMeetingType
        )
        return SpeechVocabularyContextBuilder().build(
            terms: terms(includeDisabled: false),
            session: pseudoSession,
            preferences: preferences,
            extraSystemTerms: seedPolicy.ambientSystemTerms
        )
    }

    func importCSV(_ csv: String, defaultLocale: String?) -> Int {
        var inserted = 0
        for row in SpeechVocabularyCSV.rows(from: csv) {
            guard let text = row["text"] ?? row["term"], !SpeechVocabularyTerm.cleaned(text).isEmpty else { continue }
            let category = row["category"].flatMap(SpeechVocabularyCategory.init(rawValue:)) ?? .custom
            let scope = row["scope"].flatMap(SpeechVocabularyScope.init(rawValue:)) ?? .global
            let aliases = (row["aliases"] ?? "").split(separator: "|").map(String.init)
            let templateSlots = (row["templateSlots"] ?? "").split(separator: "|").map(String.init)
            let term = SpeechVocabularyTerm(
                text: text,
                locale: row["locale"]?.nilIfEmpty ?? defaultLocale,
                category: category,
                aliases: aliases,
                pronunciationXSAMPA: row["pronunciationXSAMPA"]?.nilIfEmpty,
                boost: Double(row["boost"] ?? "") ?? 1,
                scope: scope,
                scopeValue: row["scopeValue"]?.nilIfEmpty,
                enabled: row["enabled"].map { $0.lowercased() != "false" } ?? true,
                notes: row["notes"]?.nilIfEmpty,
                templatePattern: row["templatePattern"]?.nilIfEmpty,
                templateSlots: templateSlots,
                correctionCount: Int(row["correctionCount"] ?? "") ?? 0
            )
            save(term)
            inserted += 1
        }
        return inserted
    }

    func exportCSV() -> String {
        let header = ["text", "locale", "category", "aliases", "pronunciationXSAMPA", "boost", "scope", "scopeValue", "enabled", "notes", "templatePattern", "templateSlots", "correctionCount"]
        let body = terms().map { term in
            [
                term.text,
                term.locale ?? "",
                term.category.rawValue,
                term.aliases.joined(separator: "|"),
                term.pronunciationXSAMPA ?? "",
                String(format: "%.2f", term.boost),
                term.scope.rawValue,
                term.scopeValue ?? "",
                term.enabled ? "true" : "false",
                term.notes ?? "",
                term.templatePattern ?? "",
                term.templateSlots.joined(separator: "|"),
                "\(term.correctionCount)"
            ].map(SpeechVocabularyCSV.escape).joined(separator: ",")
        }
        return ([header.joined(separator: ",")] + body).joined(separator: "\n")
    }

    func suggestedTerms(
        from segments: [TranscriptSegment],
        locale: String?,
        limit: Int = 12,
        runtimePolicy: SpeechVocabularyRuntimePolicy = .default
    ) -> [SpeechVocabularyTerm] {
        let runtimePolicy = runtimePolicy.normalized()
        let existingKeys = Set(terms().flatMap(\.allSpokenForms).map { SpeechVocabularyTerm.normalizedKey($0, locale: locale) })
        let tokenizer = SpeechVocabularyTokenExtractor(runtimePolicy: runtimePolicy)
        var counts: [String: Int] = [:]
        for segment in segments {
            let tokens = tokenizer.tokens(from: segment.text)
            for token in tokens {
                let cleaned = SpeechVocabularyTerm.cleaned(token)
                guard tokenizer.isCandidateSuggestion(cleaned) else { continue }
                let key = SpeechVocabularyTerm.normalizedKey(cleaned, locale: locale)
                guard !existingKeys.contains(key) else { continue }
                counts[cleaned, default: 0] += 1
            }
            for phrase in tokenizer.suggestionPhrases(from: tokens) {
                let key = SpeechVocabularyTerm.normalizedKey(phrase, locale: locale)
                guard !existingKeys.contains(key) else { continue }
                counts[phrase, default: 0] += 1
            }
        }
        return counts
            .sorted {
                if $0.value == $1.value { return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                return $0.value > $1.value
            }
            .prefix(limit)
            .map {
                SpeechVocabularyTerm(
                    text: $0.key,
                    locale: locale,
                    category: .custom,
                    boost: runtimePolicy.suggestedBoost,
                    notes: runtimePolicy.suggestedNotes
                )
            }
    }

    private static func defaultSeedTerms(preferences: AppPreferences) -> [SpeechVocabularyTerm] {
        let seedPolicy = Self.seedPolicy
        let userNames = ([preferences.userDisplayName] + preferences.userNicknames.split(separator: ",").map(String.init))
            .map(SpeechVocabularyTerm.cleaned)
            .filter { !$0.isEmpty }
            .map { SpeechVocabularyTerm(text: $0, locale: preferences.defaultLanguage, category: .person, boost: seedPolicy.userNameBoost, isSystemSeed: true) }

        let appTerms = preferences.knownMeetingApps.flatMap { app in
            ([app.displayName] + app.nameKeywords).map {
                SpeechVocabularyTerm(text: $0, locale: nil, category: .product, boost: seedPolicy.appTermBoost, isSystemSeed: true)
            }
        }

        let productTerms = seedPolicy.technicalTerms.map {
            SpeechVocabularyTerm(text: $0, locale: nil, category: .technicalTerm, boost: seedPolicy.technicalTermBoost, isSystemSeed: true)
        }

        return (userNames + appTerms + productTerms).deduplicatedTerms()
    }

    private static var seedPolicy: SpeechVocabularySeedPolicy {
        SpeechVocabularySeedPolicy.default
    }
}

struct SpeechVocabularyContextBuilder {
    var runtimePolicy: SpeechVocabularyRuntimePolicy = .default

    func build(
        terms: [SpeechVocabularyTerm],
        session: MeetingSession,
        preferences: AppPreferences,
        extraSystemTerms: [String] = []
    ) -> SpeechRecognitionContext {
        let runtimePolicy = runtimePolicy.normalized()
        let locale = SupportedLanguage.normalizedCode(session.primaryLanguage ?? preferences.defaultLanguage)
        let tokenizer = SpeechVocabularyTokenExtractor(runtimePolicy: runtimePolicy)
        var contextTerms = [SpeechContextTerm]()

        for term in terms where term.enabled && applies(term: term, session: session, preferences: preferences, locale: locale) {
            for spokenForm in term.allSpokenForms {
                contextTerms.append(SpeechContextTerm(
                    text: spokenForm,
                    locale: term.locale,
                    category: term.category,
                    weight: weightedBoost(for: term, session: session),
                    pronunciationXSAMPA: spokenForm == term.text ? term.pronunciationXSAMPA : nil,
                    source: term.isSystemSeed ? "system" : "user",
                    templatePattern: spokenForm == term.text ? term.templatePattern : nil,
                    templateSlots: spokenForm == term.text ? term.templateSlots : []
                ))
            }
        }

        let titleTokens = tokenizer.tokens(from: session.title)
        let titleTerms = titleTokens.filter {
            $0.count >= tokenizer.effectiveMinimumLength(for: $0, defaultMinimum: runtimePolicy.meetingTitleMinimumTermLength)
        }
        let titlePhrases = tokenizer.titlePhrases(from: titleTokens)
        for term in titleTerms + titlePhrases + extraSystemTerms {
            contextTerms.append(SpeechContextTerm(text: term, locale: locale, category: .shortPhrase, weight: runtimePolicy.meetingTitleTermWeight, pronunciationXSAMPA: nil, source: "meeting"))
        }

        return SpeechRecognitionContext(
            locale: locale,
            terms: contextTerms.deduplicatedContextTerms(),
            customLanguageModelEnabled: preferences.localOnlyMode,
            status: contextTerms.isEmpty ? "Apple Speech ready" : "Custom vocabulary active",
            runtimePolicy: runtimePolicy
        )
    }

    private func applies(term: SpeechVocabularyTerm, session: MeetingSession, preferences: AppPreferences, locale: String) -> Bool {
        if let termLocale = term.locale, SupportedLanguage.normalizedCode(termLocale) != locale {
            return false
        }
        switch term.scope {
        case .global:
            return true
        case .workspace:
            return term.scopeValue == nil || term.scopeValue == preferences.workspaceId
        case .meetingType:
            return term.scopeValue == nil || term.scopeValue == session.meetingType.rawValue
        case .meeting:
            return term.scopeValue == nil || term.scopeValue == session.id.uuidString
        }
    }

    private func weightedBoost(for term: SpeechVocabularyTerm, session: MeetingSession) -> Double {
        var weight = term.boost
        if term.scope == .meeting || term.scope == .meetingType {
            weight += runtimePolicy.scopedTermBoost
        }
        if session.title.localizedCaseInsensitiveContains(term.text) {
            weight += runtimePolicy.titleMentionBoost
        }
        weight += min(Double(term.useCount) / runtimePolicy.useCountWeightDivisor, runtimePolicy.useCountWeightMaximum)
        weight += min(Double(term.correctionCount) / runtimePolicy.correctionCountWeightDivisor, runtimePolicy.correctionCountWeightMaximum)
        return min(max(weight, runtimePolicy.minimumTermWeight), runtimePolicy.maximumTermWeight)
    }
}

struct SpeechVocabularyTokenExtractor {
    var runtimePolicy: SpeechVocabularyRuntimePolicy
    var textPolicy: QuestionTextSegmentationPolicy = QuestionIntentRulePack.default.textSegmentationPolicy
    var intentRulePack: QuestionIntentRulePack = .default

    func tokens(from text: String) -> [String] {
        if shouldUseNaturalLanguageTokenization(for: text) {
            let tokens = naturalLanguageTokens(from: text)
            if !tokens.isEmpty {
                return tokens
            }
        }
        return scalarSplitTokens(from: text)
    }

    func suggestionPhrases(from tokens: [String]) -> [String] {
        phrases(
            from: tokens,
            minimumTokenLength: runtimePolicy.suggestedMinimumTokenLength,
            minimumCharacterCount: runtimePolicy.suggestedPhraseMinimumCharacterCount
        )
    }

    func titlePhrases(from tokens: [String]) -> [String] {
        phrases(
            from: tokens,
            minimumTokenLength: runtimePolicy.meetingTitleMinimumTermLength,
            minimumCharacterCount: runtimePolicy.suggestedPhraseMinimumCharacterCount
        )
    }

    func isCandidateSuggestion(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let minimumLength = effectiveMinimumLength(for: text, defaultMinimum: runtimePolicy.suggestedMinimumTokenLength)
        guard text.count >= minimumLength else { return false }
        let preferredMinimum = effectiveMinimumLength(for: text, defaultMinimum: runtimePolicy.suggestedPreferredMinimumTokenLength)
        return text.contains(where: { $0.isUppercase }) || text.count >= preferredMinimum
    }

    func effectiveMinimumLength(for text: String, defaultMinimum: Int) -> Int {
        guard textPolicy.containsCompactScript(in: text) else {
            return defaultMinimum
        }
        return min(defaultMinimum, runtimePolicy.compactScriptMinimumTermLength)
    }

    private func phrases(
        from rawTokens: [String],
        minimumTokenLength: Int,
        minimumCharacterCount: Int
    ) -> [String] {
        let tokens = rawTokens
            .map(SpeechVocabularyTerm.cleaned)
            .filter { isPhraseToken($0, minimumTokenLength: minimumTokenLength) }
        guard tokens.count >= runtimePolicy.suggestedPhraseMinimumTokenCount else { return [] }

        var phrases: [String] = []
        let maximumCount = min(runtimePolicy.suggestedPhraseMaximumTokenCount, tokens.count)
        for tokenCount in runtimePolicy.suggestedPhraseMinimumTokenCount...maximumCount {
            guard tokens.count >= tokenCount else { continue }
            for start in 0...(tokens.count - tokenCount) {
                let phrase = tokens[start..<(start + tokenCount)].joined(separator: " ")
                let characterCount = phrase.filter { !$0.isWhitespace }.count
                guard characterCount >= effectiveMinimumLength(for: phrase, defaultMinimum: minimumCharacterCount) else {
                    continue
                }
                phrases.append(phrase)
            }
        }
        return phrases
    }

    private func isPhraseToken(_ text: String, minimumTokenLength: Int) -> Bool {
        guard !text.isEmpty else { return false }
        guard text.count >= effectiveMinimumLength(for: text, defaultMinimum: minimumTokenLength) else { return false }
        let normalized = SpeechVocabularyTerm.normalizedKey(text)
        guard !intentRulePack.stopWords.contains(normalized),
              !intentRulePack.lowInformationWords.contains(normalized) else {
            return false
        }
        return text.contains { $0.isLetter || $0.isNumber }
    }

    private func shouldUseNaturalLanguageTokenization(for text: String) -> Bool {
        switch runtimePolicy.tokenizationStrategy {
        case .scalarSplit:
            return false
        case .naturalLanguage:
            return true
        case .automatic:
            return textPolicy.containsCompactScript(in: text)
        }
    }

    private func naturalLanguageTokens(from text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let cleaned = SpeechVocabularyTerm.cleaned(String(text[range]))
            guard !cleaned.isEmpty else { return true }
            tokens.append(cleaned)
            return true
        }
        return tokens
    }

    private func scalarSplitTokens(from text: String) -> [String] {
        text
            .split { !runtimePolicy.isSuggestionTokenCharacter($0) }
            .map(String.init)
    }
}

struct AppleSpeechAlternativeRescorer {
    func rescore(formattedString: String, segments: [SFTranscriptionSegment], context: SpeechRecognitionContext) -> String {
        guard !segments.isEmpty, !context.terms.isEmpty else { return formattedString }
        let runtimePolicy = context.runtimePolicy.normalized()
        let vocabulary = Set(context.terms.map(\.normalizedText))
        let mutable = NSMutableString(string: formattedString)

        for segment in segments.reversed() {
            let confidence = Double(segment.confidence)
            guard confidence < runtimePolicy.rescoreLowConfidenceThreshold, segment.substringRange.location != NSNotFound else { continue }
            let currentKey = SpeechVocabularyTerm.normalizedKey(segment.substring, locale: context.locale)
            if vocabulary.contains(currentKey), confidence >= runtimePolicy.rescoreExistingTermConfidenceFloor {
                continue
            }
            guard let replacement = segment.alternativeSubstrings.first(where: { alternative in
                let key = SpeechVocabularyTerm.normalizedKey(alternative, locale: context.locale)
                return key != currentKey && vocabulary.contains(key)
            }) else {
                continue
            }
            let range = segment.substringRange
            guard range.location >= 0, range.location + range.length <= mutable.length else { continue }
            mutable.replaceCharacters(in: range, with: replacement)
        }

        return String(mutable).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

actor AppleCustomLanguageModelManager {
    static let shared = AppleCustomLanguageModelManager()

    private struct PreparedModel {
        var hash: String
        var configuration: SFSpeechLanguageModel.Configuration
    }

    private var preparedModels: [String: PreparedModel] = [:]
    private var failedHashes = Set<String>()

    func configuration(for context: SpeechRecognitionContext, languageCode: String?) async -> SFSpeechLanguageModel.Configuration? {
        guard #available(macOS 14.0, *) else { return nil }
        let localeIdentifier = SupportedLanguage.normalizedCode(context.locale ?? languageCode)
        guard context.customLanguageModelEnabled else { return nil }
        let terms = context.activeTermsForLanguageModel
        guard !terms.isEmpty else { return nil }

        let hash = context.stableHash
        let cacheKey = "\(localeIdentifier)-\(hash)"
        if let prepared = preparedModels[cacheKey] {
            return prepared.configuration
        }
        guard !failedHashes.contains(cacheKey) else { return nil }

        do {
            let configuration = try await prepareModel(localeIdentifier: localeIdentifier, terms: terms, hash: hash, runtimePolicy: context.runtimePolicy)
            preparedModels[cacheKey] = PreparedModel(hash: hash, configuration: configuration)
            return configuration
        } catch {
            failedHashes.insert(cacheKey)
            AppLog.audio.error("Apple custom speech vocabulary unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func prepareModel(
        localeIdentifier: String,
        terms: [SpeechContextTerm],
        hash: String,
        runtimePolicy: SpeechVocabularyRuntimePolicy
    ) async throws -> SFSpeechLanguageModel.Configuration {
        let directory = try FileStorageService.applicationSupportDirectory()
            .appending(path: "SpeechVocabularyModels", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let assetURL = directory.appending(path: "\(localeIdentifier)-\(hash).bin")
        let modelURL = directory.appending(path: "\(localeIdentifier)-\(hash).lm")
        let vocabularyURL = directory.appending(path: "\(localeIdentifier)-\(hash).vocab")
        let configuration = SFSpeechLanguageModel.Configuration(languageModel: modelURL, vocabulary: vocabularyURL)

        if FileManager.default.fileExists(atPath: modelURL.path) {
            return configuration
        }

        let data = SFCustomLanguageModelData(
            locale: Locale(identifier: localeIdentifier),
            identifier: "NotchCopilot.\(localeIdentifier)",
            version: hash
        )
        let supportedPhonemes = Set(SFCustomLanguageModelData.supportedPhonemes(locale: Locale(identifier: localeIdentifier)))
        let templateGenerator = SFCustomLanguageModelData.TemplatePhraseCountGenerator()
        var hasTemplates = false
        let runtimePolicy = runtimePolicy.normalized()
        for term in terms {
            let count = max(1, Int((runtimePolicy.languageModelPhraseCountMultiplier * term.weight).rounded()))
            data.insert(phraseCount: SFCustomLanguageModelData.PhraseCount(phrase: term.text, count: count))
            if let pronunciation = term.pronunciationXSAMPA {
                let phonemes = pronunciation.split(separator: " ").map(String.init).filter { !$0.isEmpty }
                if !phonemes.isEmpty, phonemes.allSatisfy({ supportedPhonemes.contains($0) }) {
                    data.insert(term: SFCustomLanguageModelData.CustomPronunciation(grapheme: term.text, phonemes: phonemes))
                } else if !phonemes.isEmpty {
                    AppLog.audio.info("Skipping unsupported X-SAMPA pronunciation for \(term.text, privacy: .public)")
                }
            }
            if let templatePattern = term.templatePattern,
               !term.templateSlots.isEmpty {
                let className = "term\(abs(term.normalizedText.hashValue))"
                templateGenerator.define(className: className, values: term.templateSlots)
                templateGenerator.insert(
                    template: Self.appleTemplate(from: templatePattern, className: className),
                    count: max(1, Int((runtimePolicy.languageModelTemplateCountMultiplier * term.weight).rounded()))
                )
                hasTemplates = true
            }
        }
        if hasTemplates {
            data.insert(phraseCountGenerator: templateGenerator)
        }
        try await data.export(to: assetURL)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            SFSpeechLanguageModel.prepareCustomLanguageModel(for: assetURL, configuration: configuration) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return configuration
    }

    private static func appleTemplate(from pattern: String, className: String) -> String {
        let cleaned = SpeechVocabularyTerm.cleaned(pattern)
        guard !cleaned.isEmpty else { return "<\(className)>" }
        let replaced = cleaned.replacingOccurrences(
            of: #"\{[^}]+\}"#,
            with: "<\(className)>",
            options: .regularExpression
        )
        return replaced.contains("<\(className)>") ? replaced : "\(replaced) <\(className)>"
    }
}

private enum SpeechVocabularyCSV {
    static func rows(from csv: String) -> [[String: String]] {
        let rows = csv.split(whereSeparator: \.isNewline).map(parseLine)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }), !header.isEmpty else { return [] }
        return rows.dropFirst().map { values in
            Dictionary(uniqueKeysWithValues: zip(header, values + Array(repeating: "", count: max(0, header.count - values.count))))
        }
    }

    static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private static func parseLine(_ line: Substring) -> [String] {
        var values = [String]()
        var current = ""
        var isQuoted = false
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            if character == "\"" {
                if isQuoted, let next = iterator.next() {
                    if next == "\"" {
                        current.append("\"")
                    } else {
                        isQuoted = false
                        if next == "," {
                            values.append(current)
                            current = ""
                        } else {
                            current.append(next)
                        }
                    }
                } else {
                    isQuoted.toggle()
                }
            } else if character == "," && !isQuoted {
                values.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        values.append(current)
        return values
    }
}

private extension Array where Element == String {
    func uniquedCaseAndDiacriticInsensitive() -> [String] {
        var seen = Set<String>()
        return filter { value in
            seen.insert(SpeechVocabularyTerm.normalizedKey(value)).inserted
        }
    }
}

private extension Array where Element == SpeechVocabularyTerm {
    func deduplicatedTerms() -> [SpeechVocabularyTerm] {
        var seen = Set<String>()
        return filter { term in
            seen.insert(term.normalizedText).inserted
        }
    }
}

private extension Array where Element == SpeechContextTerm {
    func deduplicatedContextTerms() -> [SpeechContextTerm] {
        var bestByKey: [String: SpeechContextTerm] = [:]
        for term in self {
            guard !SpeechVocabularyTerm.cleaned(term.text).isEmpty else { continue }
            if let existing = bestByKey[term.normalizedText], existing.weight >= term.weight {
                continue
            }
            bestByKey[term.normalizedText] = term
        }
        return bestByKey.values.sorted {
            if $0.weight == $1.weight { return $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending }
            return $0.weight > $1.weight
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
