import Foundation

struct VectorSearchService {
    func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let dot = zip(lhs, rhs).map(*).reduce(0, +)
        let lhsMagnitude = sqrt(lhs.map { $0 * $0 }.reduce(0, +))
        let rhsMagnitude = sqrt(rhs.map { $0 * $0 }.reduce(0, +))
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return dot / (lhsMagnitude * rhsMagnitude)
    }
}

