import Foundation

struct QuestionAnswerPromptField: Codable, Hashable, Sendable {
    var label: String
    var value: QuestionAnswerPromptValue
}

enum QuestionAnswerPromptValue: String, Codable, Hashable, Sendable {
    case userName
    case userAliases
    case userRole
    case meetingTypeDisplayName
    case dominantLanguage
    case recentTranscript
    case candidateRawText
    case preferredStyle
    case preferredLanguages
}

struct QuestionAnswerPromptPolicy: Codable, Hashable, Sendable {
    var classificationIntroLines: [String]
    var classificationFields: [QuestionAnswerPromptField]
    var classificationSchemaHeading: String
    var classificationSchema: String
    var answerIntroLines: [String]
    var answerInstructions: [String]
    var answerUserContextHeading: String
    var answerUserContextFields: [QuestionAnswerPromptField]
    var answerQuestionHeading: String
    var answerClassificationHeading: String
    var answerTranscriptHeading: String
    var answerRAGHeading: String
    var answerSourcesHeading: String
    var answerReturnInstructions: [String]
    var classificationSummaryTemplate: String
    var sourceItemTemplate: String
    var listItemTemplate: String
    var emptyValue: String
    var automaticValue: String

    init(
        classificationIntroLines: [String] = [],
        classificationFields: [QuestionAnswerPromptField] = [],
        classificationSchemaHeading: String = "",
        classificationSchema: String = "",
        answerIntroLines: [String] = [],
        answerInstructions: [String] = [],
        answerUserContextHeading: String = "",
        answerUserContextFields: [QuestionAnswerPromptField] = [],
        answerQuestionHeading: String = "",
        answerClassificationHeading: String = "",
        answerTranscriptHeading: String = "",
        answerRAGHeading: String = "",
        answerSourcesHeading: String = "",
        answerReturnInstructions: [String] = [],
        classificationSummaryTemplate: String = "",
        sourceItemTemplate: String = "",
        listItemTemplate: String = "",
        emptyValue: String = "",
        automaticValue: String = ""
    ) {
        self.classificationIntroLines = classificationIntroLines
        self.classificationFields = classificationFields
        self.classificationSchemaHeading = classificationSchemaHeading
        self.classificationSchema = classificationSchema
        self.answerIntroLines = answerIntroLines
        self.answerInstructions = answerInstructions
        self.answerUserContextHeading = answerUserContextHeading
        self.answerUserContextFields = answerUserContextFields
        self.answerQuestionHeading = answerQuestionHeading
        self.answerClassificationHeading = answerClassificationHeading
        self.answerTranscriptHeading = answerTranscriptHeading
        self.answerRAGHeading = answerRAGHeading
        self.answerSourcesHeading = answerSourcesHeading
        self.answerReturnInstructions = answerReturnInstructions
        self.classificationSummaryTemplate = classificationSummaryTemplate
        self.sourceItemTemplate = sourceItemTemplate
        self.listItemTemplate = listItemTemplate
        self.emptyValue = emptyValue
        self.automaticValue = automaticValue
    }

    private enum CodingKeys: String, CodingKey {
        case classificationIntroLines
        case classificationFields
        case classificationSchemaHeading
        case classificationSchema
        case answerIntroLines
        case answerInstructions
        case answerUserContextHeading
        case answerUserContextFields
        case answerQuestionHeading
        case answerClassificationHeading
        case answerTranscriptHeading
        case answerRAGHeading
        case answerSourcesHeading
        case answerReturnInstructions
        case classificationSummaryTemplate
        case sourceItemTemplate
        case listItemTemplate
        case emptyValue
        case automaticValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            classificationIntroLines: try container.decodeIfPresent([String].self, forKey: .classificationIntroLines) ?? [],
            classificationFields: try container.decodeIfPresent([QuestionAnswerPromptField].self, forKey: .classificationFields) ?? [],
            classificationSchemaHeading: try container.decodeIfPresent(String.self, forKey: .classificationSchemaHeading) ?? "",
            classificationSchema: try container.decodeIfPresent(String.self, forKey: .classificationSchema) ?? "",
            answerIntroLines: try container.decodeIfPresent([String].self, forKey: .answerIntroLines) ?? [],
            answerInstructions: try container.decodeIfPresent([String].self, forKey: .answerInstructions) ?? [],
            answerUserContextHeading: try container.decodeIfPresent(String.self, forKey: .answerUserContextHeading) ?? "",
            answerUserContextFields: try container.decodeIfPresent([QuestionAnswerPromptField].self, forKey: .answerUserContextFields) ?? [],
            answerQuestionHeading: try container.decodeIfPresent(String.self, forKey: .answerQuestionHeading) ?? "",
            answerClassificationHeading: try container.decodeIfPresent(String.self, forKey: .answerClassificationHeading) ?? "",
            answerTranscriptHeading: try container.decodeIfPresent(String.self, forKey: .answerTranscriptHeading) ?? "",
            answerRAGHeading: try container.decodeIfPresent(String.self, forKey: .answerRAGHeading) ?? "",
            answerSourcesHeading: try container.decodeIfPresent(String.self, forKey: .answerSourcesHeading) ?? "",
            answerReturnInstructions: try container.decodeIfPresent([String].self, forKey: .answerReturnInstructions) ?? [],
            classificationSummaryTemplate: try container.decodeIfPresent(String.self, forKey: .classificationSummaryTemplate) ?? "",
            sourceItemTemplate: try container.decodeIfPresent(String.self, forKey: .sourceItemTemplate) ?? "",
            listItemTemplate: try container.decodeIfPresent(String.self, forKey: .listItemTemplate) ?? "",
            emptyValue: try container.decodeIfPresent(String.self, forKey: .emptyValue) ?? "",
            automaticValue: try container.decodeIfPresent(String.self, forKey: .automaticValue) ?? ""
        )
    }

    static let `default` = QuestionAnswerPromptPolicyStore.current
}

enum QuestionAnswerPromptPolicyStore {
    static let current: QuestionAnswerPromptPolicy = load()

    private static func load() -> QuestionAnswerPromptPolicy {
        let decoder = JSONDecoder()
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let policy = try? decoder.decode(QuestionAnswerPromptPolicy.self, from: data) else {
                continue
            }
            return policy.normalized()
        }
        return fallbackPolicy()
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let bundles = [Bundle.main, Bundle(for: QuestionAnswerPromptPolicyBundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "question-answer-prompt-policy",
                withExtension: "json",
                subdirectory: "CopilotIntentPolicy"
            ) {
                urls.append(url)
            }
        }
        urls.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/CopilotIntentPolicy/question-answer-prompt-policy.json")
        )
        return urls
    }

    private static func fallbackPolicy() -> QuestionAnswerPromptPolicy {
        QuestionAnswerPromptPolicy(
            classificationIntroLines: [],
            classificationFields: [],
            classificationSchemaHeading: "",
            classificationSchema: "",
            answerIntroLines: [],
            answerInstructions: [],
            answerUserContextHeading: "",
            answerUserContextFields: [],
            answerQuestionHeading: "",
            answerClassificationHeading: "",
            answerTranscriptHeading: "",
            answerRAGHeading: "",
            answerSourcesHeading: "",
            answerReturnInstructions: [],
            classificationSummaryTemplate: "",
            sourceItemTemplate: "",
            listItemTemplate: "",
            emptyValue: "",
            automaticValue: ""
        )
    }
}

private final class QuestionAnswerPromptPolicyBundleMarker {}

private extension QuestionAnswerPromptPolicy {
    func normalized() -> QuestionAnswerPromptPolicy {
        QuestionAnswerPromptPolicy(
            classificationIntroLines: classificationIntroLines.trimmedPromptPolicyLines(),
            classificationFields: classificationFields.normalizedPromptFields(),
            classificationSchemaHeading: classificationSchemaHeading.trimmedPromptPolicyLine,
            classificationSchema: classificationSchema.trimmedPromptPolicyLine,
            answerIntroLines: answerIntroLines.trimmedPromptPolicyLines(),
            answerInstructions: answerInstructions.trimmedPromptPolicyLines(),
            answerUserContextHeading: answerUserContextHeading.trimmedPromptPolicyLine,
            answerUserContextFields: answerUserContextFields.normalizedPromptFields(),
            answerQuestionHeading: answerQuestionHeading.trimmedPromptPolicyLine,
            answerClassificationHeading: answerClassificationHeading.trimmedPromptPolicyLine,
            answerTranscriptHeading: answerTranscriptHeading.trimmedPromptPolicyLine,
            answerRAGHeading: answerRAGHeading.trimmedPromptPolicyLine,
            answerSourcesHeading: answerSourcesHeading.trimmedPromptPolicyLine,
            answerReturnInstructions: answerReturnInstructions.trimmedPromptPolicyLines(),
            classificationSummaryTemplate: classificationSummaryTemplate.trimmedPromptPolicyLine,
            sourceItemTemplate: sourceItemTemplate.trimmedPromptPolicyLine,
            listItemTemplate: listItemTemplate.trimmedPromptPolicyLine,
            emptyValue: emptyValue.trimmedPromptPolicyLine,
            automaticValue: automaticValue.trimmedPromptPolicyLine
        )
    }
}

private extension Array where Element == QuestionAnswerPromptField {
    func normalizedPromptFields() -> [QuestionAnswerPromptField] {
        map { field in
            QuestionAnswerPromptField(
                label: field.label.trimmedPromptPolicyLine,
                value: field.value
            )
        }
        .filter { !$0.label.isEmpty }
    }
}

private extension Array where Element == String {
    func trimmedPromptPolicyLines() -> [String] {
        map(\.trimmedPromptPolicyLine).filter { !$0.isEmpty }
    }
}

private extension String {
    var trimmedPromptPolicyLine: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct QuestionAnswerPromptBuilder {
    var policy: QuestionAnswerPromptPolicy = .default

    func classificationPrompt(candidate: QuestionCandidate, context: TranscriptContext, profile: UserMeetingProfile) -> String {
        let values = promptValues(candidate: candidate, context: context, profile: profile)
        var parts = policy.classificationIntroLines
        parts.append(contentsOf: renderedFields(policy.classificationFields, values: values))
        parts.append(policy.classificationSchemaHeading)
        parts.append(policy.classificationSchema)
        return parts.promptDocument()
    }

    func answerPrompt(
        question: QuestionCandidate,
        classification: QuestionClassification,
        context: AnswerContext,
        profile: UserMeetingProfile
    ) -> String {
        let values = promptValues(question: question, classification: classification, context: context, profile: profile)
        var parts = policy.answerIntroLines
        parts.append(contentsOf: renderedList(policy.answerInstructions, values: values))
        parts.append(section(policy.answerUserContextHeading, renderedFields(policy.answerUserContextFields, values: values).joined(separator: "\n")))
        parts.append(section(policy.answerQuestionHeading, question.rawText))
        parts.append(section(policy.answerClassificationHeading, renderedClassificationSummary(classification, values: values)))
        parts.append(section(policy.answerTranscriptHeading, context.transcriptWindow))
        parts.append(section(policy.answerRAGHeading, context.ragContext))
        parts.append(section(policy.answerSourcesHeading, renderedSources(context.retrievedSources, values: values)))
        parts.append(contentsOf: renderedList(policy.answerReturnInstructions, values: values))
        return parts.promptDocument()
    }

    private func promptValues(candidate: QuestionCandidate, context: TranscriptContext, profile: UserMeetingProfile) -> [String: String] {
        [
            "userName": profile.userName,
            "userAliases": profile.userAliases.joined(separator: ", "),
            "userRole": profile.userRole,
            "meetingTypeDisplayName": profile.meetingType.displayName,
            "dominantLanguage": context.dominantLanguage ?? policy.automaticValue,
            "recentTranscript": context.recentTranscript,
            "candidateRawText": candidate.rawText,
            "preferredStyle": profile.preferredStyle.rawValue,
            "preferredLanguages": profile.preferredLanguages.joined(separator: ", ")
        ]
    }

    private func promptValues(
        question: QuestionCandidate,
        classification: QuestionClassification,
        context: AnswerContext,
        profile: UserMeetingProfile
    ) -> [String: String] {
        var values = promptValues(
            candidate: question,
            context: TranscriptContext(
                recentTranscript: context.transcriptWindow,
                mediumTranscript: context.transcriptWindow,
                completeTranscript: context.completeTranscript,
                dominantLanguage: context.languageCode,
                currentSegment: nil
            ),
            profile: profile
        )
        values["questionRawText"] = question.rawText
        values["questionType"] = classification.questionType.rawValue
        values["priority"] = classification.priority.rawValue
        values["expectedAnswerStyle"] = classification.expectedAnswerStyle.rawValue
        return values
    }

    private func renderedFields(_ fields: [QuestionAnswerPromptField], values: [String: String]) -> [String] {
        fields.map { field in
            "\(field.label): \(value(for: field.value, values: values))"
        }
    }

    private func value(for value: QuestionAnswerPromptValue, values: [String: String]) -> String {
        let rendered = values[value.rawValue]?.trimmedPromptPolicyLine ?? ""
        return rendered.isEmpty ? policy.emptyValue : rendered
    }

    private func renderedList(_ lines: [String], values: [String: String]) -> [String] {
        lines.map { interpolated(policy.listItemTemplate, values: ["item": interpolated($0, values: values)]) }
    }

    private func renderedClassificationSummary(_ classification: QuestionClassification, values: [String: String]) -> String {
        let rendered = interpolated(policy.classificationSummaryTemplate, values: values)
        guard !rendered.isEmpty else {
            return [classification.questionType.rawValue, classification.priority.rawValue, classification.expectedAnswerStyle.rawValue]
                .joined(separator: " ")
        }
        return rendered
    }

    private func renderedSources(_ sources: [AnswerSource], values: [String: String]) -> String {
        sources
            .map { source in
                interpolated(
                    policy.sourceItemTemplate,
                    values: values.merging([
                        "title": source.title,
                        "snippet": source.snippet ?? ""
                    ]) { current, _ in current }
                )
            }
            .filter { !$0.trimmedPromptPolicyLine.isEmpty }
            .joined(separator: "\n")
    }

    private func section(_ heading: String, _ body: String) -> String {
        let trimmedHeading = heading.trimmedPromptPolicyLine
        let trimmedBody = body.trimmedPromptPolicyLine
        guard !trimmedHeading.isEmpty else { return trimmedBody }
        return [trimmedHeading, trimmedBody].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func interpolated(_ template: String, values: [String: String]) -> String {
        values.reduce(template) { rendered, entry in
            rendered.replacingOccurrences(of: "{\(entry.key)}", with: entry.value)
        }
    }
}

private extension Array where Element == String {
    func promptDocument() -> String {
        map(\.trimmedPromptPolicyLine)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
