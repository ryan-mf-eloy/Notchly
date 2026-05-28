import Foundation

@MainActor
protocol MeetingAnswerProvider {
    func generateAnswer(
        question: QuestionCandidate,
        classification: QuestionClassification,
        context: AnswerContext,
        options: AnswerGenerationOptions
    ) async throws -> AsyncThrowingStream<PartialAnswer, Error>
}

@MainActor
struct AnswerGenerationService: MeetingAnswerProvider {
    var provider: any AIProvider
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
                do {
                    let generated = try await provider.generateAnswer(
                        context: context,
                        question: question.rawText,
                        options: AnswerOptions(
                            maxSentences: options.maxSentences,
                            allowCommitments: options.allowCommitments,
                            enableWebSearch: options.enableWebSearch && !options.localOnlyMode
                        )
                    )
                    let formattedText = AnswerPresentationFormatter.normalizedGeneratedText(
                        generated.text,
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
                        usedSources: mergedSources(context.retrievedSources, generated.sources),
                        assumptions: assumptions(for: classification, context: context),
                        caveats: caveats(for: classification, context: context),
                        latencyMs: latency,
                        expandedAnswer: formattedText,
                        suggestedTone: classification.expectedAnswerStyle,
                        shouldAskClarification: classification.expectedAnswerStyle == .askForClarification,
                        clarifyingQuestion: classification.expectedAnswerStyle == .askForClarification ? "What detail should we confirm before answering?" : nil,
                        language: question.language ?? context.languageCode,
                        provider: generated.provider,
                        usedCloud: generated.usedCloud,
                        usedRAG: generated.usedRAG
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

enum AnswerPresentationFormat: String, Sendable, Hashable {
    case plainText
    case bullets
    case numberedSteps
    case code
    case command
    case structuredData
    case mixed
}

struct AnswerPresentationDecision: Sendable, Hashable {
    var format: AnswerPresentationFormat
    var preservesCodeBlocks: Bool
    var reason: String
}

enum AnswerPresentationFormatter {
    private struct FencedBlock: Hashable {
        var language: String?
        var code: String

        var markdown: String {
            let header = "```" + (language ?? "")
            return [header, code, "```"].joined(separator: "\n")
        }
    }

    private enum Segment: Hashable {
        case text(String)
        case fenced(FencedBlock)
    }

    static func normalizedGeneratedText(
        _ text: String,
        question: QuestionCandidate,
        classification: QuestionClassification
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("```") else { return trimmed }

        let decision = presentationDecision(for: question, classification: classification, generatedText: trimmed)
        let segments = parseSegments(trimmed)
        let outsideText = segments.compactMap { segment -> String? in
            if case let .text(value) = segment { return value }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        let rendered = segments.map { segment -> String in
            switch segment {
            case .text(let value):
                return value
            case .fenced(let block):
                if shouldPreserve(block: block, question: question.rawText, decision: decision) {
                    return block.markdown
                }

                let blockText = block.code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !blockText.isEmpty else { return "" }
                if isDuplicate(blockText, in: outsideText) {
                    return ""
                }
                return blockText
            }
        }
        .joined(separator: "\n")

        return collapseBlankLines(rendered)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shortAnswer(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("```") {
            return trimmed
        }
        let sentences = trimmed.split(whereSeparator: { ".!?".contains($0) }).map(String.init)
        let firstTwo = sentences.prefix(2).joined(separator: ". ")
        if firstTwo.isEmpty { return trimmed }
        return firstTwo.hasSuffix(".") ? firstTwo : firstTwo + "."
    }

    static func presentationDecision(
        for question: QuestionCandidate,
        classification: QuestionClassification,
        generatedText: String
    ) -> AnswerPresentationDecision {
        let questionText = normalized(question.rawText)
        let generated = normalized(generatedText)

        if asksForCommand(questionText) || generated.contains("```shell") || generated.contains("```bash") {
            return AnswerPresentationDecision(format: .command, preservesCodeBlocks: true, reason: "command_or_shell_request")
        }
        if asksForStructuredData(questionText) || generated.contains("```json") || generated.contains("```yaml") {
            return AnswerPresentationDecision(format: .structuredData, preservesCodeBlocks: true, reason: "structured_data_request")
        }
        if asksForCode(questionText) {
            return AnswerPresentationDecision(format: .code, preservesCodeBlocks: true, reason: "code_request")
        }
        if asksForProcedure(questionText) {
            return AnswerPresentationDecision(format: .numberedSteps, preservesCodeBlocks: false, reason: "procedure_request")
        }
        if asksForComparison(questionText) || classification.questionType == .technicalDecision || classification.questionType == .riskAssessment {
            return AnswerPresentationDecision(format: .bullets, preservesCodeBlocks: false, reason: "comparison_or_decision")
        }
        if isShortFactQuestion(questionText, classification: classification) {
            return AnswerPresentationDecision(format: .plainText, preservesCodeBlocks: false, reason: "short_fact")
        }
        return AnswerPresentationDecision(format: .mixed, preservesCodeBlocks: false, reason: "default_meeting_answer")
    }

    private static func parseSegments(_ text: String) -> [Segment] {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedText.components(separatedBy: "\n")
        var segments: [Segment] = []
        var textLines: [String] = []
        var codeLines: [String] = []
        var language: String?
        var isInCodeBlock = false

        func flushText() {
            guard !textLines.isEmpty else { return }
            segments.append(.text(textLines.joined(separator: "\n")))
            textLines.removeAll()
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if isInCodeBlock {
                    segments.append(.fenced(FencedBlock(
                        language: language,
                        code: codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    )))
                    codeLines.removeAll()
                    language = nil
                    isInCodeBlock = false
                } else {
                    flushText()
                    let rawLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    language = rawLanguage.isEmpty ? nil : rawLanguage
                    isInCodeBlock = true
                }
                continue
            }

            if isInCodeBlock {
                codeLines.append(rawLine)
            } else {
                textLines.append(rawLine)
            }
        }

        if isInCodeBlock {
            segments.append(.fenced(FencedBlock(
                language: language,
                code: codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            )))
        }
        flushText()
        return segments
    }

    private static func shouldPreserve(
        block: FencedBlock,
        question: String,
        decision: AnswerPresentationDecision
    ) -> Bool {
        let language = CodeLanguageRegistry.normalizedAlias(block.language)
        let code = block.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return false }
        if plainTextLanguages.contains(language), !looksLikeCode(code), !looksLikeCommand(code), !looksLikeStructuredData(code) {
            return false
        }

        let normalizedQuestion = normalized(question)
        if decision.preservesCodeBlocks {
            switch decision.format {
            case .command:
                return looksLikeCommand(code) || language == "shell" || language == "bash" || language == "zsh" || language == "sh"
            case .structuredData:
                return looksLikeStructuredData(code) || structuredDataLanguages.contains(language)
            case .code:
                return looksLikeCode(code) || codeLanguages.contains(language)
            default:
                return false
            }
        }

        return (asksForCode(normalizedQuestion) || asksForCommand(normalizedQuestion) || asksForStructuredData(normalizedQuestion))
            && (looksLikeCode(code) || looksLikeCommand(code) || looksLikeStructuredData(code))
    }

    private static func isDuplicate(_ blockText: String, in outsideText: String) -> Bool {
        let normalizedBlock = normalized(blockText)
        let normalizedOutside = normalized(outsideText)
        guard !normalizedBlock.isEmpty, !normalizedOutside.isEmpty else { return false }
        if normalizedOutside.contains(normalizedBlock) { return true }
        let blockTokens = Set(normalizedBlock.split(separator: " ").map(String.init))
        guard !blockTokens.isEmpty else { return false }
        let outsideTokens = Set(normalizedOutside.split(separator: " ").map(String.init))
        let overlap = blockTokens.filter { outsideTokens.contains($0) }.count
        return Double(overlap) / Double(blockTokens.count) >= 0.85
    }

    private static func collapseBlankLines(_ text: String) -> String {
        var output: [String] = []
        var blankCount = 0
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blankCount += 1
                if blankCount <= 1 {
                    output.append("")
                }
            } else {
                blankCount = 0
                output.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        return output.joined(separator: "\n")
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[^\\p{L}\\p{N}_/#.\\-+]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }

    private static func asksForCode(_ question: String) -> Bool {
        containsAny(question, [
            "codigo", "code", "snippet", "funcao", "function", "algoritmo", "algorithm",
            "implementar", "implement", "implementation", "classe", "class", "component",
            "python", "swift", "javascript", "typescript", "java", "kotlin", "rust", "go ",
            "sql", "query", "regex", "programa", "script", "コード", "実装", "関数",
            "codigo de exemplo", "exemplo de codigo"
        ])
    }

    private static func asksForCommand(_ question: String) -> Bool {
        containsAny(question, [
            "comando", "command", "terminal", "shell", "bash", "zsh", "cli", "curl",
            "docker", "kubectl", "npm", "yarn", "pnpm", "git ", "コマンド"
        ])
    }

    private static func asksForStructuredData(_ question: String) -> Bool {
        containsAny(question, [
            "json", "yaml", "yml", "toml", "env", "config", "schema", "payload",
            "request body", "response body", "estrutura de dados", "設定"
        ])
    }

    private static func asksForProcedure(_ question: String) -> Bool {
        containsAny(question, [
            "como faco", "como fazer", "como implementar", "passos", "steps", "step by step",
            "how do i", "how to", "como podemos", "como eu", "procedimento"
        ])
    }

    private static func asksForComparison(_ question: String) -> Bool {
        containsAny(question, [
            "comparar", "compare", "versus", " vs ", "trade-off", "tradeoff", "opcoes",
            "options", "pros and cons", "prós e contras", "riscos", "risks", "melhor escolha"
        ])
    }

    private static func isShortFactQuestion(_ question: String, classification: QuestionClassification) -> Bool {
        guard !asksForCode(question), !asksForCommand(question), !asksForStructuredData(question) else { return false }
        if classification.questionType == .generalQuestion || classification.questionType == .clarification {
            return containsAny(question, [
                "qual e", "qual eh", "qual o", "qual a", "quem e", "onde fica", "quando foi",
                "what is", "what's", "who is", "where is", "when is", "which is",
                "cual es", "quien es", "donde esta", "que es", "como se llama",
                "capital", "nome da capital", "name of the capital"
            ])
        }
        return false
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(of: #"(?m)^\s*(func|def|class|struct|enum|interface|import|from|let|var|const|return|if|for|while|switch|case)\b"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"[{}();]|=>|->|</?[A-Za-z][^>]*>"#, options: .regularExpression) != nil,
           trimmed.split(separator: "\n").count > 1 || trimmed.contains("=") {
            return true
        }
        return false
    }

    private static func looksLikeCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"(?m)^\s*(\$|%|git|npm|yarn|pnpm|curl|docker|kubectl|brew|swift|xcodebuild|python3?|node|uv|pip)\b"#, options: .regularExpression) != nil
    }

    private static func looksLikeStructuredData(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return false }
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            return true
        }
        return trimmed.range(of: #"(?m)^\s*["A-Za-z0-9_.-]+\s*[:=]\s*.+"#, options: .regularExpression) != nil
            && trimmed.split(separator: "\n").count > 1
    }

    private static let plainTextLanguages: Set<String> = ["", "text", "plain", "plaintext", "txt", "markdown", "md"]
    private static let structuredDataLanguages: Set<String> = ["json", "yaml", "yml", "toml", "env", "dotenv", "properties", "ini"]
    private static let codeLanguages: Set<String> = [
        "swift", "python", "py", "javascript", "js", "typescript", "ts", "tsx", "jsx",
        "java", "kotlin", "go", "rust", "ruby", "php", "dart", "c", "cpp", "csharp",
        "sql", "html", "css", "shell", "bash", "zsh", "sh", "diff", "log", "http"
    ]
}
