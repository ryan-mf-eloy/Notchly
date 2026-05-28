import Foundation

@MainActor
protocol WebSearchService {
    func search(query: String) async throws -> [String]
}
