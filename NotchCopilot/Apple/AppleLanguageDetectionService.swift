import Foundation
import NaturalLanguage

struct LanguageDetectionResult: Equatable {
    var languageCode: String
    var confidence: Double
}

struct AppleLanguageDetectionService {
    func dominantLanguage(for text: String, minimumConfidence: Double = 0.42) -> String? {
        detectedLanguage(for: text, minimumConfidence: minimumConfidence)?.languageCode
    }

    func detectedLanguage(for text: String, minimumConfidence: Double = 0.42) -> LanguageDetectionResult? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedText.count >= 4 else { return nil }

        let lexicalHint = lexicalDetection(for: normalizedText)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(normalizedText)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 4)
            .compactMap { language, confidence -> LanguageDetectionResult? in
                guard let supported = SupportedLanguage.language(for: language.rawValue) else { return nil }
                return LanguageDetectionResult(languageCode: supported.rawValue, confidence: Double(confidence))
            }
            .sorted { $0.confidence > $1.confidence }

        guard let best = hypotheses.first else {
            return lexicalHint?.confidence ?? 0 >= minimumConfidence ? lexicalHint : nil
        }

        if let lexicalHint {
            if lexicalHint.languageCode == best.languageCode {
                return LanguageDetectionResult(
                    languageCode: best.languageCode,
                    confidence: max(best.confidence, lexicalHint.confidence)
                )
            }

            let naturalLanguageIsWeak = best.confidence < 0.72
            let lexicalEvidenceIsStrong = lexicalHint.confidence >= 0.68
            let lexicalIsCompetitive = lexicalHint.confidence + 0.08 >= best.confidence
            if lexicalEvidenceIsStrong && (naturalLanguageIsWeak || lexicalIsCompetitive) {
                return lexicalHint
            }
        }

        if best.confidence >= minimumConfidence {
            return best
        }

        return lexicalHint?.confidence ?? 0 >= minimumConfidence ? lexicalHint : nil
    }

    private func lexicalDetection(for text: String) -> LanguageDetectionResult? {
        let hasPortugueseAccent = text.rangeOfCharacter(from: Self.portugueseAccentCharacters) != nil
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
        let tokens = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard tokens.count >= 3 || hasPortugueseAccent else { return nil }

        var portugueseScore = hasPortugueseAccent ? 3.5 : 0
        var englishScore = 0.0
        var spanishScore = 0.0
        var japaneseScore = text.range(of: #"[\u3040-\u30ff\u3400-\u9fff]"#, options: .regularExpression) == nil ? 0.0 : 4.0

        for token in tokens {
            if Self.portugueseHints.contains(token) {
                portugueseScore += 1
            }
            if Self.englishHints.contains(token) {
                englishScore += 1
            }
            if Self.spanishHints.contains(token) {
                spanishScore += 1
            }
        }

        for phrase in Self.portuguesePhrases where folded.contains(phrase) {
            portugueseScore += 1.8
        }
        for phrase in Self.englishPhrases where folded.contains(phrase) {
            englishScore += 1.8
        }
        for phrase in Self.spanishPhrases where folded.contains(phrase) {
            spanishScore += 1.8
        }
        for phrase in Self.japanesePhrases where text.contains(phrase) {
            japaneseScore += 2.4
        }

        let scores: [(SupportedLanguage, Double)] = [
            (.portugueseBR, portugueseScore),
            (.englishUS, englishScore),
            (.spanishES, spanishScore),
            (.japaneseJP, japaneseScore)
        ].sorted { $0.1 > $1.1 }
        guard let winner = scores.first else { return nil }
        let runnerUp = scores.dropFirst().first?.1 ?? 0
        let winningScore = winner.1
        let margin = winningScore - runnerUp
        guard winningScore >= 2.0, margin >= 1.0 else { return nil }

        let confidence = min(0.94, 0.52 + (margin * 0.08) + (winningScore * 0.025))
        return LanguageDetectionResult(languageCode: winner.0.rawValue, confidence: confidence)
    }
}

private extension AppleLanguageDetectionService {
    static let portugueseAccentCharacters = CharacterSet(charactersIn: "áàâãéêíóôõúüçÁÀÂÃÉÊÍÓÔÕÚÜÇ")

    static let portugueseHints: Set<String> = [
        "agora", "acoes", "acao", "alinhamos", "alinhar", "apenas", "aqui", "capturar",
        "com", "como", "decisao", "decisoes", "deixar", "devemos", "do", "dos", "duvida",
        "essa", "esse", "esta", "estamos", "estou", "exato", "explicar", "falando",
        "funcionalidade", "funciona", "habilitar", "ingles", "manter", "modo", "nao",
        "pode", "portugues", "precisamos", "privacidade", "proximos", "qual", "quando",
        "que", "reuniao", "revisar", "risco", "riscos", "roteiro", "sobre", "traducao",
        "traduzir", "um", "uma", "vamos", "voce", "voces"
    ]

    static let englishHints: Set<String> = [
        "action", "and", "are", "audio", "can", "could", "decisions", "english", "for",
        "from", "i", "is", "items", "keep", "meeting", "microphone", "need", "next",
        "portuguese", "privacy", "provider", "recording", "review", "risk", "risks",
        "roadmap", "should", "speaking", "steps", "summary", "system", "that", "the",
        "this", "to", "transcript", "translate", "translation", "we", "what", "when",
        "with", "would", "you", "your"
    ]

    static let spanishHints: Set<String> = [
        "ahora", "alguien", "api", "autenticacion", "bloqueo", "cliente", "como",
        "confirmar", "cuando", "decision", "duda", "entregar", "estado", "esto",
        "explicar", "hay", "login", "migracion", "necesitamos", "podemos", "puede",
        "puedes", "quien", "riesgo", "saber", "sentido", "viernes"
    ]

    static let portuguesePhrases = [
        "eu estou", "a gente", "por favor", "vamos revisar", "precisamos revisar",
        "modo privado", "proximos passos", "esta reuniao", "essa reuniao"
    ]

    static let englishPhrases = [
        "i am", "we should", "let us", "let's", "next steps", "this meeting",
        "the meeting", "can you", "would you"
    ]

    static let spanishPhrases = [
        "necesitamos saber", "seria bueno", "tiene sentido", "puedes explicar",
        "cual es", "hay algun"
    ]

    static let japanesePhrases = [
        "できますか", "でしょうか", "ですか", "ますか", "知りたい", "確認したい"
    ]
}
