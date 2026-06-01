import Foundation
import Accelerate

struct VectorSearchService {
    struct Candidate: Sendable, Hashable {
        var chunkId: UUID
        var vector: [Double]
    }

    func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        if lhs.count >= 64 {
            let dot = vDSP.dot(lhs, rhs)
            let lhsMagnitude = sqrt(vDSP.sumOfSquares(lhs))
            let rhsMagnitude = sqrt(vDSP.sumOfSquares(rhs))
            guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
            return dot / (lhsMagnitude * rhsMagnitude)
        }
        var dot = 0.0
        var lhsMagnitude = 0.0
        var rhsMagnitude = 0.0
        for index in lhs.indices {
            let left = lhs[index]
            let right = rhs[index]
            dot += left * right
            lhsMagnitude += left * left
            rhsMagnitude += right * right
        }
        lhsMagnitude = sqrt(lhsMagnitude)
        rhsMagnitude = sqrt(rhsMagnitude)
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return dot / (lhsMagnitude * rhsMagnitude)
    }

    func rank(
        query: [Double],
        candidates: [Candidate],
        limit: Int,
        approximateThreshold: Int = 4_096
    ) -> [(chunkId: UUID, score: Double)] {
        guard !query.isEmpty, !candidates.isEmpty, limit > 0 else { return [] }
        let searchable = candidates.count > approximateThreshold
            ? approximateCandidates(query: query, candidates: candidates, limit: max(limit * 8, 256))
            : candidates
        return searchable
            .compactMap { candidate -> (chunkId: UUID, score: Double)? in
                let score = cosineSimilarity(query, candidate.vector)
                return score > 0 ? (candidate.chunkId, score) : nil
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    private func approximateCandidates(query: [Double], candidates: [Candidate], limit: Int) -> [Candidate] {
        let querySignature = signature(query)
        let targetLimit = min(max(limit, 512), candidates.count)
        return candidates
            .map { candidate in
                (candidate: candidate, distance: hammingDistance(signature(candidate.vector), querySignature))
            }
            .sorted { lhs, rhs in
                lhs.distance < rhs.distance
            }
            .prefix(targetLimit)
            .map(\.candidate)
    }

    private func signature(_ vector: [Double]) -> UInt64 {
        guard !vector.isEmpty else { return 0 }
        let stride = max(1, vector.count / 64)
        var bits: UInt64 = 0
        for bit in 0..<64 {
            let start = bit * stride
            guard start < vector.count else { break }
            let end = min(vector.count, start + stride)
            let sum = vector[start..<end].reduce(0, +)
            if sum >= 0 {
                bits |= UInt64(1) << UInt64(bit)
            }
        }
        return bits
    }

    private func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }
}
