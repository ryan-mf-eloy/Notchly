import Foundation
import SoundAnalysis

struct SoundEvent: Identifiable, Sendable, Hashable {
    var id = UUID()
    var label: String
    var confidence: Double
    var timestamp: TimeInterval
}

final class AppleSoundAnalysisService {
    func analyzeSilence(levels: [Float], threshold: Float = 0.015) -> Bool {
        guard !levels.isEmpty else { return true }
        return levels.allSatisfy { $0 < threshold }
    }
}

