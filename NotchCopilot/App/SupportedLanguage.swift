import Foundation

enum SupportedLanguage: String, Codable, CaseIterable, Identifiable {
    case englishUS = "en-US"
    case portugueseBR = "pt-BR"
    case japaneseJP = "ja-JP"
    case spanishES = "es-ES"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .englishUS: "English"
        case .portugueseBR: "Portuguese"
        case .japaneseJP: "Japanese"
        case .spanishES: "Spanish"
        }
    }

    var speechLocaleIdentifier: String { rawValue }

    var promptName: String {
        switch self {
        case .englishUS: "English"
        case .portugueseBR: "Brazilian Portuguese"
        case .japaneseJP: "Japanese"
        case .spanishES: "Spanish"
        }
    }

    var pairedTranslationTarget: SupportedLanguage {
        switch self {
        case .englishUS: .portugueseBR
        case .portugueseBR: .englishUS
        case .japaneseJP: .englishUS
        case .spanishES: .englishUS
        }
    }

    static func normalizedCode(_ value: String?) -> String {
        language(for: value)?.rawValue ?? englishUS.rawValue
    }

    static func language(for value: String?) -> SupportedLanguage? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        let normalized = value
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if normalized == "auto" {
            return nil
        }

        if normalized == "en" || normalized.hasPrefix("en-") {
            return .englishUS
        }

        if normalized == "pt" || normalized.hasPrefix("pt-") {
            return .portugueseBR
        }

        if normalized == "ja" || normalized.hasPrefix("ja-") {
            return .japaneseJP
        }

        if normalized == "es" || normalized.hasPrefix("es-") {
            return .spanishES
        }

        return nil
    }

    static func displayName(for value: String?) -> String {
        language(for: value)?.displayName ?? "English"
    }
}
