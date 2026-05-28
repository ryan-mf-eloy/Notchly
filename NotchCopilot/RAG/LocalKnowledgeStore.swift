import Foundation
import SwiftData

struct KnowledgeSearchResult: Identifiable, Sendable, Hashable {
    var id = UUID()
    var documentName: String
    var snippet: String
    var score: Double
    var workspaceId: String = "default"
}

@MainActor
final class LocalKnowledgeStore {
    private let context: ModelContext
    private let workspaceId: String
    private let cryptor: LocalDataCryptor

    init(container: ModelContainer, workspaceId: String = "default", cryptor: LocalDataCryptor = .defaultOrCrash()) {
        self.context = ModelContext(container)
        self.workspaceId = workspaceId
        self.cryptor = cryptor
    }

    func addDocument(name: String, filePath: String? = nil, content: String, workspaceId: String? = nil) throws {
        context.insert(try StoredKnowledgeDocument(displayName: name, filePath: filePath, content: content, workspaceId: workspaceId ?? self.workspaceId, cryptor: cryptor))
        try context.save()
    }

    func documents() throws -> [KnowledgeDocument] {
        try storedDocuments().map { try $0.decrypt(cryptor: cryptor) }
    }

    func migrateEncryptedFields() throws {
        for document in try storedDocuments() {
            try document.encryptSensitiveFieldsIfNeeded(cryptor: cryptor)
        }
        try context.save()
    }

    func deleteAll() throws {
        for document in try storedDocuments() {
            context.delete(document)
        }
        try context.save()
    }

    func keywordSearch(query: String, limit: Int = 4, workspaceId: String? = nil) throws -> [KnowledgeSearchResult] {
        let terms = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !terms.isEmpty else { return [] }
        let targetWorkspaceId = workspaceId ?? self.workspaceId
        return try documents()
            .filter { $0.workspaceId == targetWorkspaceId }
            .compactMap { document in
                let lowered = document.content.lowercased()
                let matches = terms.filter { lowered.contains($0) }.count
                guard matches > 0 else { return nil }
                let snippet = makeSnippet(content: document.content, terms: terms)
                return KnowledgeSearchResult(documentName: document.displayName, snippet: snippet, score: Double(matches) / Double(max(terms.count, 1)), workspaceId: document.workspaceId)
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    func buildContext(for query: String, workspaceId: String? = nil) throws -> String {
        try keywordSearch(query: query, workspaceId: workspaceId)
            .map { "[\($0.documentName)] \($0.snippet)" }
            .joined(separator: "\n")
    }

    private func makeSnippet(content: String, terms: Set<String>) -> String {
        let sentences = content.split(whereSeparator: { ".!?\n".contains($0) }).map(String.init)
        return sentences.first { sentence in
            let lowered = sentence.lowercased()
            return terms.contains { lowered.contains($0) }
        }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? String(content.prefix(240))
    }

    private func storedDocuments() throws -> [StoredKnowledgeDocument] {
        try context.fetch(FetchDescriptor<StoredKnowledgeDocument>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }
}
