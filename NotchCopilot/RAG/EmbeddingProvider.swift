import Foundation

enum EmbeddingProviderExecutionScope: String, Sendable, Hashable {
    case localDevice
    case localLoopback
    case remoteNetwork

    var isLocal: Bool {
        switch self {
        case .localDevice, .localLoopback:
            return true
        case .remoteNetwork:
            return false
        }
    }
}

enum EmbeddingProviderSafetyError: LocalizedError, Equatable {
    case remoteProviderRejected(String)
    case invalidBatchCount(model: String, expected: Int, actual: Int)
    case invalidVectorDimensions(model: String, expected: Int, actual: Int)
    case invalidVectorValue(model: String)

    var errorDescription: String? {
        switch self {
        case .remoteProviderRejected(let modelIdentifier):
            return "Remote embedding provider '\(modelIdentifier)' is not allowed for local-first RAG."
        case .invalidBatchCount(let model, let expected, let actual):
            return "Embedding provider '\(model)' returned \(actual) vector(s) for \(expected) chunk(s)."
        case .invalidVectorDimensions(let model, let expected, let actual):
            return "Embedding provider '\(model)' returned a \(actual)d vector; expected \(expected)d."
        case .invalidVectorValue(let model):
            return "Embedding provider '\(model)' returned a non-finite vector value."
        }
    }
}

@MainActor
protocol EmbeddingProvider {
    var modelIdentifier: String { get }
    var dimensions: Int { get }
    var executionScope: EmbeddingProviderExecutionScope { get }
    func embed(_ texts: [String]) async throws -> [[Double]]
}

extension EmbeddingProvider {
    var executionScope: EmbeddingProviderExecutionScope { .remoteNetwork }

    func embed(_ text: String) async throws -> [Double] {
        try await embed([text]).first ?? []
    }
}
