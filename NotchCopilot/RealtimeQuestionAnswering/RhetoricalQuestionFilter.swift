import Foundation

struct QuestionIntentRulePack: Codable, Hashable, Sendable {
    var directQuestionMarkers: [String]
    var indirectQuestionMarkers: [String]
    var actionRequestMarkers: [String]
    var modalQuestionStarters: [String]
    var rhetoricalMarkers: [String]
    var rhetoricalSuffixes: [String]
    var fragmentPhrases: Set<String>
    var fragmentPrefixes: Set<String>
    var exactSmallTalkPhrases: Set<String>
    var operationalNoAnswerPhrases: Set<String>
    var smallTalkContinuationWords: Set<String>
    var quotedOrExplainingMarkers: [String]
    var selfAnsweredMarkers: [String]
    var lowInformationWords: Set<String>
    var stopWords: Set<String>
    var contextualPronouns: Set<String>
    var domainHintMarkers: [String]
    var answerableScoreThreshold: Double
    var partialQuestionPenalty: Double

    static let `default` = QuestionIntentRulePack(
        directQuestionMarkers: [
            "what", "what's", "what is", "when", "who", "who's", "where", "why", "how", "which",
            "do we", "do you", "do we have", "can we", "can you", "could we", "could you", "should we",
            "would it", "does this", "will this", "is there", "are there", "any blockers", "main risk",
            "quick question", "one question", "do you know if", "do you know whether", "you know if",
            "qual", "qual e", "qual a", "quando", "quem", "onde", "por que", "porque", "como", "o que e",
            "voce acha", "voces acham", "alguem sabe se", "conseguimos", "consegue", "podemos", "pode",
            "sera que", "faz sentido", "existe", "temos", "tem como", "da pra", "da para", "sabe se",
            "voce sabe se", "voces sabem se", "me diz qual", "me diz se", "me fala qual", "me fala se",
            "isso quebra", "isso impacta", "isso afeta", "algum problema", "algum bloqueio", "algum risco", "alguma dependencia",
            "que ", "cual", "cuando", "quien", "donde", "podrias", "puedes", "tiene sentido", "hay algun",
            "hay alguna", "sabemos si", "sabes si", "saben si", "alguien sabe si", "esto rompe", "esto impacta",
            "どう", "何", "いつ", "誰", "誰が", "どこ", "なぜ", "できますか", "でしょうか", "ですか", "ますか", "ましたか", "ありますか",
            "終わりましたか", "知っていますか", "わかりますか", "必要ですか", "問題ありますか", "影響しますか", "リスク"
        ],
        indirectQuestionMarkers: [
            "i want to understand", "i wanted to understand", "i'd like to understand", "we need to know",
            "we need to find out", "we should figure out", "need clarity on", "not clear",
            "the question is whether", "the question is if", "do you know if", "do you know whether",
            "you know if", "can you tell me if", "can you tell me whether", "can you tell me what",
            "quick question", "one question", "wondering if", "trying to understand",
            "eu queria entender", "gostaria de entender", "quero entender", "precisamos descobrir",
            "precisamos saber", "seria bom saber", "seria importante saber", "a duvida e", "a pergunta e se",
            "nao ficou claro", "queria saber", "queria confirmar se", "preciso entender",
            "sabe se o", "sabe se a", "sabe se isso", "sabe se esse", "sabe se essa", "sabe se ja",
            "voce sabe se", "voces sabem se", "alguem sabe se", "me diz se", "me diz qual", "me diz como",
            "me fala se", "me fala qual", "me fala como",
            "quisiera entender", "me gustaria entender", "necesitamos saber", "necesitamos descubrir",
            "tenemos que averiguar", "seria bueno saber", "la duda es", "la pregunta es si", "no queda claro",
            "no esta claro", "sabes si", "saben si", "alguien sabe si", "quiero saber si",
            "知りたい", "確認したい", "明確ではない", "はっきりしていません", "わかっていません",
            "必要があります", "疑問は"
        ],
        actionRequestMarkers: [
            "review", "validate", "approve", "explain", "confirm", "take a look", "check this", "take care",
            "own this", "revisar", "validar", "aprovar", "explicar", "confirmar", "dar uma olhada",
            "checar", "testar", "cuidar disso", "me diz", "me fala", "diz pra mim", "fala pra mim",
            "aprobar", "echar un vistazo", "probar",
            "レビュー", "確認", "承認", "説明", "見てもらえますか", "レビューして", "お願いできますか"
        ],
        modalQuestionStarters: [
            "can", "could", "should", "would", "do", "does", "is", "are", "will",
            "do you know if", "do you know whether", "any blockers", "any risks", "main risk",
            "consegue", "conseguimos", "podemos", "pode", "deve", "deveria", "deveriamos", "vale",
            "sera que", "tem como", "da pra", "da para", "sabe se o", "sabe se a", "sabe se isso",
            "voce sabe se", "voces sabem se", "alguem sabe se",
            "puede", "podria", "podriamos", "debe", "deberia", "deberiamos", "vale la pena",
            "hay algun", "hay alguna", "sabes si", "saben si", "alguien sabe si"
        ],
        rhetoricalMarkers: [
            "quem nunca", "vai entender", "o que poderia dar errado", "nao e obvio",
            "who hasn't", "what could go wrong", "isn't it obvious",
            "quien no", "que podria salir mal", "no es obvio",
            "そうでしょう", "当たり前"
        ],
        rhetoricalSuffixes: [" right", " right?", " ne", " ne?", " né", " né?"],
        fragmentPhrases: [
            "como", "how", "what", "qual", "que", "cual", "cuando", "when", "why", "where", "who", "which",
            "quanto", "quanto e", "quantos", "quantas", "cuanto", "cuanto es", "cuantos", "cuantas",
            "o que", "o que e", "what is", "what's", "qual e", "qual a",
            "mas e se", "e quando", "sera que", "but what if", "and when", "what if", "y si", "pero si",
            "もし", "それで", "何", "どう", "なぜ", "いつ", "誰", "どこ"
        ],
        fragmentPrefixes: [
            "mas como", "mas e se", "e quando", "sera que", "but how", "but what if", "and when",
            "what about", "pero como", "y si", "pero si", "que tal si", "can we", "can you",
            "could we", "could you", "should we", "do we", "podemos", "voce pode", "consegue",
            "podrias", "puedes"
        ],
        exactSmallTalkPhrases: [
            "como vai voce", "como voce esta", "como esta voce", "tudo bem", "tudo certo", "beleza",
            "how are you", "how are you doing", "how's it going", "hows it going", "how is it going",
            "que tal", "como estas", "como esta", "como te va", "元気ですか", "お元気ですか"
        ],
        operationalNoAnswerPhrases: [
            "can you hear me", "can you hear me now", "can everyone hear me", "can you guys hear me",
            "do you hear me", "can you see my screen", "is my mic working", "is my microphone working",
            "can everyone see my screen", "can everyone see the screen", "can you see the screen",
            "is my audio working", "am i audible", "am i muted", "are you hearing me",
            "voce consegue me ouvir", "voces conseguem me ouvir", "consegue me ouvir", "conseguem me ouvir",
            "me ouvem", "me escutam", "me escuta", "me escutam bem", "da para me ouvir", "da pra me ouvir",
            "da para ver minha tela", "da pra ver minha tela", "voces conseguem ver minha tela", "conseguem ver minha tela",
            "estao me ouvindo", "me escuchan", "me oyes", "pueden oirme", "puedes oirme",
            "se escucha mi audio", "pueden ver mi pantalla",
            "聞こえますか", "聞こえていますか", "私の声が聞こえますか", "画面見えますか"
        ],
        smallTalkContinuationWords: [
            "today", "there", "folks", "team", "guys", "everyone", "all", "hoje", "pessoal", "galera",
            "todos", "equipo", "hoy"
        ],
        quotedOrExplainingMarkers: [
            "como eu disse", "como disse", "como falei", "como eu falei", "tipo quando", "tipo assim quando",
            "what i mean is", "what i meant is", "as i said", "you know when", "you know like when",
            "they asked if", "they asked whether", "someone asked whether", "i was asked if", "i was asked whether",
            "i wondered if", "but i already resolved", "eles perguntaram se", "me perguntaram se", "perguntaram se",
            "eu me perguntei se", "mas ja resolvi", "preguntaron si", "me preguntaron si", "me pregunte si",
            "como dije", "como decia", "la duda era", "pero ya lo resolvi", "a duvida era",
            "質問されました", "聞かれました", "もう解決しました"
        ],
        selfAnsweredMarkers: [
            "? yes", "? no", "? sim", "? nao", "? si", "? はい", "? いいえ", "？はい", "？いいえ",
            "but we already decided", "we already decided", "ja decidimos", "já decidimos", "ya decidimos"
        ],
        lowInformationWords: [
            "what", "how", "why", "when", "where", "who", "which", "como", "qual", "que", "quando",
            "onde", "quem", "porque", "cual", "cuando", "donde", "quien", "isso", "this", "that", "eso",
            "e", "ai", "aí", "it", "there", "何", "どう"
        ],
        stopWords: [
            "a", "an", "the", "to", "of", "for", "in", "on", "at", "is", "are", "be", "we", "you", "i",
            "me", "my", "our", "this", "that", "it", "there", "can", "could", "should", "would", "do", "does",
            "o", "a", "os", "as", "um", "uma", "de", "da", "do", "das", "dos", "para", "em", "no", "na",
            "nos", "nas", "e", "ou", "eu", "voce", "voces", "nos", "isso", "aquilo", "esse", "essa", "este",
            "esta", "ser", "estar", "vai", "vamos", "como", "qual", "que", "quando", "onde", "quem",
            "el", "la", "los", "las", "un", "una", "de", "del", "para", "en", "y", "o", "yo", "tu",
            "usted", "nosotros", "eso", "esto", "como", "cual", "cuando", "donde", "quien"
        ],
        contextualPronouns: [
            "this", "that", "it", "these", "those", "isso", "esse", "essa", "isto", "aquilo", "eso", "esto",
            "ここ", "これ", "それ"
        ],
        domainHintMarkers: [
            "api", "backend", "frontend", "auth", "authentication", "autenticacao", "login", "oauth", "jwt",
            "pr", "pull request", "ticket", "jira", "github", "deploy", "release", "migration", "database",
            "cache", "queue", "latency", "security", "risk", "risco", "blocker", "cliente", "customer",
            "python", "swift", "kotlin", "javascript", "typescript", "react", "node", "hash", "hashid",
            "tree", "binary tree", "binary three", "binary dream", "data structure", "algorithm",
            "system", "sistema", "availability", "disponibilidade", "scale", "escalar", "architecture",
            "arquitetura", "サービス", "認証", "移行", "リスク", "デプロイ", "api"
        ],
        answerableScoreThreshold: 1.45,
        partialQuestionPenalty: 0.2
    )
}

struct RhetoricalQuestionFilter {
    var rulePack: QuestionIntentRulePack = .default

    func evaluation(for candidate: QuestionCandidate, context: TranscriptContext) -> (ignore: Bool, rhetorical: Bool, complete: Bool, responseNeeded: Bool, reason: String) {
        let text = candidate.normalizedText
        if isIncomplete(text) {
            return (true, false, false, false, "Question fragment is incomplete.")
        }
        if isRhetorical(text) {
            return (true, true, true, false, "Question is likely rhetorical.")
        }
        if isQuotedPastQuestion(text) {
            return (true, false, true, false, "Question is being reported rather than asked.")
        }
        if isSelfAnswered(candidate.rawText) {
            return (true, false, true, false, "Speaker answered their own question.")
        }
        return (false, false, true, true, "Question appears answerable.")
    }

    func isRhetorical(_ text: String) -> Bool {
        rulePack.rhetoricalMarkers.contains { text.contains($0) }
            || rulePack.rhetoricalSuffixes.contains { suffix in
                text.hasSuffix(suffix) || text.hasSuffix(",\(suffix)")
            }
    }

    func isIncomplete(_ text: String) -> Bool {
        let plain = QuestionIntentGate.plainQuestionText(text)
        if rulePack.fragmentPhrases.contains(plain) {
            return true
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("...")
            && plain.split(separator: " ").count < 6
    }

    func isSelfAnswered(_ text: String) -> Bool {
        let normalized = QuestionDetectionService.normalize(text)
        return rulePack.selfAnsweredMarkers.contains { normalized.contains($0) }
    }

    func isQuotedPastQuestion(_ text: String) -> Bool {
        rulePack.quotedOrExplainingMarkers.contains { text.contains($0) }
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

struct QuestionIntentGate {
    var rulePack: QuestionIntentRulePack = .default
    var adaptiveProfile: QuestionAnsweringAdaptiveProfile = QuestionAnsweringAdaptiveProfile()

    func evaluate(candidate: QuestionCandidate, context: TranscriptContext) -> QuestionIntentEvaluation {
        let normalized = QuestionDetectionService.normalize(candidate.rawText)
        let plain = Self.plainQuestionText(normalized)

        if plain.isEmpty || isFragment(plain, context: context) {
            return QuestionIntentEvaluation(
                isAnswerableQuestion: false,
                isFragment: true,
                isSmallTalk: false,
                isQuotedOrExplaining: false,
                isRhetorical: false,
                reason: "Question-like fragment has no answerable object.",
                confidence: 0.12
            )
        }

        if isSmallTalk(plain) {
            return QuestionIntentEvaluation(
                isAnswerableQuestion: false,
                isFragment: false,
                isSmallTalk: true,
                isQuotedOrExplaining: false,
                isRhetorical: false,
                reason: "Small talk greeting does not need a meeting answer.",
                confidence: 0.18
            )
        }

        if isQuotedOrExplaining(plain) && !hasRecoverableEmbeddedQuestion(plain, rawText: candidate.rawText, context: context) {
            return QuestionIntentEvaluation(
                isAnswerableQuestion: false,
                isFragment: false,
                isSmallTalk: false,
                isQuotedOrExplaining: true,
                isRhetorical: false,
                reason: "Question-like text is quoted, reported, or part of an explanation.",
                confidence: 0.22
            )
        }

        if RhetoricalQuestionFilter(rulePack: rulePack).isSelfAnswered(candidate.rawText) {
            return QuestionIntentEvaluation(
                isAnswerableQuestion: false,
                isFragment: false,
                isSmallTalk: false,
                isQuotedOrExplaining: false,
                isRhetorical: false,
                reason: "Speaker answered their own question.",
                confidence: 0.22
            )
        }

        if RhetoricalQuestionFilter(rulePack: rulePack).isRhetorical(normalized) {
            return QuestionIntentEvaluation(
                isAnswerableQuestion: false,
                isFragment: false,
                isSmallTalk: false,
                isQuotedOrExplaining: false,
                isRhetorical: true,
                reason: "Question is likely rhetorical.",
                confidence: 0.26
            )
        }

        if adaptiveProfile.isSuppressed(plain) {
            return QuestionIntentEvaluation(
                isAnswerableQuestion: false,
                isFragment: false,
                isSmallTalk: false,
                isQuotedOrExplaining: false,
                isRhetorical: false,
                reason: "Similar questions were repeatedly dismissed by the user.",
                confidence: 0.3
            )
        }

        if adaptiveProfile.isPromoted(plain) {
            return QuestionIntentEvaluation(
                isAnswerableQuestion: true,
                isFragment: false,
                isSmallTalk: false,
                isQuotedOrExplaining: false,
                isRhetorical: false,
                reason: "User feedback promoted this kind of question.",
                confidence: 0.9
            )
        }

        let score = answerabilityScore(plain: plain, rawText: candidate.rawText, context: context)
        let threshold = answerableThreshold(for: candidate)
        if score < threshold {
            return QuestionIntentEvaluation(
                isAnswerableQuestion: false,
                isFragment: true,
                isSmallTalk: false,
                isQuotedOrExplaining: false,
                isRhetorical: false,
                reason: "Question lacks enough intent and object signal to answer confidently.",
                confidence: min(max(score / max(threshold, 0.1), 0.08), 0.42)
            )
        }

        return QuestionIntentEvaluation(
            isAnswerableQuestion: true,
            isFragment: false,
            isSmallTalk: false,
            isQuotedOrExplaining: false,
            isRhetorical: false,
            reason: "Question has clear intent and an answerable object.",
            confidence: min(max(0.58 + ((score - threshold) * 0.16), 0.56), 0.94)
        )
    }

    static func plainQuestionText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[¿?？!！.,;:。、「」\(\)\[\]"“”]+"#, with: " ", options: .regularExpression)
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
        for prefix in rulePack.fragmentPhrases where plain.hasPrefix("\(prefix) ") {
            let remainder = plain.removingPrefix(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
            if meaningfulTokens(in: remainder).isEmpty && !containsAny(remainder, rulePack.domainHintMarkers) {
                return true
            }
        }
        for prefix in rulePack.fragmentPrefixes where plain == prefix || plain.hasPrefix("\(prefix) ") {
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
        for phrase in rulePack.exactSmallTalkPhrases where plain.hasPrefix("\(phrase) ") {
            let remainder = plain.removingPrefix(phrase).trimmingCharacters(in: .whitespacesAndNewlines)
            let words = remainder.split(separator: " ").map(String.init)
            if !words.isEmpty && words.allSatisfy({ rulePack.smallTalkContinuationWords.contains($0) }) {
                return true
            }
        }
        return false
    }

    private func isOperationalNoAnswerCheck(_ plain: String) -> Bool {
        guard rulePack.operationalNoAnswerPhrases.contains(where: { phrase in
            plain == phrase || plain.hasSuffix(" \(phrase)") || plain.hasPrefix("\(phrase) ") || plain.contains(" \(phrase) ")
        }) else {
            return false
        }
        return !containsAny(plain, rulePack.domainHintMarkers)
    }

    func isQuotedOrExplaining(_ plain: String) -> Bool {
        rulePack.quotedOrExplainingMarkers.contains { plain.contains($0) }
    }

    func isLowSubstanceQuestion(_ plain: String, rawText: String, context: TranscriptContext?) -> Bool {
        guard rawText.contains("?") || rawText.contains("？") || rawText.contains("¿") else { return false }
        return answerabilityScore(plain: plain, rawText: rawText, context: context) < answerableThreshold(for: nil)
    }

    private func hasRecoverableEmbeddedQuestion(_ plain: String, rawText: String, context: TranscriptContext) -> Bool {
        guard rawText.contains("?") || rawText.contains("？") || rawText.contains("¿") else { return false }
        let clauses = plain.components(separatedBy: " can ")
            + plain.components(separatedBy: " podemos ")
            + plain.components(separatedBy: " consegue ")
            + plain.components(separatedBy: " what ")
            + plain.components(separatedBy: " como ")
        return clauses.contains { clause in
            answerabilityScore(plain: clause, rawText: rawText, context: context) >= answerableThreshold(for: nil) + 0.25
        }
    }

    private func answerabilityScore(plain: String, rawText: String, context: TranscriptContext?) -> Double {
        var score = 0.0
        if rawText.contains("?") || rawText.contains("？") || rawText.contains("¿") {
            score += 0.5
        }
        if containsAny(plain, rulePack.directQuestionMarkers) {
            score += 0.8
        }
        if containsAny(plain, rulePack.indirectQuestionMarkers) {
            score += 1.0
        }
        if containsAny(plain, rulePack.actionRequestMarkers) {
            score += 0.85
        }
        if startsWithAnyToken(plain, rulePack.modalQuestionStarters) {
            score += 0.65
        }
        if containsAny(plain, rulePack.domainHintMarkers) {
            score += 0.55
        }
        score += min(Double(meaningfulTokens(in: plain).count) * 0.38, 1.35)
        if hasCodeOrIdentifierSignal(rawText) {
            score += 0.45
        }
        if containsCJK(plain), plain.count >= 5 {
            score += 0.55
        }
        if hasContextualCarryover(plain: plain, context: context) {
            score += 0.35
        }
        return score
    }

    private func answerableThreshold(for candidate: QuestionCandidate?) -> Double {
        var threshold = rulePack.answerableScoreThreshold + adaptiveProfile.strictnessAdjustment
        if candidate?.isPartial == true {
            threshold += rulePack.partialQuestionPenalty
        }
        return min(max(threshold, 1.1), 1.9)
    }

    private func hasConcreteObject(_ plain: String, context: TranscriptContext?) -> Bool {
        !meaningfulTokens(in: plain).isEmpty
            || containsAny(plain, rulePack.domainHintMarkers)
            || containsCJK(plain) && plain.count >= 4
            || hasContextualCarryover(plain: plain, context: context)
    }

    private func hasContextualCarryover(plain: String, context: TranscriptContext?) -> Bool {
        guard let context else { return false }
        let hasPronoun = plain.split(separator: " ").contains { rulePack.contextualPronouns.contains(String($0)) }
        guard hasPronoun else { return false }
        let recent = QuestionDetectionService.normalize(context.recentTranscript + " " + context.mediumTranscript)
        return containsAny(recent, rulePack.domainHintMarkers) || meaningfulTokens(in: recent).count >= 5
    }

    private func meaningfulTokens(in plain: String) -> [String] {
        plain
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                token.count >= 3
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
            text == pattern || text.hasPrefix("\(pattern) ")
        }
    }

    private func hasCodeOrIdentifierSignal(_ text: String) -> Bool {
        text.contains("_") || text.contains("`") || text.contains("/") || text.contains("#")
            || text.range(of: #"[A-Za-z]+[A-Z0-9][A-Za-z0-9]*"#, options: .regularExpression) != nil
    }

    private func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(Int(scalar.value)) || (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    private func patternMatches(_ text: String, _ pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        if pattern.contains(" ") || containsCJK(pattern) {
            return text.contains(pattern)
        }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        return text.range(of: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])", options: .regularExpression) != nil
    }

    private func wordCount(_ value: String) -> Int {
        value.split(separator: " ").count
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
