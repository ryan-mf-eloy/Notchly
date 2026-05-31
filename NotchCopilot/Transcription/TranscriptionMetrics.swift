import Darwin
import Foundation

struct TranscriptionLatencySummary: Codable, Hashable, Sendable {
    var p50: Double?
    var p95: Double?
    var p99: Double?
}

struct TranscriptionMetricsSnapshot: Codable, Hashable, Sendable {
    var firstPartialLatency: TranscriptionLatencySummary
    var finalStabilizationLatency: TranscriptionLatencySummary
    var falseSpeechRate: Double
    var silenceFalsePositiveCount: Int
    var duplicateOrTailCount: Int
    var rejectedLowEnergyCount: Int
    var refinedSegmentCount: Int
    var acceptedRefinementCount: Int
    var nativeSpeechDetectorDropCount: Int
    var voiceActivityDetectionEngineCounts: [String: Int]
    var memoryResidentBytes: UInt64?
    var cpuUsagePercent: Double?
    var benchmarkResults: [TranscriptionBenchmarkResult]
    var benchmarkSummary: TranscriptionBenchmarkSummary
}

actor TranscriptionMetrics {
    static let shared = TranscriptionMetrics()

    private var audioDecisions: [VoiceActivityDecision] = []
    private var firstPartialLatencies: [Double] = []
    private var finalStabilizationLatencies: [Double] = []
    private var silenceFalsePositiveCount = 0
    private var duplicateOrTailCount = 0
    private var rejectedLowEnergyCount = 0
    private var refinedSegmentCount = 0
    private var acceptedRefinementCount = 0
    private var nativeSpeechDetectorDropCount = 0
    private var voiceActivityDetectionEngineCounts: [VoiceActivityDetectionEngine: Int] = [:]
    private var benchmarkResults: [TranscriptionBenchmarkResult] = []

    func reset() {
        audioDecisions.removeAll()
        firstPartialLatencies.removeAll()
        finalStabilizationLatencies.removeAll()
        silenceFalsePositiveCount = 0
        duplicateOrTailCount = 0
        rejectedLowEnergyCount = 0
        refinedSegmentCount = 0
        acceptedRefinementCount = 0
        nativeSpeechDetectorDropCount = 0
        voiceActivityDetectionEngineCounts.removeAll()
        benchmarkResults.removeAll()
    }

    func recordAudioDecision(_ decision: VoiceActivityDecision) {
        audioDecisions.append(decision)
        voiceActivityDetectionEngineCounts[decision.detectionEngine, default: 0] += 1
        if audioDecisions.count > 4_000 {
            audioDecisions.removeFirst(audioDecisions.count - 4_000)
        }
        if !decision.shouldForwardToASR && decision.reason == "below_floor" {
            rejectedLowEnergyCount += 1
        }
    }

    func recordNativeSpeechDetectorObservation(source: TranscriptAudioSource, speechDetected: Bool) {
        recordAudioDecision(VoiceActivityDecision(
            source: source,
            detectionEngine: .appleSpeechDetector,
            state: speechDetected ? .speechActive : .noise,
            shouldForwardToASR: speechDetected,
            speechProbability: speechDetected ? 0.92 : 0.04,
            rms: 0,
            peak: 0,
            noiseFloor: 0,
            snrDb: 0,
            zeroCrossingRate: 0,
            dynamicRange: 0,
            envelopeVariation: 0,
            isClipping: false,
            reason: speechDetected ? "speech_detector_speech" : "speech_detector_non_speech"
        ))
    }

    func recordSegment(_ segment: TranscriptSegment, firstAudioAt: Date? = nil) {
        if !segment.isFinal {
            if let firstAudioAt {
                firstPartialLatencies.append(segment.createdAt.timeIntervalSince(firstAudioAt) * 1_000)
            } else if let latency = segment.latencyMs {
                firstPartialLatencies.append(latency)
            }
        } else if let latency = segment.latencyMs {
            finalStabilizationLatencies.append(latency)
        }

        if segment.retentionReason == .overlapDeduplicated {
            duplicateOrTailCount += 1
        }
        if segment.transcriptionPhase == .refined || segment.finalizedBy == .whisperKit {
            refinedSegmentCount += 1
            if segment.retentionReason == .localRefinerAccepted {
                acceptedRefinementCount += 1
            }
        }
        if (segment.audioEnergy ?? 1) < 0.0004 && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            silenceFalsePositiveCount += 1
        }
    }

    func recordMergeDecision(_ decision: TranscriptSegmentMerger.Decision) {
        switch decision {
        case .ignore:
            duplicateOrTailCount += 1
        case .replace(_, _, let tail) where tail != nil:
            duplicateOrTailCount += 1
        case .append, .replace:
            break
        }
    }

    func recordNativeSpeechDetectorDrop() {
        nativeSpeechDetectorDropCount += 1
    }

    func recordBenchmarkCases(_ cases: [TranscriptionBenchmarkCase]) {
        benchmarkResults = TranscriptionBenchmarkSuite().evaluate(cases)
    }

    func snapshot() -> TranscriptionMetricsSnapshot {
        let nonSpeechDecisions = audioDecisions.filter { $0.state == .silence || $0.state == .noise }
        let vadFalseForwards = nonSpeechDecisions.filter(\.shouldForwardToASR).count
        let falseSpeechEvents = vadFalseForwards + silenceFalsePositiveCount
        let falseSpeechDenominator = nonSpeechDecisions.count + silenceFalsePositiveCount
        let falseSpeechRate = falseSpeechDenominator == 0 ? 0 : Double(falseSpeechEvents) / Double(falseSpeechDenominator)
        return TranscriptionMetricsSnapshot(
            firstPartialLatency: Self.summary(firstPartialLatencies),
            finalStabilizationLatency: Self.summary(finalStabilizationLatencies),
            falseSpeechRate: falseSpeechRate,
            silenceFalsePositiveCount: silenceFalsePositiveCount,
            duplicateOrTailCount: duplicateOrTailCount,
            rejectedLowEnergyCount: rejectedLowEnergyCount,
            refinedSegmentCount: refinedSegmentCount,
            acceptedRefinementCount: acceptedRefinementCount,
            nativeSpeechDetectorDropCount: nativeSpeechDetectorDropCount,
            voiceActivityDetectionEngineCounts: voiceActivityDetectionEngineCounts.reduce(into: [:]) { partial, element in
                partial[element.key.rawValue] = element.value
            },
            memoryResidentBytes: Self.memoryResidentBytes(),
            cpuUsagePercent: Self.cpuUsagePercent(),
            benchmarkResults: benchmarkResults,
            benchmarkSummary: TranscriptionBenchmarkSuite().summarize(benchmarkResults)
        )
    }

    private static func summary(_ values: [Double]) -> TranscriptionLatencySummary {
        guard !values.isEmpty else {
            return TranscriptionLatencySummary(p50: nil, p95: nil, p99: nil)
        }
        let sorted = values.sorted()
        return TranscriptionLatencySummary(
            p50: percentile(sorted, percentile: 0.50),
            p95: percentile(sorted, percentile: 0.95),
            p99: percentile(sorted, percentile: 0.99)
        )
    }

    private static func percentile(_ sorted: [Double], percentile: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * percentile)) - 1))
        return sorted[index]
    }

    private static func memoryResidentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }

    private static func cpuUsagePercent() -> Double? {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threadList else { return nil }
        defer {
            let byteCount = vm_size_t(Int(threadCount) * MemoryLayout<thread_act_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), byteCount)
        }

        var total: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size) / 4
            let infoResult = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard infoResult == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 else { continue }
            total += (Double(info.cpu_usage) / Double(TH_USAGE_SCALE)) * 100
        }
        return total.isFinite ? max(0, total) : nil
    }
}
