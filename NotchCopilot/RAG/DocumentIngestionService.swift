import Foundation
import PDFKit

struct KnowledgeChunkDraft: Sendable, Hashable {
    var content: String
    var heading: String?
    var locationLabel: String?
    var tokenEstimate: Int
}

struct DocumentIngestionService {
    static let supportedExtensions: Set<String> = ["txt", "md", "markdown", "pdf", "json", "csv"]

    func readText(from url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown", "json", "csv":
            return try String(contentsOf: url)
        case "pdf":
            guard let document = PDFDocument(url: url) else { return "" }
            return (0..<document.pageCount)
                .compactMap { index in
                    guard let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else {
                        return nil
                    }
                    return "\(Self.pdfPageMarker)\(index + 1)\n\(text)"
                }
                .joined(separator: "\n\n")
        default:
            return try String(contentsOf: url)
        }
    }

    func documentKind(for url: URL) -> KnowledgeDocumentKind {
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            return .markdown
        case "pdf":
            return .pdf
        case "txt", "json", "csv":
            return .text
        default:
            return .unknown
        }
    }

    func chunks(from text: String, approximateSize: Int = 1_200) -> [String] {
        guard text.count > approximateSize else { return [text] }
        var chunks: [String] = []
        var current = ""
        for line in text.components(separatedBy: .newlines) {
            if current.count + line.count > approximateSize {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    func structuredChunks(
        from text: String,
        kind: KnowledgeDocumentKind,
        targetTokens: Int = 700,
        overlapTokens: Int = 120
    ) -> [KnowledgeChunkDraft] {
        let targetCharacters = max(1_400, targetTokens * 4)
        let overlapCharacters = max(0, overlapTokens * 4)
        let sections = sections(from: text, kind: kind)
        var drafts: [KnowledgeChunkDraft] = []

        for section in sections {
            let content = section.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            if content.count <= targetCharacters {
                drafts.append(KnowledgeChunkDraft(
                    content: content,
                    heading: section.heading,
                    locationLabel: section.locationLabel,
                    tokenEstimate: estimateTokens(content)
                ))
            } else {
                drafts.append(contentsOf: slidingChunks(
                    content: content,
                    heading: section.heading,
                    locationLabel: section.locationLabel,
                    targetCharacters: targetCharacters,
                    overlapCharacters: overlapCharacters
                ))
            }
        }

        return drafts.isEmpty ? [KnowledgeChunkDraft(content: text, heading: nil, locationLabel: nil, tokenEstimate: estimateTokens(text))] : drafts
    }

    private func sections(from text: String, kind: KnowledgeDocumentKind) -> [(heading: String?, locationLabel: String?, content: String)] {
        switch kind {
        case .markdown:
            return markdownSections(from: text)
        case .pdf:
            return pdfPageSections(from: text)
        case .transcript:
            return transcriptSections(from: text)
        default:
            return [(nil, nil, text)]
        }
    }

    private func markdownSections(from text: String) -> [(heading: String?, locationLabel: String?, content: String)] {
        var sections: [(String?, String?, String)] = []
        var currentHeading: String?
        var currentLines: [String] = []
        var currentStartLine = 1

        func flush(endLine: Int) {
            let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }
            let label = currentHeading.map { "\($0) - lines \(currentStartLine)-\(endLine)" } ?? "lines \(currentStartLine)-\(endLine)"
            sections.append((currentHeading, label, content))
        }

        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                flush(endLine: max(index, currentStartLine))
                currentHeading = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).nilIfEmpty
                currentLines = [line]
                currentStartLine = index + 1
            } else {
                currentLines.append(line)
            }
        }
        flush(endLine: lines.count)
        return sections
    }

    private func transcriptSections(from text: String) -> [(heading: String?, locationLabel: String?, content: String)] {
        let lines = text.components(separatedBy: .newlines)
        var sections: [(String?, String?, String)] = []
        var current: [String] = []
        var turn = 1

        func flush() {
            let content = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }
            let turnLabel = "turns \(turn)-\(turn + current.count - 1)"
            let timeLabel = transcriptTimeRangeLabel(in: current)
            let locationLabel = timeLabel.map { "\($0) / \(turnLabel)" } ?? turnLabel
            sections.append(("Transcript", locationLabel, content))
            turn += current.count
            current = []
        }

        for line in lines {
            if current.joined(separator: "\n").count > 2_800 {
                flush()
            }
            current.append(line)
        }
        flush()
        return sections
    }

    private func transcriptTimeRangeLabel(in lines: [String]) -> String? {
        let ranges = lines.compactMap(Self.transcriptTimeRange)
        guard let first = ranges.first else { return nil }
        return "\(first.start)-\((ranges.last ?? first).end)"
    }

    private static func transcriptTimeRange(in line: String) -> (start: String, end: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["),
              let close = trimmed.firstIndex(of: "]") else {
            return nil
        }
        let raw = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        let parts = raw.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0].contains(":"),
              parts[1].contains(":") else {
            return nil
        }
        return (parts[0], parts[1])
    }

    private func pdfPageSections(from text: String) -> [(heading: String?, locationLabel: String?, content: String)] {
        let lines = text.components(separatedBy: .newlines)
        var sections: [(String?, String?, String)] = []
        var currentPage: Int?
        var currentLines: [String] = []

        func flush() {
            let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }
            let label = currentPage.map { "page \($0)" }
            sections.append(("PDF", label, content))
        }

        for line in lines {
            if line.hasPrefix(Self.pdfPageMarker) {
                flush()
                currentPage = Int(line.replacingOccurrences(of: Self.pdfPageMarker, with: ""))
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        flush()
        return sections.isEmpty ? [(nil, nil, text)] : sections
    }

    private func slidingChunks(
        content: String,
        heading: String?,
        locationLabel: String?,
        targetCharacters: Int,
        overlapCharacters: Int
    ) -> [KnowledgeChunkDraft] {
        var chunks: [KnowledgeChunkDraft] = []
        var start = content.startIndex
        var part = 1
        while start < content.endIndex {
            let rawEnd = content.index(start, offsetBy: targetCharacters, limitedBy: content.endIndex) ?? content.endIndex
            let end = nearestBoundary(in: content, before: rawEnd, after: start)
            let chunkText = String(content[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunkText.isEmpty {
                chunks.append(KnowledgeChunkDraft(
                    content: chunkText,
                    heading: heading,
                    locationLabel: locationLabel.map { "\($0) - part \(part)" } ?? "part \(part)",
                    tokenEstimate: estimateTokens(chunkText)
                ))
            }
            guard end < content.endIndex else { break }
            let distance = content.distance(from: start, to: end)
            let overlap = min(overlapCharacters, distance)
            start = content.index(end, offsetBy: -overlap, limitedBy: start) ?? end
            part += 1
        }
        return chunks
    }

    private func nearestBoundary(in text: String, before rawEnd: String.Index, after start: String.Index) -> String.Index {
        let windowStart = text.index(rawEnd, offsetBy: -min(320, text.distance(from: start, to: rawEnd)), limitedBy: start) ?? start
        let slice = text[windowStart..<rawEnd]
        if let boundary = slice.lastIndex(where: { ".!?\n".contains($0) }) {
            return text.index(after: boundary)
        }
        return rawEnd
    }

    private func estimateTokens(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 4.0)))
    }

    private static let pdfPageMarker = "%%NOTCHLY_PDF_PAGE "
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
