import Foundation

struct UtteranceFrame: Identifiable, Hashable, Sendable {
    var id: UUID
    var meetingId: UUID
    var rawText: String
    var normalizedText: String
    var language: String?
    var speakerId: UUID?
    var speakerLabel: String?
    var audioSource: TranscriptAudioSource
    var startTime: TimeInterval
    var endTime: TimeInterval?
    var sourceSegmentId: UUID
    var isPartial: Bool
    var isFinal: Bool
    var asrConfidence: Double?
    var hasTerminalPause: Bool
    var multimodalSignal: QuestionMultimodalSignal?
}

struct UtteranceFrameBuilder {
    func frames(from segment: TranscriptSegment, context: TranscriptContext, signal: QuestionMultimodalSignal? = nil) -> [UtteranceFrame] {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4 else { return [] }

        let spans = sentenceSpans(in: text)
        guard !spans.isEmpty else {
            return [frame(text: text, segment: segment, index: 0, count: 1, signal: signal)]
        }

        return spans.enumerated().compactMap { index, span in
            let value = span.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 4 else { return nil }
            return frame(text: value, segment: segment, index: index, count: spans.count, signal: signal)
        }
    }

    private func frame(text: String, segment: TranscriptSegment, index: Int, count: Int, signal: QuestionMultimodalSignal?) -> UtteranceFrame {
        let duration = max(segment.endTime - segment.startTime, 0)
        let step = count > 0 ? duration / Double(count) : 0
        let start = segment.startTime + (Double(index) * step)
        let end = duration > 0 ? start + step : segment.endTime
        let frameSignal = signal.map {
            QuestionMultimodalSignal(
                language: $0.language,
                asrConfidence: $0.asrConfidence,
                isFinal: $0.isFinal,
                isPartial: $0.isPartial,
                speakerLabel: $0.speakerLabel,
                audioSource: $0.audioSource,
                duration: step > 0 ? step : $0.duration,
                hasTerminalPause: index == count - 1 && $0.hasTerminalPause,
                partialStability: $0.partialStability,
                partialRevisionCount: $0.partialRevisionCount,
                rms: $0.rms,
                peak: $0.peak,
                isClipping: $0.isClipping,
                isSilence: $0.isSilence,
                isTooQuiet: $0.isTooQuiet,
                gapCount: $0.gapCount,
                noiseFloor: $0.noiseFloor,
                audioEnergy: $0.audioEnergy,
                createdAt: $0.createdAt
            )
        }
        return UtteranceFrame(
            id: index == 0 ? segment.id : UUID(),
            meetingId: segment.meetingId,
            rawText: text,
            normalizedText: QuestionDetectionService.normalize(text),
            language: segment.originalLanguage,
            speakerId: segment.speakerId,
            speakerLabel: segment.speakerLabel,
            audioSource: segment.audioSource,
            startTime: start,
            endTime: end,
            sourceSegmentId: segment.id,
            isPartial: !segment.isFinal,
            isFinal: segment.isFinal,
            asrConfidence: segment.confidence,
            hasTerminalPause: segment.isFinal,
            multimodalSignal: frameSignal
        )
    }

    private func sentenceSpans(in text: String) -> [String] {
        var spans: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?？。;；".contains(character) {
                spans.append(current)
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            spans.append(tail)
        }
        return spans.isEmpty ? [text] : spans
    }
}

struct QuestionSurfaceAnalysis: Hashable, Sendable {
    var plainText: String
    var textAfterAddress: String
    var strongSignals: Set<QuestionUnderstandingSignal> = []
    var negativeSignals: [String] = []
    var meaningfulTokens: [String] = []
    var hasQuestionPunctuation: Bool = false
    var hasWeakQuestionWordOnly: Bool = false

    var isRejected: Bool { !negativeSignals.isEmpty }
    var strongSignalCount: Int { strongSignals.count }
}

struct QuestionRejectedFrame: Hashable, Sendable {
    var frame: UtteranceFrame
    var surfaceSignals: [String]
    var suppressionSignals: [String]
    var reason: String

    var hasHardSuppression: Bool {
        suppressionSignals.contains { signal in
            [
                "empty",
                "small_talk",
                "operational_check",
                "reported_question",
                "rhetorical",
                "self_answered",
                "fragment",
                "noun_phrase_or_title"
            ].contains(signal)
        }
    }
}

struct QuestionDetectionResult: Hashable, Sendable {
    var surfaceCandidates: [QuestionCandidate]
    var rejectedFrames: [QuestionRejectedFrame]

    static let empty = QuestionDetectionResult(surfaceCandidates: [], rejectedFrames: [])
}

struct QuestionSurfaceAnalyzer {
    var rulePack: QuestionIntentRulePack = .default

    func analyze(
        text rawText: String,
        normalized: String? = nil,
        context: TranscriptContext?,
        profile: UserMeetingProfile? = nil,
        isPartial: Bool,
        isFinal: Bool
    ) -> QuestionSurfaceAnalysis {
        let normalized = normalized ?? QuestionDetectionService.normalize(rawText)
        let plain = QuestionIntentGate.plainQuestionText(normalized)
        let addressed = removeLeadingDiscourse(from: removeLeadingAddress(from: plain, profile: profile))
        var analysis = QuestionSurfaceAnalysis(
            plainText: plain,
            textAfterAddress: addressed,
            meaningfulTokens: meaningfulTokens(in: addressed)
        )
        analysis.hasQuestionPunctuation = normalized.contains("?") || normalized.contains("？") || normalized.contains("¿")

        if plain.isEmpty {
            analysis.negativeSignals.append("empty")
            return analysis
        }

        if QuestionIntentGate(rulePack: rulePack).isSmallTalk(plain) {
            analysis.negativeSignals.append("small_talk")
        }
        if isOperationalNoAnswerCheck(plain) {
            analysis.negativeSignals.append("operational_check")
        }
        if QuestionIntentGate(rulePack: rulePack).isQuotedOrExplaining(plain) {
            analysis.negativeSignals.append("reported_question")
        }
        if RhetoricalQuestionFilter(rulePack: rulePack).isRhetorical(normalized) {
            analysis.negativeSignals.append("rhetorical")
        }
        if RhetoricalQuestionFilter(rulePack: rulePack).isSelfAnswered(rawText) {
            analysis.negativeSignals.append("self_answered")
        }
        if isFragment(addressed) {
            analysis.negativeSignals.append("fragment")
        }
        if isLikelyTitleOrNounPhrase(addressed, rawText: rawText) {
            analysis.negativeSignals.append("noun_phrase_or_title")
        }

        if analysis.hasQuestionPunctuation {
            analysis.strongSignals.insert(.terminalQuestionMark)
        }
        if startsWithInterrogative(addressed) {
            analysis.strongSignals.insert(.interrogativeStarter)
        }
        if startsWithModalQuestionFrame(addressed) {
            analysis.strongSignals.insert(.modalQuestionFrame)
        }
        if hasIndirectQuestionFrame(addressed) {
            analysis.strongSignals.insert(.indirectQuestionFrame)
        }
        if hasActionRequestFrame(addressed) {
            analysis.strongSignals.insert(.actionRequestFrame)
        }
        if isDirectedToUser(plain, profile: profile) {
            analysis.strongSignals.insert(.directedToUser)
        }
        if isDirectedToGroup(addressed) {
            analysis.strongSignals.insert(.directedToGroup)
        }
        if !analysis.meaningfulTokens.isEmpty || hasNumericQuestionPayload(addressed) || containsCJK(addressed) && addressed.count >= 5 {
            analysis.strongSignals.insert(.concreteObject)
        }
        if containsAny(addressed, rulePack.domainHintMarkers) {
            analysis.strongSignals.insert(.domainObject)
        }
        if hasContextualCarryover(plain: addressed, context: context) {
            analysis.strongSignals.insert(.contextualCarryover)
        }
        if isFinal && !isPartial {
            analysis.strongSignals.insert(.finalUtterance)
        }

        analysis.hasWeakQuestionWordOnly = analysis.strongSignals.isSubset(of: Set([.interrogativeStarter, .concreteObject, .finalUtterance]))
            && !analysis.hasQuestionPunctuation
            && !startsWithInterrogative(addressed, requireObject: true)

        if isDeclarativeWithoutInterrogativeSyntax(addressed, analysis: analysis) {
            analysis.negativeSignals.append("declarative_without_interrogative_syntax")
        }

        return analysis
    }

    func isCandidateSurface(_ analysis: QuestionSurfaceAnalysis, precisionMode: QAPrecisionMode) -> Bool {
        guard !analysis.isRejected else { return false }
        if analysis.hasQuestionPunctuation {
            return analysis.strongSignals.contains(.interrogativeStarter)
                || analysis.strongSignals.contains(.modalQuestionFrame)
                || analysis.strongSignals.contains(.indirectQuestionFrame)
                || analysis.strongSignals.contains(.actionRequestFrame)
                || analysis.strongSignals.contains(.directedToUser)
                || analysis.strongSignals.contains(.directedToGroup)
                || analysis.strongSignals.contains(.domainObject)
                || analysis.strongSignals.contains(.concreteObject)
        }
        if analysis.strongSignals.contains(.indirectQuestionFrame) {
            return analysis.strongSignals.contains(.concreteObject) || analysis.strongSignals.contains(.domainObject)
        }
        if analysis.strongSignals.contains(.actionRequestFrame) {
            return analysis.strongSignals.contains(.directedToUser)
                || analysis.strongSignals.contains(.directedToGroup)
                || analysis.strongSignals.contains(.concreteObject)
        }
        if analysis.strongSignals.contains(.modalQuestionFrame) {
            return analysis.strongSignals.contains(.concreteObject) || analysis.strongSignals.contains(.domainObject)
        }
        if analysis.strongSignals.contains(.interrogativeStarter) {
            return startsWithInterrogative(analysis.textAfterAddress, requireObject: true)
        }
        return false
    }

    func confidence(for analysis: QuestionSurfaceAnalysis, isPartial: Bool, precisionMode: QAPrecisionMode) -> Double {
        if analysis.isRejected { return 0.12 }
        var score = 0.50
        if analysis.hasQuestionPunctuation { score += 0.18 }
        if analysis.strongSignals.contains(.interrogativeStarter) { score += 0.22 }
        if analysis.strongSignals.contains(.modalQuestionFrame) { score += 0.24 }
        if analysis.strongSignals.contains(.indirectQuestionFrame) { score += 0.24 }
        if analysis.strongSignals.contains(.actionRequestFrame) { score += 0.24 }
        if analysis.strongSignals.contains(.directedToUser) { score += 0.11 }
        if analysis.strongSignals.contains(.directedToGroup) { score += 0.07 }
        if analysis.strongSignals.contains(.concreteObject) { score += 0.12 }
        if analysis.strongSignals.contains(.domainObject) { score += 0.05 }
        if analysis.strongSignals.contains(.contextualCarryover) { score += 0.04 }
        if analysis.strongSignals.contains(.finalUtterance) { score += 0.04 }
        if analysis.hasWeakQuestionWordOnly { score -= 0.24 }
        if isPartial { score -= precisionMode == .highPrecision ? 0.12 : 0.06 }
        return min(max(score, 0.05), 0.98)
    }

    private func removeLeadingAddress(from plain: String, profile: UserMeetingProfile?) -> String {
        var text = plain
        let aliases = ([profile?.userName].compactMap { $0 } + (profile?.userAliases ?? []))
            .map(QuestionDetectionService.normalize)
            .filter { !$0.isEmpty }
        for alias in aliases where text == alias || text.hasPrefix("\(alias) ") {
            text = text.removingPrefix(alias).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        let words = text.split(separator: " ").map(String.init)
        if words.count >= 3,
           let first = words.first,
           first.count >= 2,
           !nonAddressLeadTokens.contains(first),
           !rulePack.stopWords.contains(first),
           !rulePack.lowInformationWords.contains(first) {
            let remainder = words.dropFirst().joined(separator: " ")
            if startsWithInterrogative(remainder)
                || startsWithModalQuestionFrame(remainder)
                || hasActionRequestFrame(remainder) {
                return remainder
            }
        }
        return text
    }

    private func removeLeadingDiscourse(from plain: String) -> String {
        let prefixes = [
            "quick question", "one question", "one quick question", "small question",
            "so quick question", "ok quick question", "okay quick question",
            "pergunta rapida", "uma pergunta", "uma duvida", "tenho uma duvida",
            "minha duvida e", "a minha duvida e", "a duvida e", "a pergunta e",
            "entao", "então", "bom", "beleza",
            "pregunta rapida", "una pregunta", "una duda", "la duda es", "la pregunta es",
            "entonces", "bueno"
        ]
        for prefix in prefixes {
            let normalized = QuestionDetectionService.normalize(prefix)
            guard plain.hasPrefix("\(normalized) ") else { continue }
            let remainder = plain.removingPrefix(normalized).trimmingCharacters(in: .whitespacesAndNewlines)
            if isQuestionLikeLead(remainder) {
                return remainder
            }
        }
        return plain
    }

    private func isQuestionLikeLead(_ text: String) -> Bool {
        startsWithInterrogative(text)
            || startsWithModalQuestionFrame(text)
            || hasIndirectQuestionFrame(text)
            || hasActionRequestFrame(text)
    }

    private func startsWithInterrogative(_ text: String, requireObject: Bool = false) -> Bool {
        if containsCJK(text) {
            let cjkText = text.replacingOccurrences(of: #"\s+#\d+$"#, with: "", options: .regularExpression)
            let cjkQuestionStarters = ["どう", "何", "いつ", "誰", "どこ", "なぜ"]
            let cjkQuestionEndings = ["ですか", "ますか", "ましたか", "でしょうか", "できますか", "ありますか", "必要ですか", "問題ありますか", "影響しますか", "終わりましたか", "いいですか"]
            let hasCJKQuestionFrame = cjkQuestionStarters.contains { cjkText.hasPrefix($0) }
                || cjkQuestionEndings.contains { cjkText.hasSuffix($0) }
                || (cjkText.contains("何") && cjkQuestionEndings.contains { cjkText.hasSuffix($0) })
            if hasCJKQuestionFrame {
                return !requireObject || cjkText.count >= 5
            }
        }
        let starters = [
            "what", "what is", "what's", "when", "who", "where", "why", "how", "which", "which one",
            "qual", "qual e", "qual a", "quais", "quais sao", "quais sao os", "quais sao as", "quando", "quem", "onde", "por que", "porque", "como", "quanto", "quantos", "quantas", "o que", "o que e", "o que sao",
            "que es", "cual", "cuales", "cuales son", "cuando", "quien", "donde", "por que", "como", "cuanto", "cuantos", "cuantas",
            "何", "どう", "いつ", "誰", "どこ", "なぜ"
        ]
        guard starters.contains(where: { starter in text == starter || text.hasPrefix("\(starter) ") || text.hasPrefix(starter) && containsCJK(starter) }) else {
            return false
        }
        guard requireObject else { return true }
        return meaningfulTokens(in: text).count >= 1
            || hasNumericQuestionPayload(text)
            || containsAny(text, rulePack.domainHintMarkers)
            || containsCJK(text) && text.count >= 5
    }

    private func startsWithModalQuestionFrame(_ text: String) -> Bool {
        if text.hasPrefix("tem como objetivo ") || text.hasPrefix("tiene como objetivo ") {
            return false
        }
        if text.hasPrefix("any blockers were ") || text.hasPrefix("any blockers are ")
            || text.hasPrefix("any risks were ") || text.hasPrefix("any risks are ") {
            return false
        }
        if (text.hasPrefix("hay algun ") || text.hasPrefix("hay alguna "))
            && !containsAny(text, ["bloqueo", "riesgo", "problema", "dependencia"]) {
            return false
        }
        let starters = [
            "can", "could", "should", "would", "do", "does", "did", "is", "are", "will",
            "do you know if", "do you know whether", "you know if", "any blockers", "any risks", "main risk",
            "consegue", "conseguimos", "podemos", "pode", "voce pode", "voces podem", "deve", "deveria", "deveriamos", "vale",
            "sera que", "tem como", "da pra", "da para", "sabe se o", "sabe se a", "sabe se isso", "sabe se esse", "sabe se essa", "sabe se ja",
            "voce sabe se", "voces sabem se", "alguem sabe se", "algum problema", "algum bloqueio", "algum risco",
            "puede", "puedes", "podria", "podrias", "podriamos", "debe", "deberia", "vale la pena",
            "hay algun", "hay alguna", "sabes si", "saben si", "alguien sabe si", "esto rompe", "esto impacta"
        ]
        guard starters.contains(where: { text == $0 || text.hasPrefix("\($0) ") }) else { return false }
        return meaningfulTokens(in: text).count >= 1 || containsAny(text, rulePack.domainHintMarkers)
    }

    private func hasIndirectQuestionFrame(_ text: String) -> Bool {
        let markers = [
            "i want to understand", "i wanted to understand", "i'd like to understand", "we need to know",
            "we need to find out", "we should figure out", "need clarity on", "not clear",
            "the question is whether", "the question is if",
            "do you know if", "do you know whether", "you know if", "can you tell me if", "can you tell me whether",
            "can you tell me what", "can you tell me how", "wondering if", "trying to understand",
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
        ]
        return containsAny(text, markers)
    }

    private func hasActionRequestFrame(_ text: String) -> Bool {
        let starters = [
            "please review", "please validate", "please approve", "please explain", "please confirm",
            "review", "validate", "approve", "explain", "confirm", "take a look", "check this", "take care",
            "can you review", "can you validate", "can you explain", "could you review", "could you validate",
            "consegue revisar", "consegue validar", "consegue explicar", "voce pode revisar", "voce pode validar", "voce pode explicar",
            "revisar", "validar", "aprovar", "explicar", "confirmar", "dar uma olhada",
            "me diz", "me fala", "diz pra mim", "fala pra mim",
            "puedes revisar", "puedes validar", "puedes explicar", "podrias revisar", "podrias validar",
            "レビュー", "確認", "承認", "説明", "見てもらえますか", "レビューして", "お願いできますか"
        ]
        return starters.contains { starter in
            let normalized = QuestionDetectionService.normalize(starter)
            if containsCJK(normalized) {
                let requestMarkers = ["見てもらえますか", "レビューして", "確認して", "お願いできますか", "説明してください", "承認してください"]
                guard requestMarkers.contains(normalized) else { return false }
                return text == normalized || text.hasPrefix(normalized) || text.hasSuffix(normalized) || text.contains(normalized)
            }
            return text == normalized || text.hasPrefix("\(normalized) ")
        }
    }

    private func isDirectedToUser(_ plain: String, profile: UserMeetingProfile?) -> Bool {
        let aliases = ([profile?.userName].compactMap { $0 } + (profile?.userAliases ?? []))
            .map(QuestionDetectionService.normalize)
            .filter { !$0.isEmpty }
        return aliases.contains { alias in
            plain == alias || plain.hasPrefix("\(alias) ") || plain.contains(" \(alias) ")
        }
    }

    private func isDirectedToGroup(_ text: String) -> Bool {
        containsAny(text, ["anyone", "alguem", "alguém", "do we", "can we", "should we", "podemos", "temos", "alguien", "チーム", "みんな", "誰か"])
    }

    private func isOperationalNoAnswerCheck(_ plain: String) -> Bool {
        rulePack.operationalNoAnswerPhrases.contains { phrase in
            plain == phrase || plain.hasSuffix(" \(phrase)") || plain.hasPrefix("\(phrase) ") || plain.contains(" \(phrase) ")
        }
    }

    private func isFragment(_ text: String) -> Bool {
        if rulePack.fragmentPhrases.contains(text) { return true }
        for prefix in rulePack.fragmentPrefixes where text == prefix {
            return true
        }
        for prefix in rulePack.fragmentPhrases where text.hasPrefix("\(prefix) ") {
            let remainder = text.removingPrefix(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
            if meaningfulTokens(in: remainder).isEmpty
                && !hasNumericQuestionPayload(remainder)
                && !containsAny(remainder, rulePack.domainHintMarkers) {
                return true
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("...")
            && text.split(separator: " ").count < 6
    }

    private func isLikelyTitleOrNounPhrase(_ text: String, rawText: String) -> Bool {
        guard !rawText.contains("?"), !rawText.contains("？"), !rawText.contains("¿") else { return false }
        let words = text.split(separator: " ")
        guard words.count >= 5 else { return false }
        let hasVerbLikeQuestionFrame = startsWithInterrogative(text, requireObject: true)
            || startsWithModalQuestionFrame(text)
            || hasIndirectQuestionFrame(text)
            || hasActionRequestFrame(text)
        guard !hasVerbLikeQuestionFrame else { return false }
        let titleMarkers = ["livros sobre", "books about", "resumen de", "summary of", "arquitetura de software", "system design"]
        return titleMarkers.contains { text.contains($0) }
    }

    private func isDeclarativeWithoutInterrogativeSyntax(_ text: String, analysis: QuestionSurfaceAnalysis) -> Bool {
        if analysis.hasQuestionPunctuation { return false }
        if analysis.strongSignals.contains(.modalQuestionFrame)
            || analysis.strongSignals.contains(.indirectQuestionFrame)
            || analysis.strongSignals.contains(.actionRequestFrame) {
            return false
        }
        if startsWithInterrogative(text, requireObject: true) { return false }
        let words = text.split(separator: " ")
        return words.count >= 8 && (text.contains(" que ") || text.contains(" como ") || text.contains(" that ") || text.contains(" how "))
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

    private func hasNumericQuestionPayload(_ text: String) -> Bool {
        QuestionDetectionService.hasNumericQuestionPayload(text)
    }

    private func containsAny(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { pattern in
            let normalized = QuestionDetectionService.normalize(pattern)
            guard !normalized.isEmpty else { return false }
            if normalized.contains(" ") || containsCJK(normalized) {
                return text.contains(normalized)
            }
            let escaped = NSRegularExpression.escapedPattern(for: normalized)
            return text.range(of: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])", options: .regularExpression) != nil
        }
    }

    private func containsCJK(_ text: String) -> Bool {
        QuestionDetectionService.containsCJK(text)
    }

    private var nonAddressLeadTokens: Set<String> {
        [
            "tem", "tiene", "hay", "sabe", "sabemos", "sabes", "da", "dá", "sera", "será",
            "me", "any", "quick", "one", "isso", "esto", "este", "esta", "essa", "esse"
        ]
    }
}

struct QuestionCandidateExtractor {
    var rulePack: QuestionIntentRulePack = .default
    var precisionMode: QAPrecisionMode = .highPrecision
    var analyzer: QuestionSurfaceAnalyzer { QuestionSurfaceAnalyzer(rulePack: rulePack) }

    func candidates(from frames: [UtteranceFrame], context: TranscriptContext, profile: UserMeetingProfile? = nil) -> [QuestionCandidate] {
        detectionResult(from: frames, context: context, profile: profile).surfaceCandidates
    }

    func detectionResult(from frames: [UtteranceFrame], context: TranscriptContext, profile: UserMeetingProfile? = nil) -> QuestionDetectionResult {
        var surfaceCandidates: [QuestionCandidate] = []
        var rejectedFrames: [QuestionRejectedFrame] = []

        for frame in frames {
            let analysis = analyzer.analyze(
                text: frame.rawText,
                normalized: frame.normalizedText,
                context: context,
                profile: profile,
                isPartial: frame.isPartial,
                isFinal: frame.isFinal
            )
            let surfaceSignals = analysis.strongSignals.map(\.rawValue).sorted()
            let suppressionSignals = analysis.negativeSignals
            guard analyzer.isCandidateSurface(analysis, precisionMode: precisionMode) else {
                rejectedFrames.append(
                    QuestionRejectedFrame(
                        frame: frame,
                        surfaceSignals: surfaceSignals,
                        suppressionSignals: suppressionSignals,
                        reason: suppressionSignals.isEmpty
                            ? "surface_below_candidate_threshold"
                            : suppressionSignals.joined(separator: ",")
                    )
                )
                continue
            }
            surfaceCandidates.append(
                QuestionCandidate(
                    meetingId: frame.meetingId,
                    rawText: frame.rawText,
                    normalizedText: frame.normalizedText,
                    language: frame.language,
                    speakerId: frame.speakerId,
                    speakerLabel: frame.speakerLabel,
                    startTime: frame.startTime,
                    endTime: frame.endTime,
                    sourceSegmentIds: [frame.sourceSegmentId],
                    isPartial: frame.isPartial,
                    multimodalSignal: frame.multimodalSignal,
                    discovery: QuestionCandidateDiscovery(
                        source: .surface,
                        surfaceSignals: surfaceSignals,
                        surfaceSuppressionSignals: suppressionSignals
                    )
                )
            )
        }

        return QuestionDetectionResult(
            surfaceCandidates: surfaceCandidates,
            rejectedFrames: rejectedFrames
        )
    }
}

struct QuestionSpanExtractor: Sendable {
    var rulePack: QuestionIntentRulePack = .default

    func extractedQuestion(
        from rawText: String,
        language: String?,
        profile: UserMeetingProfile? = nil
    ) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }

        var text = trimmed
        text = removeLeadingAddress(from: text, profile: profile)
        text = removeLeadingDiscourse(from: text)
        text = removeTrailingSelfAnswer(from: text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:"))
        return text.isEmpty ? trimmed : text
    }

    private func removeLeadingAddress(from text: String, profile: UserMeetingProfile?) -> String {
        var aliases = ([profile?.userName].compactMap { $0 } + (profile?.userAliases ?? []))
        aliases.append(contentsOf: ["ryan", "team", "pessoal", "galera", "equipo", "チーム"])
        for alias in aliases.sorted(by: { $0.count > $1.count }) {
            let normalizedAlias = QuestionDetectionService.normalize(alias)
            let normalizedText = QuestionDetectionService.normalize(text)
            guard !normalizedAlias.isEmpty,
                  normalizedText == normalizedAlias || normalizedText.hasPrefix("\(normalizedAlias) ") || normalizedText.hasPrefix("\(normalizedAlias),") else { continue }
            let dropCount = min(alias.count, text.count)
            let remainder = String(text.dropFirst(dropCount))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;-")))
            if isQuestionLike(remainder) {
                return remainder
            }
        }
        return text
    }

    private func removeLeadingDiscourse(from text: String) -> String {
        let prefixes = [
            "quick question", "one question", "one quick question", "small question", "so quick question", "okay quick question",
            "uma pergunta", "uma duvida", "uma dúvida", "tenho uma duvida", "tenho uma dúvida", "minha duvida e", "minha dúvida é",
            "a minha duvida e", "a minha dúvida é", "a duvida e", "a dúvida é", "a pergunta e", "a pergunta é", "entao", "então", "bom", "beleza",
            "pregunta rapida", "pregunta rápida", "una pregunta", "una duda", "la duda es", "la pregunta es", "entonces", "bueno",
            "質問ですが", "質問は", "確認ですが", "疑問は"
        ]
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) {
            let normalizedPrefix = QuestionDetectionService.normalize(prefix)
            let normalizedText = QuestionDetectionService.normalize(text)
            guard normalizedText == normalizedPrefix || normalizedText.hasPrefix("\(normalizedPrefix) ") else { continue }
            let remainder = String(text.dropFirst(min(prefix.count, text.count)))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;-")))
            if isQuestionLike(remainder) {
                return remainder
            }
        }
        return text
    }

    private func removeTrailingSelfAnswer(from text: String) -> String {
        let markers = ["? yes", "? no", "? sim", "? nao", "? não", "? si", "? sí", "？はい", "？いいえ", "? はい", "? いいえ"]
        let normalized = QuestionDetectionService.normalize(text)
        for marker in markers {
            let normalizedMarker = QuestionDetectionService.normalize(marker)
            guard let range = normalized.range(of: normalizedMarker) else { continue }
            let distance = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
            guard distance > 0, distance < text.count else { continue }
            let index = text.index(text.startIndex, offsetBy: distance)
            return String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func isQuestionLike(_ text: String) -> Bool {
        let normalized = QuestionDetectionService.normalize(text)
        guard !normalized.isEmpty else { return false }
        let plain = QuestionIntentGate.plainQuestionText(normalized)
        return normalized.contains("?")
            || normalized.contains("？")
            || normalized.contains("¿")
            || rulePack.directQuestionMarkers.contains { plain == $0 || plain.hasPrefix("\($0) ") || (QuestionDetectionService.containsCJK($0) && plain.contains($0)) }
            || rulePack.indirectQuestionMarkers.contains { plain == $0 || plain.hasPrefix("\($0) ") || plain.contains($0) }
            || rulePack.actionRequestMarkers.contains { plain == $0 || plain.hasPrefix("\($0) ") || (QuestionDetectionService.containsCJK($0) && plain.contains($0)) }
            || rulePack.modalQuestionStarters.contains { plain == $0 || plain.hasPrefix("\($0) ") }
    }
}

struct QuestionDetectionService {
    private let languageDetector: AppleLanguageDetectionService
    private let rulePack: QuestionIntentRulePack
    private let frameBuilder: UtteranceFrameBuilder
    private let extractor: QuestionCandidateExtractor

    init(
        rulePack: QuestionIntentRulePack = .default,
        adaptiveProfile: QuestionAnsweringAdaptiveProfile = QuestionAnsweringAdaptiveProfile(),
        precisionMode: QAPrecisionMode = .highPrecision,
        languageDetector: AppleLanguageDetectionService = AppleLanguageDetectionService()
    ) {
        self.rulePack = rulePack
        self.frameBuilder = UtteranceFrameBuilder()
        self.extractor = QuestionCandidateExtractor(rulePack: rulePack, precisionMode: precisionMode)
        self.languageDetector = languageDetector
        _ = adaptiveProfile
    }

    func detectCandidates(from segment: TranscriptSegment, context: TranscriptContext) -> [QuestionCandidate] {
        detectCandidates(from: segment, context: context, signal: nil)
    }

    func detectCandidates(from segment: TranscriptSegment, context: TranscriptContext, signal: QuestionMultimodalSignal?) -> [QuestionCandidate] {
        detect(from: segment, context: context, signal: signal).surfaceCandidates
    }

    func detect(from segment: TranscriptSegment, context: TranscriptContext) -> QuestionDetectionResult {
        detect(from: segment, context: context, signal: nil)
    }

    func detect(from segment: TranscriptSegment, context: TranscriptContext, signal: QuestionMultimodalSignal?) -> QuestionDetectionResult {
        let frames = frameBuilder.frames(from: segment, context: context, signal: signal)
        guard !frames.isEmpty else { return .empty }
        let result = extractor.detectionResult(from: frames, context: context)
        return QuestionDetectionResult(
            surfaceCandidates: result.surfaceCandidates.map { candidate in
                if candidate.language != nil { return candidate }
                return QuestionCandidate(
                    id: candidate.id,
                    meetingId: candidate.meetingId,
                    rawText: candidate.rawText,
                    normalizedText: candidate.normalizedText,
                    language: languageDetector.dominantLanguage(for: candidate.rawText),
                    speakerId: candidate.speakerId,
                    speakerLabel: candidate.speakerLabel,
                    startTime: candidate.startTime,
                    endTime: candidate.endTime,
                    sourceSegmentIds: candidate.sourceSegmentIds,
                    isPartial: candidate.isPartial,
                    detectedAt: candidate.detectedAt,
                    multimodalSignal: candidate.multimodalSignal,
                    discovery: candidate.discovery,
                    classification: candidate.classification,
                    status: candidate.status
                )
            },
            rejectedFrames: result.rejectedFrames
        )
    }

    func isLikelyQuestion(_ normalized: String) -> Bool {
        let analyzer = QuestionSurfaceAnalyzer(rulePack: rulePack)
        let analysis = analyzer.analyze(
            text: normalized,
            normalized: normalized,
            context: nil,
            profile: nil,
            isPartial: false,
            isFinal: true
        )
        return analyzer.isCandidateSurface(analysis, precisionMode: .highPrecision)
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(Int(scalar.value)) || (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    static func hasNumericQuestionPayload(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }

        let digitCount = normalized.split { !$0.isNumber }.count
        let numberWords: Set<String> = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "um", "uma", "dois", "duas", "tres", "três", "quatro", "cinco", "seis", "sete", "oito", "nove", "dez",
            "uno", "una", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve", "diez"
        ]
        let wordNumberCount = normalized
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { numberWords.contains($0) }
            .count
        let numericCount = digitCount + wordNumberCount
        guard numericCount >= 2 else { return false }

        let operatorMarkers = [
            "+", "-", "*", "/", "×", "÷",
            "plus", "minus", "times", "divided", "over",
            "mais", "menos", "vezes", "dividido", "por",
            "mas", "más"
        ]
        return operatorMarkers.contains { marker in
            let normalizedMarker = normalize(marker)
            guard !normalizedMarker.isEmpty else { return false }
            if normalizedMarker.count == 1, !normalizedMarker.first!.isLetter, !normalizedMarker.first!.isNumber {
                return normalized.contains(normalizedMarker)
            }
            return normalized.range(
                of: "(?<![A-Za-z0-9])\(NSRegularExpression.escapedPattern(for: normalizedMarker))(?![A-Za-z0-9])",
                options: .regularExpression
            ) != nil
        }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}
