import Foundation

protocol EmbeddingProvider {
    func embed(_ texts: [String]) async throws -> [[Double]]
}
