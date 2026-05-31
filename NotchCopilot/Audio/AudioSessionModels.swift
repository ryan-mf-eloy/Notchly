import AVFoundation
import CoreMedia
import Foundation

struct AudioBuffer: @unchecked Sendable {
    var pcmBuffer: AVAudioPCMBuffer?
    var time: AVAudioTime?
    var mediaTime: CMTime?
    var rms: Float
    var peak: Float
    var createdAt: Date
    var audioSource: TranscriptAudioSource

    static func silence() -> AudioBuffer {
        AudioBuffer(pcmBuffer: nil, time: nil, rms: 0, peak: 0, createdAt: Date())
    }

    init(
        pcmBuffer: AVAudioPCMBuffer?,
        time: AVAudioTime?,
        mediaTime: CMTime? = nil,
        rms: Float,
        peak: Float,
        createdAt: Date,
        audioSource: TranscriptAudioSource = .unknown
    ) {
        self.pcmBuffer = pcmBuffer
        self.time = time
        self.mediaTime = mediaTime
        self.rms = rms
        self.peak = peak
        self.createdAt = createdAt
        self.audioSource = audioSource
    }
}

enum AudioConditioningTarget: Sendable, Hashable {
    case nativeSpeech
    case cloudRealtime
}

struct AudioConditioningConfig: Sendable, Hashable {
    var accuracyMode: TranscriptionAccuracyMode
    var target: AudioConditioningTarget
    var audioSource: TranscriptAudioSource

    init(
        accuracyMode: TranscriptionAccuracyMode,
        target: AudioConditioningTarget,
        audioSource: TranscriptAudioSource
    ) {
        self.accuracyMode = accuracyMode
        self.target = target
        self.audioSource = audioSource
    }

    var targetSampleRate: Double? {
        target == .cloudRealtime ? Double(CloudPCM16AudioEncoder.elevenLabsSampleRate) : nil
    }

    var targetChannelCount: AVAudioChannelCount? {
        target == .cloudRealtime ? 1 : nil
    }

    var shouldNormalizeGain: Bool {
        accuracyMode == .highAccuracy && audioSource != .system
    }
}

struct AudioConditioningResult: Sendable {
    var buffer: AudioBuffer
    var quality: SpeechAudioQualitySnapshot
    var activity: SpeechActivityLevel
    var appliedGain: Float
    var convertedFormat: Bool
}

struct AudioConditioningPipeline: Sendable {
    private var monitor: SpeechAudioQualityMonitor
    private var activityPolicy = SpeechActivityPolicy()
    private let analyzer = AppleAccelerateAudioAnalyzer()

    init(source: TranscriptAudioSource) {
        self.monitor = SpeechAudioQualityMonitor(source: source)
    }

    mutating func condition(_ input: AudioBuffer, config: AudioConditioningConfig) -> AudioConditioningResult {
        var output = input
        output.audioSource = input.audioSource == .unknown ? config.audioSource : input.audioSource
        var appliedGain: Float = 1
        var convertedFormat = false

        if config.accuracyMode == .highAccuracy,
           let pcmBuffer = input.pcmBuffer,
           let conditioned = Self.conditionedPCMBuffer(from: pcmBuffer, config: config, appliedGain: &appliedGain, convertedFormat: &convertedFormat) {
            let result = analyzer.analyze(conditioned)
            output.pcmBuffer = conditioned
            output.rms = result.rms
            output.peak = result.peak
        }

        let snapshot = monitor.ingest(output)
        return AudioConditioningResult(
            buffer: output,
            quality: snapshot,
            activity: activityPolicy.classify(snapshot),
            appliedGain: appliedGain,
            convertedFormat: convertedFormat
        )
    }

    private static func conditionedPCMBuffer(
        from buffer: AVAudioPCMBuffer,
        config: AudioConditioningConfig,
        appliedGain: inout Float,
        convertedFormat: inout Bool
    ) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return buffer.copiedForAsyncUse() }

        let targetSampleRate = config.targetSampleRate ?? buffer.format.sampleRate
        let targetChannels = config.targetChannelCount ?? buffer.format.channelCount
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            return buffer.copiedForAsyncUse()
        }

        let workingBuffer: AVAudioPCMBuffer
        if formatsMatch(buffer.format, targetFormat) {
            workingBuffer = buffer.copiedForAsyncUse() ?? buffer
        } else if let converted = convert(buffer, to: targetFormat) {
            workingBuffer = converted
            convertedFormat = true
        } else {
            workingBuffer = buffer.copiedForAsyncUse() ?? buffer
        }

        guard config.shouldNormalizeGain,
              let channelData = workingBuffer.floatChannelData else {
            return workingBuffer
        }

        let frameCount = Int(workingBuffer.frameLength)
        let channelCount = Int(workingBuffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return workingBuffer }

        let metrics = amplitudeMetrics(channelData: channelData, channels: channelCount, frames: frameCount)
        let targetRMS: Float = config.target == .cloudRealtime ? 0.052 : 0.045
        let minimumRMS: Float = 0.0006
        let maxGain: Float = config.target == .cloudRealtime ? 5.0 : 3.5
        let clippingCeiling: Float = 0.92
        var gain: Float = 1
        if metrics.rms >= minimumRMS {
            gain = min(maxGain, max(1, targetRMS / metrics.rms))
            if metrics.peak > 0 {
                gain = min(gain, clippingCeiling / metrics.peak)
            }
        }
        gain = max(0.25, gain)
        appliedGain = gain

        guard abs(gain - 1) > 0.015 else { return workingBuffer }
        for channelIndex in 0..<channelCount {
            let channel = channelData[channelIndex]
            for frameIndex in 0..<frameCount {
                channel[frameIndex] = max(-clippingCeiling, min(clippingCeiling, channel[frameIndex] * gain))
            }
        }
        return workingBuffer
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
        let ratio = targetFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(max(1, Int((Double(buffer.frameLength) * ratio).rounded(.up)) + 16))
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        let state = AudioConditioningConverterInputState(buffer: buffer)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if state.didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            state.didProvideInput = true
            status.pointee = .haveData
            return state.buffer
        }
        return error == nil ? converted : nil
    }

    private static func amplitudeMetrics(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channels: Int,
        frames: Int
    ) -> (rms: Float, peak: Float) {
        var squareSum: Float = 0
        var peak: Float = 0
        for channelIndex in 0..<channels {
            let channel = channelData[channelIndex]
            for frameIndex in 0..<frames {
                let value = channel[frameIndex]
                squareSum += value * value
                peak = max(peak, abs(value))
            }
        }
        let sampleCount = max(1, channels * frames)
        return (sqrt(squareSum / Float(sampleCount)), min(max(peak, 0), 1))
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate &&
            lhs.channelCount == rhs.channelCount &&
            lhs.commonFormat == rhs.commonFormat &&
            lhs.isInterleaved == rhs.isInterleaved
    }
}

final class AudioConditioningStreamProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline: AudioConditioningPipeline

    init(source: TranscriptAudioSource) {
        self.pipeline = AudioConditioningPipeline(source: source)
    }

    func condition(_ buffer: AudioBuffer, config: AudioConditioningConfig) -> AudioConditioningResult {
        lock.lock()
        let result = pipeline.condition(buffer, config: config)
        lock.unlock()
        return result
    }
}

private final class AudioConditioningConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

enum AppleNativeSpeechBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case speechAnalyzer
    case dictationTranscriber
    case sfSpeechRecognizer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speechAnalyzer:
            return "SpeechAnalyzer"
        case .dictationTranscriber:
            return "DictationTranscriber"
        case .sfSpeechRecognizer:
            return "Apple Speech"
        }
    }

    var transcriptionEngineName: TranscriptionEngineName {
        switch self {
        case .speechAnalyzer: .speechAnalyzer
        case .dictationTranscriber: .dictationTranscriber
        case .sfSpeechRecognizer: .appleSpeech
        }
    }
}

enum SpeechAssetStatus: Equatable, Sendable {
    case ready
    case preparing(progress: Double?)
    case unsupportedLanguage
    case fallbackActive
    case failed(String)

    var displayName: String {
        switch self {
        case .ready:
            return "Apple Speech ready"
        case .preparing(let progress):
            if let progress {
                return "Preparing speech assets \(Int((progress * 100).rounded()))%"
            }
            return "Preparing speech assets"
        case .unsupportedLanguage:
            return "Apple Speech unavailable for language"
        case .fallbackActive:
            return "Using SFSpeech fallback"
        case .failed(let message):
            return message
        }
    }
}

struct SpeechAudioQualitySnapshot: Equatable, Sendable {
    var source: TranscriptAudioSource
    var rms: Float
    var peak: Float
    var isClipping: Bool
    var isTooQuiet: Bool
    var noiseFloor: Float
    var gapCount: Int
    var lastAudioAt: Date?
    var sampleRate: Double?
    var channelCount: Int?
    var deviceChanged: Bool

    init(
        source: TranscriptAudioSource,
        rms: Float,
        peak: Float,
        isClipping: Bool,
        isTooQuiet: Bool,
        noiseFloor: Float,
        gapCount: Int,
        lastAudioAt: Date?,
        sampleRate: Double? = nil,
        channelCount: Int? = nil,
        deviceChanged: Bool = false
    ) {
        self.source = source
        self.rms = rms
        self.peak = peak
        self.isClipping = isClipping
        self.isTooQuiet = isTooQuiet
        self.noiseFloor = noiseFloor
        self.gapCount = gapCount
        self.lastAudioAt = lastAudioAt
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.deviceChanged = deviceChanged
    }
}

struct SpeechAudioQualityMonitor: Sendable {
    private(set) var source: TranscriptAudioSource
    private(set) var noiseFloor: Float = 0
    private(set) var gapCount = 0
    private(set) var lastAudioAt: Date?
    private(set) var lastBufferAt: Date?
    private(set) var lastSampleRate: Double?
    private(set) var lastChannelCount: Int?
    private(set) var deviceChangeCount = 0
    private(set) var lastSnapshot: SpeechAudioQualitySnapshot

    init(source: TranscriptAudioSource) {
        self.source = source
        self.lastSnapshot = SpeechAudioQualitySnapshot(
            source: source,
            rms: 0,
            peak: 0,
            isClipping: false,
            isTooQuiet: true,
            noiseFloor: 0,
            gapCount: 0,
            lastAudioAt: nil
        )
    }

    mutating func ingest(_ buffer: AudioBuffer) -> SpeechAudioQualitySnapshot {
        let now = buffer.createdAt
        if let lastBufferAt, now.timeIntervalSince(lastBufferAt) > 0.28 {
            gapCount += 1
        }
        lastBufferAt = now

        let sampleRate = buffer.pcmBuffer?.format.sampleRate
        let channelCount = buffer.pcmBuffer.map { Int($0.format.channelCount) }
        let deviceChanged = (lastSampleRate != nil && sampleRate != nil && lastSampleRate != sampleRate) ||
            (lastChannelCount != nil && channelCount != nil && lastChannelCount != channelCount)
        if deviceChanged {
            deviceChangeCount += 1
        }
        if let sampleRate {
            lastSampleRate = sampleRate
        }
        if let channelCount {
            lastChannelCount = channelCount
        }

        if buffer.rms > 0.002 {
            lastAudioAt = now
        }

        if noiseFloor == 0 {
            noiseFloor = buffer.rms
        } else if buffer.rms < 0.012 {
            noiseFloor = noiseFloor * 0.94 + buffer.rms * 0.06
        }

        let snapshot = SpeechAudioQualitySnapshot(
            source: buffer.audioSource == .unknown ? source : buffer.audioSource,
            rms: buffer.rms,
            peak: buffer.peak,
            isClipping: buffer.peak >= 0.98,
            isTooQuiet: buffer.rms < 0.0018,
            noiseFloor: noiseFloor,
            gapCount: gapCount,
            lastAudioAt: lastAudioAt,
            sampleRate: sampleRate,
            channelCount: channelCount,
            deviceChanged: deviceChanged
        )
        lastSnapshot = snapshot
        return snapshot
    }
}

enum SpeechActivityLevel: String, Sendable, Equatable {
    case silence
    case lowAudio
    case speechLikely
    case speechActive

    var isSignificant: Bool {
        self == .speechLikely || self == .speechActive
    }
}

struct SpeechActivityPolicy: Sendable, Equatable {
    var preRollDuration: TimeInterval = 1.2
    var hangoverDuration: TimeInterval = 1.5
    var absoluteSpeechRMS: Float = 0.0012
    var likelySpeechRMS: Float = 0.0020
    var activeSpeechRMS: Float = 0.0060
    var peakAssistThreshold: Float = 0.018
    var noiseFloorLift: Float = 2.4

    func classify(_ snapshot: SpeechAudioQualitySnapshot) -> SpeechActivityLevel {
        let rms = max(snapshot.rms, 0)
        let peak = max(snapshot.peak, 0)
        let adaptiveLikely = max(absoluteSpeechRMS, snapshot.noiseFloor * noiseFloorLift)
        if rms >= max(activeSpeechRMS, adaptiveLikely * 1.8) || peak >= 0.08 {
            return .speechActive
        }
        if rms >= max(likelySpeechRMS, adaptiveLikely) || peak >= peakAssistThreshold {
            return .speechLikely
        }
        if rms >= max(absoluteSpeechRMS * 0.45, snapshot.noiseFloor * 1.35) {
            return .lowAudio
        }
        return .silence
    }

    func isWithinHangover(now: Date, lastSignificantAudioAt: Date) -> Bool {
        now.timeIntervalSince(lastSignificantAudioAt) <= hangoverDuration
    }
}

enum AppleSpeechWindowStartReason: String, Sendable, Equatable {
    case initial
    case audioActivity
    case watchdogRestart
    case scheduledRotation
    case languageSwitch
}

struct AppleSpeechWindowStart: Sendable, Equatable {
    var id: UUID
    var startedAt: Date
    var reason: AppleSpeechWindowStartReason
    var preservesSegment: Bool
}

struct AppleSpeechWindowController: Sendable, Equatable {
    private(set) var activeWindowId = UUID()
    private(set) var activeWindowStartedAt = Date.distantPast
    private(set) var parkedUntil = Date.distantPast
    var startCooldown: TimeInterval = 0.85

    mutating func reset() {
        activeWindowId = UUID()
        activeWindowStartedAt = .distantPast
        parkedUntil = .distantPast
    }

    func canStartFromAudio(now: Date) -> Bool {
        now >= parkedUntil && now.timeIntervalSince(activeWindowStartedAt) >= startCooldown
    }

    mutating func begin(
        reason: AppleSpeechWindowStartReason,
        now: Date,
        preservesSegment: Bool
    ) -> AppleSpeechWindowStart {
        activeWindowId = UUID()
        activeWindowStartedAt = now
        parkedUntil = .distantPast
        return AppleSpeechWindowStart(
            id: activeWindowId,
            startedAt: now,
            reason: reason,
            preservesSegment: preservesSegment
        )
    }

    mutating func park(until date: Date) {
        parkedUntil = date
    }
}

struct SpeechAudioTimelineClock: Sendable, Equatable {
    private(set) var firstMediaTime: CMTime?
    private(set) var firstSampleTime: AVAudioFramePosition?
    private(set) var elapsedTime: CMTime = .zero
    private(set) var lastStartTime: CMTime?

    private let timescale: CMTimeScale = 1_000_000

    mutating func nextStartTime(for buffer: AudioBuffer, convertedBuffer: AVAudioPCMBuffer?) -> CMTime {
        let pcmBuffer = convertedBuffer ?? buffer.pcmBuffer
        let duration = Self.duration(for: pcmBuffer, timescale: timescale)
        var candidate = candidateStartTime(for: buffer, sampleRate: pcmBuffer?.format.sampleRate)

        if Self.compare(candidate, elapsedTime) < 0 {
            candidate = elapsedTime
        }
        if let lastStartTime, Self.compare(candidate, lastStartTime) <= 0, Self.compare(elapsedTime, candidate) > 0 {
            candidate = elapsedTime
        }
        if !candidate.isValid || candidate.secondsValue < 0 {
            candidate = elapsedTime
        }

        lastStartTime = candidate
        elapsedTime = Self.max(candidate + duration, elapsedTime + Self.minimumTick(timescale: timescale))
        return candidate
    }

    mutating func reset() {
        firstMediaTime = nil
        firstSampleTime = nil
        elapsedTime = .zero
        lastStartTime = nil
    }

    private mutating func candidateStartTime(for buffer: AudioBuffer, sampleRate: Double?) -> CMTime {
        if let mediaTime = buffer.mediaTime, mediaTime.isValid {
            if firstMediaTime == nil {
                firstMediaTime = mediaTime
            }
            if let firstMediaTime {
                return Self.max(.zero, CMTimeSubtract(mediaTime, firstMediaTime))
            }
        }

        if let audioTime = buffer.time,
           audioTime.isSampleTimeValid,
           let sampleRate = sampleRate ?? Optional(audioTime.sampleRate),
           sampleRate > 0 {
            if firstSampleTime == nil {
                firstSampleTime = audioTime.sampleTime
            }
            if let firstSampleTime {
                let deltaFrames = Swift.max(0, audioTime.sampleTime - firstSampleTime)
                return CMTime(seconds: Double(deltaFrames) / sampleRate, preferredTimescale: timescale)
            }
        }

        return elapsedTime
    }

    private static func duration(for buffer: AVAudioPCMBuffer?, timescale: CMTimeScale) -> CMTime {
        guard let buffer, buffer.format.sampleRate > 0, buffer.frameLength > 0 else {
            return minimumTick(timescale: timescale)
        }
        return CMTime(seconds: Double(buffer.frameLength) / buffer.format.sampleRate, preferredTimescale: timescale)
    }

    private static func minimumTick(timescale: CMTimeScale) -> CMTime {
        CMTime(value: 1, timescale: timescale)
    }

    private static func max(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        compare(lhs, rhs) >= 0 ? lhs : rhs
    }

    private static func compare(_ lhs: CMTime, _ rhs: CMTime) -> Int32 {
        CMTimeCompare(lhs, rhs)
    }
}

private extension CMTime {
    static func + (lhs: CMTime, rhs: CMTime) -> CMTime {
        CMTimeAdd(lhs, rhs)
    }

    var secondsValue: Double {
        let value = CMTimeGetSeconds(self)
        return value.isFinite ? value : 0
    }
}

struct SpeechAnalyzerRangeReconciler: Sendable, Equatable {
    private struct Record: Sendable, Equatable {
        var key: SpeechAnalyzerRangeKey
        var id: UUID
        var isFinal: Bool
    }

    private var records: [Record] = []
    private let maxRecords: Int

    init(maxRecords: Int = 160) {
        self.maxRecords = maxRecords
    }

    mutating func segmentID(for range: CMTimeRange, audioSource: TranscriptAudioSource, isFinal: Bool) -> UUID {
        let key = SpeechAnalyzerRangeKey(range: range, audioSource: audioSource)
        if let index = records.firstIndex(where: { $0.key == key }) {
            records[index].isFinal = records[index].isFinal || isFinal
            return records[index].id
        }

        if let index = bestOverlappingRecordIndex(for: key, isFinal: isFinal) {
            let id = records[index].id
            records[index] = Record(key: key, id: id, isFinal: records[index].isFinal || isFinal)
            pruneIfNeeded()
            return id
        }

        let id = UUID()
        records.append(Record(key: key, id: id, isFinal: isFinal))
        pruneIfNeeded()
        return id
    }

    mutating func reset() {
        records.removeAll()
    }

    private func bestOverlappingRecordIndex(for key: SpeechAnalyzerRangeKey, isFinal: Bool) -> Int? {
        let threshold = isFinal ? 0.25 : 0.60
        return records.indices
            .filter { records[$0].key.audioSource == key.audioSource }
            .map { index in (index, records[index].key.overlapRatio(with: key)) }
            .filter { $0.1 >= threshold }
            .max { $0.1 < $1.1 }?
            .0
    }

    private mutating func pruneIfNeeded() {
        guard records.count > maxRecords else { return }
        records.sort { lhs, rhs in
            if lhs.key.startMilliseconds == rhs.key.startMilliseconds {
                return lhs.key.endMilliseconds < rhs.key.endMilliseconds
            }
            return lhs.key.startMilliseconds < rhs.key.startMilliseconds
        }
        records.removeFirst(records.count - maxRecords)
    }
}

struct SpeechAnalyzerRangeKey: Hashable, Comparable, Sendable {
    var audioSource: TranscriptAudioSource
    var startMilliseconds: Int64
    var endMilliseconds: Int64

    init(range: CMTimeRange, audioSource: TranscriptAudioSource) {
        self.audioSource = audioSource
        self.startMilliseconds = Int64((range.start.secondsValue * 1_000).rounded())
        self.endMilliseconds = Int64((CMTimeRangeGetEnd(range).secondsValue * 1_000).rounded())
    }

    static func < (lhs: SpeechAnalyzerRangeKey, rhs: SpeechAnalyzerRangeKey) -> Bool {
        if lhs.startMilliseconds == rhs.startMilliseconds {
            return lhs.endMilliseconds < rhs.endMilliseconds
        }
        return lhs.startMilliseconds < rhs.startMilliseconds
    }

    func overlapRatio(with other: SpeechAnalyzerRangeKey) -> Double {
        guard audioSource == other.audioSource else { return 0 }
        let overlapStart = max(startMilliseconds, other.startMilliseconds)
        let overlapEnd = min(endMilliseconds, other.endMilliseconds)
        let overlap = max(0, overlapEnd - overlapStart)
        let ownDuration = max(1, endMilliseconds - startMilliseconds)
        let otherDuration = max(1, other.endMilliseconds - other.startMilliseconds)
        return Double(overlap) / Double(min(ownDuration, otherDuration))
    }
}

struct SpeechRecognitionWatchdogPolicy: Sendable, Equatable {
    var significantAudioRMS: Float = 0.0012
    var significantAudioWindow: TimeInterval = 5
    var noSegmentWindow: TimeInterval = 4
    var minimumRestartInterval: TimeInterval = 2

    func shouldRestart(
        now: Date,
        lastSignificantAudioAt: Date,
        lastSegmentAt: Date,
        lastRestartAt: Date
    ) -> Bool {
        guard now.timeIntervalSince(lastSignificantAudioAt) <= significantAudioWindow else { return false }
        guard now.timeIntervalSince(lastSegmentAt) >= noSegmentWindow else { return false }
        guard now.timeIntervalSince(lastRestartAt) >= minimumRestartInterval else { return false }
        return true
    }
}

struct AppleSpeechSegmentAssembler: Sendable, Equatable {
    private(set) var lastSegment: TranscriptSegment?

    mutating func reset() {
        lastSegment = nil
    }

    mutating func assemble(_ incoming: TranscriptSegment) -> TranscriptSegment? {
        guard let previous = lastSegment else {
            lastSegment = incoming
            return incoming
        }

        guard previous.audioSource == incoming.audioSource else {
            lastSegment = incoming
            return incoming
        }

        if previous.id == incoming.id {
            if shouldIgnoreShorterDraft(previous: previous, incoming: incoming) {
                return nil
            }
            if shouldPreserveLongerDraft(previous: previous, incoming: incoming) {
                var preserved = previous
                preserved.isFinal = incoming.isFinal
                preserved.transcriptionPhase = incoming.transcriptionPhase
                preserved.finalizedBy = incoming.finalizedBy
                preserved.engineConfidence = max(previous.engineConfidence ?? 0, incoming.engineConfidence ?? 0)
                preserved.confidence = max(previous.confidence, incoming.confidence)
                preserved.endTime = max(previous.endTime, incoming.endTime)
                preserved.sourceFrameRange = mergedRange(previous.sourceFrameRange, incoming.sourceFrameRange)
                preserved.revisionNumber = max(previous.revisionNumber, incoming.revisionNumber) + 1
                lastSegment = preserved
                return preserved
            }
        }

        lastSegment = incoming
        return incoming
    }

    private func shouldIgnoreShorterDraft(previous: TranscriptSegment, incoming: TranscriptSegment) -> Bool {
        guard !incoming.isFinal else { return false }
        let previousText = normalized(previous.text)
        let incomingText = normalized(incoming.text)
        return previousText.count > incomingText.count + 8 && previousText.hasPrefix(incomingText)
    }

    private func shouldPreserveLongerDraft(previous: TranscriptSegment, incoming: TranscriptSegment) -> Bool {
        guard incoming.isFinal, !previous.isFinal else { return false }
        let previousText = normalized(previous.text)
        let incomingText = normalized(incoming.text)
        guard previousText.count > incomingText.count + 8 else { return false }
        return previousText.hasPrefix(incomingText) || previousText.contains(incomingText)
    }

    private func normalized(_ text: String) -> String {
        text
            .lowercased()
            .folding(options: [.diacriticInsensitive], locale: .current)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func mergedRange(_ lhs: AudioSourceFrameRange?, _ rhs: AudioSourceFrameRange?) -> AudioSourceFrameRange? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            return AudioSourceFrameRange(start: min(lhs.start, rhs.start), end: max(lhs.end, rhs.end))
        case let (.some(range), .none), let (.none, .some(range)):
            return range
        case (.none, .none):
            return nil
        }
    }
}

struct TranscriptionBenchmarkCase: Codable, Hashable, Sendable {
    var id: String
    var audioFilePath: String?
    var reference: String
    var hypothesis: String
    var locale: String
    var activeVocabulary: [String]
    var firstPartialLatencyMs: Double?
    var finalLatencyMs: Double?
    var gapCount: Int
    var duplicateCount: Int

    init(
        id: String,
        audioFilePath: String? = nil,
        reference: String,
        hypothesis: String,
        locale: String,
        activeVocabulary: [String] = [],
        firstPartialLatencyMs: Double? = nil,
        finalLatencyMs: Double? = nil,
        gapCount: Int = 0,
        duplicateCount: Int = 0
    ) {
        self.id = id
        self.audioFilePath = audioFilePath
        self.reference = reference
        self.hypothesis = hypothesis
        self.locale = locale
        self.activeVocabulary = activeVocabulary
        self.firstPartialLatencyMs = firstPartialLatencyMs
        self.finalLatencyMs = finalLatencyMs
        self.gapCount = gapCount
        self.duplicateCount = duplicateCount
    }
}

struct TranscriptionBenchmarkResult: Codable, Hashable, Sendable {
    var id: String
    var locale: String
    var wordErrorRate: Double
    var characterErrorRate: Double
    var vocabularyRecognitionRate: Double
    var firstPartialLatencyMs: Double?
    var finalLatencyMs: Double?
    var gapCount: Int
    var duplicateCount: Int
}

struct TranscriptionBenchmarkSuite: Sendable {
    func evaluate(_ cases: [TranscriptionBenchmarkCase]) -> [TranscriptionBenchmarkResult] {
        cases.map { testCase in
            TranscriptionBenchmarkResult(
                id: testCase.id,
                locale: testCase.locale,
                wordErrorRate: Self.wordErrorRate(reference: testCase.reference, hypothesis: testCase.hypothesis),
                characterErrorRate: Self.characterErrorRate(reference: testCase.reference, hypothesis: testCase.hypothesis),
                vocabularyRecognitionRate: Self.vocabularyRecognitionRate(
                    terms: testCase.activeVocabulary,
                    hypothesis: testCase.hypothesis,
                    locale: testCase.locale
                ),
                firstPartialLatencyMs: testCase.firstPartialLatencyMs,
                finalLatencyMs: testCase.finalLatencyMs,
                gapCount: testCase.gapCount,
                duplicateCount: testCase.duplicateCount
            )
        }
    }

    func jsonReport(for cases: [TranscriptionBenchmarkCase]) throws -> Data {
        try JSONEncoder.prettyBenchmarkEncoder.encode(evaluate(cases))
    }

    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let referenceWords = normalizedTokens(reference)
        let hypothesisWords = normalizedTokens(hypothesis)
        guard !referenceWords.isEmpty else { return hypothesisWords.isEmpty ? 0 : 1 }
        return Double(editDistance(referenceWords, hypothesisWords)) / Double(referenceWords.count)
    }

    static func characterErrorRate(reference: String, hypothesis: String) -> Double {
        let referenceCharacters = Array(normalizedText(reference))
        let hypothesisCharacters = Array(normalizedText(hypothesis))
        guard !referenceCharacters.isEmpty else { return hypothesisCharacters.isEmpty ? 0 : 1 }
        return Double(editDistance(referenceCharacters, hypothesisCharacters)) / Double(referenceCharacters.count)
    }

    static func vocabularyRecognitionRate(terms: [String], hypothesis: String, locale: String?) -> Double {
        let activeTerms = terms
            .map { SpeechVocabularyTerm.normalizedKey($0, locale: locale) }
            .filter { !$0.isEmpty }
            .deduplicatedNormalizedStrings()
        guard !activeTerms.isEmpty else { return 1 }
        let normalizedHypothesis = SpeechVocabularyTerm.normalizedKey(hypothesis, locale: locale)
        let recognized = activeTerms.filter { normalizedHypothesis.contains($0) }.count
        return Double(recognized) / Double(activeTerms.count)
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        normalizedText(text)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func normalizedText(_ text: String) -> String {
        SpeechVocabularyTerm.normalizedKey(text)
    }

    private static func editDistance<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)
        for lhsIndex in 1...lhs.count {
            current[0] = lhsIndex
            for rhsIndex in 1...rhs.count {
                let substitution = previous[rhsIndex - 1] + (lhs[lhsIndex - 1] == rhs[rhsIndex - 1] ? 0 : 1)
                current[rhsIndex] = min(previous[rhsIndex] + 1, current[rhsIndex - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}

private extension Array where Element == String {
    func deduplicatedNormalizedStrings() -> [String] {
        var seen = Set<String>()
        return filter { value in
            seen.insert(SpeechVocabularyTerm.normalizedKey(value)).inserted
        }
    }
}

private extension JSONEncoder {
    static var prettyBenchmarkEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

enum AudioCaptureError: LocalizedError {
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case noInputNode
    case audioDeviceUnavailable(String)
    case screenCaptureUnavailable
    case recorderUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: "Microphone permission is required to listen."
        case .systemAudioPermissionDenied: "Screen recording permission is required for system audio capture."
        case .noInputNode: "No microphone input node is available."
        case .audioDeviceUnavailable(let name): "\(name) is not available."
        case .screenCaptureUnavailable: "System audio capture is unavailable on this macOS version."
        case .recorderUnavailable: "Audio recorder is not available."
        }
    }
}

struct TranscriptionConfig: Sendable, Hashable {
    var languageCode: String?
    var requiresOnDeviceRecognition: Bool
    var meetingId: UUID
    var contextualStrings: [String]
    var speechContext: SpeechRecognitionContext?
    var audioSource: TranscriptAudioSource
    var accuracyMode: TranscriptionAccuracyMode
    var commitPolicy: CopilotASRCommitPolicy
    var preferredLanguageHints: [String]
    var sourceSeparationRequired: Bool

    init(
        languageCode: String? = nil,
        requiresOnDeviceRecognition: Bool = false,
        meetingId: UUID,
        contextualStrings: [String] = [],
        speechContext: SpeechRecognitionContext? = nil,
        audioSource: TranscriptAudioSource = .unknown,
        accuracyMode: TranscriptionAccuracyMode = .highAccuracy,
        commitPolicy: CopilotASRCommitPolicy = .accurate,
        preferredLanguageHints: [String] = [],
        sourceSeparationRequired: Bool = false
    ) {
        self.languageCode = languageCode
        self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        self.meetingId = meetingId
        self.contextualStrings = contextualStrings
        self.speechContext = speechContext
        self.audioSource = audioSource
        self.accuracyMode = accuracyMode
        self.commitPolicy = commitPolicy
        self.preferredLanguageHints = Self.normalizedLanguageHints(primary: languageCode, hints: preferredLanguageHints)
        self.sourceSeparationRequired = sourceSeparationRequired
    }

    static func normalizedLanguageHints(primary: String?, hints: [String]) -> [String] {
        var ordered = [String]()
        if let primary {
            ordered.append(primary)
        }
        ordered.append(contentsOf: hints)
        ordered.append(contentsOf: [
            SupportedLanguage.portugueseBR.rawValue,
            SupportedLanguage.englishUS.rawValue,
            SupportedLanguage.spanishES.rawValue,
            SupportedLanguage.japaneseJP.rawValue
        ])
        var seen = Set<String>()
        return ordered
            .map(SupportedLanguage.normalizedCode)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0).inserted }
    }
}

extension AVAudioPCMBuffer {
    func copiedForAsyncUse() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)

        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData else {
                continue
            }
            memcpy(destination, source, Int(min(sourceBuffers[index].mDataByteSize, destinationBuffers[index].mDataByteSize)))
        }

        return copy
    }
}
