import Foundation

@MainActor
struct RAGContextBuilder {
    var store: LocalKnowledgeStore

    func context(for question: String) -> String {
        (try? store.buildContext(for: question)) ?? ""
    }
}

