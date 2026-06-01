import Foundation

struct LocalBM25Index {
    private struct Posting {
        var chunkId: UUID
        var termFrequency: Double
        var length: Double
    }

    private let postingsByTerm: [String: [Posting]]
    private let documentFrequency: [String: Double]
    private let averageLength: Double
    private let documentCount: Double
    private let k1 = 1.35
    private let b = 0.72

    init(
        chunks: [KnowledgeChunkRecord],
        documentsById: [UUID: KnowledgeDocumentRecord],
        sourcesById: [UUID: KnowledgeSource]
    ) {
        var postings: [String: [Posting]] = [:]
        var df: [String: Double] = [:]
        var lengths: [Double] = []
        lengths.reserveCapacity(chunks.count)

        for chunk in chunks {
            var frequencies: [String: Double] = [:]
            Self.addTokens(from: chunk.content, weight: 1.0, into: &frequencies)
            if let heading = chunk.heading {
                Self.addTokens(from: heading, weight: 2.0, into: &frequencies)
            }
            if let locationLabel = chunk.locationLabel {
                Self.addTokens(from: locationLabel, weight: 1.25, into: &frequencies)
            }
            if let document = documentsById[chunk.documentId] {
                Self.addTokens(from: document.displayName, weight: 1.45, into: &frequencies)
                Self.addTokens(from: document.kind.rawValue, weight: 1.15, into: &frequencies)
                if let tags = document.metadata["tags"] {
                    Self.addTokens(from: tags, weight: 1.7, into: &frequencies)
                }
                if let kind = document.metadata["kind"] {
                    Self.addTokens(from: kind, weight: 1.35, into: &frequencies)
                }
                if let wikilinks = document.metadata["wikilinks"] {
                    Self.addTokens(from: "wikilinks \(wikilinks)", weight: 1.55, into: &frequencies)
                }
                if let backlinks = document.metadata["backlinks"] {
                    Self.addTokens(from: "backlinks \(backlinks)", weight: 1.65, into: &frequencies)
                }
                if let attachments = document.metadata["attachments"] {
                    Self.addTokens(from: "attachments \(attachments)", weight: 1.15, into: &frequencies)
                }
            }
            if let source = sourcesById[chunk.sourceId] {
                Self.addTokens(from: source.kind.rawValue, weight: 1.2, into: &frequencies)
                Self.addTokens(from: source.displayName, weight: 1.15, into: &frequencies)
            }
            let length = max(1.0, frequencies.values.reduce(0, +))
            lengths.append(length)
            for (term, frequency) in frequencies where frequency > 0 {
                postings[term, default: []].append(Posting(
                    chunkId: chunk.id,
                    termFrequency: frequency,
                    length: length
                ))
                df[term, default: 0] += 1
            }
        }
        postingsByTerm = postings
        documentFrequency = df
        documentCount = Double(max(chunks.count, 1))
        averageLength = max(1.0, lengths.reduce(0, +) / documentCount)
    }

    func search(terms: [String], limit: Int) -> [(chunkId: UUID, score: Double)] {
        let uniqueTerms = Array(Set(terms))
        guard !uniqueTerms.isEmpty, limit > 0 else { return [] }
        var scores: [UUID: Double] = [:]
        for term in uniqueTerms {
            guard let postings = postingsByTerm[term], !postings.isEmpty else { continue }
            let df = documentFrequency[term] ?? Double(postings.count)
            let idf = log((documentCount - df + 0.5) / (df + 0.5) + 1.0)
            for posting in postings {
                let denominator = posting.termFrequency + k1 * (1 - b + b * posting.length / averageLength)
                scores[posting.chunkId, default: 0] += idf * ((posting.termFrequency * (k1 + 1)) / denominator)
            }
        }
        return scores
            .map { (chunkId: $0.key, score: $0.value) }
            .filter { $0.score > 0 }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }

    static func tokens(from text: String) -> [String] {
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        var tokens = normalized
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 }

        let codeRuns = normalized.split { character in
            !(character.isLetter || character.isNumber || Self.isIdentifierConnector(character))
        }
        for run in codeRuns {
            guard run.contains(where: Self.isIdentifierConnector) else { continue }
            let parts = run
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { !$0.isEmpty }
            guard parts.count > 1 else { continue }
            let compact = parts.joined()
            guard compact.count > 2 else { continue }
            let hasDigit = compact.contains { $0.isNumber }
            let hasShortCodePart = parts.contains { $0.count <= 3 }
            if hasDigit || hasShortCodePart {
                tokens.append(compact)
            }
        }

        return tokens
    }

    private static func addTokens(from text: String, weight: Double, into frequencies: inout [String: Double]) {
        for token in tokens(from: text) {
            frequencies[token, default: 0] += weight
        }
    }

    private static func isIdentifierConnector(_ character: Character) -> Bool {
        character == "-" || character == "_" || character == "." || character == "/" || character == "#"
    }
}
