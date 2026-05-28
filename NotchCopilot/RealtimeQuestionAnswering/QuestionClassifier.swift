import Foundation

@MainActor
protocol QuestionClassifierProvider {
    func classifyQuestion(
        candidate: QuestionCandidate,
        context: TranscriptContext,
        userProfile: UserMeetingProfile
    ) async throws -> QuestionClassification
}

struct QuestionMultimodalDecision: Hashable, Sendable {
    var textualConfidence: Double
    var multimodalConfidence: Double
    var decisionScore: Double
    var shouldAllow: Bool
    var decisionSignals: [String]
    var suppressionSignals: [String]
}

struct QuestionMultimodalScorer: Sendable {
    func score(
        understanding: LocalQuestionUnderstanding,
        signal: QuestionMultimodalSignal?,
        precisionMode: QAPrecisionMode,
        isPartial: Bool
    ) -> QuestionMultimodalDecision {
        let textual = min(max(understanding.confidence, 0.05), 0.98)
        guard let signal else {
            return QuestionMultimodalDecision(
                textualConfidence: textual,
                multimodalConfidence: textual,
                decisionScore: textual,
                shouldAllow: true,
                decisionSignals: ["text_only"],
                suppressionSignals: []
            )
        }

        var multimodal = textual
        var decisionSignals: [String] = []
        var suppressionSignals: [String] = []

        if signal.isFinal {
            multimodal += 0.05
            decisionSignals.append("final")
        } else if signal.partialStability >= 0.82 {
            multimodal += 0.04
            decisionSignals.append("partial_stable")
        } else if isPartial {
            multimodal -= 0.18
            suppressionSignals.append("partial_unstable")
        }

        if let asr = signal.asrConfidence {
            if asr >= 0.82 {
                multimodal += 0.03
                decisionSignals.append("asr_confident")
            } else if asr < 0.45 {
                multimodal -= 0.12
                suppressionSignals.append("low_asr_confidence")
            }
        }

        if signal.hasTerminalPause {
            multimodal += 0.03
            decisionSignals.append("terminal_pause")
        }

        if signal.duration >= 0.45 && signal.duration <= 18 {
            multimodal += 0.02
            decisionSignals.append("duration_plausible")
        } else if signal.duration > 0 && signal.duration < 0.30 {
            multimodal -= 0.10
            suppressionSignals.append("too_short_audio")
        } else if signal.duration > 30 {
            multimodal -= 0.04
            suppressionSignals.append("too_long_audio")
        }

        let energy = signal.audioEnergy ?? signal.rms
        if let energy {
            if energy >= 0.002 && energy <= 0.35 {
                multimodal += 0.02
                decisionSignals.append("energy_present")
            } else if energy < 0.001 {
                multimodal -= 0.08
                suppressionSignals.append("near_silence")
            }
        }

        if signal.isSilence {
            multimodal -= 0.10
            suppressionSignals.append("silence")
        }
        if signal.isTooQuiet {
            multimodal -= 0.08
            suppressionSignals.append("too_quiet")
        }
        if signal.isClipping {
            multimodal -= 0.08
            suppressionSignals.append("clipping")
        }
        if signal.gapCount >= 2 {
            multimodal -= 0.04
            suppressionSignals.append("audio_gaps")
        }

        multimodal = min(max(multimodal, 0.05), 0.98)
        let decisionScore = min(max((textual * 0.65) + (multimodal * 0.35), 0.05), 0.98)
        let threshold = isPartial ? precisionMode.partialConfidenceThreshold : precisionMode.confidenceThreshold
        let hardSuppression = suppressionSignals.contains("partial_unstable")
            || suppressionSignals.contains("silence")
            || suppressionSignals.contains("near_silence")
        let shouldAllow = !hardSuppression && decisionScore >= min(threshold, textual)

        return QuestionMultimodalDecision(
            textualConfidence: textual,
            multimodalConfidence: multimodal,
            decisionScore: decisionScore,
            shouldAllow: shouldAllow,
            decisionSignals: decisionSignals.isEmpty ? ["multimodal_neutral"] : decisionSignals,
            suppressionSignals: suppressionSignals
        )
    }
}

struct QuestionTypeRule: Codable, Hashable, Sendable {
    var type: QuestionType
    var markers: [String]
}

struct QuestionClassificationRulePack: Codable, Hashable, Sendable {
    var typeRules: [QuestionTypeRule]
    var directedToUserMarkers: [String]
    var directedToGroupMarkers: [String]
    var actionableMarkers: [String]
    var informationalMarkers: [String]
    var technicalObjectMarkers: [String]

    static let `default` = QuestionClassificationRulePack(
        typeRules: [
            QuestionTypeRule(type: .statusCheck, markers: ["status", "estado", "situacao", "situación", "api pronta", "progress", "progreso", "terminou", "finished", "ready", "pronto", "done", "está listo", "esta listo", "進捗", "状況", "状態", "終わりました"]),
            QuestionTypeRule(type: .riskAssessment, markers: ["risk", "risco", "blocker", "blockers", "bloqueio", "bloqueio", "break", "quebra", "rompe", "impacta", "afeta", "security", "seguranca", "production", "producao", "migration", "migracao", "migracion", "リスク", "影響", "壊れ", "セキュリティ", "移行"]),
            QuestionTypeRule(type: .technicalDecision, markers: ["approach", "abordagem", "arquitetura", "architecture", "faz mais sentido", "which option", "decision", "decisao", "decisión", "scale", "scalable", "highly available", "alta disponibilidade", "altamente disponivel", "escalaria", "escalar", "system design", "lidar com", "como vamos lidar", "handle authentication", "how should we handle", "how do we handle", "アプローチ", "設計", "判断"]),
            QuestionTypeRule(type: .technicalExplanation, markers: ["explain", "explicar", "como funciona", "how does", "what is", "what's", "o que e", "que es", "hashid", "hash id", "python", "binary tree", "binary three", "binary dream", "arvore binaria", "invert a tree", "invert tree", "inverter uma arvore", "data structure", "algorithm", "algoritmo", "説明", "仕組み", "どう動く"]),
            QuestionTypeRule(type: .deadlineOrEstimate, markers: ["sexta", "friday", "deadline", "prazo", "entregar", "ship", "timeline", "estimate", "estimativa", "fecha", "plazo", "quando entregamos", "when can we ship", "いつ", "期限", "金曜", "金曜日"]),
            QuestionTypeRule(type: .ownership, markers: ["quem vai", "quem fica", "responsavel", "responsável", "owner", "owns this", "who owns", "who will", "who is responsible", "quem cuida", "responsable", "quien se encarga", "quién se encarga", "誰が", "担当", "オーナー"]),
            QuestionTypeRule(type: .productScope, markers: ["scope", "escopo", "mvp", "roadmap", "alcance", "スコープ"]),
            QuestionTypeRule(type: .businessContext, markers: ["business", "cliente", "customer", "impacto", "impact", "negocio", "negócio", "revenue", "receita", "ventas", "顧客", "ビジネス"]),
            QuestionTypeRule(type: .clarification, markers: ["clarify", "claro", "duvida", "doubt", "not clear", "nao ficou claro", "no queda claro", "no esta claro", "明確", "はっきり"]),
            QuestionTypeRule(type: .approvalRequest, markers: ["approve", "approval", "aprovar", "aprovacao", "aprobacion", "sign off", "承認"]),
            QuestionTypeRule(type: .actionRequest, markers: ["review", "validate", "revisar", "validar", "checar", "confirmar", "consegue", "can you", "could you", "please", "puedes", "podrias", "podrías", "レビュー", "確認して", "見てもらえ"]),
            QuestionTypeRule(type: .opinionRequest, markers: ["think", "acha", "opinion", "opiniao", "what do you think", "o que voces acham", "que opinan", "どう思"]),
            QuestionTypeRule(type: .followUp, markers: ["follow up", "next step", "proximo passo", "acompanhar", "siguiente paso", "次のステップ", "フォロー"])
        ],
        directedToUserMarkers: ["can you", "could you", "do you know if", "voce pode", "consegue", "você consegue", "me diz", "me fala", "puedes", "podrias", "sabes si", "確認して", "レビューして", "見てもらえ"],
        directedToGroupMarkers: ["anyone", "alguem", "do we", "can we", "should we", "we ", "temos", "podemos", "alguien", "nosotros", "any blockers", "hay algun", "hay alguna", "チーム", "みんな", "誰か"],
        actionableMarkers: ["next", "proximo", "validate", "review", "confirm", "decide", "validar", "revisar", "confirmar", "me diz", "me fala", "確認", "レビュー", "決め"],
        informationalMarkers: ["what", "what is", "what's", "how", "why", "which", "do you know if", "any blockers", "qual", "quanto", "quanto e", "quantos", "quantas", "o que", "como", "por que", "sabe se", "sera que", "que es", "cual", "cuanto", "cuanto es", "cuantos", "cuantas", "sabes si", "hay algun", "何", "どう", "なぜ", "capital", "hash", "python", "arvore", "tree", "system", "sistema", "scale", "escalar"],
        technicalObjectMarkers: ["api", "backend", "frontend", "auth", "authentication", "autenticacao", "login", "oauth", "jwt", "database", "cache", "queue", "python", "swift", "kotlin", "javascript", "typescript", "react", "node", "hash", "hashid", "tree", "binary tree", "binary three", "binary dream", "algorithm", "algoritmo", "data structure", "service", "endpoint", "system", "sistema", "architecture", "arquitetura", "認証", "サービス"]
    )
}

struct LocalQuestionUnderstandingProvider {
    var rulePack: QuestionIntentRulePack = .default
    var precisionMode: QAPrecisionMode = .highPrecision
    var analyzer: QuestionSurfaceAnalyzer { QuestionSurfaceAnalyzer(rulePack: rulePack) }

    func understand(
        candidate: QuestionCandidate,
        context: TranscriptContext,
        userProfile: UserMeetingProfile
    ) -> LocalQuestionUnderstanding {
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
                confidence: min(confidence, 0.48),
                strongSignals: analysis.strongSignals,
                negativeSignals: analysis.negativeSignals,
                reason: "Utterance does not have enough interrogative structure for high-precision Notchly activation.",
                extractedQuestion: candidate.rawText
            )
        }

        let intent: LocalQuestionIntent = analysis.strongSignals.contains(.actionRequestFrame) ? .actionRequest : .answerableQuestion
        return LocalQuestionUnderstanding(
            intent: intent,
            confidence: confidence,
            strongSignals: analysis.strongSignals,
            negativeSignals: [],
            reason: "Local detector found a complete answerable question with \(decisionSignalCount(analysis.strongSignals)) strong signals.",
            extractedQuestion: candidate.rawText
        )
    }

    private func intent(fromNegativeSignals signals: [String]) -> LocalQuestionIntent? {
        if signals.contains("small_talk") { return .smallTalk }
        if signals.contains("operational_check") { return .operationalCheck }
        if signals.contains("reported_question") { return .reportedQuestion }
        if signals.contains("rhetorical") { return .rhetorical }
        if signals.contains("fragment") { return .fragment }
        if signals.contains("self_answered") { return .statement }
        if signals.contains("noun_phrase_or_title") || signals.contains("declarative_without_interrogative_syntax") {
            return .statement
        }
        return nil
    }

    private func reason(for intent: LocalQuestionIntent, signals: [String]) -> String {
        switch intent {
        case .smallTalk:
            "Small talk greeting does not need a meeting answer."
        case .operationalCheck:
            "Operational audio or screen check should not trigger Notchly."
        case .reportedQuestion:
            "Question-like text is being reported or explained, not asked."
        case .rhetorical:
            "Question is likely rhetorical."
        case .fragment:
            "Question-like fragment has no answerable object."
        case .statement:
            "Statement or title-like utterance is not an answerable question."
        case .ambiguous:
            "Question signal is ambiguous below the local precision threshold."
        case .answerableQuestion, .actionRequest:
            signals.isEmpty ? "Question appears answerable." : signals.joined(separator: ", ")
        }
    }

    private func decisionSignalCount(_ signals: Set<QuestionUnderstandingSignal>) -> Int {
        signals.subtracting(Set([.finalUtterance])).count
    }
}

struct QuestionDecisionGate {
    func shouldAccept(
        understanding: LocalQuestionUnderstanding,
        precisionMode: QAPrecisionMode,
        isPartial: Bool
    ) -> Bool {
        guard understanding.responseNeeded else { return false }
        let decisionSignals = understanding.strongSignals.subtracting(Set([.finalUtterance]))
        guard decisionSignals.count >= precisionMode.requiredStrongSignalCount else { return false }
        if isPartial {
            let meetsPartialThreshold = understanding.confidence >= precisionMode.partialConfidenceThreshold
            let completeQuestionShape = decisionSignals.contains(.interrogativeStarter)
                && decisionSignals.contains(.concreteObject)
                && understanding.confidence >= max(precisionMode.confidenceThreshold - 0.12, 0.70)
            return (meetsPartialThreshold && (decisionSignals.contains(.directedToUser) || decisionSignals.contains(.actionRequestFrame)))
                || completeQuestionShape
        }
        guard understanding.confidence >= precisionMode.confidenceThreshold else { return false }
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

    init(
        intentRulePack: QuestionIntentRulePack = .default,
        classificationRulePack: QuestionClassificationRulePack = .default,
        adaptiveProfile: QuestionAnsweringAdaptiveProfile = QuestionAnsweringAdaptiveProfile(),
        priorityScorer: QuestionPriorityScorer = QuestionPriorityScorer(),
        precisionMode: QAPrecisionMode = .highPrecision,
        multimodalMode: QAMultimodalMode = .shadow
    ) {
        self.rhetoricalFilter = RhetoricalQuestionFilter(rulePack: intentRulePack)
        self.intentGate = QuestionIntentGate(rulePack: intentRulePack, adaptiveProfile: adaptiveProfile)
        self.rulePack = classificationRulePack
        self.priorityScorer = priorityScorer
        self.understandingProvider = LocalQuestionUnderstandingProvider(rulePack: intentRulePack, precisionMode: precisionMode)
        self.decisionGate = QuestionDecisionGate()
        self.multimodalScorer = QuestionMultimodalScorer()
        self.spanExtractor = QuestionSpanExtractor(rulePack: intentRulePack)
        self.precisionMode = precisionMode
        self.multimodalMode = multimodalMode
    }

    func classifyQuestion(
        candidate: QuestionCandidate,
        context: TranscriptContext,
        userProfile: UserMeetingProfile
    ) async throws -> QuestionClassification {
        let understanding = understandingProvider.understand(candidate: candidate, context: context, userProfile: userProfile)
        guard understanding.intent.isQuestionLike else {
            return QuestionClassification(understanding: understanding, candidate: candidate)
        }

        let intent = intentGate.evaluate(candidate: candidate, context: context)
        guard intent.isAnswerableQuestion else {
            return QuestionClassification(ignoredBy: intent, candidate: candidate)
        }

        let filter = rhetoricalFilter.evaluation(for: candidate, context: context)
        let type = questionType(for: candidate.normalizedText, profile: userProfile)
        let directedToUser = isDirectedToUser(candidate.normalizedText, speakerLabel: candidate.speakerLabel, profile: userProfile)
        let directedToGroup = !directedToUser && isDirectedToGroup(candidate.normalizedText)
        let actionable = isActionable(candidate.normalizedText, type: type)
        let informational = isInformational(candidate.normalizedText)
        let indirectQuestion = understanding.strongSignals.contains(.indirectQuestionFrame)
        let acceptedByDecisionGate = decisionGate.shouldAccept(
            understanding: understanding,
            precisionMode: precisionMode,
            isPartial: candidate.isPartial
        )
        let multimodalDecision = multimodalScorer.score(
            understanding: understanding,
            signal: candidate.multimodalSignal,
            precisionMode: precisionMode,
            isPartial: candidate.isPartial
        )
        let acceptedByMultimodalGate = multimodalMode == .enforced ? multimodalDecision.shouldAllow : true
        let responseNeeded = acceptedByDecisionGate
            && acceptedByMultimodalGate
            && understanding.responseNeeded
            && !filter.rhetorical
            && filter.complete
            && (actionable || directedToUser || directedToGroup || informational || indirectQuestion || type != .generalQuestion)
        let priority = priorityScorer.priority(
            for: candidate,
            type: type,
            directedToUser: directedToUser,
            directedToGroup: directedToGroup,
            actionable: actionable,
            responseNeeded: responseNeeded
        )
        let confidence = min(
            max(confidence(for: candidate, filter: filter, directedToUser: directedToUser, type: type), multimodalMode == .enforced ? multimodalDecision.decisionScore : understanding.confidence),
            0.98
        )
        let extractedQuestion = spanExtractor.extractedQuestion(
            from: understanding.extractedQuestion,
            language: candidate.language,
            profile: userProfile
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
                confidence: min(confidence, 0.72),
                reason: !acceptedByMultimodalGate
                    ? "Rejected by multimodal stability gate: \(multimodalDecision.suppressionSignals.joined(separator: ", "))"
                    : "Rejected by high-precision local decision gate: \(understanding.reason)",
                extractedQuestion: extractedQuestion,
                expectedAnswerStyle: .concise,
                textualConfidence: multimodalDecision.textualConfidence,
                multimodalConfidence: multimodalDecision.multimodalConfidence,
                decisionScore: multimodalDecision.decisionScore,
                decisionSignals: multimodalDecision.decisionSignals,
                suppressionSignals: multimodalDecision.suppressionSignals
            )
        }

        return QuestionClassification(
            isQuestion: !filter.ignore || filter.rhetorical,
            rhetorical: filter.rhetorical,
            complete: filter.complete,
            actionable: actionable,
            responseNeeded: responseNeeded,
            userAttentionNeeded: responseNeeded && (directedToUser || priority == .urgent || priority == .high),
            directedToUser: directedToUser,
            directedToGroup: directedToGroup,
            questionType: type,
            priority: priority,
            confidence: confidence,
            reason: understanding.reason,
            extractedQuestion: extractedQuestion,
            expectedAnswerStyle: answerStyle(for: type, filter: filter),
            textualConfidence: multimodalDecision.textualConfidence,
            multimodalConfidence: multimodalDecision.multimodalConfidence,
            decisionScore: multimodalDecision.decisionScore,
            decisionSignals: multimodalDecision.decisionSignals,
            suppressionSignals: multimodalDecision.suppressionSignals
        )
    }

    private func questionType(for text: String, profile: UserMeetingProfile) -> QuestionType {
        for rule in rulePack.typeRules where contains(text, rule.markers) {
            return rule.type
        }
        if profile.meetingType == .engineering,
           contains(text, ["como vamos", "como devemos", "lidar com", "how should we", "how do we", "how would you", "scale this system", "escalaria"]),
           contains(text, rulePack.technicalObjectMarkers + ["scale", "escalar", "escalaria", "disponivel", "available"]) {
            return .technicalDecision
        }
        if profile.meetingType == .engineering,
           contains(text, rulePack.technicalObjectMarkers),
           contains(text, ["what is", "what's", "how does", "how do", "como", "o que e", "que es", "どう", "説明"]) {
            return .technicalExplanation
        }
        return .generalQuestion
    }

    private func answerStyle(for type: QuestionType, filter: (ignore: Bool, rhetorical: Bool, complete: Bool, responseNeeded: Bool, reason: String)) -> AnswerStyle {
        if !filter.complete { return .askForClarification }
        switch type {
        case .technicalExplanation, .technicalDecision, .riskAssessment: return .technical
        case .deadlineOrEstimate, .approvalRequest, .productScope: return .cautious
        case .businessContext: return .executive
        case .opinionRequest, .actionRequest: return .diplomatic
        default: return .concise
        }
    }

    private func isDirectedToUser(_ text: String, speakerLabel: String?, profile: UserMeetingProfile) -> Bool {
        let aliases = ([profile.userName] + profile.userAliases)
            .map(QuestionDetectionService.normalize)
            .filter { !$0.isEmpty }
        if aliases.contains(where: { text.contains($0) }) {
            return true
        }
        if speakerLabel?.localizedCaseInsensitiveContains("You") == true || speakerLabel == "Você" {
            return false
        }
        return contains(text, rulePack.directedToUserMarkers)
    }

    private func isDirectedToGroup(_ text: String) -> Bool {
        contains(text, rulePack.directedToGroupMarkers)
    }

    private func isActionable(_ text: String, type: QuestionType) -> Bool {
        if [.actionRequest, .approvalRequest, .deadlineOrEstimate, .ownership, .technicalDecision, .riskAssessment, .statusCheck].contains(type) {
            return true
        }
        return contains(text, rulePack.actionableMarkers)
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
        if filter.ignore && !filter.rhetorical { return 0.28 }
        var score = candidate.rawText.contains("?") || candidate.rawText.contains("？") ? 0.72 : 0.58
        if directedToUser { score += 0.14 }
        if type != .generalQuestion { score += 0.08 }
        if candidate.isPartial { score -= 0.08 }
        if filter.rhetorical { score = 0.62 }
        return min(max(score, 0.05), 0.98)
    }

    private func contains(_ text: String, _ patterns: [String]) -> Bool {
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
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(Int(scalar.value)) || (0x4E00...0x9FFF).contains(Int(scalar.value))
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
