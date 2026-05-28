import Foundation

@MainActor
struct OpenAIStreamingMeetingAnswerProvider: MeetingAnswerProvider {
    var provider: OpenAIProvider
    var safetyGuard = AnswerSafetyGuard()

    func generateAnswer(
        question: QuestionCandidate,
        classification: QuestionClassification,
        context: AnswerContext,
        options: AnswerGenerationOptions
    ) async throws -> AsyncThrowingStream<PartialAnswer, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                let startedAt = Date()
                var accumulatedText = ""
                var providerSources: [AnswerSource] = []
                do {
                    if shouldEmitImmediateDraft(classification: classification, context: context) {
                        continuation.yield(PartialAnswer(textDelta: provisionalText(for: question), isFinal: false, suggestedAnswer: nil))
                    }

                    let stream = try await provider.streamAnswer(
                        context: context,
                        question: question.rawText,
                        options: AnswerOptions(
                            maxSentences: options.maxSentences,
                            allowCommitments: options.allowCommitments,
                            enableWebSearch: options.enableWebSearch && !options.localOnlyMode
                        )
                    )
                    for try await event in stream {
                        switch event {
                        case .delta(let text):
                            guard !text.isEmpty else { continue }
                            accumulatedText += text
                            continuation.yield(PartialAnswer(textDelta: text, isFinal: false, suggestedAnswer: nil))
                        case .completed:
                            break
                        }
                    }

                    if accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let fallback = try await provider.generateAnswer(
                            context: context,
                            question: question.rawText,
                            options: AnswerOptions(
                                maxSentences: options.maxSentences,
                                allowCommitments: options.allowCommitments,
                                enableWebSearch: options.enableWebSearch && !options.localOnlyMode
                            )
                        )
                        accumulatedText = fallback.text
                        providerSources = fallback.sources
                    }

                    let formattedText = AnswerPresentationFormatter.normalizedGeneratedText(
                        accumulatedText,
                        question: question,
                        classification: classification
                    )
                    let latency = Int(Date().timeIntervalSince(startedAt) * 1000)
                    let answer = SuggestedAnswer(
                        questionId: question.id,
                        answerText: formattedText,
                        shortAnswer: AnswerPresentationFormatter.shortAnswer(from: formattedText),
                        confidence: classification.confidence,
                        riskLevel: .safe,
                        usedSources: mergedSources(context.retrievedSources, providerSources),
                        assumptions: assumptions(for: classification, context: context),
                        caveats: caveats(for: classification, context: context),
                        latencyMs: latency,
                        expandedAnswer: formattedText,
                        suggestedTone: classification.expectedAnswerStyle,
                        shouldAskClarification: classification.expectedAnswerStyle == .askForClarification,
                        clarifyingQuestion: classification.expectedAnswerStyle == .askForClarification ? "What detail should we confirm before answering?" : nil,
                        language: question.language ?? context.languageCode,
                        provider: .openAI,
                        usedCloud: true,
                        usedRAG: !context.ragContext.isEmpty
                    )
                    let safeAnswer = safetyGuard.sanitized(answer, classification: classification)
                    continuation.yield(PartialAnswer(textDelta: safeAnswer.shortAnswer, isFinal: true, suggestedAnswer: safeAnswer))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func shouldEmitImmediateDraft(classification: QuestionClassification, context: AnswerContext) -> Bool {
        classification.priority == .urgent || classification.priority == .high || !context.ragContext.isEmpty
    }

    private func provisionalText(for question: QuestionCandidate) -> String {
        if SupportedLanguage.language(for: question.language) == .portugueseBR || question.rawText.localizedCaseInsensitiveContains("você") {
            return "Estou checando o contexto; já vou sugerir uma resposta curta e segura."
        }
        return "I’m checking the context and drafting a short, safe answer."
    }

    private func assumptions(for classification: QuestionClassification, context: AnswerContext) -> [String] {
        context.retrievedSources.isEmpty && classification.questionType != .generalQuestion ? ["No external source was available for this draft."] : []
    }

    private func caveats(for classification: QuestionClassification, context: AnswerContext) -> [String] {
        switch classification.questionType {
        case .deadlineOrEstimate:
            ["Confirm PR status, tests, and blockers before committing to a date."]
        case .approvalRequest:
            ["Needs explicit human approval before being treated as a decision."]
        case .riskAssessment:
            ["Validate the risk against the actual implementation before shipping."]
        default:
            []
        }
    }

    private func mergedSources(_ contextSources: [AnswerSource], _ generatedSources: [AnswerSource]) -> [AnswerSource] {
        var seen: Set<AnswerSource> = []
        return (contextSources + generatedSources).filter { seen.insert($0).inserted }
    }
}
