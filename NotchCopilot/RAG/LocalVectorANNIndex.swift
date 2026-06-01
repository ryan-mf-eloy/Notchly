import Foundation

struct LocalVectorANNIndex {
    static let minimumCandidateCount = 512

    private struct Node {
        var chunkId: UUID
        var vector: [Double]
        var signature: UInt64
        var level: Int
        var neighbors: [[Int]]
    }

    private let maxConnections: Int
    private let efConstruction: Int
    private let maxLevel: Int
    private let vectorSearch = VectorSearchService()
    private var nodes: [Node] = []
    private var signatureBuckets: [UInt16: [Int]] = [:]
    private var entryIndex: Int?

    init(
        candidates: [VectorSearchService.Candidate],
        maxConnections: Int = 12,
        efConstruction: Int = 96
    ) {
        self.maxConnections = max(4, maxConnections)
        self.efConstruction = max(32, efConstruction)
        self.maxLevel = min(6, max(1, Int(log2(Double(max(candidates.count, 2)))) / 2))
        for candidate in candidates where !candidate.vector.isEmpty {
            insert(candidate)
        }
    }

    func search(query: [Double], limit: Int, efSearch: Int = 96) -> [(chunkId: UUID, score: Double)] {
        guard !query.isEmpty, limit > 0, let entryIndex else { return [] }
        var current = entryIndex
        var currentScore = vectorSearch.cosineSimilarity(query, nodes[current].vector)
        let topLevel = nodes.map(\.level).max() ?? 0

        if topLevel > 0 {
            for level in stride(from: topLevel, through: 1, by: -1) {
                var improved = true
                while improved {
                    improved = false
                    for neighbor in neighbors(of: current, at: level) {
                        let score = vectorSearch.cosineSimilarity(query, nodes[neighbor].vector)
                        if score > currentScore {
                            current = neighbor
                            currentScore = score
                            improved = true
                        }
                    }
                }
            }
        }

        var pool = Set(searchLayer(query: query, entry: current, level: 0, ef: max(efSearch, limit * 12)))
        pool.formUnion(signatureShortlist(for: query, limit: max(1_024, efSearch * 8, limit * 64)))
        return pool
            .map { index in
                (chunkId: nodes[index].chunkId, score: vectorSearch.cosineSimilarity(query, nodes[index].vector))
            }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    private func signatureShortlist(for query: [Double], limit: Int) -> [Int] {
        let querySignature = Self.signature(query)
        let targetLimit = min(limit, nodes.count)
        guard targetLimit > 0 else { return [] }
        let queryBucket = Self.signatureBucket(querySignature)
        var candidateIndices = signatureBuckets[queryBucket] ?? []
        if candidateIndices.count < targetLimit {
            for bucket in signatureBuckets.keys.sorted(by: { lhs, rhs in
                Self.bucketDistance(lhs, queryBucket) < Self.bucketDistance(rhs, queryBucket)
            }) where bucket != queryBucket {
                candidateIndices.append(contentsOf: signatureBuckets[bucket] ?? [])
                if candidateIndices.count >= targetLimit { break }
            }
        }
        guard candidateIndices.count > targetLimit else { return candidateIndices }
        return candidateIndices
            .map { (index: $0, distance: (nodes[$0].signature ^ querySignature).nonzeroBitCount) }
            .sorted { lhs, rhs in lhs.distance < rhs.distance }
            .prefix(targetLimit)
            .map(\.index)
    }

    private mutating func insert(_ candidate: VectorSearchService.Candidate) {
        let newIndex = nodes.count
        let level = deterministicLevel(for: candidate.chunkId)
        let node = Node(
            chunkId: candidate.chunkId,
            vector: candidate.vector,
            signature: Self.signature(candidate.vector),
            level: level,
            neighbors: Array(repeating: [], count: level + 1)
        )
        nodes.append(node)
        signatureBuckets[Self.signatureBucket(node.signature), default: []].append(newIndex)

        guard let currentEntry = entryIndex else {
            entryIndex = newIndex
            return
        }

        for graphLevel in stride(from: level, through: 0, by: -1) {
            let existing = nodes.indices.dropLast().filter { nodes[$0].level >= graphLevel }
            let neighbors = nearestNeighbors(
                to: candidate.vector,
                signature: nodes[newIndex].signature,
                among: Array(existing),
                limit: maxConnections,
                level: graphLevel
            )
            connect(newIndex, to: neighbors, at: graphLevel)
        }

        if level > nodes[currentEntry].level {
            entryIndex = newIndex
        }
    }

    private func nearestNeighbors(
        to vector: [Double],
        signature: UInt64,
        among indices: [Int],
        limit: Int,
        level: Int
    ) -> [Int] {
        guard !indices.isEmpty else { return [] }
        let shortlistLimit = min(indices.count, max(efConstruction, limit * 8))
        let shortlist = indices.count > shortlistLimit
            ? indices
                .map { (index: $0, distance: (nodes[$0].signature ^ signature).nonzeroBitCount) }
                .sorted { lhs, rhs in lhs.distance < rhs.distance }
                .prefix(shortlistLimit)
                .map(\.index)
            : indices

        return shortlist
            .map { (index: $0, score: vectorSearch.cosineSimilarity(vector, nodes[$0].vector)) }
            .filter { $0.score > 0 || level == 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.index)
    }

    private mutating func connect(_ index: Int, to neighbors: [Int], at level: Int) {
        guard nodes[index].neighbors.indices.contains(level) else { return }
        for neighbor in neighbors where neighbor != index && nodes[neighbor].neighbors.indices.contains(level) {
            if !nodes[index].neighbors[level].contains(neighbor) {
                nodes[index].neighbors[level].append(neighbor)
            }
            if !nodes[neighbor].neighbors[level].contains(index) {
                nodes[neighbor].neighbors[level].append(index)
                pruneNeighbors(for: neighbor, at: level)
            }
        }
        pruneNeighbors(for: index, at: level)
    }

    private mutating func pruneNeighbors(for index: Int, at level: Int) {
        guard nodes[index].neighbors.indices.contains(level),
              nodes[index].neighbors[level].count > maxConnections else { return }
        let vector = nodes[index].vector
        nodes[index].neighbors[level] = nodes[index].neighbors[level]
            .map { (index: $0, score: vectorSearch.cosineSimilarity(vector, nodes[$0].vector)) }
            .sorted { $0.score > $1.score }
            .prefix(maxConnections)
            .map(\.index)
    }

    private func searchLayer(query: [Double], entry: Int, level: Int, ef: Int) -> [Int] {
        var visited = Set([entry])
        var candidates = [(index: entry, score: vectorSearch.cosineSimilarity(query, nodes[entry].vector))]
        var best = candidates

        while !candidates.isEmpty {
            let bestCandidateOffset = candidates.indices.max { candidates[$0].score < candidates[$1].score }
            guard let bestCandidateOffset else { break }
            let candidate = candidates.remove(at: bestCandidateOffset)
            let worstBest = best.map(\.score).min() ?? -Double.infinity
            if best.count >= ef, candidate.score < worstBest {
                break
            }

            for neighbor in neighbors(of: candidate.index, at: level) where visited.insert(neighbor).inserted {
                let score = vectorSearch.cosineSimilarity(query, nodes[neighbor].vector)
                let currentWorst = best.map(\.score).min() ?? -Double.infinity
                if best.count < ef || score > currentWorst {
                    candidates.append((neighbor, score))
                    best.append((neighbor, score))
                    if best.count > ef,
                       let worstOffset = best.indices.min(by: { best[$0].score < best[$1].score }) {
                        best.remove(at: worstOffset)
                    }
                }
            }
        }

        return best.map(\.index)
    }

    private func neighbors(of index: Int, at level: Int) -> [Int] {
        guard nodes.indices.contains(index),
              nodes[index].neighbors.indices.contains(level) else { return [] }
        return nodes[index].neighbors[level]
    }

    private func deterministicLevel(for id: UUID) -> Int {
        var value = Self.stableHash(id.uuidString)
        var level = 0
        while level < maxLevel, value & 0b11 == 0 {
            level += 1
            value >>= 2
        }
        return level
    }

    private static func signature(_ vector: [Double]) -> UInt64 {
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

    private static func signatureBucket(_ signature: UInt64) -> UInt16 {
        UInt16(truncatingIfNeeded: signature >> 48)
    }

    private static func bucketDistance(_ lhs: UInt16, _ rhs: UInt16) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
