import Foundation

enum RichAnswerBlockKind: String, CaseIterable, Sendable {
    case lead
    case paragraph
    case sourceCards
    case steps
    case checklist
    case comparison
    case metrics
    case code
    case timeline
    case memoryResults
    case clarification
    case warning
    case actions

    static let allowed = Set(allCases.map(\.rawValue))
}

enum RichAnswerActionKind: String, CaseIterable, Sendable {
    case copy
    case openSources = "open_sources"
    case regenerateWithWeb = "regenerate_with_web"

    static let allowed = Set(allCases.map(\.rawValue))
}

struct RichAnswerPayload: Codable, Hashable, Sendable {
    static let currentVersion = 1

    enum CodingKeys: String, CodingKey {
        case version
        case blocks
    }

    var version: Int
    var blocks: [RichAnswerBlockPayload]

    init(version: Int = Self.currentVersion, blocks: [RichAnswerBlockPayload]) {
        self.version = version
        self.blocks = blocks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        self.blocks = try container.decodeIfPresent([RichAnswerBlockPayload].self, forKey: .blocks) ?? []
    }
}

struct RichAnswerBlockPayload: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey {
        case type
        case title
        case subtitle
        case text
        case label
        case value
        case formula
        case language
        case code
        case severity
        case items
        case sourceIndexes
        case actions
    }

    var type: String
    var title: String?
    var subtitle: String?
    var text: String?
    var label: String?
    var value: String?
    var formula: String?
    var language: String?
    var code: String?
    var severity: String?
    var items: [RichAnswerItemPayload]
    var sourceIndexes: [Int]
    var actions: [RichAnswerActionPayload]

    init(
        type: String,
        title: String? = nil,
        subtitle: String? = nil,
        text: String? = nil,
        label: String? = nil,
        value: String? = nil,
        formula: String? = nil,
        language: String? = nil,
        code: String? = nil,
        severity: String? = nil,
        items: [RichAnswerItemPayload] = [],
        sourceIndexes: [Int] = [],
        actions: [RichAnswerActionPayload] = []
    ) {
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.text = text
        self.label = label
        self.value = value
        self.formula = formula
        self.language = language
        self.code = code
        self.severity = severity
        self.items = items
        self.sourceIndexes = sourceIndexes
        self.actions = actions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.value = try container.decodeIfPresent(String.self, forKey: .value)
        self.formula = try container.decodeIfPresent(String.self, forKey: .formula)
        self.language = try container.decodeIfPresent(String.self, forKey: .language)
        self.code = try container.decodeIfPresent(String.self, forKey: .code)
        self.severity = try container.decodeIfPresent(String.self, forKey: .severity)
        self.items = try container.decodeIfPresent([RichAnswerItemPayload].self, forKey: .items) ?? []
        self.sourceIndexes = try container.decodeIfPresent([Int].self, forKey: .sourceIndexes) ?? []
        self.actions = try container.decodeIfPresent([RichAnswerActionPayload].self, forKey: .actions) ?? []
    }
}

struct RichAnswerItemPayload: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey {
        case title
        case text
        case detail
        case value
        case isChecked
        case sourceIndex
    }

    var title: String?
    var text: String
    var detail: String?
    var value: String?
    var isChecked: Bool?
    var sourceIndex: Int?

    init(
        title: String? = nil,
        text: String,
        detail: String? = nil,
        value: String? = nil,
        isChecked: Bool? = nil,
        sourceIndex: Int? = nil
    ) {
        self.title = title
        self.text = text
        self.detail = detail
        self.value = value
        self.isChecked = isChecked
        self.sourceIndex = sourceIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.detail = try container.decodeIfPresent(String.self, forKey: .detail)
        self.value = try container.decodeIfPresent(String.self, forKey: .value)
        self.text = try container.decodeIfPresent(String.self, forKey: .text) ?? title ?? value ?? ""
        self.isChecked = try container.decodeIfPresent(Bool.self, forKey: .isChecked)
        self.sourceIndex = try container.decodeIfPresent(Int.self, forKey: .sourceIndex)
    }
}

struct RichAnswerActionPayload: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey {
        case kind
        case title
    }

    var kind: String
    var title: String

    init(kind: String, title: String) {
        self.kind = kind
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    }
}

struct RichAnswerValidator {
    var maxBlocks = 16
    var maxItemsPerBlock = 8
    var maxActionsPerBlock = 4
    var maxTextLength = 1_200
    var maxTitleLength = 160
    var maxCodeLength = 4_000
    var maxSourceIndexes = 6

    func validated(_ payload: RichAnswerPayload?, sources: [AnswerSource]) -> RichAnswerPayload? {
        guard let payload else { return nil }
        let normalizedVersion = payload.version <= 0 ? RichAnswerPayload.currentVersion : payload.version
        let blocks = payload.blocks.prefix(maxBlocks).compactMap { validated(block: $0, sources: sources) }
        guard !blocks.isEmpty else { return nil }
        return RichAnswerPayload(version: normalizedVersion, blocks: blocks)
    }

    private func validated(block: RichAnswerBlockPayload, sources: [AnswerSource]) -> RichAnswerBlockPayload? {
        guard RichAnswerBlockKind.allowed.contains(block.type) else { return nil }
        var copy = block
        copy.title = trimmed(block.title, limit: maxTitleLength)
        copy.subtitle = trimmed(block.subtitle, limit: maxTitleLength)
        copy.text = trimmed(block.text, limit: maxTextLength)
        copy.label = trimmed(block.label, limit: 80)
        copy.value = trimmed(block.value, limit: 140)
        copy.formula = trimmed(block.formula, limit: 240)
        copy.language = trimmed(block.language, limit: 40)
        copy.severity = trimmed(block.severity, limit: 40)
        copy.code = trimmed(block.code, limit: maxCodeLength, collapseWhitespace: false)
        copy.items = Array(block.items.prefix(maxItemsPerBlock)).compactMap { validated(item: $0, sources: sources) }
        copy.sourceIndexes = validSourceIndexes(block.sourceIndexes, sources: sources)
        copy.actions = Array(block.actions.prefix(maxActionsPerBlock)).compactMap(validated(action:))

        switch block.type {
        case RichAnswerBlockKind.lead.rawValue,
             RichAnswerBlockKind.paragraph.rawValue,
             RichAnswerBlockKind.clarification.rawValue,
             RichAnswerBlockKind.warning.rawValue:
            return copy.text?.isEmpty == false || copy.title?.isEmpty == false ? copy : nil
        case RichAnswerBlockKind.sourceCards.rawValue:
            return copy.sourceIndexes.isEmpty ? nil : copy
        case RichAnswerBlockKind.steps.rawValue,
             RichAnswerBlockKind.checklist.rawValue,
             RichAnswerBlockKind.comparison.rawValue,
             RichAnswerBlockKind.timeline.rawValue,
             RichAnswerBlockKind.memoryResults.rawValue:
            return copy.items.isEmpty ? nil : copy
        case RichAnswerBlockKind.metrics.rawValue:
            return copy.value?.isEmpty == false || copy.text?.isEmpty == false || !copy.items.isEmpty ? copy : nil
        case RichAnswerBlockKind.code.rawValue:
            return copy.code?.isEmpty == false ? copy : nil
        case RichAnswerBlockKind.actions.rawValue:
            return copy.actions.isEmpty ? nil : copy
        default:
            return nil
        }
    }

    private func validated(item: RichAnswerItemPayload, sources: [AnswerSource]) -> RichAnswerItemPayload? {
        var copy = item
        copy.title = trimmed(item.title, limit: maxTitleLength)
        copy.text = trimmed(item.text, limit: maxTextLength) ?? ""
        copy.detail = trimmed(item.detail, limit: maxTextLength)
        copy.value = trimmed(item.value, limit: 140)
        if let sourceIndex = item.sourceIndex, !isValidSourceIndex(sourceIndex, sources: sources) {
            copy.sourceIndex = nil
        }
        return copy.text.isEmpty && copy.title?.isEmpty != false ? nil : copy
    }

    private func validated(action: RichAnswerActionPayload) -> RichAnswerActionPayload? {
        guard RichAnswerActionKind.allowed.contains(action.kind) else { return nil }
        let title = trimmed(action.title, limit: 80) ?? ""
        return title.isEmpty ? nil : RichAnswerActionPayload(kind: action.kind, title: title)
    }

    private func validSourceIndexes(_ indexes: [Int], sources: [AnswerSource]) -> [Int] {
        var seen = Set<Int>()
        return indexes
            .prefix(maxSourceIndexes)
            .filter { isValidSourceIndex($0, sources: sources) && seen.insert($0).inserted }
    }

    private func isValidSourceIndex(_ index: Int, sources: [AnswerSource]) -> Bool {
        guard sources.indices.contains(index) else { return false }
        let source = sources[index]
        if source.type == .web {
            return source.webURL != nil
        }
        return true
    }

    private func trimmed(_ value: String?, limit: Int, collapseWhitespace: Bool = true) -> String? {
        guard let value else { return nil }
        let normalized = collapseWhitespace ? value.collapsedRichAnswerWhitespace : value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RichAnswerFallbackBuilder {
    static func payload(
        text rawText: String,
        format: CopilotAnswerFormat?,
        sources: [AnswerSource],
        confidence: Double? = nil,
        riskLevel: AnswerRiskLevel? = nil,
        tone: AnswerStyle? = nil,
        caveats: [String] = []
    ) -> RichAnswerPayload {
        let format = format ?? .paragraph
        let text = RichAnswerTextSanitizer.removingRenderedSourceURLs(from: rawText, sources: sources)
        var blocks: [RichAnswerBlockPayload] = []

        switch format {
        case .plainShort, .reminderConfirmation:
            blocks.append(lead(text: text, confidence: confidence, riskLevel: riskLevel, tone: tone))
        case .calculation:
            blocks.append(metric(from: text))
        case .steps:
            blocks.append(listBlock(kind: .steps, title: "Steps", text: text))
        case .bullets:
            blocks.append(listBlock(kind: .checklist, title: "Key points", text: text))
        case .newsWithSources:
            if !text.isEmpty {
                blocks.append(RichAnswerBlockPayload(type: RichAnswerBlockKind.paragraph.rawValue, text: text))
            }
            let sourceIndexes = validDisplaySourceIndexes(in: sources)
            if !sourceIndexes.isEmpty {
                blocks.append(RichAnswerBlockPayload(type: RichAnswerBlockKind.sourceCards.rawValue, title: "Sources", sourceIndexes: sourceIndexes))
            }
        case .memoryResults:
            let items = sources.enumerated().compactMap { index, source -> RichAnswerItemPayload? in
                guard source.type != .web else { return nil }
                return RichAnswerItemPayload(title: source.title, text: source.snippet ?? source.title, sourceIndex: index)
            }
            if !items.isEmpty {
                blocks.append(RichAnswerBlockPayload(type: RichAnswerBlockKind.memoryResults.rawValue, title: "Context", items: items))
            } else if !text.isEmpty {
                blocks.append(RichAnswerBlockPayload(type: RichAnswerBlockKind.paragraph.rawValue, text: text))
            }
        case .code:
            blocks.append(contentsOf: codeBlocks(from: text))
        case .errorState:
            blocks.append(RichAnswerBlockPayload(type: RichAnswerBlockKind.warning.rawValue, title: "Could not complete", text: text, severity: "error"))
        case .paragraph:
            blocks.append(RichAnswerBlockPayload(type: RichAnswerBlockKind.paragraph.rawValue, text: text))
        }

        let nonWebEvidence = evidenceItems(from: sources)
        if !nonWebEvidence.isEmpty, format != .memoryResults {
            blocks.append(RichAnswerBlockPayload(type: RichAnswerBlockKind.memoryResults.rawValue, title: "Evidence", items: nonWebEvidence))
        }
        for caveat in caveats where !caveat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(RichAnswerBlockPayload(type: RichAnswerBlockKind.warning.rawValue, text: caveat, severity: "caution"))
        }

        let validated = RichAnswerValidator().validated(RichAnswerPayload(blocks: blocks), sources: sources)
        return validated ?? RichAnswerPayload(blocks: [RichAnswerBlockPayload(type: RichAnswerBlockKind.paragraph.rawValue, text: text)])
    }

    private static func lead(text: String, confidence: Double?, riskLevel: AnswerRiskLevel?, tone: AnswerStyle?) -> RichAnswerBlockPayload {
        let subtitleParts = [
            tone.map { "Tone: \($0.rawValue.replacingOccurrences(of: "_", with: " "))" },
            riskLevel.map { "Risk: \($0.rawValue.replacingOccurrences(of: "_", with: " "))" },
            confidence.map { "Confidence: \(Int(($0 * 100).rounded()))%" }
        ]
        .compactMap { $0 }
        return RichAnswerBlockPayload(type: RichAnswerBlockKind.lead.rawValue, subtitle: subtitleParts.joined(separator: " - "), text: text)
    }

    private static func metric(from text: String) -> RichAnswerBlockPayload {
        let firstNumber = firstNumberLikeToken(in: text)
        return RichAnswerBlockPayload(
            type: RichAnswerBlockKind.metrics.rawValue,
            title: "Result",
            text: firstNumber == nil ? text : nil,
            label: firstNumber == nil ? nil : "Value",
            value: firstNumber ?? text
        )
    }

    private static func listBlock(kind: RichAnswerBlockKind, title: String, text: String) -> RichAnswerBlockPayload {
        let items = listItems(from: text)
        if items.isEmpty {
            return RichAnswerBlockPayload(type: RichAnswerBlockKind.paragraph.rawValue, text: text)
        }
        return RichAnswerBlockPayload(type: kind.rawValue, title: title, items: items)
    }

    private static func listItems(from text: String) -> [RichAnswerItemPayload] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .compactMap { rawLine -> RichAnswerItemPayload? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    return RichAnswerItemPayload(text: String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if let dot = line.firstIndex(of: "."),
                   Int(line[..<dot]) != nil {
                    let text = line[line.index(after: dot)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : RichAnswerItemPayload(text: text)
                }
                return nil
            }
    }

    private static func codeBlocks(from text: String) -> [RichAnswerBlockPayload] {
        var blocks: [RichAnswerBlockPayload] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var language: String?
        var isInCode = false

        func flushProse() {
            let prose = proseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !prose.isEmpty {
                blocks.append(RichAnswerBlockPayload(type: RichAnswerBlockKind.paragraph.rawValue, text: prose))
            }
            proseLines.removeAll()
        }

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if isInCode {
                    let code = codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    blocks.append(RichAnswerBlockPayload(type: RichAnswerBlockKind.code.rawValue, language: language, code: code))
                    codeLines.removeAll()
                    language = nil
                    isInCode = false
                } else {
                    flushProse()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyRichAnswer
                    isInCode = true
                }
                continue
            }
            if isInCode {
                codeLines.append(line)
            } else {
                proseLines.append(line)
            }
        }
        if isInCode {
            blocks.append(RichAnswerBlockPayload(type: RichAnswerBlockKind.code.rawValue, language: language, code: codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
        }
        flushProse()
        if blocks.isEmpty {
            blocks.append(RichAnswerBlockPayload(type: RichAnswerBlockKind.paragraph.rawValue, text: text))
        }
        return blocks
    }

    private static func evidenceItems(from sources: [AnswerSource]) -> [RichAnswerItemPayload] {
        sources.enumerated().compactMap { index, source -> RichAnswerItemPayload? in
            guard source.type != .web else { return nil }
            let text = source.snippet?.collapsedRichAnswerWhitespace.nilIfEmptyRichAnswer ?? source.title
            return RichAnswerItemPayload(title: source.title, text: text, sourceIndex: index)
        }
        .prefix(4)
        .map { $0 }
    }

    private static func validDisplaySourceIndexes(in sources: [AnswerSource]) -> [Int] {
        sources.indices.filter { index in
            let source = sources[index]
            return source.type == .web ? source.webURL != nil : true
        }
    }

    private static func firstNumberLikeToken(in text: String) -> String? {
        let pattern = #"[-+]?\d+(?:[.,]\d+)?(?:\s?[%$€£]| ?[A-Za-z]{1,6})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RichAnswerTextSanitizer {
    static func removingRenderedSourceURLs(from text: String, sources: [AnswerSource]) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for source in sources {
            guard let url = source.webURL else { continue }
            output = replacingMarkdownLinks(to: url, in: output, replacement: source.title)
            output = output.replacingOccurrences(of: url.absoluteString, with: source.title.nilIfEmptyRichAnswer ?? source.displayHost)
        }
        output = replacingRawURLsWithHosts(in: output)
        return collapseBlankLines(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingMarkdownLinks(to url: URL, in text: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]\n]{1,180})\]\((https?://[^\s\)]+)\)"#, options: [.caseInsensitive]) else {
            return text
        }
        let nsText = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed() where match.numberOfRanges > 2 {
            let linkURL = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\r.,;:)]}\"'"))
            guard linkURL == url.absoluteString else { continue }
            let label = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = label.isEmpty ? replacement : label
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: value)
            }
        }
        return result
    }

    private static func replacingRawURLsWithHosts(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s\)\]\}\"'>]+"#, options: [.caseInsensitive]) else {
            return text
        }
        let nsText = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed() {
            let raw = nsText.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\r.,;:)]}\"'"))
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let range = Range(match.range, in: result) else {
                continue
            }
            let host = url.host(percentEncoded: false) ?? url.host ?? raw
            result.replaceSubrange(range, with: host)
        }
        return result
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
}

extension AnswerSource {
    var webURL: URL? {
        guard type == .web,
              let rawReference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawReference),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    var displayHost: String {
        if let webURL {
            return webURL.host(percentEncoded: false) ?? webURL.host ?? webURL.absoluteString
        }
        return reference?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyRichAnswer ?? type.rawValue
    }
}

extension String {
    var collapsedRichAnswerWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmptyRichAnswer: String? {
        isEmpty ? nil : self
    }
}
