import Foundation
import NaturalLanguage

enum RAGQuestionTokenizationStrategy: String, Codable, Hashable, Sendable {
    case scalarSplit
    case naturalLanguage
    case automatic
}

struct RAGQuestionContextPolicy: Codable, Hashable, Sendable {
    var queryExpansions: [String: [String]]
    var entityMarkers: [String]
    var stopWords: Set<String>
    var lowInformationWords: Set<String>
    var maxExtractedTerms: Int
    var maxFallbackTerms: Int
    var minimumExtractedTermLength: Int
    var minimumFallbackTermLength: Int
    var extractedTermPreservedCharacters: Set<String>
    var fallbackTermPreservedCharacters: Set<String>
    var dynamicEntityExtractionEnabled: Bool
    var maxDynamicEntities: Int
    var maxDynamicPhrases: Int
    var dynamicPhraseMinimumTokenLength: Int
    var dynamicPhraseMinimumTokenCount: Int
    var dynamicPhraseMaximumTokenCount: Int
    var dynamicPhrasePreservedCharacters: Set<String>
    var tokenizationStrategy: RAGQuestionTokenizationStrategy
    var compactScriptMinimumTermLength: Int
    var contextualCarryoverEnabled: Bool
    var maxContextualCarryoverTerms: Int
    var contextualCarryoverMinimumQuestionTerms: Int
    var contextualCarryoverMinimumTermLength: Int
    var contextualCarryoverPreservedCharacters: Set<String>

    init(
        queryExpansions: [String: [String]],
        entityMarkers: [String],
        stopWords: Set<String>,
        lowInformationWords: Set<String> = [],
        maxExtractedTerms: Int,
        maxFallbackTerms: Int,
        minimumExtractedTermLength: Int = 3,
        minimumFallbackTermLength: Int = 1,
        extractedTermPreservedCharacters: Set<String> = [],
        fallbackTermPreservedCharacters: Set<String> = [],
        dynamicEntityExtractionEnabled: Bool = false,
        maxDynamicEntities: Int = 0,
        maxDynamicPhrases: Int = 0,
        dynamicPhraseMinimumTokenLength: Int = 3,
        dynamicPhraseMinimumTokenCount: Int = 2,
        dynamicPhraseMaximumTokenCount: Int = 3,
        dynamicPhrasePreservedCharacters: Set<String> = [],
        tokenizationStrategy: RAGQuestionTokenizationStrategy = .scalarSplit,
        compactScriptMinimumTermLength: Int = 2,
        contextualCarryoverEnabled: Bool = false,
        maxContextualCarryoverTerms: Int = 0,
        contextualCarryoverMinimumQuestionTerms: Int = 1,
        contextualCarryoverMinimumTermLength: Int = 3,
        contextualCarryoverPreservedCharacters: Set<String> = []
    ) {
        self.queryExpansions = queryExpansions
        self.entityMarkers = entityMarkers
        self.stopWords = stopWords
        self.lowInformationWords = lowInformationWords
        self.maxExtractedTerms = maxExtractedTerms
        self.maxFallbackTerms = maxFallbackTerms
        self.minimumExtractedTermLength = minimumExtractedTermLength
        self.minimumFallbackTermLength = minimumFallbackTermLength
        self.extractedTermPreservedCharacters = extractedTermPreservedCharacters
        self.fallbackTermPreservedCharacters = fallbackTermPreservedCharacters
        self.dynamicEntityExtractionEnabled = dynamicEntityExtractionEnabled
        self.maxDynamicEntities = maxDynamicEntities
        self.maxDynamicPhrases = maxDynamicPhrases
        self.dynamicPhraseMinimumTokenLength = dynamicPhraseMinimumTokenLength
        self.dynamicPhraseMinimumTokenCount = dynamicPhraseMinimumTokenCount
        self.dynamicPhraseMaximumTokenCount = dynamicPhraseMaximumTokenCount
        self.dynamicPhrasePreservedCharacters = dynamicPhrasePreservedCharacters
        self.tokenizationStrategy = tokenizationStrategy
        self.compactScriptMinimumTermLength = compactScriptMinimumTermLength
        self.contextualCarryoverEnabled = contextualCarryoverEnabled
        self.maxContextualCarryoverTerms = maxContextualCarryoverTerms
        self.contextualCarryoverMinimumQuestionTerms = contextualCarryoverMinimumQuestionTerms
        self.contextualCarryoverMinimumTermLength = contextualCarryoverMinimumTermLength
        self.contextualCarryoverPreservedCharacters = contextualCarryoverPreservedCharacters
    }

    private enum CodingKeys: String, CodingKey {
        case queryExpansions
        case entityMarkers
        case stopWords
        case lowInformationWords
        case maxExtractedTerms
        case maxFallbackTerms
        case minimumExtractedTermLength
        case minimumFallbackTermLength
        case extractedTermPreservedCharacters
        case fallbackTermPreservedCharacters
        case dynamicEntityExtractionEnabled
        case maxDynamicEntities
        case maxDynamicPhrases
        case dynamicPhraseMinimumTokenLength
        case dynamicPhraseMinimumTokenCount
        case dynamicPhraseMaximumTokenCount
        case dynamicPhrasePreservedCharacters
        case tokenizationStrategy
        case compactScriptMinimumTermLength
        case contextualCarryoverEnabled
        case maxContextualCarryoverTerms
        case contextualCarryoverMinimumQuestionTerms
        case contextualCarryoverMinimumTermLength
        case contextualCarryoverPreservedCharacters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            queryExpansions: try container.decodeIfPresent([String: [String]].self, forKey: .queryExpansions) ?? [:],
            entityMarkers: try container.decodeIfPresent([String].self, forKey: .entityMarkers) ?? [],
            stopWords: try container.decodeIfPresent(Set<String>.self, forKey: .stopWords) ?? [],
            lowInformationWords: try container.decodeIfPresent(Set<String>.self, forKey: .lowInformationWords) ?? [],
            maxExtractedTerms: try container.decodeIfPresent(Int.self, forKey: .maxExtractedTerms) ?? 10,
            maxFallbackTerms: try container.decodeIfPresent(Int.self, forKey: .maxFallbackTerms) ?? 8,
            minimumExtractedTermLength: try container.decodeIfPresent(Int.self, forKey: .minimumExtractedTermLength) ?? 3,
            minimumFallbackTermLength: try container.decodeIfPresent(Int.self, forKey: .minimumFallbackTermLength) ?? 1,
            extractedTermPreservedCharacters: try container.decodeIfPresent(Set<String>.self, forKey: .extractedTermPreservedCharacters) ?? [],
            fallbackTermPreservedCharacters: try container.decodeIfPresent(Set<String>.self, forKey: .fallbackTermPreservedCharacters) ?? [],
            dynamicEntityExtractionEnabled: try container.decodeIfPresent(Bool.self, forKey: .dynamicEntityExtractionEnabled) ?? false,
            maxDynamicEntities: try container.decodeIfPresent(Int.self, forKey: .maxDynamicEntities) ?? 0,
            maxDynamicPhrases: try container.decodeIfPresent(Int.self, forKey: .maxDynamicPhrases) ?? 0,
            dynamicPhraseMinimumTokenLength: try container.decodeIfPresent(Int.self, forKey: .dynamicPhraseMinimumTokenLength) ?? 3,
            dynamicPhraseMinimumTokenCount: try container.decodeIfPresent(Int.self, forKey: .dynamicPhraseMinimumTokenCount) ?? 2,
            dynamicPhraseMaximumTokenCount: try container.decodeIfPresent(Int.self, forKey: .dynamicPhraseMaximumTokenCount) ?? 3,
            dynamicPhrasePreservedCharacters: try container.decodeIfPresent(Set<String>.self, forKey: .dynamicPhrasePreservedCharacters) ?? [],
            tokenizationStrategy: try container.decodeIfPresent(RAGQuestionTokenizationStrategy.self, forKey: .tokenizationStrategy) ?? .scalarSplit,
            compactScriptMinimumTermLength: try container.decodeIfPresent(Int.self, forKey: .compactScriptMinimumTermLength) ?? 2,
            contextualCarryoverEnabled: try container.decodeIfPresent(Bool.self, forKey: .contextualCarryoverEnabled) ?? false,
            maxContextualCarryoverTerms: try container.decodeIfPresent(Int.self, forKey: .maxContextualCarryoverTerms) ?? 0,
            contextualCarryoverMinimumQuestionTerms: try container.decodeIfPresent(Int.self, forKey: .contextualCarryoverMinimumQuestionTerms) ?? 1,
            contextualCarryoverMinimumTermLength: try container.decodeIfPresent(Int.self, forKey: .contextualCarryoverMinimumTermLength) ?? 3,
            contextualCarryoverPreservedCharacters: try container.decodeIfPresent(Set<String>.self, forKey: .contextualCarryoverPreservedCharacters) ?? []
        )
    }

    static let `default` = RAGQuestionContextPolicyStore.current

    func expansionTerms(for type: QuestionType) -> [String] {
        queryExpansions[type.rawValue] ?? []
    }
}

enum RAGQuestionContextPolicyStore {
    static let current: RAGQuestionContextPolicy = load()

    private static func load() -> RAGQuestionContextPolicy {
        let decoder = JSONDecoder()
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let policy = try? decoder.decode(RAGQuestionContextPolicy.self, from: data) else {
                continue
            }
            return policy.normalized()
        }
        return fallbackPolicy()
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let bundles = [Bundle.main, Bundle(for: RAGQuestionContextPolicyBundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "question-rag-policy",
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
                .appendingPathComponent("Resources/CopilotIntentPolicy/question-rag-policy.json")
        )
        return urls
    }

    private static func fallbackPolicy() -> RAGQuestionContextPolicy {
        RAGQuestionContextPolicy(
            queryExpansions: [:],
            entityMarkers: [],
            stopWords: [],
            lowInformationWords: [],
            maxExtractedTerms: 10,
            maxFallbackTerms: 8,
            minimumExtractedTermLength: 3,
            minimumFallbackTermLength: 1,
            extractedTermPreservedCharacters: [],
            fallbackTermPreservedCharacters: [],
            dynamicEntityExtractionEnabled: false,
            maxDynamicEntities: 0,
            maxDynamicPhrases: 0,
            dynamicPhraseMinimumTokenLength: 3,
            dynamicPhraseMinimumTokenCount: 2,
            dynamicPhraseMaximumTokenCount: 3,
            dynamicPhrasePreservedCharacters: [],
            tokenizationStrategy: .scalarSplit,
            compactScriptMinimumTermLength: 2,
            contextualCarryoverEnabled: false,
            maxContextualCarryoverTerms: 0,
            contextualCarryoverMinimumQuestionTerms: 1,
            contextualCarryoverMinimumTermLength: 3,
            contextualCarryoverPreservedCharacters: []
        )
    }
}

private final class RAGQuestionContextPolicyBundleMarker {}

private extension RAGQuestionContextPolicy {
    func normalized() -> RAGQuestionContextPolicy {
        let normalizedPhraseMinimumCount = max(1, dynamicPhraseMinimumTokenCount)
        return RAGQuestionContextPolicy(
            queryExpansions: queryExpansions.reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value.map(QuestionDetectionService.normalize).filter { !$0.isEmpty }
            },
            entityMarkers: entityMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            stopWords: Set(stopWords.map(QuestionDetectionService.normalize).filter { !$0.isEmpty }),
            lowInformationWords: Set(lowInformationWords.map(QuestionDetectionService.normalize).filter { !$0.isEmpty }),
            maxExtractedTerms: max(1, maxExtractedTerms),
            maxFallbackTerms: max(1, maxFallbackTerms),
            minimumExtractedTermLength: max(1, minimumExtractedTermLength),
            minimumFallbackTermLength: max(1, minimumFallbackTermLength),
            extractedTermPreservedCharacters: Set(extractedTermPreservedCharacters.filter { $0.count == 1 }),
            fallbackTermPreservedCharacters: Set(fallbackTermPreservedCharacters.filter { $0.count == 1 }),
            dynamicEntityExtractionEnabled: dynamicEntityExtractionEnabled,
            maxDynamicEntities: max(0, maxDynamicEntities),
            maxDynamicPhrases: max(0, maxDynamicPhrases),
            dynamicPhraseMinimumTokenLength: max(1, dynamicPhraseMinimumTokenLength),
            dynamicPhraseMinimumTokenCount: normalizedPhraseMinimumCount,
            dynamicPhraseMaximumTokenCount: max(normalizedPhraseMinimumCount, dynamicPhraseMaximumTokenCount),
            dynamicPhrasePreservedCharacters: Set(dynamicPhrasePreservedCharacters.filter { $0.count == 1 }),
            tokenizationStrategy: tokenizationStrategy,
            compactScriptMinimumTermLength: max(1, compactScriptMinimumTermLength),
            contextualCarryoverEnabled: contextualCarryoverEnabled,
            maxContextualCarryoverTerms: max(0, maxContextualCarryoverTerms),
            contextualCarryoverMinimumQuestionTerms: max(0, contextualCarryoverMinimumQuestionTerms),
            contextualCarryoverMinimumTermLength: max(1, contextualCarryoverMinimumTermLength),
            contextualCarryoverPreservedCharacters: Set(contextualCarryoverPreservedCharacters.filter { $0.count == 1 })
        )
    }
}

struct RAGQuestionContextBuilder {
    var policy: RAGQuestionContextPolicy = .default
    var textPolicy: QuestionTextSegmentationPolicy = QuestionIntentRulePack.default.textSegmentationPolicy
    var intentRulePack: QuestionIntentRulePack = .default

    func query(
        for question: QuestionCandidate,
        classification: QuestionClassification,
        context: TranscriptContext? = nil
    ) -> String {
        let semanticText = semanticQuestionText(for: question, classification: classification)
        let text = QuestionDetectionService.normalize(semanticText)
        var terms = policy.expansionTerms(for: classification.questionType)

        terms += extractEntities(from: text)
        terms += extractDynamicEntities(from: semanticText)
        terms += extractDynamicPhrases(from: semanticText)
        terms += extractedQuestionTerms(from: text)
        terms += contextualCarryoverTerms(
            from: context,
            questionText: text,
            currentQuestionText: question.rawText,
            existingTerms: Set(terms)
        )
        if terms.isEmpty {
            terms = fallbackTerms(from: text)
        }
        return Array(NSOrderedSet(array: terms)).compactMap { $0 as? String }.joined(separator: " ")
    }

    private func semanticQuestionText(
        for question: QuestionCandidate,
        classification: QuestionClassification
    ) -> String {
        let extracted = classification.extractedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        return extracted.isEmpty ? question.rawText : extracted
    }

    private func extractEntities(from text: String) -> [String] {
        policy.entityMarkers.filter { marker in
            textPolicy.containsMarker(marker, in: text)
        }
    }

    private func extractDynamicEntities(from text: String) -> [String] {
        guard policy.dynamicEntityExtractionEnabled, policy.maxDynamicEntities > 0 else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let range = text.startIndex..<text.endIndex
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        var terms: [String] = []
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            guard let tag,
                  tag == .organizationName || tag == .personalName || tag == .placeName else {
                return true
            }
            let term = normalizedMeaningfulTerm(String(text[tokenRange]), minimumLength: policy.dynamicPhraseMinimumTokenLength)
            guard let term, !terms.contains(term) else { return true }
            terms.append(term)
            return terms.count < policy.maxDynamicEntities
        }
        return terms
    }

    private func extractDynamicPhrases(from text: String) -> [String] {
        guard policy.maxDynamicPhrases > 0 else { return [] }
        let tokens = normalizedTermTokens(
            from: text,
            minimumLength: policy.dynamicPhraseMinimumTokenLength,
            preservedCharacters: policy.dynamicPhrasePreservedCharacters,
            filtersLowInformationTerms: true
        )
        guard tokens.count >= policy.dynamicPhraseMinimumTokenCount else { return [] }

        var phrases: [String] = []
        let maximumLength = min(policy.dynamicPhraseMaximumTokenCount, tokens.count)
        for length in policy.dynamicPhraseMinimumTokenCount...maximumLength {
            guard tokens.count >= length else { continue }
            for start in 0...(tokens.count - length) {
                let phrase = tokens[start..<(start + length)].joined(separator: " ")
                guard !phrases.contains(phrase) else { continue }
                phrases.append(phrase)
                if phrases.count >= policy.maxDynamicPhrases {
                    return phrases
                }
            }
        }
        return phrases
    }

    private func extractedQuestionTerms(from text: String) -> [String] {
        Array(
            normalizedTermTokens(
                from: text,
                minimumLength: policy.minimumExtractedTermLength,
                preservedCharacters: policy.extractedTermPreservedCharacters,
                filtersLowInformationTerms: true
            )
                .prefix(policy.maxExtractedTerms)
        )
    }

    private func fallbackTerms(from text: String) -> [String] {
        Array(
            normalizedTermTokens(
                from: text,
                minimumLength: policy.minimumFallbackTermLength,
                preservedCharacters: policy.fallbackTermPreservedCharacters,
                filtersLowInformationTerms: false
            )
                .prefix(policy.maxFallbackTerms)
        )
    }

    private func contextualCarryoverTerms(
        from context: TranscriptContext?,
        questionText: String,
        currentQuestionText: String,
        existingTerms: Set<String>
    ) -> [String] {
        guard policy.contextualCarryoverEnabled,
              policy.maxContextualCarryoverTerms > 0,
              shouldUseContextualCarryover(questionText: questionText, existingTerms: existingTerms),
              let contextLines = contextualTranscriptLines(from: context, excluding: [questionText, QuestionDetectionService.normalize(currentQuestionText)]),
              !contextLines.isEmpty else {
            return []
        }

        var terms: [String] = []
        for contextLine in contextLines {
            let contextPhrases = extractDynamicPhrases(from: contextLine)
            let contextTokens = normalizedTermTokens(
                from: contextLine,
                minimumLength: policy.contextualCarryoverMinimumTermLength,
                preservedCharacters: policy.contextualCarryoverPreservedCharacters,
                filtersLowInformationTerms: true
            )
            for term in contextPhrases + contextTokens {
                guard !existingTerms.contains(term), !terms.contains(term) else { continue }
                terms.append(term)
                if terms.count >= policy.maxContextualCarryoverTerms {
                    return terms
                }
            }
        }
        return terms
    }

    private func shouldUseContextualCarryover(questionText: String, existingTerms: Set<String>) -> Bool {
        if existingTerms.count <= policy.contextualCarryoverMinimumQuestionTerms {
            return true
        }
        return textPolicy.lexicalTokens(in: questionText).contains { token in
            intentRulePack.contextualPronouns.contains(token)
        }
    }

    private func contextualTranscriptLines(from context: TranscriptContext?, excluding excludedTexts: Set<String>) -> [String]? {
        guard let context else { return nil }
        let currentSegmentText = context.currentSegment.map { QuestionDetectionService.normalize($0.text) }
        let sources = [context.recentTranscript, context.mediumTranscript, context.completeTranscript]
        var seen: Set<String> = []
        var lines: [String] = []

        for source in sources where !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for rawLine in source.split(whereSeparator: \.isNewline).map(String.init).reversed() {
                let line = stripTranscriptPrefix(from: rawLine)
                let normalized = QuestionIntentGate.plainQuestionText(
                    QuestionDetectionService.normalize(line),
                    textPolicy: textPolicy
                )
                guard !isExcludedContextLine(
                    normalized,
                    excludedTexts: excludedTexts,
                    currentSegmentText: currentSegmentText
                ),
                      seen.insert(normalized).inserted else {
                    continue
                }
                lines.append(line)
            }
        }

        return lines.isEmpty ? nil : lines
    }

    private func isExcludedContextLine(
        _ normalizedLine: String,
        excludedTexts: Set<String>,
        currentSegmentText: String?
    ) -> Bool {
        guard !normalizedLine.isEmpty else { return true }

        if currentSegmentText.map({ isContextLine(normalizedLine, equivalentTo: $0) }) == true {
            return true
        }

        return excludedTexts.contains { excluded in
            isContextLine(normalizedLine, equivalentTo: excluded)
        }
    }

    private func isContextLine(_ normalizedLine: String, equivalentTo excludedText: String) -> Bool {
        let excluded = QuestionIntentGate.plainQuestionText(
            QuestionDetectionService.normalize(excludedText),
            textPolicy: textPolicy
        )
        guard !excluded.isEmpty else { return false }
        return normalizedLine == excluded
            || textPolicy.containsMarker(excluded, in: normalizedLine)
            || textPolicy.containsMarker(normalizedLine, in: excluded)
    }

    private func stripTranscriptPrefix(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return trimmed }
        let prefix = trimmed[..<colon]
        guard prefix.contains("[") || prefix.unicodeScalars.allSatisfy({
            CharacterSet.letters.contains($0)
                || CharacterSet.decimalDigits.contains($0)
                || CharacterSet.whitespaces.contains($0)
                || CharacterSet.punctuationCharacters.contains($0)
        }) else {
            return trimmed
        }
        let remainder = trimmed[trimmed.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? trimmed : String(remainder)
    }

    private func isTermCharacter(_ character: Character, preservedCharacters: Set<String>) -> Bool {
        character.isLetter || character.isNumber || preservedCharacters.contains(String(character))
    }

    private func normalizedMeaningfulTerm(_ term: String, minimumLength: Int) -> String? {
        let normalized = QuestionDetectionService.normalize(term)
        guard normalized.count >= effectiveMinimumLength(for: normalized, defaultMinimum: minimumLength),
              !policy.stopWords.contains(normalized),
              !policy.lowInformationWords.contains(normalized) else {
            return nil
        }
        return normalized
    }

    private func normalizedTermTokens(
        from text: String,
        minimumLength: Int,
        preservedCharacters: Set<String>,
        filtersLowInformationTerms: Bool
    ) -> [String] {
        termTokens(from: text, preservedCharacters: preservedCharacters).compactMap { token in
            let normalized = QuestionDetectionService.normalize(token)
            guard normalized.count >= effectiveMinimumLength(for: normalized, defaultMinimum: minimumLength) else {
                return nil
            }
            if filtersLowInformationTerms,
               policy.stopWords.contains(normalized) || policy.lowInformationWords.contains(normalized) {
                return nil
            }
            return normalized
        }
    }

    private func termTokens(from text: String, preservedCharacters: Set<String>) -> [String] {
        if shouldUseNaturalLanguageTokenization(for: text, preservedCharacters: preservedCharacters) {
            let tokens = naturalLanguageTokens(from: text)
            if !tokens.isEmpty {
                return tokens
            }
        }
        return scalarSplitTokens(from: text, preservedCharacters: preservedCharacters)
    }

    private func shouldUseNaturalLanguageTokenization(for text: String, preservedCharacters: Set<String>) -> Bool {
        switch policy.tokenizationStrategy {
        case .scalarSplit:
            return false
        case .naturalLanguage:
            return true
        case .automatic:
            guard textPolicy.containsCompactScript(in: text) else { return false }
            return !text.contains { preservedCharacters.contains(String($0)) }
        }
    }

    private func naturalLanguageTokens(from text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            tokens.append(String(text[range]))
            return true
        }
        return tokens
    }

    private func scalarSplitTokens(from text: String, preservedCharacters: Set<String>) -> [String] {
        text
            .split { !isTermCharacter($0, preservedCharacters: preservedCharacters) }
            .map(String.init)
    }

    private func effectiveMinimumLength(for normalizedTerm: String, defaultMinimum: Int) -> Int {
        guard textPolicy.containsCompactScript(in: normalizedTerm) else {
            return defaultMinimum
        }
        return min(defaultMinimum, policy.compactScriptMinimumTermLength)
    }
}
