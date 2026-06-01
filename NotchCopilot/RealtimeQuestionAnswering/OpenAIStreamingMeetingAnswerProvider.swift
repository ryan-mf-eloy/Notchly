import Foundation

@MainActor
struct OpenAIStreamingMeetingAnswerProvider: MeetingAnswerProvider {
    var provider: OpenAIProvider
    var safetyGuard = AnswerSafetyGuard()
    var generationPolicy: AnswerGenerationPolicy = .default

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
                        if let provisionalText = generationPolicy.provisionalDraft(for: question.language ?? context.languageCode) {
                            continuation.yield(PartialAnswer(textDelta: provisionalText, isFinal: false, suggestedAnswer: nil))
                        }
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
                    let sources = mergedSources(context.retrievedSources, providerSources)
                    let presentation = try CopilotAnswerPresenter().present(
                        text: formattedText,
                        candidate: question,
                        classification: classification,
                        tool: .answerSynthesis,
                        intent: generationPolicy.copilotIntent(for: classification.questionType),
                        sources: sources
                    )
                    let answer = SuggestedAnswer(
                        questionId: question.id,
                        answerText: presentation.text,
                        shortAnswer: presentation.shortText,
                        confidence: classification.confidence,
                        riskLevel: .safe,
                        usedSources: presentation.sources,
                        assumptions: assumptions(for: classification, context: context),
                        caveats: mergedCaveats(caveats(for: classification, context: context), presentation.caveats),
                        latencyMs: latency,
                        expandedAnswer: presentation.text,
                        suggestedTone: classification.expectedAnswerStyle,
                        shouldAskClarification: classification.expectedAnswerStyle == .askForClarification,
                        clarifyingQuestion: classification.expectedAnswerStyle == .askForClarification ? generationPolicy.defaultClarifyingQuestion.nilIfEmptyAnswerGeneration : nil,
                        language: question.language ?? context.languageCode,
                        provider: .openAI,
                        usedCloud: true,
                        usedRAG: !context.ragContext.isEmpty,
                        answerFormat: presentation.format,
                        richAnswer: presentation.richAnswer
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
        generationPolicy.shouldEmitImmediateDraft(for: classification, context: context)
    }

    private func assumptions(for classification: QuestionClassification, context: AnswerContext) -> [String] {
        guard context.retrievedSources.isEmpty,
              classification.questionType != .generalQuestion,
              let assumption = generationPolicy.noExternalSourceAssumption.nilIfEmptyAnswerGeneration else {
            return []
        }
        return [assumption]
    }

    private func caveats(for classification: QuestionClassification, context: AnswerContext) -> [String] {
        generationPolicy.caveats(for: classification.questionType)
    }

    private func mergedSources(_ contextSources: [AnswerSource], _ generatedSources: [AnswerSource]) -> [AnswerSource] {
        var seen: Set<AnswerSource> = []
        return (contextSources + generatedSources).filter { seen.insert($0).inserted }
    }

    private func mergedCaveats(_ primary: [String], _ secondary: [String]) -> [String] {
        var seen = Set<String>()
        return (primary + secondary).filter { caveat in
            let key = caveat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
    }
}
