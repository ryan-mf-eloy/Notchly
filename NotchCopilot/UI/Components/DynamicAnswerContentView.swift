import AppKit
import SwiftUI

enum RichAnswerBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(index: Int, text: String)
    case code(language: String?, code: String)
}

enum SyntaxHighlightRole: String, Hashable, Sendable {
    case plain
    case keyword
    case type
    case string
    case number
    case comment
    case symbol
    case attribute
    case tag
    case inserted
    case deleted
    case metadata
    case warning
    case error
    case prompt

    var color: Color {
        switch self {
        case .plain: Color.white.opacity(0.80)
        case .keyword: Color(red: 0.58, green: 0.74, blue: 1.0)
        case .type: Color(red: 0.55, green: 0.84, blue: 0.72)
        case .string: Color(red: 0.96, green: 0.73, blue: 0.50)
        case .number: Color(red: 0.82, green: 0.72, blue: 1.0)
        case .comment: Color.white.opacity(0.36)
        case .symbol: Color.white.opacity(0.54)
        case .attribute: Color(red: 0.78, green: 0.84, blue: 0.92)
        case .tag: Color(red: 0.64, green: 0.82, blue: 0.94)
        case .inserted: Color(red: 0.56, green: 0.86, blue: 0.62)
        case .deleted: Color(red: 1.0, green: 0.56, blue: 0.56)
        case .metadata: Color.white.opacity(0.46)
        case .warning: Color(red: 1.0, green: 0.76, blue: 0.34)
        case .error: Color(red: 1.0, green: 0.46, blue: 0.46)
        case .prompt: Color(red: 0.62, green: 0.82, blue: 1.0)
        }
    }
}

struct SyntaxHighlightToken: Hashable, Sendable {
    var text: String
    var role: SyntaxHighlightRole
}

struct CodeBlockCommentPair: Hashable, Sendable {
    var opening: String
    var closing: String
}

enum CodeLanguageFamily: String, Hashable, Sendable {
    case cLike
    case scripting
    case shell
    case markup
    case stylesheet
    case data
    case sql
    case diff
    case log
    case markdown
    case http
    case plain
}

struct CodeLanguageDefinition: Hashable, Sendable {
    var id: String
    var displayName: String
    var aliases: Set<String>
    var family: CodeLanguageFamily
    var keywords: Set<String>
    var types: Set<String>
    var lineCommentPrefixes: [String]
    var blockCommentPairs: [CodeBlockCommentPair]
    var isCaseInsensitive: Bool

    init(
        id: String,
        displayName: String,
        aliases: Set<String>,
        family: CodeLanguageFamily,
        keywords: Set<String> = [],
        types: Set<String> = [],
        lineCommentPrefixes: [String] = [],
        blockCommentPairs: [(String, String)] = [],
        isCaseInsensitive: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases.union([id, displayName.lowercased()])
        self.family = family
        self.keywords = isCaseInsensitive ? Set(keywords.map { $0.lowercased() }) : keywords
        self.types = isCaseInsensitive ? Set(types.map { $0.lowercased() }) : types
        self.lineCommentPrefixes = lineCommentPrefixes
        self.blockCommentPairs = blockCommentPairs.map { CodeBlockCommentPair(opening: $0.0, closing: $0.1) }
        self.isCaseInsensitive = isCaseInsensitive
    }
}

enum CodeLanguageRegistry {
    static func definition(for language: String?, code: String = "") -> CodeLanguageDefinition {
        let alias = normalizedAlias(language)
        if let definition = definitions.first(where: { $0.aliases.contains(alias) }) {
            return definition
        }
        if let inferred = inferDefinition(from: code) {
            return inferred
        }
        return plainTextDefinition(displayName: alias.isEmpty ? "Text" : title(for: alias))
    }

    static func normalizedAlias(_ language: String?) -> String {
        guard let language else { return "" }
        let token = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == ":" })
            .first
            .map(String.init) ?? ""
        return token
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".#"))
    }

    private static func inferDefinition(from code: String) -> CodeLanguageDefinition? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if trimmed.hasPrefix("diff --git") || trimmed.hasPrefix("@@") || lower.hasPrefix("index ") {
            return definition(for: "diff")
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return definition(for: "json")
        }
        if lower.hasPrefix("select ") || lower.hasPrefix("with ") || lower.hasPrefix("insert ") || lower.hasPrefix("update ") {
            return definition(for: "sql")
        }
        if lower.hasPrefix("http/") || lower.hasPrefix("get ") || lower.hasPrefix("post ") || lower.hasPrefix("put ") {
            return definition(for: "http")
        }
        if trimmed.hasPrefix("<") {
            return definition(for: "html")
        }
        if trimmed.contains("="), !trimmed.contains("{") {
            return definition(for: "env")
        }
        return nil
    }

    private static func plainTextDefinition(displayName: String) -> CodeLanguageDefinition {
        CodeLanguageDefinition(
            id: "text",
            displayName: displayName,
            aliases: ["text", "plain", "plaintext", "txt"],
            family: .plain
        )
    }

    private static func title(for alias: String) -> String {
        alias
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static let definitions: [CodeLanguageDefinition] = [
        CodeLanguageDefinition(
            id: "swift",
            displayName: "Swift",
            aliases: ["swiftui"],
            family: .cLike,
            keywords: ["actor", "as", "associatedtype", "async", "await", "case", "catch", "class", "defer", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import", "in", "init", "inout", "let", "nil", "private", "protocol", "public", "return", "self", "static", "struct", "switch", "throw", "throws", "true", "try", "var", "where", "while"],
            types: ["Any", "Array", "Bool", "Codable", "Date", "Dictionary", "Double", "Error", "Int", "Result", "Sendable", "Set", "String", "UUID", "View"],
            lineCommentPrefixes: ["//"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "objective-c",
            displayName: "Objective-C",
            aliases: ["objc", "objectivec", "m", "mm"],
            family: .cLike,
            keywords: ["@autoreleasepool", "@class", "@end", "@implementation", "@interface", "@property", "@protocol", "@selector", "BOOL", "NO", "NULL", "YES", "break", "case", "const", "continue", "else", "enum", "for", "if", "import", "return", "self", "static", "struct", "switch", "void", "while"],
            types: ["NSArray", "NSDictionary", "NSError", "NSObject", "NSString", "NSURL"],
            lineCommentPrefixes: ["//"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "c",
            displayName: "C",
            aliases: ["h"],
            family: .cLike,
            keywords: ["break", "case", "char", "const", "continue", "double", "else", "enum", "float", "for", "if", "include", "int", "long", "return", "short", "sizeof", "static", "struct", "switch", "typedef", "void", "while"],
            types: ["FILE", "size_t", "uint32_t", "uint64_t"],
            lineCommentPrefixes: ["//"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "cpp",
            displayName: "C++",
            aliases: ["c++", "cc", "cxx", "hpp", "hxx"],
            family: .cLike,
            keywords: ["auto", "break", "case", "class", "const", "constexpr", "continue", "else", "enum", "for", "if", "include", "namespace", "new", "private", "public", "return", "static", "struct", "switch", "template", "typename", "using", "virtual", "void", "while"],
            types: ["bool", "double", "float", "int", "size_t", "std", "string", "vector"],
            lineCommentPrefixes: ["//"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "csharp",
            displayName: "C#",
            aliases: ["c#", "cs"],
            family: .cLike,
            keywords: ["async", "await", "break", "case", "catch", "class", "const", "else", "enum", "false", "for", "if", "interface", "namespace", "new", "private", "public", "return", "static", "switch", "this", "throw", "true", "try", "using", "var", "void", "while"],
            types: ["Action", "Dictionary", "Guid", "IEnumerable", "List", "Task", "string"],
            lineCommentPrefixes: ["//"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "java",
            displayName: "Java",
            aliases: [],
            family: .cLike,
            keywords: ["abstract", "break", "case", "catch", "class", "else", "enum", "extends", "final", "for", "if", "implements", "import", "interface", "new", "null", "private", "protected", "public", "return", "static", "switch", "this", "throw", "throws", "try", "void", "while"],
            types: ["Boolean", "Integer", "List", "Map", "Optional", "String"],
            lineCommentPrefixes: ["//"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "kotlin",
            displayName: "Kotlin",
            aliases: ["kt", "kts"],
            family: .cLike,
            keywords: ["as", "break", "by", "catch", "class", "data", "else", "false", "for", "fun", "if", "import", "in", "interface", "is", "null", "object", "package", "return", "sealed", "throw", "true", "try", "val", "var", "when", "while"],
            types: ["Boolean", "Int", "List", "Map", "String"],
            lineCommentPrefixes: ["//"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "javascript",
            displayName: "JavaScript",
            aliases: ["js", "jsx", "mjs", "cjs"],
            family: .cLike,
            keywords: ["async", "await", "catch", "class", "const", "default", "else", "export", "extends", "false", "for", "from", "function", "if", "import", "let", "new", "null", "return", "throw", "true", "try", "undefined", "var", "while", "yield"],
            types: ["Array", "Boolean", "Error", "Map", "Number", "Promise", "Set", "String"],
            lineCommentPrefixes: ["//"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "typescript",
            displayName: "TypeScript",
            aliases: ["ts", "tsx"],
            family: .cLike,
            keywords: ["as", "async", "await", "catch", "class", "const", "default", "else", "enum", "export", "extends", "false", "for", "from", "function", "if", "import", "interface", "let", "new", "null", "readonly", "return", "satisfies", "throw", "true", "try", "type", "undefined", "var", "while"],
            types: ["Array", "Boolean", "Error", "Map", "Number", "Promise", "Record", "Set", "String"],
            lineCommentPrefixes: ["//"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "python",
            displayName: "Python",
            aliases: ["py", "pyw"],
            family: .scripting,
            keywords: ["False", "None", "True", "and", "as", "async", "await", "class", "def", "elif", "else", "except", "finally", "for", "from", "if", "import", "in", "is", "lambda", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"],
            types: ["Any", "Dict", "List", "Optional", "Set", "Tuple"],
            lineCommentPrefixes: ["#"]
        ),
        CodeLanguageDefinition(
            id: "ruby",
            displayName: "Ruby",
            aliases: ["rb"],
            family: .scripting,
            keywords: ["begin", "case", "class", "def", "do", "else", "elsif", "end", "false", "if", "module", "nil", "require", "rescue", "return", "self", "true", "unless", "while", "yield"],
            types: ["Array", "Hash", "String"],
            lineCommentPrefixes: ["#"]
        ),
        CodeLanguageDefinition(
            id: "go",
            displayName: "Go",
            aliases: ["golang"],
            family: .cLike,
            keywords: ["break", "case", "chan", "const", "continue", "defer", "else", "fallthrough", "for", "func", "go", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"],
            types: ["bool", "byte", "context", "error", "int", "rune", "string"],
            lineCommentPrefixes: ["//"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "rust",
            displayName: "Rust",
            aliases: ["rs"],
            family: .cLike,
            keywords: ["async", "await", "break", "const", "crate", "else", "enum", "false", "fn", "for", "if", "impl", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "static", "struct", "trait", "true", "type", "use", "where", "while"],
            types: ["Box", "Option", "Result", "String", "Vec", "bool", "i32", "usize"],
            lineCommentPrefixes: ["//"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "php",
            displayName: "PHP",
            aliases: [],
            family: .scripting,
            keywords: ["abstract", "array", "as", "catch", "class", "echo", "else", "extends", "false", "final", "foreach", "function", "if", "implements", "interface", "namespace", "new", "null", "private", "protected", "public", "return", "static", "throw", "trait", "true", "try", "use", "while"],
            types: ["DateTime", "Exception"],
            lineCommentPrefixes: ["//", "#"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "dart",
            displayName: "Dart",
            aliases: [],
            family: .cLike,
            keywords: ["async", "await", "class", "const", "else", "enum", "extends", "false", "final", "for", "if", "import", "new", "null", "return", "static", "this", "throw", "true", "try", "var", "void", "while", "yield"],
            types: ["BuildContext", "Future", "List", "Map", "String", "Widget"],
            lineCommentPrefixes: ["//"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "shell",
            displayName: "Shell",
            aliases: ["bash", "zsh", "sh", "terminal", "console", "cli"],
            family: .shell,
            keywords: ["case", "cd", "curl", "do", "done", "echo", "elif", "else", "esac", "export", "fi", "for", "function", "git", "if", "in", "then", "while"],
            lineCommentPrefixes: ["#"]
        ),
        CodeLanguageDefinition(
            id: "sql",
            displayName: "SQL",
            aliases: ["postgres", "postgresql", "mysql", "sqlite"],
            family: .sql,
            keywords: ["alter", "and", "as", "between", "by", "case", "create", "delete", "desc", "distinct", "drop", "else", "end", "from", "group", "having", "in", "insert", "into", "is", "join", "left", "limit", "not", "null", "on", "or", "order", "right", "select", "set", "table", "then", "union", "update", "values", "where", "with"],
            types: ["bigint", "boolean", "date", "integer", "jsonb", "numeric", "serial", "text", "timestamp", "uuid", "varchar"],
            lineCommentPrefixes: ["--"],
            blockCommentPairs: [("/*", "*/")],
            isCaseInsensitive: true
        ),
        CodeLanguageDefinition(
            id: "html",
            displayName: "HTML",
            aliases: ["xml", "svg"],
            family: .markup,
            keywords: ["doctype"],
            types: [],
            lineCommentPrefixes: [],
            blockCommentPairs: [("<!--", "-->")]
        ),
        CodeLanguageDefinition(
            id: "css",
            displayName: "CSS",
            aliases: ["scss", "sass", "less"],
            family: .stylesheet,
            keywords: ["and", "from", "important", "in", "media", "not", "only", "supports", "to"],
            types: [],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "json",
            displayName: "JSON",
            aliases: ["jsonc"],
            family: .data,
            keywords: ["false", "null", "true"],
            lineCommentPrefixes: ["//"],
            blockCommentPairs: [("/*", "*/")]
        ),
        CodeLanguageDefinition(
            id: "yaml",
            displayName: "YAML",
            aliases: ["yml"],
            family: .data,
            keywords: ["false", "null", "true"],
            lineCommentPrefixes: ["#"]
        ),
        CodeLanguageDefinition(
            id: "toml",
            displayName: "TOML",
            aliases: [],
            family: .data,
            keywords: ["false", "true"],
            lineCommentPrefixes: ["#"]
        ),
        CodeLanguageDefinition(
            id: "env",
            displayName: "ENV",
            aliases: ["dotenv", "properties", "ini"],
            family: .data,
            keywords: ["false", "true"],
            lineCommentPrefixes: ["#", ";"]
        ),
        CodeLanguageDefinition(
            id: "markdown",
            displayName: "Markdown",
            aliases: ["md", "mdx"],
            family: .markdown,
            keywords: [],
            lineCommentPrefixes: []
        ),
        CodeLanguageDefinition(
            id: "diff",
            displayName: "Diff",
            aliases: ["patch"],
            family: .diff
        ),
        CodeLanguageDefinition(
            id: "log",
            displayName: "Log",
            aliases: ["logs"],
            family: .log
        ),
        CodeLanguageDefinition(
            id: "http",
            displayName: "HTTP",
            aliases: ["curl-request", "request", "response"],
            family: .http,
            keywords: ["CONNECT", "DELETE", "GET", "HEAD", "HTTP", "OPTIONS", "PATCH", "POST", "PUT", "TRACE"],
            isCaseInsensitive: true
        ),
        plainTextDefinition(displayName: "Text")
    ]
}

enum RichAnswerMarkdownParser {
    static func containsRichContent(_ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.contains("```") { return true }
        return normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return heading(from: trimmed) != nil
                    || bullet(from: trimmed) != nil
                    || numbered(from: trimmed) != nil
            }
    }

    static func parse(_ text: String) -> [RichAnswerBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var blocks: [RichAnswerBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var isInCodeBlock = false

        func flushParagraph() {
            let paragraph = paragraphLines
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph))
            }
            paragraphLines.removeAll()
        }

        for rawLine in normalized.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if isInCodeBlock {
                    blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
                    codeLines.removeAll()
                    codeLanguage = nil
                    isInCodeBlock = false
                } else {
                    flushParagraph()
                    let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = language.isEmpty ? nil : language
                    isInCodeBlock = true
                }
                continue
            }

            if isInCodeBlock {
                codeLines.append(rawLine)
                continue
            }

            guard !trimmed.isEmpty else {
                flushParagraph()
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let bullet = bullet(from: trimmed) {
                flushParagraph()
                blocks.append(.bullet(bullet))
                continue
            }

            if let numbered = numbered(from: trimmed) {
                flushParagraph()
                blocks.append(.numbered(index: numbered.index, text: numbered.text))
                continue
            }

            let unquoted = trimmed.hasPrefix("> ") ? String(trimmed.dropFirst(2)) : trimmed
            paragraphLines.append(unquoted)
        }

        if isInCodeBlock {
            blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
        }
        flushParagraph()

        if blocks.isEmpty {
            let fallback = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? [] : [.paragraph(fallback)]
        }
        return blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(level), line.dropFirst(level).first == " " else { return nil }
        let text = line.dropFirst(level + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (level, text)
    }

    private static func bullet(from line: String) -> String? {
        for marker in ["- ", "* "] where line.hasPrefix(marker) {
            let text = line.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func numbered(from line: String) -> (index: Int, text: String)? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let prefix = String(line[..<dotIndex])
        guard let index = Int(prefix), index > 0 else { return nil }
        let afterDot = line[line.index(after: dotIndex)...]
        guard afterDot.first == " " else { return nil }
        let text = afterDot.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (index, text)
    }
}

enum CodeSyntaxHighlighter {
    static func tokens(for code: String, language: String?) -> [SyntaxHighlightToken] {
        let definition = CodeLanguageRegistry.definition(for: language, code: code)
        var output: [SyntaxHighlightToken] = []
        var index = code.startIndex

        func append(_ text: String, role: SyntaxHighlightRole) {
            guard !text.isEmpty else { return }
            if output.last?.role == role {
                output[output.count - 1].text += text
            } else {
                output.append(SyntaxHighlightToken(text: text, role: role))
            }
        }

        while index < code.endIndex {
            if let lineRole = roleForWholeLine(in: code, at: index, definition: definition) {
                let lineEnd = code[index...].firstIndex(of: "\n") ?? code.endIndex
                append(String(code[index..<lineEnd]), role: lineRole)
                index = lineEnd
                continue
            }

            let character = code[index]
            let nextIndex = code.index(after: index)

            if character == "\n" || character == "\t" || character == " " {
                append(String(character), role: .plain)
                index = nextIndex
                continue
            }

            if lineCommentPrefix(in: code, at: index, definition: definition) != nil {
                let lineEnd = code[index...].firstIndex(of: "\n") ?? code.endIndex
                append(String(code[index..<lineEnd]), role: .comment)
                index = lineEnd
                continue
            }

            if let blockCommentPair = blockCommentPair(in: code, at: index, definition: definition) {
                let searchStart = code.index(index, offsetBy: blockCommentPair.opening.count, limitedBy: code.endIndex) ?? code.endIndex
                let closeRange = code[searchStart...].range(of: blockCommentPair.closing)
                let commentEnd = closeRange.map(\.upperBound) ?? code.endIndex
                append(String(code[index..<commentEnd]), role: .comment)
                index = commentEnd
                continue
            }

            if isMarkdownMarker(in: code, at: index, definition: definition) {
                let lineEnd = code[index...].firstIndex(of: "\n") ?? code.endIndex
                append(String(code[index..<lineEnd]), role: .metadata)
                index = lineEnd
                continue
            }

            if isShellPromptStart(in: code, at: index, definition: definition) {
                append(String(character), role: .prompt)
                index = nextIndex
                continue
            }

            if character == "\"" || character == "'" || character == "`" {
                let (stringLiteral, endIndex) = consumeString(in: code, from: index, delimiter: character)
                let role: SyntaxHighlightRole = isQuotedKey(in: code, end: endIndex, definition: definition) ? .attribute : .string
                append(stringLiteral, role: role)
                index = endIndex
                continue
            }

            if character.isNumber {
                let endIndex = consumeWhile(in: code, from: index) { $0.isNumber || $0 == "." || $0 == "_" }
                append(String(code[index..<endIndex]), role: .number)
                index = endIndex
                continue
            }

            if character.isLetter || character == "_" {
                let endIndex = consumeWhile(in: code, from: index) { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                let word = String(code[index..<endIndex])
                append(word, role: role(for: word, in: code, start: index, end: endIndex, definition: definition))
                index = endIndex
                continue
            }

            append(String(character), role: .symbol)
            index = nextIndex
        }

        return output
    }

    private static func role(
        for word: String,
        in code: String,
        start: String.Index,
        end: String.Index,
        definition: CodeLanguageDefinition
    ) -> SyntaxHighlightRole {
        let comparable = definition.isCaseInsensitive ? word.lowercased() : word
        let lower = word.lowercased()

        if definition.family == .log {
            if ["error", "fatal", "failed", "failure"].contains(lower) { return .error }
            if ["warn", "warning"].contains(lower) { return .warning }
            if ["debug", "info", "notice", "trace"].contains(lower) { return .metadata }
        }

        if definition.family == .http {
            if definition.keywords.contains(comparable) { return .keyword }
            if lower.hasPrefix("http") { return .type }
            if nextNonWhitespace(in: code, after: end) == ":" { return .attribute }
        }

        if isKeyLikeWord(in: code, start: start, end: end, definition: definition) {
            return .attribute
        }

        if definition.family == .markup {
            let previous = previousNonWhitespace(in: code, before: start)
            if previous == "<" || previous == "/" {
                return .tag
            }
            if nextNonWhitespace(in: code, after: end) == "=" {
                return .attribute
            }
        }

        if ["true", "false", "null", "nil", "none"].contains(lower) {
            return .number
        }
        if definition.keywords.contains(comparable) {
            return .keyword
        }
        if definition.types.contains(comparable) || (word.first?.isUppercase == true && definition.family != .data) {
            return .type
        }
        return .plain
    }

    private static func roleForWholeLine(
        in code: String,
        at index: String.Index,
        definition: CodeLanguageDefinition
    ) -> SyntaxHighlightRole? {
        guard isStartOfLine(in: code, at: index) else { return nil }
        let lineEnd = code[index...].firstIndex(of: "\n") ?? code.endIndex
        let line = String(code[index..<lineEnd])
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if definition.family == .diff {
            if trimmed.hasPrefix("@@") || trimmed.hasPrefix("diff ") || trimmed.hasPrefix("index ") || trimmed.hasPrefix("+++") || trimmed.hasPrefix("---") {
                return .metadata
            }
            if line.hasPrefix("+") { return .inserted }
            if line.hasPrefix("-") { return .deleted }
        }

        if definition.family == .log {
            let lower = trimmed.lowercased()
            if lower.contains("error") || lower.contains("fatal") || lower.contains("failed") {
                return .error
            }
            if lower.contains("warn") {
                return .warning
            }
        }

        return nil
    }

    private static func isKeyLikeWord(
        in code: String,
        start: String.Index,
        end: String.Index,
        definition: CodeLanguageDefinition
    ) -> Bool {
        let next = nextNonWhitespace(in: code, after: end)
        switch definition.family {
        case .data:
            return next == ":" || next == "="
        case .stylesheet:
            return next == ":"
        default:
            return false
        }
    }

    private static func isQuotedKey(
        in code: String,
        end: String.Index,
        definition: CodeLanguageDefinition
    ) -> Bool {
        guard definition.family == .data else { return false }
        let next = nextNonWhitespace(in: code, after: end)
        return next == ":" || next == "="
    }

    private static func lineCommentPrefix(
        in code: String,
        at index: String.Index,
        definition: CodeLanguageDefinition
    ) -> String? {
        definition.lineCommentPrefixes.first { prefix in
            code[index...].hasPrefix(prefix)
        }
    }

    private static func blockCommentPair(
        in code: String,
        at index: String.Index,
        definition: CodeLanguageDefinition
    ) -> CodeBlockCommentPair? {
        definition.blockCommentPairs.first { pair in
            code[index...].hasPrefix(pair.opening)
        }
    }

    private static func isMarkdownMarker(
        in code: String,
        at index: String.Index,
        definition: CodeLanguageDefinition
    ) -> Bool {
        guard definition.family == .markdown, isStartOfLine(in: code, at: index) else { return false }
        let lineEnd = code[index...].firstIndex(of: "\n") ?? code.endIndex
        let line = String(code[index..<lineEnd]).trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix(">") || line.hasPrefix("```")
    }

    private static func isShellPromptStart(
        in code: String,
        at index: String.Index,
        definition: CodeLanguageDefinition
    ) -> Bool {
        guard definition.family == .shell, isStartOfLine(in: code, at: index) else { return false }
        return code[index] == "$" || code[index] == "%"
    }

    private static func isStartOfLine(in code: String, at index: String.Index) -> Bool {
        index == code.startIndex || code[code.index(before: index)] == "\n"
    }

    private static func previousNonWhitespace(in code: String, before index: String.Index) -> Character? {
        guard index > code.startIndex else { return nil }
        var cursor = code.index(before: index)
        while true {
            let character = code[cursor]
            if !character.isWhitespace {
                return character
            }
            if cursor == code.startIndex { return nil }
            cursor = code.index(before: cursor)
        }
    }

    private static func nextNonWhitespace(in code: String, after index: String.Index) -> Character? {
        var cursor = index
        while cursor < code.endIndex {
            let character = code[cursor]
            if !character.isWhitespace {
                return character
            }
            cursor = code.index(after: cursor)
        }
        return nil
    }

    private static func consumeString(in code: String, from start: String.Index, delimiter: Character) -> (String, String.Index) {
        var index = code.index(after: start)
        var isEscaped = false
        while index < code.endIndex {
            let character = code[index]
            let next = code.index(after: index)
            if character == delimiter && !isEscaped {
                return (String(code[start..<next]), next)
            }
            isEscaped = character == "\\" && !isEscaped
            if character != "\\" {
                isEscaped = false
            }
            index = next
        }
        return (String(code[start..<code.endIndex]), code.endIndex)
    }

    private static func consumeWhile(in code: String, from start: String.Index, predicate: (Character) -> Bool) -> String.Index {
        var index = start
        while index < code.endIndex, predicate(code[index]) {
            index = code.index(after: index)
        }
        return index
    }
}

enum CodeBlockLineNumbering {
    static func lines(for code: String) -> [String] {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.isEmpty ? [""] : lines
    }

    static func lineNumberText(for code: String) -> String {
        lines(for: code).indices
            .map { String($0 + 1) }
            .joined(separator: "\n")
    }

    static func digitCount(for code: String) -> Int {
        max(2, String(lines(for: code).count).count)
    }
}

enum CodeBlockClipboard {
    @discardableResult
    static func copy(_ code: String, pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(code, forType: .string)
    }
}

struct DynamicAnswerContentView: View {
    enum Density {
        case compact
        case detail
        case qa
    }

    enum ContentAlignment {
        case leading
        case center

        var horizontal: HorizontalAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            }
        }

        var frame: Alignment {
            switch self {
            case .leading: .leading
            case .center: .center
            }
        }

        var text: TextAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            }
        }
    }

    var text: String
    var density: Density = .compact
    var alignment: ContentAlignment = .leading

    private var blocks: [RichAnswerBlock] {
        RichAnswerMarkdownParser.parse(text)
    }

    private var paragraphFont: Font {
        switch density {
        case .compact: .system(size: 14, weight: .medium)
        case .detail: .system(size: 11.5, weight: .regular)
        case .qa: .system(size: 15.8, weight: .light)
        }
    }

    private var headingFont: Font {
        switch density {
        case .compact: .system(size: 13, weight: .semibold)
        case .detail: .system(size: 12, weight: .semibold)
        case .qa: .system(size: 15.2, weight: .medium)
        }
    }

    private var spacing: CGFloat {
        switch density {
        case .compact: 8
        case .detail: 6
        case .qa: 13
        }
    }

    private var paragraphLineSpacing: CGFloat {
        switch density {
        case .compact: 1.5
        case .detail: 1
        case .qa: 5.2
        }
    }

    private var headingLineSpacing: CGFloat {
        switch density {
        case .compact: 1.2
        case .detail: 1
        case .qa: 4
        }
    }

    private var paragraphColor: Color {
        Color.white.opacity(density == .qa ? 0.73 : 0.84)
    }

    private var listTextColor: Color {
        Color.white.opacity(density == .qa ? 0.72 : 0.82)
    }

    private var headingColor: Color {
        Color.white.opacity(density == .qa ? 0.82 : 0.90)
    }

    var body: some View {
        VStack(alignment: alignment.horizontal, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment.frame)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: RichAnswerBlock) -> some View {
        switch block {
        case let .heading(level, text):
            MarkdownInlineText(text: text, font: headingFont, color: density == .qa ? headingColor : Color.white.opacity(level == 1 ? 0.9 : 0.82), textAlignment: alignment.text, lineSpacing: headingLineSpacing)
                .frame(maxWidth: .infinity, alignment: alignment.frame)
        case let .paragraph(text):
            MarkdownInlineText(text: text, font: paragraphFont, color: paragraphColor, textAlignment: alignment.text, lineSpacing: paragraphLineSpacing)
                .frame(maxWidth: .infinity, alignment: alignment.frame)
        case let .bullet(text):
            listRow(prefix: "*", text: text)
        case let .numbered(index, text):
            listRow(prefix: "\(index).", text: text)
        case let .code(language, code):
            CodeBlockView(language: language, code: code, density: density)
        }
    }

    private func listRow(prefix: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(prefix)
                .font(paragraphFont)
                .foregroundStyle(Color.white.opacity(density == .qa ? 0.40 : 0.48))
                .frame(width: prefix == "*" ? 10 : 20, alignment: .trailing)
            MarkdownInlineText(text: text, font: paragraphFont, color: listTextColor, textAlignment: .leading, lineSpacing: paragraphLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownInlineText: View {
    var text: String
    var font: Font
    var color: Color
    var textAlignment: TextAlignment
    var lineSpacing: CGFloat = 0

    var body: some View {
        Group {
            if let attributed = try? AttributedString(markdown: text) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(font)
        .foregroundStyle(color)
        .multilineTextAlignment(textAlignment)
        .lineSpacing(lineSpacing)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CodeBlockView: View {
    var language: String?
    var code: String
    var density: DynamicAnswerContentView.Density
    @State private var didCopy = false
    @State private var resetCopyFeedbackTask: Task<Void, Never>?

    private var definition: CodeLanguageDefinition {
        CodeLanguageRegistry.definition(for: language, code: code)
    }

    private var codeFont: Font {
        switch density {
        case .compact:
            .system(size: 10.5, weight: .regular, design: .monospaced)
        case .detail:
            .system(size: 10, weight: .regular, design: .monospaced)
        case .qa:
            .system(size: 12, weight: .light, design: .monospaced)
        }
    }

    private var codeLineSpacing: CGFloat {
        switch density {
        case .compact: 2
        case .detail: 2
        case .qa: 3.4
        }
    }

    private var lineNumberText: String {
        CodeBlockLineNumbering.lineNumberText(for: code)
    }

    private var lineNumberColumnWidth: CGFloat {
        let digitCount = CodeBlockLineNumbering.digitCount(for: code)
        let characterWidth: CGFloat = density == .qa ? 7.2 : 6.4
        return CGFloat(digitCount) * characterWidth + 8
    }

    private var lineNumberColor: Color {
        Color.white.opacity(density == .qa ? 0.30 : 0.24)
    }

    private func copyCode() {
        guard CodeBlockClipboard.copy(code) else { return }
        resetCopyFeedbackTask?.cancel()
        didCopy = false
        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.78, blendDuration: 0.02)) {
            didCopy = true
        }
        resetCopyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_100))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                didCopy = false
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(definition.displayName.uppercased())
                    .font(.system(size: density == .qa ? 8.8 : 8, weight: .bold))
                    .foregroundStyle(Color.white.opacity(density == .qa ? 0.48 : 0.42))
                    .lineLimit(1)
                    .padding(.trailing, 66)

                HStack(alignment: .top, spacing: 10) {
                    Text(lineNumberText)
                        .font(codeFont)
                        .foregroundStyle(lineNumberColor)
                        .lineSpacing(codeLineSpacing)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(width: lineNumberColumnWidth, alignment: .trailing)
                        .padding(.vertical, 2)

                    Rectangle()
                        .fill(Color.white.opacity(0.065))
                        .frame(width: 0.6)
                        .padding(.vertical, 1)

                    ScrollView(.horizontal, showsIndicators: false) {
                        SyntaxHighlightedCodeText(code: code, language: language)
                            .font(codeFont)
                            .lineSpacing(codeLineSpacing)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.vertical, 2)
                    }
                }
            }

            CodeBlockCopyButton(didCopy: didCopy, action: copyCode)
        }
        .padding(.horizontal, density == .qa ? 12 : 10)
        .padding(.vertical, density == .qa ? 10 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.075), lineWidth: 0.6)
        )
        .onDisappear {
            resetCopyFeedbackTask?.cancel()
        }
    }
}

private struct CodeBlockCopyButton: View {
    var didCopy: Bool
    var action: () -> Void
    @Environment(\.islandDesignMode) private var islandDesignMode
    @State private var isHovering = false
    @State private var isPressed = false

    private var backgroundOpacity: Double {
        guard islandDesignMode == .solid else { return glassFallbackOpacity }
        if didCopy { return 0.180 }
        if isPressed { return 0.13 }
        return isHovering ? 0.110 : 0.070
    }

    private var strokeOpacity: Double {
        if islandDesignMode == .liquidGlass {
            if didCopy { return 0.34 }
            return isHovering || isPressed ? 0.17 : 0.095
        }
        if didCopy { return 0.34 }
        return isHovering || isPressed ? 0.16 : 0.10
    }

    private var glassTintOpacity: Double {
        if didCopy { return 0.130 }
        if isPressed { return 0.095 }
        return isHovering ? 0.072 : 0.045
    }

    private var glassFallbackOpacity: Double {
        if didCopy { return 0.115 }
        if isPressed { return 0.078 }
        return isHovering ? 0.058 : 0.035
    }

    private var foregroundOpacity: Double {
        if didCopy { return 0.92 }
        if isPressed { return 0.86 }
        return isHovering ? 0.78 : 0.64
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                shape
                    .fill(Color.clear)
                    .background(
                        IslandGlassFill(
                            shape: shape,
                            mode: islandDesignMode,
                            solidOpacity: backgroundOpacity,
                            glassTintOpacity: glassTintOpacity,
                            glassFallbackOpacity: glassFallbackOpacity
                        )
                    )
                    .overlay(
                        shape
                            .stroke(Color.white.opacity(strokeOpacity), lineWidth: 0.6)
                    )
                shape
                    .stroke(Color.white.opacity(didCopy ? 0.28 : 0), lineWidth: 1)
                    .scaleEffect(didCopy ? 1.08 : 0.92)
                    .opacity(didCopy ? 1 : 0)
                    .animation(.easeOut(duration: 0.42), value: didCopy)
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.8, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(foregroundOpacity))
                    .contentTransition(.opacity)
                    .allowsHitTesting(false)
            }
            .frame(width: 29, height: 27)
            .shadow(color: Color.white.opacity(didCopy ? 0.18 : 0), radius: didCopy ? 7 : 0)
        }
        .buttonStyle(.plain)
        .frame(width: 34, height: 32)
        .scaleEffect(isPressed ? 0.94 : didCopy ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.76, blendDuration: 0.02), value: didCopy)
        .animation(.easeOut(duration: 0.08), value: isPressed)
        .overlay(
            MouseDownActionOverlay(
                action: action,
                onHover: { isHovering = $0 },
                onPress: { isPressed = $0 }
            )
            .frame(width: 34, height: 32)
            .contentShape(Rectangle())
        )
        .contentShape(Rectangle())
        .textSelection(.disabled)
        .accessibilityLabel(Text(didCopy ? "Código copiado" : "Copiar código"))
        .help(didCopy ? "Copiado" : "Copiar código")
    }
}

private struct SyntaxHighlightedCodeText: View {
    var code: String
    var language: String?

    private var highlightedText: Text {
        CodeSyntaxHighlighter.tokens(for: code, language: language).reduce(Text("")) { partial, token in
            partial + Text(token.text).foregroundColor(token.role.color)
        }
    }

    var body: some View {
        highlightedText
    }
}
