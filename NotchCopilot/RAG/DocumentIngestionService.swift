import Foundation
import PDFKit

struct DocumentIngestionService {
    func readText(from url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "txt", "md":
            return try String(contentsOf: url)
        case "pdf":
            guard let document = PDFDocument(url: url) else { return "" }
            return (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n")
        default:
            return try String(contentsOf: url)
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
}

