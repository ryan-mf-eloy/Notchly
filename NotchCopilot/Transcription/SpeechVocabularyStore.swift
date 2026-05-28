import CryptoKit
import Foundation
import Speech
import SwiftData

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
            .split(separator: " ")
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

    init(locale: String?, terms: [SpeechContextTerm], customLanguageModelEnabled: Bool = true, status: String = "Apple Speech ready") {
        self.locale = locale.map(SupportedLanguage.normalizedCode)
        self.terms = terms
        self.customLanguageModelEnabled = customLanguageModelEnabled
        self.status = status
    }

    var contextualStrings: [String] {
        SpeechContextRanker().rank(terms, limit: 100, locale: locale)
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
            .prefix(400)
            .map { $0 }
    }

    var stableHash: String {
        var hasher = SHA256()
        hasher.update(data: Data((locale ?? "auto").utf8))
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
        let pseudoSession = MeetingSession(
            title: "Notchly",
            source: .manual,
            primaryLanguage: SupportedLanguage.normalizedCode(preferences.defaultLanguage),
            meetingType: preferences.defaultMeetingType
        )
        return SpeechVocabularyContextBuilder().build(
            terms: terms(includeDisabled: false),
            session: pseudoSession,
            preferences: preferences,
            extraSystemTerms: ["Notchly", "pesquise", "notícias", "me lembra", "calcula", "remind me", "search", "latest", "calculate"]
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

    func suggestedTerms(from segments: [TranscriptSegment], locale: String?, limit: Int = 12) -> [SpeechVocabularyTerm] {
        let existingKeys = Set(terms().flatMap(\.allSpokenForms).map { SpeechVocabularyTerm.normalizedKey($0, locale: locale) })
        var counts: [String: Int] = [:]
        for segment in segments {
            let tokens = segment.text.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
            for token in tokens {
                let cleaned = SpeechVocabularyTerm.cleaned(token)
                guard cleaned.count >= 3 else { continue }
                guard cleaned.contains(where: { $0.isUppercase }) || cleaned.count >= 8 else { continue }
                let key = SpeechVocabularyTerm.normalizedKey(cleaned, locale: locale)
                guard !existingKeys.contains(key) else { continue }
                counts[cleaned, default: 0] += 1
            }
        }
        return counts
            .sorted {
                if $0.value == $1.value { return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                return $0.value > $1.value
            }
            .prefix(limit)
            .map { SpeechVocabularyTerm(text: $0.key, locale: locale, category: .custom, boost: 1.2, notes: "Suggested from transcript") }
    }

    private static func defaultSeedTerms(preferences: AppPreferences) -> [SpeechVocabularyTerm] {
        let userNames = ([preferences.userDisplayName] + preferences.userNicknames.split(separator: ",").map(String.init))
            .map(SpeechVocabularyTerm.cleaned)
            .filter { !$0.isEmpty }
            .map { SpeechVocabularyTerm(text: $0, locale: preferences.defaultLanguage, category: .person, boost: 1.7, isSystemSeed: true) }

        let appTerms = preferences.knownMeetingApps.flatMap { app in
            ([app.displayName] + app.nameKeywords).map {
                SpeechVocabularyTerm(text: $0, locale: nil, category: .product, boost: 1.25, isSystemSeed: true)
            }
        }

        let productTerms = [
            "Notchly", "Dynamic Island", "Local Only", "OpenAI", "ChatGPT", "Realtime API",
            "Swift", "SwiftUI", "AppKit", "AVFoundation", "ScreenCaptureKit", "Speech framework",
            "macOS", "Keychain", "RAG", "transcript", "transcrição", "resumo", "decisão",
            "action item", "follow-up", "bloqueio", "risco", "deadline", "roadmap",
            "Python", "gravação", "meeting", "reunião", "microfone", "system audio",
            "API", "deploy", "deployment", "PR", "pull request", "branch", "bug", "latency",
            "roadmap", "commit", "merge", "rollback", "release", "debug", "feature flag",
            "endpoint", "payload", "schema", "prompt", "Copilot", "high accuracy"
        ].map {
            SpeechVocabularyTerm(text: $0, locale: nil, category: .technicalTerm, boost: 1.35, isSystemSeed: true)
        }

        return (userNames + appTerms + productTerms).deduplicatedTerms()
    }
}

struct SpeechVocabularyContextBuilder {
    func build(
        terms: [SpeechVocabularyTerm],
        session: MeetingSession,
        preferences: AppPreferences,
        extraSystemTerms: [String] = []
    ) -> SpeechRecognitionContext {
        let locale = SupportedLanguage.normalizedCode(session.primaryLanguage ?? preferences.defaultLanguage)
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

        let titleTerms = session.title.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        for term in titleTerms + extraSystemTerms {
            contextTerms.append(SpeechContextTerm(text: term, locale: locale, category: .shortPhrase, weight: 1.15, pronunciationXSAMPA: nil, source: "meeting"))
        }

        return SpeechRecognitionContext(
            locale: locale,
            terms: contextTerms.deduplicatedContextTerms(),
            customLanguageModelEnabled: preferences.localOnlyMode,
            status: contextTerms.isEmpty ? "Apple Speech ready" : "Custom vocabulary active"
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
            weight += 0.35
        }
        if session.title.localizedCaseInsensitiveContains(term.text) {
            weight += 0.3
        }
        weight += min(Double(term.useCount) / 20.0, 0.4)
        weight += min(Double(term.correctionCount) / 10.0, 0.45)
        return min(max(weight, 0.1), 3.0)
    }
}

struct AppleSpeechAlternativeRescorer {
    func rescore(formattedString: String, segments: [SFTranscriptionSegment], context: SpeechRecognitionContext) -> String {
        guard !segments.isEmpty, !context.terms.isEmpty else { return formattedString }
        let vocabulary = Set(context.terms.map(\.normalizedText))
        let mutable = NSMutableString(string: formattedString)

        for segment in segments.reversed() {
            guard segment.confidence < 0.88, segment.substringRange.location != NSNotFound else { continue }
            let currentKey = SpeechVocabularyTerm.normalizedKey(segment.substring, locale: context.locale)
            if vocabulary.contains(currentKey), segment.confidence >= 0.54 {
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
            let configuration = try await prepareModel(localeIdentifier: localeIdentifier, terms: terms, hash: hash)
            preparedModels[cacheKey] = PreparedModel(hash: hash, configuration: configuration)
            return configuration
        } catch {
            failedHashes.insert(cacheKey)
            AppLog.audio.error("Apple custom speech vocabulary unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func prepareModel(localeIdentifier: String, terms: [SpeechContextTerm], hash: String) async throws -> SFSpeechLanguageModel.Configuration {
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
        for term in terms {
            let count = max(1, Int((8 * term.weight).rounded()))
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
                    count: max(1, Int((60 * term.weight).rounded()))
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
