import Foundation
import NaturalLanguage
import SwiftUI

#if canImport(Translation)
@preconcurrency import Translation
#endif

#if canImport(_Translation_SwiftUI)
@preconcurrency import _Translation_SwiftUI
#endif

enum AppleTranslationServiceError: LocalizedError {
    case unavailable
    case unsupportedLanguagePair
    case languagePairNotInstalled
    case noMeaningfulTranslation

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple Translation is unavailable on this macOS version."
        case .unsupportedLanguagePair:
            "Apple Translation does not support this language pair."
        case .languagePairNotInstalled:
            "The Apple Translation language pair is supported but not installed."
        case .noMeaningfulTranslation:
            "The translation output matched the original text."
        }
    }
}

@MainActor
protocol AppleTranslationProviding {
    func supports(source: String, target: String) async -> Bool
    func translate(_ text: String, source: String?, target: String) async throws -> String
}

enum TranslationResult: Equatable {
    case translated(
        text: String,
        engine: EngineName,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        phase: TranslationPhase,
        confidence: Double,
        preservedTerms: [String],
        isSemanticRefinement: Bool
    )
    case preserved(
        text: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        confidence: Double,
        preservedTerms: [String]
    )
    case unavailable(reason: String)
    case failed(reason: String)

    var translatedText: String? {
        if case let .translated(text, _, _, _, _, _, _, _) = self {
            return text
        }
        if case let .preserved(text, _, _, _, _) = self {
            return text
        }
        return nil
    }

    var state: TranslationState {
        switch self {
        case .translated: .translated
        case .preserved: .preserved
        case .unavailable: .unavailable
        case .failed: .failed
        }
    }
}

struct TranslationRequestMetadata: Equatable {
    var phase: TranslationPhase
    var confidence: Double
    var preservedTerms: [String]
    var isSemanticRefinement: Bool

    static let draft = TranslationRequestMetadata(
        phase: .draft,
        confidence: 0.74,
        preservedTerms: [],
        isSemanticRefinement: false
    )

    static let refinement = TranslationRequestMetadata(
        phase: .refinement,
        confidence: 0.9,
        preservedTerms: [],
        isSemanticRefinement: false
    )
}

struct TranslationOutputValidator {
    static func validated(_ translatedText: String, originalText: String, source: SupportedLanguage, target: SupportedLanguage) -> String? {
        let trimmed = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isMeaningful(trimmed, originalText: originalText, source: source, target: target) else { return nil }
        guard isTargetLanguagePlausible(trimmed, source: source, target: target) else { return nil }
        return trimmed
    }

    static func isMeaningful(_ translatedText: String, originalText: String, source: SupportedLanguage, target: SupportedLanguage) -> Bool {
        guard source != target else { return true }
        return canonicalText(translatedText) != canonicalText(originalText)
    }

    private static func canonicalText(_ text: String) -> String {
        textWithoutLanguagePrefix(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func textWithoutLanguagePrefix(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["[English]", "[Português]", "[Portuguese]"] where trimmed.hasPrefix(prefix) {
            trimmed.removeFirst(prefix.count)
            return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func isTargetLanguagePlausible(_ text: String, source: SupportedLanguage, target: SupportedLanguage) -> Bool {
        guard source != target else { return true }
        let tokens = lexicalTokens(in: text)
        guard text.count >= 18, tokens.count >= 4 else { return true }
        if technicalTokenRatio(tokens) >= 0.45 { return true }

        guard let detection = AppleLanguageDetectionService().detectedLanguage(for: text, minimumConfidence: 0.48),
              let detectedLanguage = SupportedLanguage.language(for: detection.languageCode) else {
            return true
        }
        if detectedLanguage == target { return true }
        if detectedLanguage == source, detection.confidence >= 0.5 { return false }
        return detection.confidence < 0.72
    }

    private static func lexicalTokens(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func technicalTokenRatio(_ tokens: [String]) -> Double {
        guard !tokens.isEmpty else { return 0 }
        let technicalCount = tokens.filter(isTechnicalToken).count
        return Double(technicalCount) / Double(tokens.count)
    }

    private static func isTechnicalToken(_ token: String) -> Bool {
        let hasDigit = token.contains { $0.isNumber }
        let hasSeparator = token.rangeOfCharacter(from: CharacterSet(charactersIn: "._/-#")) != nil
        let hasAcronymShape = token.count >= 2 && token.allSatisfy { !$0.isLetter || $0.isUppercase }
        let hasInnerUppercase = token.dropFirst().contains { $0.isUppercase }
        return hasDigit || hasSeparator || hasAcronymShape || hasInnerUppercase
    }
}

enum AppleTranslationStrategy: Hashable {
    case lowLatency
    case highFidelity
}

struct AppleTranslationBatchRequest: Hashable {
    var id: String
    var text: String
}

struct AppleTranslationBatchResponse: Hashable {
    var id: String
    var sourceText: String
    var targetText: String
}

@MainActor
final class AppleTranslationSessionPool {
    static let shared = AppleTranslationSessionPool()

    private struct SessionKey: Hashable {
        var source: String
        var target: String
        var strategy: AppleTranslationStrategy
    }

    private var directSessions: [SessionKey: Any] = [:]

    func prepare(source: SupportedLanguage, target: SupportedLanguage, strategy: AppleTranslationStrategy = .lowLatency) async throws {
        guard source != target else { return }

        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let box = directSession(source: source, target: target, strategy: strategy)
            try await box.prepare()
            return
        }
        #endif

        guard #available(macOS 15.0, *) else {
            throw AppleTranslationServiceError.unavailable
        }
        #if canImport(_Translation_SwiftUI)
        try await AppleNativeTranslationTaskBroker.shared.prepare(
            source: Locale.Language(identifier: source.rawValue),
            target: Locale.Language(identifier: target.rawValue)
        )
        #else
        throw AppleTranslationServiceError.unavailable
        #endif
    }

    func translate(
        _ text: String,
        source: SupportedLanguage,
        target: SupportedLanguage,
        strategy: AppleTranslationStrategy = .lowLatency
    ) async throws -> String {
        guard source != target else { return text }

        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let box = directSession(source: source, target: target, strategy: strategy)
            try await box.prepare()
            return try await box.translate(text)
        }
        #endif

        guard #available(macOS 15.0, *) else {
            throw AppleTranslationServiceError.unavailable
        }
        #if canImport(_Translation_SwiftUI)
        return try await AppleNativeTranslationTaskBroker.shared.translate(
            text,
            source: Locale.Language(identifier: source.rawValue),
            target: Locale.Language(identifier: target.rawValue)
        )
        #else
        throw AppleTranslationServiceError.unavailable
        #endif
    }

    func translateBatch(
        _ requests: [AppleTranslationBatchRequest],
        source: SupportedLanguage,
        target: SupportedLanguage,
        strategy: AppleTranslationStrategy = .lowLatency
    ) async throws -> [AppleTranslationBatchResponse] {
        guard !requests.isEmpty else { return [] }

        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let box = directSession(source: source, target: target, strategy: strategy)
            try await box.prepare()
            return try await box.translateBatch(requests)
        }
        #endif

        var responses: [AppleTranslationBatchResponse] = []
        for request in requests {
            let translated = try await translate(request.text, source: source, target: target, strategy: strategy)
            responses.append(AppleTranslationBatchResponse(id: request.id, sourceText: request.text, targetText: translated))
        }
        return responses
    }

    #if canImport(Translation)
    @available(macOS 26.0, *)
    private func directSession(
        source: SupportedLanguage,
        target: SupportedLanguage,
        strategy: AppleTranslationStrategy
    ) -> AppleDirectTranslationSessionBox {
        let key = SessionKey(source: source.rawValue, target: target.rawValue, strategy: strategy)
        if let box = directSessions[key] as? AppleDirectTranslationSessionBox {
            return box
        }
        let box = AppleDirectTranslationSessionBox(source: source, target: target, strategy: strategy)
        directSessions[key] = box
        return box
    }
    #endif
}

#if canImport(Translation)
@available(macOS 26.0, *)
@MainActor
private final class AppleDirectTranslationSessionBox {
    private let session: TranslationSession
    private var prepared = false

    init(source: SupportedLanguage, target: SupportedLanguage, strategy: AppleTranslationStrategy) {
        let sourceLanguage = Locale.Language(identifier: source.rawValue)
        let targetLanguage = Locale.Language(identifier: target.rawValue)
        if #available(macOS 26.4, *) {
            session = TranslationSession(
                installedSource: sourceLanguage,
                target: targetLanguage,
                preferredStrategy: strategy.translationSessionStrategy
            )
        } else {
            session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        }
    }

    func prepare() async throws {
        guard !prepared else { return }
        try await session.prepareTranslation()
        prepared = true
    }

    func translate(_ text: String) async throws -> String {
        let response = try await session.translate(text)
        return response.targetText
    }

    func translateBatch(_ requests: [AppleTranslationBatchRequest]) async throws -> [AppleTranslationBatchResponse] {
        nonisolated(unsafe) let batch = requests.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
        }
        let responses = try await session.translations(from: batch)
        return responses.map {
            AppleTranslationBatchResponse(
                id: $0.clientIdentifier ?? UUID().uuidString,
                sourceText: $0.sourceText,
                targetText: $0.targetText
            )
        }
    }
}

@available(macOS 26.4, *)
private extension AppleTranslationStrategy {
    var translationSessionStrategy: TranslationSession.Strategy {
        switch self {
        case .lowLatency: .lowLatency
        case .highFidelity: .highFidelity
        }
    }
}
#endif

struct AppleTranslationService: AppleTranslationProviding {
    func supports(source: String, target: String) async -> Bool {
        guard SupportedLanguage.language(for: source) != nil,
              SupportedLanguage.language(for: target) != nil else { return false }
        guard #available(macOS 15.0, *) else { return false }
        #if canImport(Translation)
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        let status = await availability.status(
            from: Locale.Language(identifier: SupportedLanguage.normalizedCode(source)),
            to: Locale.Language(identifier: SupportedLanguage.normalizedCode(target))
        )
        return status == .installed || status == .supported
        #else
        return false
        #endif
    }

    func translate(_ text: String, source: String?, target: String) async throws -> String {
        try await translate(text, source: source, target: target, strategy: .lowLatency)
    }

    func translate(_ text: String, source: String?, target: String, strategy: AppleTranslationStrategy) async throws -> String {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return text }

        let sourceCode = SupportedLanguage.normalizedCode(source)
        let targetCode = SupportedLanguage.normalizedCode(target)
        guard sourceCode != targetCode else { return text }

        #if canImport(Translation)
        guard #available(macOS 15.0, *) else {
            throw AppleTranslationServiceError.unavailable
        }

        let sourceLanguage = Locale.Language(identifier: sourceCode)
        let targetLanguage = Locale.Language(identifier: targetCode)
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: strategy.translationSessionStrategy)
        } else {
            availability = LanguageAvailability()
        }
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        switch status {
        case .installed:
            let source = SupportedLanguage.language(for: sourceCode) ?? .englishUS
            let target = SupportedLanguage.language(for: targetCode) ?? .portugueseBR
            let translatedText = try await AppleTranslationSessionPool.shared.translate(
                normalizedText,
                source: source,
                target: target,
                strategy: strategy
            )
            guard let validatedText = TranslationOutputValidator.validated(
                translatedText,
                originalText: normalizedText,
                source: source,
                target: target
            ) else {
                throw AppleTranslationServiceError.noMeaningfulTranslation
            }
            return validatedText
        case .supported:
            throw AppleTranslationServiceError.languagePairNotInstalled
        case .unsupported:
            throw AppleTranslationServiceError.unsupportedLanguagePair
        @unknown default:
            throw AppleTranslationServiceError.unsupportedLanguagePair
        }
        #else
        throw AppleTranslationServiceError.unavailable
        #endif
    }

    func prepareLanguagePair(source: String, target: String) async throws {
        let sourceCode = SupportedLanguage.normalizedCode(source)
        let targetCode = SupportedLanguage.normalizedCode(target)
        guard sourceCode != targetCode else { return }

        #if canImport(Translation)
        guard #available(macOS 15.0, *) else {
            throw AppleTranslationServiceError.unavailable
        }

        let sourceLanguage = Locale.Language(identifier: sourceCode)
        let targetLanguage = Locale.Language(identifier: targetCode)
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }

        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        switch status {
        case .installed:
            guard let source = SupportedLanguage.language(for: sourceCode),
                  let target = SupportedLanguage.language(for: targetCode) else { return }
            try await AppleTranslationSessionPool.shared.prepare(source: source, target: target, strategy: .lowLatency)
        case .supported:
            try await prepareWithSwiftUITask(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        case .unsupported:
            throw AppleTranslationServiceError.unsupportedLanguagePair
        @unknown default:
            throw AppleTranslationServiceError.unsupportedLanguagePair
        }
        #else
        throw AppleTranslationServiceError.unavailable
        #endif
    }

    #if canImport(Translation)
    @available(macOS 15.0, *)
    private func prepareWithSwiftUITask(sourceLanguage: Locale.Language, targetLanguage: Locale.Language) async throws {
        #if canImport(_Translation_SwiftUI)
        try await AppleNativeTranslationTaskBroker.shared.prepare(source: sourceLanguage, target: targetLanguage)
        #else
        throw AppleTranslationServiceError.unavailable
        #endif
    }

    @available(macOS 15.0, *)
    private func translateWithSwiftUITask(
        _ normalizedText: String,
        sourceLanguage: Locale.Language,
        targetLanguage: Locale.Language,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> String {
        #if canImport(_Translation_SwiftUI)
        let translatedText = try await AppleNativeTranslationTaskBroker.shared.translate(
            normalizedText,
            source: sourceLanguage,
            target: targetLanguage
        )
        guard let validatedText = TranslationOutputValidator.validated(
            translatedText,
            originalText: normalizedText,
            source: source,
            target: target
        ) else {
            throw AppleTranslationServiceError.noMeaningfulTranslation
        }
        return validatedText
        #else
        throw AppleTranslationServiceError.unavailable
        #endif
    }

    @available(macOS 26.0, *)
    private func prepareWithDirectSession(sourceLanguage: Locale.Language, targetLanguage: Locale.Language) async throws {
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(
                installedSource: sourceLanguage,
                target: targetLanguage,
                preferredStrategy: .lowLatency
            )
        } else {
            session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        }
        try await session.prepareTranslation()
    }

    @available(macOS 26.0, *)
    private func translateWithDirectSession(
        _ normalizedText: String,
        sourceLanguage: Locale.Language,
        targetLanguage: Locale.Language,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> String {
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(
                installedSource: sourceLanguage,
                target: targetLanguage,
                preferredStrategy: .lowLatency
            )
        } else {
            session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        }
        try await session.prepareTranslation()
        let response = try await session.translate(normalizedText)
        guard let translatedText = TranslationOutputValidator.validated(
            response.targetText,
            originalText: normalizedText,
            source: source,
            target: target
        ) else {
            throw AppleTranslationServiceError.noMeaningfulTranslation
        }
        return translatedText
    }
    #endif
}

#if canImport(_Translation_SwiftUI)
@available(macOS 15.0, *)
@MainActor
final class AppleNativeTranslationTaskBroker: ObservableObject {
    static let shared = AppleNativeTranslationTaskBroker()

    @Published fileprivate var configuration: TranslationSession.Configuration?

    fileprivate struct Job: Sendable {
        let id: UUID
        let text: String?
    }

    private struct Request {
        let id: UUID
        let text: String?
        let source: Locale.Language
        let target: Locale.Language
        let continuation: CheckedContinuation<String, Error>
    }

    private var isHostAttached = false
    private var activeRequest: Request?
    private var queue: [Request] = []

    func prepare(source: Locale.Language, target: Locale.Language) async throws {
        _ = try await enqueue(text: nil, source: source, target: target)
    }

    func setHostAttached(_ isAttached: Bool) {
        isHostAttached = isAttached
        if isAttached {
            startNextIfNeeded()
        }
    }

    func translate(_ text: String, source: Locale.Language, target: Locale.Language) async throws -> String {
        try await enqueue(text: text, source: source, target: target)
    }

    private func enqueue(text: String?, source: Locale.Language, target: Locale.Language) async throws -> String {
        guard await waitForHostAttachment() else {
            throw AppleTranslationServiceError.unavailable
        }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Request(id: id, text: text, source: source, target: target, continuation: continuation))
                startNextIfNeeded()
            }
        } onCancel: {
            Task { @MainActor in
                AppleNativeTranslationTaskBroker.shared.cancel(id: id)
            }
        }
    }

    fileprivate func currentJob() -> Job? {
        guard let activeRequest else { return nil }
        return Job(id: activeRequest.id, text: activeRequest.text)
    }

    fileprivate func complete(id: UUID, translatedText: String) {
        guard activeRequest?.id == id else { return }
        activeRequest?.continuation.resume(returning: translatedText)
        activeRequest = nil
        configuration = nil
        startNextIfNeeded()
    }

    fileprivate func fail(id: UUID, reason: String) {
        guard activeRequest?.id == id else { return }
        activeRequest?.continuation.resume(
            throwing: AppleNativeTranslationTaskError(message: reason)
        )
        activeRequest = nil
        configuration = nil
        startNextIfNeeded()
    }

    private func startNextIfNeeded() {
        guard isHostAttached, activeRequest == nil, !queue.isEmpty else { return }
        activeRequest = queue.removeFirst()
        guard let activeRequest else { return }

        configuration = nil
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.configuration = TranslationSession.Configuration(
                source: activeRequest.source,
                target: activeRequest.target
            )
        }
    }

    private func cancel(id: UUID) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            let request = queue.remove(at: index)
            request.continuation.resume(throwing: CancellationError())
        }
    }

    private func waitForHostAttachment() async -> Bool {
        if isHostAttached { return true }

        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(50))
            if isHostAttached { return true }
        }
        return false
    }
}

private struct AppleNativeTranslationTaskError: LocalizedError {
    var message: String

    var errorDescription: String? {
        message
    }
}

@available(macOS 15.0, *)
private struct AppleNativeTranslationTaskAvailableHostView: View {
    @ObservedObject var broker: AppleNativeTranslationTaskBroker

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(broker.configuration) { session in
                guard let job = broker.currentJob() else { return }
                do {
                    try await session.prepareTranslation()
                    if let text = job.text {
                        let response = try await session.translate(text)
                        broker.complete(id: job.id, translatedText: response.targetText)
                    } else {
                        broker.complete(id: job.id, translatedText: "")
                    }
                } catch {
                    broker.fail(id: job.id, reason: error.localizedDescription)
                }
            }
            .onAppear {
                broker.setHostAttached(true)
            }
            .onDisappear {
                broker.setHostAttached(false)
            }
    }
}
#endif

struct AppleNativeTranslationTaskHostView: View {
    var body: some View {
        #if canImport(_Translation_SwiftUI)
        if #available(macOS 15.0, *) {
            AppleNativeTranslationTaskAvailableHostView(broker: AppleNativeTranslationTaskBroker.shared)
        } else {
            EmptyView()
        }
        #else
        EmptyView()
        #endif
    }
}

struct TranscriptPhraseSegmenter {
    func translationText(for segment: TranscriptSegment) -> String? {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if segment.isFinal { return text }

        let words = words(in: text)
        guard text.count >= 18, words.count >= 4 else { return nil }

        if let sentence = stableSentencePrefix(in: text), sentence.count >= 16 {
            return sentence
        }

        guard words.count >= 5 else { return nil }
        return text
    }

    private func stableSentencePrefix(in text: String) -> String? {
        let punctuation = CharacterSet(charactersIn: ".!?。？！")
        guard let scalarIndex = text.unicodeScalars.lastIndex(where: { punctuation.contains($0) }) else {
            return nil
        }
        let stringIndex = String.Index(scalarIndex, within: text) ?? text.endIndex
        return String(text[...stringIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func words(in text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

struct MeetingTerminologyMemory {
    private var counts: [String: Int] = [:]

    mutating func observe(_ terms: [String]) {
        for term in terms {
            counts[canonical(term), default: 0] += 1
        }
    }

    func isKnown(_ term: String) -> Bool {
        (counts[canonical(term)] ?? 0) >= 2
    }

    private func canonical(_ term: String) -> String {
        term
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

struct TerminologyGuard {
    func candidateTerms(in text: String, memory: MeetingTerminologyMemory) -> [String] {
        var terms: [String] = []
        terms.append(contentsOf: regexTerms(in: text))
        terms.append(contentsOf: properNameTerms(in: text))

        var seen: Set<String> = []
        return terms.filter { term in
            let canonical = canonical(term)
            guard canonical.count >= 2, !seen.contains(canonical) else { return false }
            seen.insert(canonical)
            return isTechnicalSignal(term) || memory.isKnown(term)
        }
    }

    func shouldPreserveWholePhrase(_ text: String, preservedTerms: [String]) -> Bool {
        let words = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, !preservedTerms.isEmpty else { return false }
        let preservedWordCount = preservedTerms.reduce(0) { total, term in
            total + term.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.count
        }
        return words.count <= 4 && preservedWordCount >= max(1, words.count - 1)
    }

    func applyPreservation(to translatedText: String, originalText: String, preservedTerms: [String]) -> String {
        var output = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return translatedText }

        for term in preservedTerms where originalText.localizedCaseInsensitiveContains(term) {
            if containsCanonicalTerm(term, in: output) { continue }
            output += " \(term)"
        }
        return output
    }

    private func regexTerms(in text: String) -> [String] {
        let pattern = #"\b[A-Za-z][A-Za-z0-9]*(?:[._/\-][A-Za-z0-9]+)+\b|\b[A-Z]{2,}\b|\b[A-Za-z]+[A-Z][A-Za-z0-9]*\b|#\d+\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap {
            guard let termRange = Range($0.range, in: text) else { return nil }
            return String(text[termRange])
        }
    }

    private func properNameTerms(in text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var terms: [String] = []
        let range = text.startIndex..<text.endIndex
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation]) { tag, tokenRange in
            if tag == .personalName || tag == .placeName || tag == .organizationName {
                terms.append(String(text[tokenRange]))
            }
            return true
        }
        return terms
    }

    private func isTechnicalSignal(_ term: String) -> Bool {
        let hasDigit = term.contains { $0.isNumber }
        let hasSeparator = term.rangeOfCharacter(from: CharacterSet(charactersIn: "._/-#")) != nil
        let hasAcronymShape = term.count >= 2 && term.allSatisfy { !$0.isLetter || $0.isUppercase }
        let hasInnerUppercase = term.dropFirst().contains { $0.isUppercase }
        return hasDigit || hasSeparator || hasAcronymShape || hasInnerUppercase
    }

    private func containsCanonicalTerm(_ term: String, in text: String) -> Bool {
        canonical(text).contains(canonical(term))
    }

    private func canonical(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

@MainActor
struct SemanticTranslationRefiner {
    var privacyGuard = PrivacyGuard()

    func refine(
        segment: TranscriptSegment,
        draft: String,
        targetLanguage: SupportedLanguage,
        preferences: AppPreferences,
        provider: (any AIProvider)?
    ) async -> String? {
        guard let provider else { return nil }
        if provider.name != .appleFoundationModels {
            guard !preferences.localOnlyMode,
                  preferences.aiConfig.cloudProcessingEnabled else { return nil }
        }

        var redactedSegment = segment
        redactedSegment.text = privacyGuard.redact(segment.text)
        guard let refined = try? await provider.translateSegment(redactedSegment, targetLanguage: targetLanguage.rawValue) else {
            return nil
        }
        let trimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != draft else { return nil }
        return trimmed
    }
}

struct RealtimeTranslationJob: Hashable {
    var segmentId: UUID
    var text: String
    var sourceLanguage: SupportedLanguage
    var targetLanguage: SupportedLanguage
    var phase: TranslationPhase
    var confidence: Double
    var preservedTerms: [String]
    var delayMilliseconds: Int
    var coverageRevision: Int
}

struct TranslationPlan: Hashable {
    var source: SupportedLanguage
    var target: SupportedLanguage
}

struct RealtimeTranslationPreparation {
    var segment: TranscriptSegment
    var job: RealtimeTranslationJob?
}

struct TranslationCoverageCoordinator: Sendable, Hashable {
    func shouldCover(_ segment: TranscriptSegment, preferences: AppPreferences) -> Bool {
        guard preferences.liveTranslationEnabled else { return false }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if segment.translationState == .translated || segment.translationState == .preserved {
            return false
        }
        return segment.isFinal ||
            segment.transcriptionPhase == .final ||
            segment.retentionReason == .appleDraftRetained
    }

    func coverageRevision(for segment: TranscriptSegment) -> Int {
        var hasher = Hasher()
        hasher.combine(segment.id)
        hasher.combine(segment.text)
        hasher.combine(segment.originalLanguage)
        hasher.combine(segment.transcriptionPhase)
        hasher.combine(segment.retentionReason)
        hasher.combine(segment.sourceFrameRange)
        return hasher.finalize()
    }
}

struct TranslationCompletenessPass: Sendable, Hashable {
    private let coverage = TranslationCoverageCoordinator()

    func segmentsNeedingCoverage(in meeting: MeetingSession, preferences: AppPreferences) -> [TranscriptSegment] {
        meeting.transcriptSegments.filter { coverage.shouldCover($0, preferences: preferences) }
    }
}

struct RealtimeTranslationCoordinator {
    private var phraseSegmenter = TranscriptPhraseSegmenter()
    private var terminologyMemory = MeetingTerminologyMemory()
    private var terminologyGuard = TerminologyGuard()
    private let coverageCoordinator = TranslationCoverageCoordinator()

    mutating func prepare(
        segment incomingSegment: TranscriptSegment,
        existingSegment: TranscriptSegment?,
        plan: TranslationPlan?,
        preferences: AppPreferences
    ) -> RealtimeTranslationPreparation {
        var segment = incomingSegment
        let observedTerms = terminologyGuard.candidateTerms(in: segment.text, memory: terminologyMemory)
        terminologyMemory.observe(observedTerms)

        guard preferences.liveTranslationEnabled else {
            carryExistingTranslation(from: existingSegment, to: &segment)
            segment.translationState = existingSegment?.translationState ?? .none
            return RealtimeTranslationPreparation(segment: segment, job: nil)
        }

        guard let plan else {
            segment.translationState = .unavailable
            return RealtimeTranslationPreparation(segment: segment, job: nil)
        }

        segment.sourceLanguage = plan.source.rawValue
        segment.targetLanguage = plan.target.rawValue
        segment.translatedLanguage = plan.target.rawValue

        let preservedTerms = terminologyGuard.candidateTerms(in: segment.text, memory: terminologyMemory)
        segment.preservedTerms = preservedTerms

        if terminologyGuard.shouldPreserveWholePhrase(segment.text, preservedTerms: preservedTerms) {
            segment.draftTranslatedText = segment.text
            segment.translatedText = segment.isFinal ? segment.text : nil
            segment.translationPhase = .preserved
            segment.translationConfidence = 0.96
            segment.translationState = .preserved
            return RealtimeTranslationPreparation(segment: segment, job: nil)
        }

        let existingTarget = SupportedLanguage.language(for: existingSegment?.translatedLanguage)
        let canCarryExistingDraft = existingSegment?.originalLanguage == segment.originalLanguage
            && (existingTarget == nil || existingTarget == plan.target)
            && isCompatibleRevision(previousText: existingSegment?.text, currentText: segment.text)
        let canReuseTranslation = existingSegment?.text == segment.text
            && existingSegment?.originalLanguage == segment.originalLanguage
            && (existingTarget == nil || existingTarget == plan.target)

        if canReuseTranslation {
            segment.draftTranslatedText = existingSegment?.draftTranslatedText
            segment.translatedText = existingSegment?.translatedText
            segment.translationPhase = existingSegment?.translationPhase
            segment.translationConfidence = existingSegment?.translationConfidence
            if existingSegment?.translatedText != nil {
                segment.translationState = existingSegment?.translationState ?? .translated
                return RealtimeTranslationPreparation(segment: segment, job: nil)
            }
        } else {
            segment.draftTranslatedText = canCarryExistingDraft ? existingSegment?.draftTranslatedText : nil
            segment.translatedText = nil
            segment.translationConfidence = nil
        }

        guard let text = phraseSegmenter.translationText(for: segment) else {
            segment.translationPhase = .draft
            segment.translationState = segment.draftTranslatedText == nil ? .drafting : .draftTranslated
            return RealtimeTranslationPreparation(segment: segment, job: nil)
        }

        let phase: TranslationPhase = segment.isFinal ? .refinement : .draft
        segment.translationPhase = phase
        segment.translationState = segment.isFinal
            ? (segment.draftTranslatedText == nil ? .pending : .refining)
            : (segment.draftTranslatedText == nil ? .drafting : .draftTranslated)

        let job = RealtimeTranslationJob(
            segmentId: segment.id,
            text: text,
            sourceLanguage: plan.source,
            targetLanguage: plan.target,
            phase: phase,
            confidence: phase == .draft ? 0.74 : 0.9,
            preservedTerms: preservedTerms,
            delayMilliseconds: phase == .draft ? 90 : 40,
            coverageRevision: coverageCoordinator.coverageRevision(for: segment)
        )
        return RealtimeTranslationPreparation(segment: segment, job: job)
    }

    func applyPreservedTerms(_ translatedText: String, originalText: String, terms: [String]) -> String {
        terminologyGuard.applyPreservation(to: translatedText, originalText: originalText, preservedTerms: terms)
    }

    private func carryExistingTranslation(from existingSegment: TranscriptSegment?, to segment: inout TranscriptSegment) {
        segment.sourceLanguage = existingSegment?.sourceLanguage
        segment.targetLanguage = existingSegment?.targetLanguage
        segment.draftTranslatedText = existingSegment?.draftTranslatedText
        segment.translatedText = existingSegment?.translatedText
        segment.translatedLanguage = existingSegment?.translatedLanguage
        segment.translationPhase = existingSegment?.translationPhase
        segment.translationConfidence = existingSegment?.translationConfidence
        segment.preservedTerms = existingSegment?.preservedTerms ?? []
    }

    private func isCompatibleRevision(previousText: String?, currentText: String) -> Bool {
        guard let previousText else { return false }
        let previousTokens = canonicalTokens(in: previousText)
        let currentTokens = canonicalTokens(in: currentText)
        guard !previousTokens.isEmpty, !currentTokens.isEmpty else { return false }

        let previousJoined = previousTokens.joined(separator: " ")
        let currentJoined = currentTokens.joined(separator: " ")
        if previousJoined == currentJoined { return true }
        if currentJoined.hasPrefix(previousJoined) || previousJoined.hasPrefix(currentJoined) { return true }

        let previousSet = Set(previousTokens)
        let currentSet = Set(currentTokens)
        let overlap = previousSet.intersection(currentSet).count
        let denominator = max(1, min(previousSet.count, currentSet.count))
        return Double(overlap) / Double(denominator) >= 0.72 && denominator >= 4
    }

    private func canonicalTokens(in text: String) -> [String] {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

@MainActor
struct LiveTranslationEngine {
    var appleTranslator: any AppleTranslationProviding = AppleTranslationService()
    var cloudProvider: (AppPreferences) -> (any AIProvider)?

    init(
        appleTranslator: any AppleTranslationProviding = AppleTranslationService(),
        cloudProvider: @escaping (AppPreferences) -> (any AIProvider)? = { _ in nil }
    ) {
        self.appleTranslator = appleTranslator
        self.cloudProvider = cloudProvider
    }

    func translate(segment: TranscriptSegment, preferences: AppPreferences) async -> TranslationResult {
        let source = SupportedLanguage.language(for: segment.originalLanguage)
            ?? SupportedLanguage.language(for: preferences.defaultLanguage)
            ?? .englishUS
        let target = translationTarget(for: source, preferences: preferences)
        return await translateText(
            segment.text,
            source: source,
            target: target,
            segment: segment,
            preferences: preferences,
            metadata: .refinement
        )
    }

    func translateText(
        _ text: String,
        source: SupportedLanguage,
        target: SupportedLanguage,
        segment: TranscriptSegment,
        preferences: AppPreferences,
        metadata: TranslationRequestMetadata
    ) async -> TranslationResult {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return .unavailable(reason: "Empty transcript segment.")
        }

        do {
            let strategy: AppleTranslationStrategy = metadata.phase == .refinement ? .highFidelity : .lowLatency
            let translated: String
            if let nativeTranslator = appleTranslator as? AppleTranslationService {
                translated = try await nativeTranslator.translate(
                    normalizedText,
                    source: source.rawValue,
                    target: target.rawValue,
                    strategy: strategy
                )
            } else {
                translated = try await appleTranslator.translate(normalizedText, source: source.rawValue, target: target.rawValue)
            }
            if let validated = TranslationOutputValidator.validated(translated, originalText: normalizedText, source: source, target: target) {
                return .translated(
                    text: validated,
                    engine: .appleTranslation,
                    sourceLanguage: source,
                    targetLanguage: target,
                    phase: metadata.phase,
                    confidence: metadata.confidence,
                    preservedTerms: metadata.preservedTerms,
                    isSemanticRefinement: metadata.isSemanticRefinement
                )
            }
        } catch {
            AppLog.ai.info("Apple Translation unavailable for \(source.rawValue, privacy: .public)->\(target.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        guard !preferences.localOnlyMode,
              preferences.aiConfig.cloudProcessingEnabled,
              let provider = cloudProvider(preferences) else {
            return .unavailable(reason: "Translation unavailable locally.")
        }

        do {
            let translated = try await provider.translateSegment(segment, targetLanguage: target.rawValue)
            guard let validated = TranslationOutputValidator.validated(translated, originalText: normalizedText, source: source, target: target) else {
                return .failed(reason: "Cloud translation matched the original text.")
            }
            return .translated(
                text: validated,
                engine: provider.name,
                sourceLanguage: source,
                targetLanguage: target,
                phase: metadata.phase,
                confidence: max(metadata.confidence, 0.88),
                preservedTerms: metadata.preservedTerms,
                isSemanticRefinement: true
            )
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    func translationTarget(for source: SupportedLanguage, preferences: AppPreferences) -> SupportedLanguage {
        if source == .englishUS || source == .portugueseBR {
            return source.pairedTranslationTarget
        }

        let configuredTarget = SupportedLanguage.language(for: preferences.targetLanguage)
        guard let configuredTarget, configuredTarget != source else {
            return source.pairedTranslationTarget
        }
        return configuredTarget
    }
}
