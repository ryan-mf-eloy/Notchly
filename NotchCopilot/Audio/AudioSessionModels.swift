import AVFoundation
import CoreMedia
import CryptoKit
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

        if buffer.rms > 0.0012 {
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
            isTooQuiet: buffer.rms < 0.0010,
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
    var preRollDuration: TimeInterval = 1.45
    var hangoverDuration: TimeInterval = 1.9
    var absoluteSpeechRMS: Float = 0.0008
    var likelySpeechRMS: Float = 0.0014
    var activeSpeechRMS: Float = 0.0048
    var peakAssistThreshold: Float = 0.012
    var noiseFloorLift: Float = 1.85

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

struct TranscriptionBenchmarkThresholds: Codable, Hashable, Sendable {
    var maxWordErrorRate: Double
    var maxCharacterErrorRate: Double
    var minVocabularyRecognitionRate: Double
    var minNamedEntityRecognitionRate: Double
    var maxFirstPartialLatencyMs: Double
    var maxFinalLatencyMs: Double
    var maxRealTimeFactor: Double
    var maxLanguageSwitchLatencyMs: Double
    var maxCorrectionChurnCount: Int
    var maxMemoryResidentBytes: UInt64?
    var maxCPUUsagePercent: Double?

    static let `default` = TranscriptionBenchmarkThresholds(
        maxWordErrorRate: 0.18,
        maxCharacterErrorRate: 0.12,
        minVocabularyRecognitionRate: 0.92,
        minNamedEntityRecognitionRate: 0.95,
        maxFirstPartialLatencyMs: 500,
        maxFinalLatencyMs: 1_500,
        maxRealTimeFactor: 1.0,
        maxLanguageSwitchLatencyMs: 1_500,
        maxCorrectionChurnCount: 2,
        maxMemoryResidentBytes: nil,
        maxCPUUsagePercent: nil
    )
}

enum TranscriptionEvaluationCorpus: String, Codable, CaseIterable, Identifiable, Sendable {
    case internalCritical = "internal-critical"
    case privateMeetingPack = "private-meeting-pack"
    case ami
    case fleurs
    case voxLingua107 = "voxlingua107"
    case earnings21 = "earnings21"
    case conec

    var id: String { rawValue }
}

enum TranscriptionEvaluationTag: String, Codable, CaseIterable, Identifiable, Sendable {
    case meeting
    case farField = "far-field"
    case overlap
    case multilingual
    case spokenLanguageID = "spoken-language-id"
    case entityDense = "entity-dense"
    case contextualBias = "contextual-bias"
    case codeSwitching = "code-switching"
    case jargon
    case criticalNonSpeech = "critical-non-speech"
    case silence
    case noise
    case clicks
    case music
    case breathing
    case reverb
    case lowVolume = "low-volume"
    case clipping

    var id: String { rawValue }
}

enum TranscriptionBenchmarkEvidenceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case synthetic
    case generatedFixture = "generated-fixture"
    case recordedFixture = "recorded-fixture"
    case publicCorpus = "public-corpus"
    case privateCorpus = "private-corpus"

    var id: String { rawValue }
}

enum TranscriptionHypothesisSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual
    case deterministicFixture = "deterministic-fixture"
    case evaluationReplay = "evaluation-replay"
    case importedASR = "imported-asr"
    case appleSpeech = "apple-speech"
    case speechAnalyzer = "speech-analyzer"
    case sfSpeech = "sf-speech"
    case whisperKit = "whisperkit"
    case cloudFallback = "cloud-fallback"

    var id: String { rawValue }
}

enum TranscriptionLatencyMeasurementMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case liveCapture = "live-capture"
    case realtimeReplay = "realtime-replay"
    case offlineReplay = "offline-replay"
    case importedTrace = "imported-trace"

    var id: String { rawValue }
}

enum TranscriptionCorpusRecordingOrigin: String, Codable, CaseIterable, Identifiable, Sendable {
    case generatedFixture = "generated-fixture"
    case recordedFixture = "recorded-fixture"
    case publicCorpusSample = "public-corpus-sample"
    case privateMeetingRecording = "private-meeting-recording"

    var id: String { rawValue }
}

struct TranscriptionCorpusProvenance: Codable, Hashable, Sendable {
    var corpus: TranscriptionEvaluationCorpus
    var sampleID: String
    var sourceURI: String
    var datasetVersion: String?
    var license: String?
    var origin: TranscriptionCorpusRecordingOrigin
    var speakerCount: Int?
    var consentVerified: Bool?

    init(
        corpus: TranscriptionEvaluationCorpus,
        sampleID: String,
        sourceURI: String,
        datasetVersion: String? = nil,
        license: String? = nil,
        origin: TranscriptionCorpusRecordingOrigin,
        speakerCount: Int? = nil,
        consentVerified: Bool? = nil
    ) {
        self.corpus = corpus
        self.sampleID = sampleID
        self.sourceURI = sourceURI
        self.datasetVersion = datasetVersion
        self.license = license
        self.origin = origin
        self.speakerCount = speakerCount
        self.consentVerified = consentVerified
    }
}

struct TranscriptionAudioConditioningEvidence: Codable, Hashable, Sendable {
    var audioSource: TranscriptAudioSource
    var conditioningTarget: String
    var advancedConditioningEnabled: Bool
    var vadGatingEnabled: Bool
    var inputBufferCount: Int
    var emittedBufferCount: Int
    var forwardedDecisionCount: Int
    var droppedDecisionCount: Int
    var speechDecisionCount: Int
    var nonSpeechDecisionCount: Int
    var clippingDecisionCount: Int
    var lowEnergyDropCount: Int
    var preRollReplayBufferCount: Int
    var vadEngineCounts: [String: Int]
    var inputSampleRates: [Double]
    var inputChannelCounts: [Int]
    var averageRMS: Float
    var peakMax: Float
    var snrP50Db: Double?
    var snrP95Db: Double?

    init(
        audioSource: TranscriptAudioSource,
        conditioningTarget: String,
        advancedConditioningEnabled: Bool,
        vadGatingEnabled: Bool,
        inputBufferCount: Int,
        emittedBufferCount: Int,
        forwardedDecisionCount: Int,
        droppedDecisionCount: Int,
        speechDecisionCount: Int,
        nonSpeechDecisionCount: Int,
        clippingDecisionCount: Int,
        lowEnergyDropCount: Int,
        preRollReplayBufferCount: Int,
        vadEngineCounts: [String: Int],
        inputSampleRates: [Double],
        inputChannelCounts: [Int],
        averageRMS: Float,
        peakMax: Float,
        snrP50Db: Double? = nil,
        snrP95Db: Double? = nil
    ) {
        self.audioSource = audioSource
        self.conditioningTarget = conditioningTarget
        self.advancedConditioningEnabled = advancedConditioningEnabled
        self.vadGatingEnabled = vadGatingEnabled
        self.inputBufferCount = inputBufferCount
        self.emittedBufferCount = emittedBufferCount
        self.forwardedDecisionCount = forwardedDecisionCount
        self.droppedDecisionCount = droppedDecisionCount
        self.speechDecisionCount = speechDecisionCount
        self.nonSpeechDecisionCount = nonSpeechDecisionCount
        self.clippingDecisionCount = clippingDecisionCount
        self.lowEnergyDropCount = lowEnergyDropCount
        self.preRollReplayBufferCount = preRollReplayBufferCount
        self.vadEngineCounts = vadEngineCounts
        self.inputSampleRates = inputSampleRates
        self.inputChannelCounts = inputChannelCounts
        self.averageRMS = averageRMS
        self.peakMax = peakMax
        self.snrP50Db = snrP50Db
        self.snrP95Db = snrP95Db
    }
}

struct TranscriptionHypothesisTranscriptEvidence: Codable, Hashable, Sendable {
    struct SegmentEvidence: Codable, Hashable, Sendable {
        var text: String
        var audioSource: TranscriptAudioSource
        var speakerLabel: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var isFinal: Bool
        var transcriptionPhase: TranscriptionPhase?
        var transcriptionEngine: TranscriptionEngineName?
        var finalizedBy: TranscriptionEngineName?
        var confidence: Double
        var engineConfidence: Double?
        var languageCode: String?
        var languageConfidence: Double?
        var languageEvidenceSource: String?
        var languageDetectionWindowMs: Double?
        var languageSpanCodes: [String]?
        var revisionOfSegmentId: UUID?
        var revisionNumber: Int
        var retentionReason: TranscriptionRetentionReason?
        var sourceFrameRange: AudioSourceFrameRange?
        var wordTimestampCount: Int

        init(
            text: String,
            audioSource: TranscriptAudioSource,
            speakerLabel: String,
            startTime: TimeInterval,
            endTime: TimeInterval,
            isFinal: Bool,
            transcriptionPhase: TranscriptionPhase? = nil,
            transcriptionEngine: TranscriptionEngineName? = nil,
            finalizedBy: TranscriptionEngineName? = nil,
            confidence: Double,
            engineConfidence: Double? = nil,
            languageCode: String? = nil,
            languageConfidence: Double? = nil,
            languageEvidenceSource: String? = nil,
            languageDetectionWindowMs: Double? = nil,
            languageSpanCodes: [String]? = nil,
            revisionOfSegmentId: UUID? = nil,
            revisionNumber: Int = 0,
            retentionReason: TranscriptionRetentionReason? = nil,
            sourceFrameRange: AudioSourceFrameRange? = nil,
            wordTimestampCount: Int = 0
        ) {
            self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.audioSource = audioSource
            self.speakerLabel = speakerLabel
            self.startTime = startTime
            self.endTime = endTime
            self.isFinal = isFinal
            self.transcriptionPhase = transcriptionPhase
            self.transcriptionEngine = transcriptionEngine
            self.finalizedBy = finalizedBy
            self.confidence = confidence
            self.engineConfidence = engineConfidence
            self.languageCode = languageCode
            self.languageConfidence = languageConfidence
            self.languageEvidenceSource = languageEvidenceSource
            self.languageDetectionWindowMs = languageDetectionWindowMs
            self.languageSpanCodes = languageSpanCodes
            self.revisionOfSegmentId = revisionOfSegmentId
            self.revisionNumber = revisionNumber
            self.retentionReason = retentionReason
            self.sourceFrameRange = sourceFrameRange
            self.wordTimestampCount = wordTimestampCount
        }
    }

    var caseID: String
    var hypothesis: String
    var source: TranscriptionHypothesisSource
    var engineIdentifier: String?
    var runID: String?
    var locale: String?
    var segmentCount: Int?
    var segments: [SegmentEvidence]?
    var audioSHA256: String?
    var audioDurationMs: Double?
    var audioConditioning: TranscriptionAudioConditioningEvidence?
    var latencyMeasurementMode: TranscriptionLatencyMeasurementMode?
    var replayChunkDurationMs: Double?
    var postAudioDrainMs: Double?
    var generatedAt: String?
    var corpusProvenance: TranscriptionCorpusProvenance?

    init(
        caseID: String,
        hypothesis: String,
        source: TranscriptionHypothesisSource,
        engineIdentifier: String? = nil,
        runID: String? = nil,
        locale: String? = nil,
        segmentCount: Int? = nil,
        segments: [SegmentEvidence]? = nil,
        audioSHA256: String? = nil,
        audioDurationMs: Double? = nil,
        audioConditioning: TranscriptionAudioConditioningEvidence? = nil,
        latencyMeasurementMode: TranscriptionLatencyMeasurementMode? = nil,
        replayChunkDurationMs: Double? = nil,
        postAudioDrainMs: Double? = nil,
        generatedAt: String? = nil,
        corpusProvenance: TranscriptionCorpusProvenance? = nil
    ) {
        self.caseID = caseID
        self.hypothesis = hypothesis
        self.source = source
        self.engineIdentifier = engineIdentifier
        self.runID = runID
        self.locale = locale
        self.segmentCount = segmentCount
        self.segments = segments
        self.audioSHA256 = audioSHA256
        self.audioDurationMs = audioDurationMs
        self.audioConditioning = audioConditioning
        self.latencyMeasurementMode = latencyMeasurementMode
        self.replayChunkDurationMs = replayChunkDurationMs
        self.postAudioDrainMs = postAudioDrainMs
        self.generatedAt = generatedAt
        self.corpusProvenance = corpusProvenance
    }
}

struct TranscriptionBenchmarkSummary: Codable, Hashable, Sendable {
    var caseCount: Int
    var passedCaseCount: Int
    var averageWordErrorRate: Double
    var averageCharacterErrorRate: Double
    var averageVocabularyRecognitionRate: Double
    var averageNamedEntityRecognitionRate: Double
    var firstPartialP95Ms: Double?
    var finalLatencyP95Ms: Double?
    var realTimeFactorP95: Double?
    var languageSwitchP95Ms: Double?
    var memoryResidentMaxBytes: UInt64?
    var cpuUsageP95Percent: Double?
    var totalGapCount: Int
    var totalDuplicateCount: Int
    var totalCorrectionChurnCount: Int
}

struct TranscriptionBenchmarkCase: Codable, Hashable, Sendable {
    var id: String
    var audioFilePath: String?
    var audioSource: TranscriptAudioSource?
    var reference: String
    var hypothesis: String
    var locale: String
    var activeVocabulary: [String]
    var namedEntities: [String]
    var corpus: TranscriptionEvaluationCorpus?
    var evaluationTags: [TranscriptionEvaluationTag]?
    var evidenceKind: TranscriptionBenchmarkEvidenceKind?
    var audioSHA256: String?
    var corpusProvenance: TranscriptionCorpusProvenance?
    var hypothesisSource: TranscriptionHypothesisSource?
    var hypothesisEngineIdentifier: String?
    var hypothesisRunID: String?
    var hypothesisTranscriptFilePath: String?
    var hypothesisTranscriptSHA256: String?
    var firstPartialLatencyMs: Double?
    var finalLatencyMs: Double?
    var audioDurationMs: Double?
    var processingDurationMs: Double?
    var languageSwitchLatencyMs: Double?
    var latencyMeasurementMode: TranscriptionLatencyMeasurementMode?
    var replayChunkDurationMs: Double?
    var memoryResidentBytes: UInt64?
    var cpuUsagePercent: Double?
    var gapCount: Int
    var duplicateCount: Int
    var correctionChurnCount: Int

    init(
        id: String,
        audioFilePath: String? = nil,
        audioSource: TranscriptAudioSource? = nil,
        reference: String,
        hypothesis: String,
        locale: String,
        activeVocabulary: [String] = [],
        namedEntities: [String] = [],
        corpus: TranscriptionEvaluationCorpus = .internalCritical,
        evaluationTags: [TranscriptionEvaluationTag] = [],
        evidenceKind: TranscriptionBenchmarkEvidenceKind = .synthetic,
        audioSHA256: String? = nil,
        corpusProvenance: TranscriptionCorpusProvenance? = nil,
        hypothesisSource: TranscriptionHypothesisSource? = nil,
        hypothesisEngineIdentifier: String? = nil,
        hypothesisRunID: String? = nil,
        hypothesisTranscriptFilePath: String? = nil,
        hypothesisTranscriptSHA256: String? = nil,
        firstPartialLatencyMs: Double? = nil,
        finalLatencyMs: Double? = nil,
        audioDurationMs: Double? = nil,
        processingDurationMs: Double? = nil,
        languageSwitchLatencyMs: Double? = nil,
        latencyMeasurementMode: TranscriptionLatencyMeasurementMode? = nil,
        replayChunkDurationMs: Double? = nil,
        memoryResidentBytes: UInt64? = nil,
        cpuUsagePercent: Double? = nil,
        gapCount: Int = 0,
        duplicateCount: Int = 0,
        correctionChurnCount: Int = 0
    ) {
        self.id = id
        self.audioFilePath = audioFilePath
        self.audioSource = audioSource
        self.reference = reference
        self.hypothesis = hypothesis
        self.locale = locale
        self.activeVocabulary = activeVocabulary
        self.namedEntities = namedEntities
        self.corpus = corpus
        self.evaluationTags = evaluationTags
        self.evidenceKind = evidenceKind
        self.audioSHA256 = audioSHA256
        self.corpusProvenance = corpusProvenance
        self.hypothesisSource = hypothesisSource
        self.hypothesisEngineIdentifier = hypothesisEngineIdentifier
        self.hypothesisRunID = hypothesisRunID
        self.hypothesisTranscriptFilePath = hypothesisTranscriptFilePath
        self.hypothesisTranscriptSHA256 = hypothesisTranscriptSHA256
        self.firstPartialLatencyMs = firstPartialLatencyMs
        self.finalLatencyMs = finalLatencyMs
        self.audioDurationMs = audioDurationMs
        self.processingDurationMs = processingDurationMs
        self.languageSwitchLatencyMs = languageSwitchLatencyMs
        self.latencyMeasurementMode = latencyMeasurementMode
        self.replayChunkDurationMs = replayChunkDurationMs
        self.memoryResidentBytes = memoryResidentBytes
        self.cpuUsagePercent = cpuUsagePercent
        self.gapCount = gapCount
        self.duplicateCount = duplicateCount
        self.correctionChurnCount = correctionChurnCount
    }
}

struct TranscriptionBenchmarkResult: Codable, Hashable, Sendable {
    var id: String
    var locale: String
    var wordErrorRate: Double
    var characterErrorRate: Double
    var vocabularyRecognitionRate: Double
    var namedEntityRecognitionRate: Double
    var firstPartialLatencyMs: Double?
    var finalLatencyMs: Double?
    var realTimeFactor: Double?
    var languageSwitchLatencyMs: Double?
    var memoryResidentBytes: UInt64?
    var cpuUsagePercent: Double?
    var gapCount: Int
    var duplicateCount: Int
    var correctionChurnCount: Int
    var passedQualityGate: Bool
    var failedGates: [String]
}

struct TranscriptionBenchmarkImprovementThresholds: Codable, Hashable, Sendable {
    var minAverageWordErrorRateReduction: Double
    var minAverageCharacterErrorRateReduction: Double
    var minAverageVocabularyRecallImprovementWhenBaselineMisses: Double
    var minAverageNamedEntityRecallImprovementWhenBaselineMisses: Double
    var maxPerCaseWordErrorRateRegression: Double
    var maxPerCaseCharacterErrorRateRegression: Double
    var maxPerCaseVocabularyRecallRegression: Double
    var maxPerCaseNamedEntityRecallRegression: Double
    var requireSameCaseIDs: Bool
    var requireAudioIdentityEvidence: Bool
    var requireEvidenceKindIdentity: Bool
    var requireExternalCorpusProvenanceIdentity: Bool
    var requireHypothesisEvidence: Bool
    var allowedHypothesisSources: [TranscriptionHypothesisSource]
    var allowedHypothesisSourcesByCorpus: [TranscriptionEvaluationCorpus: [TranscriptionHypothesisSource]]

    static let topTierRefinement = TranscriptionBenchmarkImprovementThresholds(
        minAverageWordErrorRateReduction: 0.005,
        minAverageCharacterErrorRateReduction: 0.0025,
        minAverageVocabularyRecallImprovementWhenBaselineMisses: 0.01,
        minAverageNamedEntityRecallImprovementWhenBaselineMisses: 0.01,
        maxPerCaseWordErrorRateRegression: 0.02,
        maxPerCaseCharacterErrorRateRegression: 0.015,
        maxPerCaseVocabularyRecallRegression: 0,
        maxPerCaseNamedEntityRecallRegression: 0,
        requireSameCaseIDs: true,
        requireAudioIdentityEvidence: true,
        requireEvidenceKindIdentity: true,
        requireExternalCorpusProvenanceIdentity: true,
        requireHypothesisEvidence: true,
        allowedHypothesisSources: [.appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit],
        allowedHypothesisSourcesByCorpus: [
            .internalCritical: [.evaluationReplay, .appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit],
            .privateMeetingPack: [.appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit],
            .ami: [.appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit],
            .fleurs: [.appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit],
            .voxLingua107: [.appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit],
            .earnings21: [.appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit],
            .conec: [.appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit]
        ]
    )
}

struct TranscriptionBenchmarkComparisonResult: Codable, Hashable, Sendable {
    var id: String
    var baseline: TranscriptionBenchmarkResult
    var candidate: TranscriptionBenchmarkResult
    var wordErrorRateReduction: Double
    var characterErrorRateReduction: Double
    var vocabularyRecallDelta: Double
    var namedEntityRecallDelta: Double
    var passedImprovementGate: Bool
    var failedGates: [String]
}

struct TranscriptionBenchmarkComparisonSummary: Codable, Hashable, Sendable {
    var comparableCaseCount: Int
    var improvedWordErrorRateCaseCount: Int
    var improvedCharacterErrorRateCaseCount: Int
    var improvedVocabularyRecallCaseCount: Int
    var improvedNamedEntityRecallCaseCount: Int
    var averageWordErrorRateReduction: Double
    var averageCharacterErrorRateReduction: Double
    var averageVocabularyRecallDelta: Double
    var averageNamedEntityRecallDelta: Double
}

struct TranscriptionBenchmarkComparisonReport: Codable, Hashable, Sendable {
    var passed: Bool
    var failures: [String]
    var baselineSummary: TranscriptionBenchmarkSummary
    var candidateSummary: TranscriptionBenchmarkSummary
    var comparisonSummary: TranscriptionBenchmarkComparisonSummary
    var results: [TranscriptionBenchmarkComparisonResult]
}

struct TranscriptionBenchmarkComparator: Sendable {
    func compare(
        baseline baselineCases: [TranscriptionBenchmarkCase],
        candidate candidateCases: [TranscriptionBenchmarkCase],
        benchmarkThresholds: TranscriptionBenchmarkThresholds = .default,
        improvementThresholds: TranscriptionBenchmarkImprovementThresholds = .topTierRefinement
    ) -> TranscriptionBenchmarkComparisonReport {
        let suite = TranscriptionBenchmarkSuite()
        let baselineResults = suite.evaluate(baselineCases, thresholds: benchmarkThresholds)
        let candidateResults = suite.evaluate(candidateCases, thresholds: benchmarkThresholds)
        var failures = [String]()
        var baselineByID: [String: TranscriptionBenchmarkResult] = [:]
        var candidateByID: [String: TranscriptionBenchmarkResult] = [:]
        var baselineCaseByID: [String: TranscriptionBenchmarkCase] = [:]
        var candidateCaseByID: [String: TranscriptionBenchmarkCase] = [:]
        for testCase in baselineCases {
            baselineCaseByID[testCase.id] = testCase
        }
        for testCase in candidateCases {
            candidateCaseByID[testCase.id] = testCase
        }
        for result in baselineResults {
            if baselineByID[result.id] != nil {
                failures.append("duplicate_baseline_case:\(result.id)")
            }
            baselineByID[result.id] = result
        }
        for result in candidateResults {
            if candidateByID[result.id] != nil {
                failures.append("duplicate_candidate_case:\(result.id)")
            }
            candidateByID[result.id] = result
        }
        let baselineIDs = Set(baselineByID.keys)
        let candidateIDs = Set(candidateByID.keys)

        if improvementThresholds.requireSameCaseIDs {
            for id in baselineIDs.subtracting(candidateIDs).sorted() {
                failures.append("missing_candidate_case:\(id)")
            }
            for id in candidateIDs.subtracting(baselineIDs).sorted() {
                failures.append("missing_baseline_case:\(id)")
            }
        }

        let comparableIDs = Array(baselineIDs.intersection(candidateIDs)).sorted()
        var comparisonResults = [TranscriptionBenchmarkComparisonResult]()
        for id in comparableIDs {
            guard let baseline = baselineByID[id], let candidate = candidateByID[id] else { continue }
            if let baselineCase = baselineCaseByID[id], let candidateCase = candidateCaseByID[id] {
                failures.append(contentsOf: Self.caseIdentityFailures(
                    baseline: baselineCase,
                    candidate: candidateCase,
                    thresholds: improvementThresholds
                ).map { "\($0):\(id)" })
            }
            let wordReduction = baseline.wordErrorRate - candidate.wordErrorRate
            let characterReduction = baseline.characterErrorRate - candidate.characterErrorRate
            let vocabularyDelta = candidate.vocabularyRecognitionRate - baseline.vocabularyRecognitionRate
            let namedEntityDelta = candidate.namedEntityRecognitionRate - baseline.namedEntityRecognitionRate
            let failedGates = Self.failedPerCaseGates(
                id: id,
                wordErrorRateReduction: wordReduction,
                characterErrorRateReduction: characterReduction,
                vocabularyRecallDelta: vocabularyDelta,
                namedEntityRecallDelta: namedEntityDelta,
                thresholds: improvementThresholds
            )
            failures.append(contentsOf: failedGates.map { "\($0):\(id)" })
            comparisonResults.append(TranscriptionBenchmarkComparisonResult(
                id: id,
                baseline: baseline,
                candidate: candidate,
                wordErrorRateReduction: wordReduction,
                characterErrorRateReduction: characterReduction,
                vocabularyRecallDelta: vocabularyDelta,
                namedEntityRecallDelta: namedEntityDelta,
                passedImprovementGate: failedGates.isEmpty,
                failedGates: failedGates
            ))
        }

        let baselineSummary = suite.summarize(baselineResults)
        let candidateSummary = suite.summarize(candidateResults)
        let comparisonSummary = Self.summary(for: comparisonResults)
        failures.append(contentsOf: Self.aggregateFailures(
            baselineSummary: baselineSummary,
            comparisonSummary: comparisonSummary,
            thresholds: improvementThresholds
        ))

        return TranscriptionBenchmarkComparisonReport(
            passed: failures.isEmpty,
            failures: failures,
            baselineSummary: baselineSummary,
            candidateSummary: candidateSummary,
            comparisonSummary: comparisonSummary,
            results: comparisonResults
        )
    }

    private static func failedPerCaseGates(
        id: String,
        wordErrorRateReduction: Double,
        characterErrorRateReduction: Double,
        vocabularyRecallDelta: Double,
        namedEntityRecallDelta: Double,
        thresholds: TranscriptionBenchmarkImprovementThresholds
    ) -> [String] {
        var failures = [String]()
        if wordErrorRateReduction < -thresholds.maxPerCaseWordErrorRateRegression {
            failures.append("word_error_rate_regression")
        }
        if characterErrorRateReduction < -thresholds.maxPerCaseCharacterErrorRateRegression {
            failures.append("character_error_rate_regression")
        }
        if vocabularyRecallDelta < -thresholds.maxPerCaseVocabularyRecallRegression {
            failures.append("vocabulary_recall_regression")
        }
        if namedEntityRecallDelta < -thresholds.maxPerCaseNamedEntityRecallRegression {
            failures.append("named_entity_recall_regression")
        }
        return failures
    }

    private static func aggregateFailures(
        baselineSummary: TranscriptionBenchmarkSummary,
        comparisonSummary: TranscriptionBenchmarkComparisonSummary,
        thresholds: TranscriptionBenchmarkImprovementThresholds
    ) -> [String] {
        guard comparisonSummary.comparableCaseCount > 0 else {
            return ["missing_comparable_cases"]
        }
        var failures = [String]()
        if baselineSummary.averageWordErrorRate > 0,
           comparisonSummary.averageWordErrorRateReduction < thresholds.minAverageWordErrorRateReduction {
            failures.append("insufficient_average_word_error_rate_reduction:\(Self.formattedDelta(comparisonSummary.averageWordErrorRateReduction))")
        }
        if baselineSummary.averageCharacterErrorRate > 0,
           comparisonSummary.averageCharacterErrorRateReduction < thresholds.minAverageCharacterErrorRateReduction {
            failures.append("insufficient_average_character_error_rate_reduction:\(Self.formattedDelta(comparisonSummary.averageCharacterErrorRateReduction))")
        }
        if baselineSummary.averageVocabularyRecognitionRate < 0.999,
           comparisonSummary.averageVocabularyRecallDelta < thresholds.minAverageVocabularyRecallImprovementWhenBaselineMisses {
            failures.append("insufficient_average_vocabulary_recall_improvement:\(Self.formattedDelta(comparisonSummary.averageVocabularyRecallDelta))")
        }
        if baselineSummary.averageNamedEntityRecognitionRate < 0.999,
           comparisonSummary.averageNamedEntityRecallDelta < thresholds.minAverageNamedEntityRecallImprovementWhenBaselineMisses {
            failures.append("insufficient_average_named_entity_recall_improvement:\(Self.formattedDelta(comparisonSummary.averageNamedEntityRecallDelta))")
        }
        return failures
    }

    private static func caseIdentityFailures(
        baseline: TranscriptionBenchmarkCase,
        candidate: TranscriptionBenchmarkCase,
        thresholds: TranscriptionBenchmarkImprovementThresholds
    ) -> [String] {
        var failures = [String]()
        if normalizedComparisonText(baseline.reference) != normalizedComparisonText(candidate.reference) {
            failures.append("reference_mismatch")
        }
        if normalizedLocale(baseline.locale) != normalizedLocale(candidate.locale) {
            failures.append("locale_mismatch")
        }
        if (baseline.corpus ?? .internalCritical) != (candidate.corpus ?? .internalCritical) {
            failures.append("corpus_mismatch")
        }
        if thresholds.requireEvidenceKindIdentity,
           (baseline.evidenceKind ?? .synthetic) != (candidate.evidenceKind ?? .synthetic) {
            failures.append("evidence_kind_mismatch")
        }
        failures.append(contentsOf: corpusProvenanceIdentityFailures(
            baseline: baseline,
            candidate: candidate,
            requiresExternalProvenance: thresholds.requireExternalCorpusProvenanceIdentity
        ))
        if Set(baseline.evaluationTags ?? []) != Set(candidate.evaluationTags ?? []) {
            failures.append("evaluation_tags_mismatch")
        }
        if normalizedTermSet(baseline.activeVocabulary, locale: baseline.locale) != normalizedTermSet(candidate.activeVocabulary, locale: candidate.locale) {
            failures.append("active_vocabulary_mismatch")
        }
        if normalizedTermSet(baseline.namedEntities, locale: baseline.locale) != normalizedTermSet(candidate.namedEntities, locale: candidate.locale) {
            failures.append("named_entities_mismatch")
        }
        failures.append(contentsOf: audioIdentityFailures(
            baseline: baseline,
            candidate: candidate,
            requiresEvidence: thresholds.requireAudioIdentityEvidence
        ))
        failures.append(contentsOf: hypothesisEvidenceFailures(
            baseline: baseline,
            candidate: candidate,
            requiresEvidence: thresholds.requireHypothesisEvidence,
            defaultAllowedSources: thresholds.allowedHypothesisSources,
            allowedSourcesByCorpus: thresholds.allowedHypothesisSourcesByCorpus
        ))
        return failures
    }

    private static func corpusProvenanceIdentityFailures(
        baseline: TranscriptionBenchmarkCase,
        candidate: TranscriptionBenchmarkCase,
        requiresExternalProvenance: Bool
    ) -> [String] {
        guard requiresExternalProvenance else { return [] }
        let baselineCorpus = baseline.corpus ?? .internalCritical
        let candidateCorpus = candidate.corpus ?? .internalCritical
        guard baselineCorpus == candidateCorpus,
              baselineCorpus != .internalCritical else {
            return []
        }

        var failures = [String]()
        if baseline.corpusProvenance == nil {
            failures.append("missing_baseline_corpus_provenance")
        }
        if candidate.corpusProvenance == nil {
            failures.append("missing_candidate_corpus_provenance")
        }
        if let baselineProvenance = baseline.corpusProvenance,
           let candidateProvenance = candidate.corpusProvenance,
           baselineProvenance != candidateProvenance {
            failures.append("corpus_provenance_mismatch")
        }
        return failures
    }

    private static func audioIdentityFailures(
        baseline: TranscriptionBenchmarkCase,
        candidate: TranscriptionBenchmarkCase,
        requiresEvidence: Bool
    ) -> [String] {
        var failures = [String]()
        let baselineSource = sourceSeparatedAudioSource(baseline.audioSource)
        let candidateSource = sourceSeparatedAudioSource(candidate.audioSource)
        if requiresEvidence {
            if baseline.audioSource == nil {
                failures.append("missing_baseline_audio_source")
            } else if baselineSource == nil {
                failures.append("invalid_baseline_audio_source")
            }
            if candidate.audioSource == nil {
                failures.append("missing_candidate_audio_source")
            } else if candidateSource == nil {
                failures.append("invalid_candidate_audio_source")
            }
        }
        if let baselineSource, let candidateSource, baselineSource != candidateSource {
            failures.append("audio_source_mismatch")
        }

        let baselineChecksum = normalizedChecksum(baseline.audioSHA256)
        let candidateChecksum = normalizedChecksum(candidate.audioSHA256)
        if requiresEvidence {
            if baselineChecksum == nil {
                failures.append("missing_baseline_audio_checksum")
            }
            if candidateChecksum == nil {
                failures.append("missing_candidate_audio_checksum")
            }
        }
        if let baselineChecksum, let candidateChecksum, baselineChecksum != candidateChecksum {
            failures.append("audio_checksum_mismatch")
        }

        let baselineDuration = validAudioDurationMs(baseline.audioDurationMs)
        let candidateDuration = validAudioDurationMs(candidate.audioDurationMs)
        if requiresEvidence {
            if baselineDuration == nil {
                failures.append("missing_baseline_audio_duration")
            }
            if candidateDuration == nil {
                failures.append("missing_candidate_audio_duration")
            }
        }
        if let baselineDuration, let candidateDuration {
            let allowedDrift = max(250, baselineDuration * 0.05)
            if abs(baselineDuration - candidateDuration) > allowedDrift {
                failures.append("audio_duration_mismatch")
            }
        }
        return failures
    }

    private static func hypothesisEvidenceFailures(
        baseline: TranscriptionBenchmarkCase,
        candidate: TranscriptionBenchmarkCase,
        requiresEvidence: Bool,
        defaultAllowedSources: [TranscriptionHypothesisSource],
        allowedSourcesByCorpus: [TranscriptionEvaluationCorpus: [TranscriptionHypothesisSource]]
    ) -> [String] {
        guard requiresEvidence else { return [] }
        return hypothesisEvidenceFailures(
            for: baseline,
            role: "baseline",
            defaultAllowedSources: defaultAllowedSources,
            allowedSourcesByCorpus: allowedSourcesByCorpus
        ) + hypothesisEvidenceFailures(
            for: candidate,
            role: "candidate",
            defaultAllowedSources: defaultAllowedSources,
            allowedSourcesByCorpus: allowedSourcesByCorpus
        )
    }

    private static func hypothesisEvidenceFailures(
        for testCase: TranscriptionBenchmarkCase,
        role: String,
        defaultAllowedSources: [TranscriptionHypothesisSource],
        allowedSourcesByCorpus: [TranscriptionEvaluationCorpus: [TranscriptionHypothesisSource]]
    ) -> [String] {
        var failures = [String]()
        let source = testCase.hypothesisSource
        let allowedSources = Self.allowedHypothesisSources(
            for: testCase,
            defaultAllowedSources: defaultAllowedSources,
            allowedSourcesByCorpus: allowedSourcesByCorpus
        )
        if let source {
            if !allowedSources.contains(source) {
                failures.append("unsupported_\(role)_hypothesis_source:\(source.rawValue)")
            }
        } else {
            failures.append("missing_\(role)_hypothesis_source")
        }

        let engineIdentifier = testCase.hypothesisEngineIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if engineIdentifier.isEmpty {
            failures.append("missing_\(role)_hypothesis_engine")
        }
        let runID = testCase.hypothesisRunID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if runID.isEmpty {
            failures.append("missing_\(role)_hypothesis_run_id")
        }

        guard let transcriptPath = testCase.hypothesisTranscriptFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcriptPath.isEmpty else {
            failures.append("missing_\(role)_hypothesis_transcript_file")
            failures.append("missing_\(role)_hypothesis_transcript_checksum")
            return failures
        }

        let url = URL(fileURLWithPath: transcriptPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: transcriptPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            failures.append("\(role)_hypothesis_transcript_file_not_found")
            if normalizedChecksum(testCase.hypothesisTranscriptSHA256) == nil {
                failures.append("missing_\(role)_hypothesis_transcript_checksum")
            }
            return failures
        }

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if (values.fileSize ?? 0) <= 0 {
                failures.append("empty_\(role)_hypothesis_transcript_file")
            }
        } catch {
            failures.append("unreadable_\(role)_hypothesis_transcript_file")
        }

        if let expectedChecksum = normalizedChecksum(testCase.hypothesisTranscriptSHA256) {
            guard let actualChecksum = sha256HexDigest(of: url) else {
                failures.append("unreadable_\(role)_hypothesis_transcript_checksum")
                return failures
            }
            if actualChecksum.lowercased() != expectedChecksum {
                failures.append("\(role)_hypothesis_transcript_checksum_mismatch")
            }
        } else {
            failures.append("missing_\(role)_hypothesis_transcript_checksum")
        }

        guard let evidence = hypothesisTranscriptEvidence(of: url) else {
            failures.append("\(role)_hypothesis_transcript_not_decodable")
            return failures
        }
        if evidence.caseID != testCase.id {
            failures.append("\(role)_hypothesis_transcript_case_mismatch")
        }
        if let source, evidence.source != source {
            failures.append("\(role)_hypothesis_transcript_source_mismatch")
        }
        if !engineIdentifier.isEmpty,
           evidence.engineIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) != engineIdentifier {
            failures.append("\(role)_hypothesis_transcript_engine_mismatch")
        }
        if !runID.isEmpty,
           evidence.runID?.trimmingCharacters(in: .whitespacesAndNewlines) != runID {
            failures.append("\(role)_hypothesis_transcript_run_mismatch")
        }
        if normalizedComparisonText(evidence.hypothesis) != normalizedComparisonText(testCase.hypothesis) {
            failures.append("\(role)_hypothesis_transcript_text_mismatch")
        }

        let corpus = testCase.corpus ?? .internalCritical
        if corpus != .internalCritical {
            guard let expectedProvenance = testCase.corpusProvenance else {
                failures.append("missing_\(role)_hypothesis_corpus_provenance_reference")
                return failures
            }
            guard let evidenceProvenance = evidence.corpusProvenance else {
                failures.append("missing_\(role)_hypothesis_corpus_provenance")
                return failures
            }
            if evidenceProvenance != expectedProvenance {
                failures.append("\(role)_hypothesis_corpus_provenance_mismatch")
            }
        }

        if let expectedAudioChecksum = normalizedChecksum(testCase.audioSHA256) {
            guard let evidenceAudioChecksum = normalizedChecksum(evidence.audioSHA256) else {
                failures.append("missing_\(role)_hypothesis_audio_checksum")
                return failures
            }
            if evidenceAudioChecksum != expectedAudioChecksum {
                failures.append("\(role)_hypothesis_audio_checksum_mismatch")
            }
        } else {
            failures.append("missing_\(role)_hypothesis_audio_checksum_reference")
        }

        if let expectedDuration = validAudioDurationMs(testCase.audioDurationMs) {
            guard let evidenceDuration = validAudioDurationMs(evidence.audioDurationMs) else {
                failures.append("missing_\(role)_hypothesis_audio_duration")
                return failures
            }
            let allowedDrift = max(250, expectedDuration * 0.05)
            if abs(evidenceDuration - expectedDuration) > allowedDrift {
                failures.append("\(role)_hypothesis_audio_duration_mismatch")
            }
        } else {
            failures.append("missing_\(role)_hypothesis_audio_duration_reference")
        }

        return failures
    }

    private static func allowedHypothesisSources(
        for testCase: TranscriptionBenchmarkCase,
        defaultAllowedSources: [TranscriptionHypothesisSource],
        allowedSourcesByCorpus: [TranscriptionEvaluationCorpus: [TranscriptionHypothesisSource]]
    ) -> [TranscriptionHypothesisSource] {
        let corpus = testCase.corpus ?? .internalCritical
        return allowedSourcesByCorpus[corpus] ?? defaultAllowedSources
    }

    private static func sourceSeparatedAudioSource(_ source: TranscriptAudioSource?) -> TranscriptAudioSource? {
        guard let source else { return nil }
        switch source {
        case .microphone, .system:
            return source
        case .mixed, .cloud, .unknown:
            return nil
        }
    }

    private static func validAudioDurationMs(_ duration: Double?) -> Double? {
        guard let duration, duration.isFinite, duration > 0 else {
            return nil
        }
        return duration
    }

    private static func normalizedComparisonText(_ text: String) -> String {
        SpeechVocabularyTerm.normalizedKey(text)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedLocale(_ locale: String) -> String {
        SupportedLanguage.language(for: locale)?.rawValue ?? locale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedTermSet(_ terms: [String], locale: String?) -> [String] {
        terms
            .map { SpeechVocabularyTerm.normalizedKey($0, locale: locale) }
            .filter { !$0.isEmpty }
            .deduplicatedNormalizedStrings()
            .sorted()
    }

    private static func normalizedChecksum(_ checksum: String?) -> String? {
        guard let checksum = checksum?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !checksum.isEmpty else {
            return nil
        }
        return checksum
    }

    private static func sha256HexDigest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hypothesisTranscriptEvidence(of url: URL) -> TranscriptionHypothesisTranscriptEvidence? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return try? JSONDecoder().decode(TranscriptionHypothesisTranscriptEvidence.self, from: data)
    }

    private static func summary(
        for results: [TranscriptionBenchmarkComparisonResult]
    ) -> TranscriptionBenchmarkComparisonSummary {
        TranscriptionBenchmarkComparisonSummary(
            comparableCaseCount: results.count,
            improvedWordErrorRateCaseCount: results.filter { $0.wordErrorRateReduction > 0 }.count,
            improvedCharacterErrorRateCaseCount: results.filter { $0.characterErrorRateReduction > 0 }.count,
            improvedVocabularyRecallCaseCount: results.filter { $0.vocabularyRecallDelta > 0 }.count,
            improvedNamedEntityRecallCaseCount: results.filter { $0.namedEntityRecallDelta > 0 }.count,
            averageWordErrorRateReduction: average(results.map(\.wordErrorRateReduction)),
            averageCharacterErrorRateReduction: average(results.map(\.characterErrorRateReduction)),
            averageVocabularyRecallDelta: average(results.map(\.vocabularyRecallDelta)),
            averageNamedEntityRecallDelta: average(results.map(\.namedEntityRecallDelta))
        )
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func formattedDelta(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

struct TranscriptionReleaseGatePolicy: Codable, Hashable, Sendable {
    var requiredCorpora: [TranscriptionEvaluationCorpus]
    var requiredLocales: [String]
    var requiredTags: [TranscriptionEvaluationTag]
    var thresholds: TranscriptionBenchmarkThresholds
    var minimumCaseCountPerCorpus: Int
    var minimumCaseCountsByCorpus: [TranscriptionEvaluationCorpus: Int]
    var minimumUniqueSampleCountsByCorpus: [TranscriptionEvaluationCorpus: Int]
    var minimumUniqueAudioChecksumCountsByCorpus: [TranscriptionEvaluationCorpus: Int]
    var minimumTotalAudioDurationMsByCorpus: [TranscriptionEvaluationCorpus: Double]
    var requiredLocalesByCorpus: [TranscriptionEvaluationCorpus: [String]]
    var requiredTagsByCorpus: [TranscriptionEvaluationCorpus: [TranscriptionEvaluationTag]]
    var requiredAudioSourcesByCorpus: [TranscriptionEvaluationCorpus: [TranscriptAudioSource]]
    var maxTotalGapCount: Int
    var maxTotalDuplicateCount: Int
    var requireSpeechLatencyMeasurements: Bool
    var requireRealtimeLatencyEvidenceForRequiredCorpora: Bool
    var maxReplayChunkDurationMsForLatencyEvidence: Double?
    var requireSpeechRealTimeFactorMeasurements: Bool
    var requireResourceMeasurementsForRequiredCorpora: Bool
    var requireBaselineImprovementComparison: Bool
    var requireAudioEvidenceForRequiredCorpora: Bool
    var requireAudioChecksumForRequiredCorpora: Bool
    var requireDecodableAudioForRequiredCorpora: Bool
    var requireAudioDurationMatchesEvidence: Bool
    var requireNonTemporaryAudioEvidenceForExternalCorpora: Bool
    var maxAudioDurationMismatchMs: Double
    var requiredEvidenceKindsByCorpus: [TranscriptionEvaluationCorpus: [TranscriptionBenchmarkEvidenceKind]]
    var requireCorpusProvenanceForExternalCorpora: Bool
    var requirePrivateCorpusConsentVerification: Bool
    var requireASRHypothesisEvidenceForRequiredCorpora: Bool
    var requireHypothesisTranscriptChecksumForRequiredCorpora: Bool
    var requireHypothesisSegmentEvidenceForRequiredCorpora: Bool
    var requireAudioConditioningEvidenceForRequiredCorpora: Bool
    var allowedHypothesisSourcesByCorpus: [TranscriptionEvaluationCorpus: [TranscriptionHypothesisSource]]
    var requiredLocalRefinerEvidenceCorpora: [TranscriptionEvaluationCorpus]
    var requiredLocalRefinerAcceptedEvidenceCorpora: [TranscriptionEvaluationCorpus]
    var allowedPublicCorpusSourceURIPrefixes: [TranscriptionEvaluationCorpus: [String]]
    var disallowedHypothesisEnginePrefixesForRequiredCorpora: [String]

    static let topTierRelease = TranscriptionReleaseGatePolicy(
        requiredCorpora: [
            .internalCritical,
            .privateMeetingPack,
            .ami,
            .fleurs,
            .voxLingua107,
            .earnings21,
            .conec
        ],
        requiredLocales: SupportedLanguage.allCases.map(\.rawValue),
        requiredTags: [
            .meeting,
            .farField,
            .overlap,
            .multilingual,
            .spokenLanguageID,
            .entityDense,
            .contextualBias,
            .codeSwitching,
            .jargon,
            .criticalNonSpeech,
            .silence,
            .noise,
            .clicks,
            .music,
            .breathing,
            .reverb,
            .lowVolume,
            .clipping
        ],
        thresholds: .default,
        minimumCaseCountPerCorpus: 1,
        minimumCaseCountsByCorpus: [
            .internalCritical: 4,
            .privateMeetingPack: 4,
            .ami: 3,
            .fleurs: 4,
            .voxLingua107: 4,
            .earnings21: 3,
            .conec: 3
        ],
        minimumUniqueSampleCountsByCorpus: [
            .privateMeetingPack: 4,
            .ami: 3,
            .fleurs: 4,
            .voxLingua107: 4,
            .earnings21: 3,
            .conec: 3
        ],
        minimumUniqueAudioChecksumCountsByCorpus: [
            .internalCritical: 4,
            .privateMeetingPack: 4,
            .ami: 3,
            .fleurs: 4,
            .voxLingua107: 4,
            .earnings21: 3,
            .conec: 3
        ],
        minimumTotalAudioDurationMsByCorpus: [
            .internalCritical: 4_000,
            .privateMeetingPack: 120_000,
            .ami: 180_000,
            .fleurs: 60_000,
            .voxLingua107: 60_000,
            .earnings21: 180_000,
            .conec: 120_000
        ],
        requiredLocalesByCorpus: [
            .privateMeetingPack: SupportedLanguage.allCases.map(\.rawValue),
            .ami: ["en-US"],
            .fleurs: SupportedLanguage.allCases.map(\.rawValue),
            .voxLingua107: SupportedLanguage.allCases.map(\.rawValue),
            .earnings21: ["en-US"],
            .conec: ["en-US"]
        ],
        requiredTagsByCorpus: [
            .internalCritical: [.criticalNonSpeech, .silence, .noise, .clicks, .music, .breathing],
            .privateMeetingPack: [.meeting, .multilingual, .codeSwitching, .jargon, .noise, .lowVolume, .reverb, .clipping],
            .ami: [.meeting, .farField, .overlap],
            .fleurs: [.multilingual],
            .voxLingua107: [.spokenLanguageID, .multilingual],
            .earnings21: [.entityDense, .jargon],
            .conec: [.contextualBias, .jargon]
        ],
        requiredAudioSourcesByCorpus: [
            .internalCritical: [.microphone, .system],
            .privateMeetingPack: [.microphone, .system]
        ],
        maxTotalGapCount: 0,
        maxTotalDuplicateCount: 0,
        requireSpeechLatencyMeasurements: true,
        requireRealtimeLatencyEvidenceForRequiredCorpora: true,
        maxReplayChunkDurationMsForLatencyEvidence: 250,
        requireSpeechRealTimeFactorMeasurements: true,
        requireResourceMeasurementsForRequiredCorpora: true,
        requireBaselineImprovementComparison: true,
        requireAudioEvidenceForRequiredCorpora: true,
        requireAudioChecksumForRequiredCorpora: true,
        requireDecodableAudioForRequiredCorpora: true,
        requireAudioDurationMatchesEvidence: true,
        requireNonTemporaryAudioEvidenceForExternalCorpora: true,
        maxAudioDurationMismatchMs: 250,
        requiredEvidenceKindsByCorpus: [
            .internalCritical: [.generatedFixture, .recordedFixture, .privateCorpus],
            .privateMeetingPack: [.privateCorpus],
            .ami: [.publicCorpus],
            .fleurs: [.publicCorpus],
            .voxLingua107: [.publicCorpus],
            .earnings21: [.publicCorpus],
            .conec: [.publicCorpus]
        ],
        requireCorpusProvenanceForExternalCorpora: true,
        requirePrivateCorpusConsentVerification: true,
        requireASRHypothesisEvidenceForRequiredCorpora: true,
        requireHypothesisTranscriptChecksumForRequiredCorpora: true,
        requireHypothesisSegmentEvidenceForRequiredCorpora: true,
        requireAudioConditioningEvidenceForRequiredCorpora: true,
        allowedHypothesisSourcesByCorpus: [
            .internalCritical: [.evaluationReplay, .appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit],
            .privateMeetingPack: [.appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit],
            .ami: [.appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit],
            .fleurs: [.appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit],
            .voxLingua107: [.appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit],
            .earnings21: [.appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit],
            .conec: [.appleSpeech, .speechAnalyzer, .sfSpeech, .whisperKit]
        ],
        requiredLocalRefinerEvidenceCorpora: [
            .privateMeetingPack,
            .earnings21,
            .conec
        ],
        requiredLocalRefinerAcceptedEvidenceCorpora: [
            .privateMeetingPack,
            .earnings21,
            .conec
        ],
        allowedPublicCorpusSourceURIPrefixes: [
            .ami: [
                "https://groups.inf.ed.ac.uk/ami/corpus/",
                "https://www.idiap.ch/webarchives/sites/www.amiproject.org/ami-scientific-portal/meeting-corpus/"
            ],
            .fleurs: [
                "https://huggingface.co/datasets/google/fleurs",
                "https://tensorflow.google.cn/datasets/catalog/xtreme_s",
                "https://www.tensorflow.org/datasets/catalog/xtreme_s"
            ],
            .voxLingua107: [
                "https://bark.phon.ioc.ee/voxlingua107/",
                "https://huggingface.co/datasets/TalTechNLP/voxlingua107_wds"
            ],
            .earnings21: [
                "https://github.com/revdotcom/speech-datasets/tree/main/earnings21",
                "https://huggingface.co/datasets/Revai/earnings21"
            ],
            .conec: [
                "https://github.com/huangruizhe/ConEC",
                "https://www.amazon.science/publications/conec-earnings-call-dataset-with-real-world-contexts-for-benchmarking-contextual-speech-recognition",
                "https://aclanthology.org/2024.lrec-main.328"
            ]
        ],
        disallowedHypothesisEnginePrefixesForRequiredCorpora: [
            "whisperkit/tiny",
            "whisperkit/openai_whisper-tiny",
            "whisperkit/argmaxinc/whisperkit-coreml/openai_whisper-tiny"
        ]
    )
}

struct TranscriptionReleaseGateCoverage: Codable, Hashable, Sendable {
    var corpus: TranscriptionEvaluationCorpus
    var caseCount: Int
    var uniqueSampleCount: Int
    var uniqueAudioChecksumCount: Int
    var totalAudioDurationMs: Double
    var locales: [String]
    var tags: [TranscriptionEvaluationTag]
    var audioSources: [TranscriptAudioSource]
    var localRefinerDecisionCount: Int
    var localRefinerAcceptedCount: Int?
    var localRefinerRejectedCount: Int?
}

struct TranscriptionReleaseGateReport: Codable, Hashable, Sendable {
    var passed: Bool
    var failures: [String]
    var coverage: [TranscriptionReleaseGateCoverage]
    var benchmarkSummary: TranscriptionBenchmarkSummary
    var failedCaseIDs: [String]
}

struct TranscriptionReleaseGate: Sendable {
    func evaluate(
        cases: [TranscriptionBenchmarkCase],
        policy: TranscriptionReleaseGatePolicy = .topTierRelease
    ) -> TranscriptionReleaseGateReport {
        let benchmarkSuite = TranscriptionBenchmarkSuite()
        let results = benchmarkSuite.evaluate(cases, thresholds: policy.thresholds)
        let summary = benchmarkSuite.summarize(results)
        var resultByID: [String: TranscriptionBenchmarkResult] = [:]
        var failures = [String]()
        for result in results {
            if resultByID[result.id] != nil {
                failures.append("duplicate_benchmark_id:\(result.id)")
            }
            resultByID[result.id] = result
        }

        if cases.isEmpty {
            failures.append("missing_benchmark_cases")
        }

        let casesByCorpus = Dictionary(grouping: cases) { $0.corpus ?? .internalCritical }
        for corpus in policy.requiredCorpora {
            let count = casesByCorpus[corpus]?.count ?? 0
            let requiredCount = max(0, policy.minimumCaseCountsByCorpus[corpus] ?? policy.minimumCaseCountPerCorpus)
            if count < requiredCount {
                failures.append("missing_corpus:\(corpus.rawValue)")
                if count > 0 {
                    failures.append("insufficient_corpus_case_count:\(corpus.rawValue):\(count)/\(requiredCount)")
                }
            }

            let uniqueSampleCount = Self.uniqueSampleCount(in: casesByCorpus[corpus] ?? [])
            let requiredUniqueSamples = max(0, policy.minimumUniqueSampleCountsByCorpus[corpus] ?? 0)
            if uniqueSampleCount < requiredUniqueSamples {
                failures.append("insufficient_corpus_unique_sample_count:\(corpus.rawValue):\(uniqueSampleCount)/\(requiredUniqueSamples)")
            }

            let uniqueAudioChecksumCount = Self.uniqueAudioChecksumCount(in: casesByCorpus[corpus] ?? [])
            let requiredUniqueAudioChecksums = max(0, policy.minimumUniqueAudioChecksumCountsByCorpus[corpus] ?? 0)
            if uniqueAudioChecksumCount < requiredUniqueAudioChecksums {
                failures.append("insufficient_corpus_unique_audio_checksum_count:\(corpus.rawValue):\(uniqueAudioChecksumCount)/\(requiredUniqueAudioChecksums)")
            }

            let totalAudioDurationMs = Self.totalAudioDurationMs(in: casesByCorpus[corpus] ?? [])
            let requiredTotalAudioDurationMs = max(0, policy.minimumTotalAudioDurationMsByCorpus[corpus] ?? 0)
            if totalAudioDurationMs < requiredTotalAudioDurationMs {
                failures.append("insufficient_corpus_audio_duration:\(corpus.rawValue):\(Self.roundedMilliseconds(totalAudioDurationMs))/\(Self.roundedMilliseconds(requiredTotalAudioDurationMs))")
            }
        }

        let coveredLocales = Set(cases.map { Self.normalizedLocale($0.locale) })
        for locale in policy.requiredLocales.map(Self.normalizedLocale) where !coveredLocales.contains(locale) {
            failures.append("missing_locale:\(locale)")
        }

        let coveredTags = Set(cases.flatMap { $0.evaluationTags ?? [] })
        for tag in policy.requiredTags where !coveredTags.contains(tag) {
            failures.append("missing_tag:\(tag.rawValue)")
        }

        for corpus in policy.requiredCorpora {
            let corpusCases = casesByCorpus[corpus] ?? []
            let corpusLocales = Set(corpusCases.map { Self.normalizedLocale($0.locale) })
            let requiredCorpusLocales = policy.requiredLocalesByCorpus[corpus] ?? []
            for locale in requiredCorpusLocales.map(Self.normalizedLocale) where !corpusLocales.contains(locale) {
                failures.append("missing_corpus_locale:\(corpus.rawValue):\(locale)")
            }

            let corpusTags = Set(corpusCases.flatMap { $0.evaluationTags ?? [] })
            let requiredCorpusTags = policy.requiredTagsByCorpus[corpus] ?? []
            for tag in requiredCorpusTags where !corpusTags.contains(tag) {
                failures.append("missing_corpus_tag:\(corpus.rawValue):\(tag.rawValue)")
            }

            if policy.requireASRHypothesisEvidenceForRequiredCorpora,
               policy.requireHypothesisSegmentEvidenceForRequiredCorpora,
               policy.requiredCorpora.contains(corpus) {
                let corpusAudioSources = Self.audioSources(in: corpusCases)
                let requiredSources = policy.requiredAudioSourcesByCorpus[corpus] ?? []
                for source in requiredSources where !corpusAudioSources.contains(source) {
                    failures.append("missing_corpus_audio_source:\(corpus.rawValue):\(source.rawValue)")
                }
            }

            let localRefinerCounts = Self.localRefinerEvidenceCounts(in: corpusCases)
            if policy.requiredLocalRefinerEvidenceCorpora.contains(corpus),
               localRefinerCounts.decisionCount <= 0 {
                failures.append("missing_local_refiner_evidence:\(corpus.rawValue)")
            }
            if policy.requiredLocalRefinerAcceptedEvidenceCorpora.contains(corpus),
               localRefinerCounts.acceptedCount <= 0 {
                failures.append("missing_local_refiner_accepted_evidence:\(corpus.rawValue)")
            }
        }

        for result in results where !result.passedQualityGate {
            failures.append("quality_gate_failed:\(result.id):\(result.failedGates.joined(separator: "+"))")
        }

        for testCase in cases {
            let tags = Set(testCase.evaluationTags ?? [])
            let corpus = testCase.corpus ?? .internalCritical
            let isCriticalNonSpeech = tags.contains(.criticalNonSpeech)
            let isSpeechCase = !testCase.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCriticalNonSpeech

            if policy.requireAudioEvidenceForRequiredCorpora,
               policy.requiredCorpora.contains(corpus) {
                failures.append(contentsOf: Self.audioEvidenceFailures(for: testCase, corpus: corpus, policy: policy))
            }
            if policy.requireASRHypothesisEvidenceForRequiredCorpora,
               policy.requiredCorpora.contains(corpus) {
                failures.append(contentsOf: Self.hypothesisEvidenceFailures(for: testCase, corpus: corpus, policy: policy))
            }
            failures.append(contentsOf: Self.corpusProvenanceFailures(for: testCase, corpus: corpus, policy: policy))

            if isCriticalNonSpeech {
                if !testCase.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    failures.append("critical_non_speech_reference_not_empty:\(testCase.id)")
                }
                if !testCase.hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    failures.append("critical_non_speech_false_text:\(testCase.id)")
                }
            }

            failures.append(contentsOf: Self.latencyMeasurementValueFailures(for: testCase))

            if policy.requireSpeechLatencyMeasurements && isSpeechCase {
                if testCase.firstPartialLatencyMs == nil {
                    failures.append("missing_first_partial_latency:\(testCase.id)")
                }
                if testCase.finalLatencyMs == nil {
                    failures.append("missing_final_latency:\(testCase.id)")
                }
            }

            if policy.requireRealtimeLatencyEvidenceForRequiredCorpora,
               policy.requiredCorpora.contains(corpus),
               isSpeechCase {
                failures.append(contentsOf: Self.latencyEvidenceFailures(for: testCase, policy: policy))
            }

            if policy.requireSpeechRealTimeFactorMeasurements && isSpeechCase {
                if testCase.audioDurationMs == nil || testCase.processingDurationMs == nil || resultByID[testCase.id]?.realTimeFactor == nil {
                    failures.append("missing_real_time_factor:\(testCase.id)")
                }
            }

            if policy.requireResourceMeasurementsForRequiredCorpora,
               policy.requiredCorpora.contains(corpus) {
                failures.append(contentsOf: Self.resourceMeasurementFailures(for: testCase))
            }

            if (tags.contains(.codeSwitching) || tags.contains(.spokenLanguageID)) && testCase.languageSwitchLatencyMs == nil {
                failures.append("missing_language_switch_latency:\(testCase.id)")
            }
        }

        if summary.totalGapCount > policy.maxTotalGapCount {
            failures.append("gap_count:\(summary.totalGapCount)")
        }
        if summary.totalDuplicateCount > policy.maxTotalDuplicateCount {
            failures.append("duplicate_count:\(summary.totalDuplicateCount)")
        }

        let coverage = policy.requiredCorpora.map { corpus in
            let corpusCases = casesByCorpus[corpus] ?? []
            let localRefinerCounts = Self.localRefinerEvidenceCounts(in: corpusCases)
            return TranscriptionReleaseGateCoverage(
                corpus: corpus,
                caseCount: corpusCases.count,
                uniqueSampleCount: Self.uniqueSampleCount(in: corpusCases),
                uniqueAudioChecksumCount: Self.uniqueAudioChecksumCount(in: corpusCases),
                totalAudioDurationMs: Self.totalAudioDurationMs(in: corpusCases),
                locales: Array(Set(corpusCases.map { Self.normalizedLocale($0.locale) })).sorted(),
                tags: Array(Set(corpusCases.flatMap { $0.evaluationTags ?? [] })).sorted { $0.rawValue < $1.rawValue },
                audioSources: Array(Self.audioSources(in: corpusCases)).sorted { $0.rawValue < $1.rawValue },
                localRefinerDecisionCount: localRefinerCounts.decisionCount,
                localRefinerAcceptedCount: localRefinerCounts.acceptedCount,
                localRefinerRejectedCount: localRefinerCounts.rejectedCount
            )
        }

        let failedCaseIDs = results
            .filter { !$0.passedQualityGate }
            .map(\.id)
            .sorted()
        let uniqueFailures = failures.deduplicatedPreservingOrder()
        return TranscriptionReleaseGateReport(
            passed: uniqueFailures.isEmpty,
            failures: uniqueFailures,
            coverage: coverage,
            benchmarkSummary: summary,
            failedCaseIDs: failedCaseIDs
        )
    }

    private static func latencyEvidenceFailures(
        for testCase: TranscriptionBenchmarkCase,
        policy: TranscriptionReleaseGatePolicy
    ) -> [String] {
        guard testCase.firstPartialLatencyMs != nil || testCase.finalLatencyMs != nil else {
            return []
        }

        guard let mode = testCase.latencyMeasurementMode else {
            return ["missing_latency_measurement_mode:\(testCase.id)"]
        }

        switch mode {
        case .liveCapture:
            return []
        case .realtimeReplay:
            guard let maxChunkDuration = policy.maxReplayChunkDurationMsForLatencyEvidence else {
                return []
            }
            guard let chunkDuration = testCase.replayChunkDurationMs else {
                return ["missing_replay_chunk_duration_for_latency:\(testCase.id)"]
            }
            guard chunkDuration.isFinite, chunkDuration > 0 else {
                return ["invalid_replay_chunk_duration:\(testCase.id)"]
            }
            return chunkDuration <= maxChunkDuration
                ? []
                : ["replay_chunk_duration_too_large_for_latency:\(testCase.id):\(Self.roundedMilliseconds(chunkDuration))/\(Self.roundedMilliseconds(maxChunkDuration))"]
        case .offlineReplay, .importedTrace:
            return ["non_realtime_latency_measurement:\(testCase.id):\(mode.rawValue)"]
        }
    }

    private static func latencyMeasurementValueFailures(for testCase: TranscriptionBenchmarkCase) -> [String] {
        var failures = [String]()
        if let firstPartialLatencyMs = testCase.firstPartialLatencyMs,
           (!firstPartialLatencyMs.isFinite || firstPartialLatencyMs < 0) {
            failures.append("invalid_first_partial_latency:\(testCase.id)")
        }
        if let finalLatencyMs = testCase.finalLatencyMs,
           (!finalLatencyMs.isFinite || finalLatencyMs < 0) {
            failures.append("invalid_final_latency:\(testCase.id)")
        }
        if let firstPartialLatencyMs = testCase.firstPartialLatencyMs,
           let finalLatencyMs = testCase.finalLatencyMs,
           firstPartialLatencyMs.isFinite,
           finalLatencyMs.isFinite,
           firstPartialLatencyMs >= 0,
           finalLatencyMs >= 0,
           finalLatencyMs < firstPartialLatencyMs {
            failures.append("final_latency_before_first_partial:\(testCase.id)")
        }
        if let languageSwitchLatencyMs = testCase.languageSwitchLatencyMs,
           (!languageSwitchLatencyMs.isFinite || languageSwitchLatencyMs < 0) {
            failures.append("invalid_language_switch_latency:\(testCase.id)")
        }
        if let replayChunkDurationMs = testCase.replayChunkDurationMs,
           (!replayChunkDurationMs.isFinite || replayChunkDurationMs <= 0) {
            failures.append("invalid_replay_chunk_duration:\(testCase.id)")
        }
        return failures
    }

    private static func resourceMeasurementFailures(for testCase: TranscriptionBenchmarkCase) -> [String] {
        var failures = [String]()
        if let memoryResidentBytes = testCase.memoryResidentBytes {
            if memoryResidentBytes == 0 {
                failures.append("invalid_memory_resident_bytes:\(testCase.id)")
            }
        } else {
            failures.append("missing_memory_resident_bytes:\(testCase.id)")
        }

        if let cpuUsagePercent = testCase.cpuUsagePercent {
            if !cpuUsagePercent.isFinite || cpuUsagePercent < 0 {
                failures.append("invalid_cpu_usage_percent:\(testCase.id)")
            }
        } else {
            failures.append("missing_cpu_usage_percent:\(testCase.id)")
        }
        return failures
    }

    private static func corpusProvenanceFailures(
        for testCase: TranscriptionBenchmarkCase,
        corpus: TranscriptionEvaluationCorpus,
        policy: TranscriptionReleaseGatePolicy
    ) -> [String] {
        guard policy.requireCorpusProvenanceForExternalCorpora,
              policy.requiredCorpora.contains(corpus),
              corpus != .internalCritical else {
            return []
        }

        guard let provenance = testCase.corpusProvenance else {
            return ["missing_corpus_provenance:\(testCase.id)"]
        }

        var failures = [String]()
        if provenance.corpus != corpus {
            failures.append("corpus_provenance_mismatch:\(testCase.id):\(provenance.corpus.rawValue)")
        }

        let sampleID = provenance.sampleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if sampleID.isEmpty {
            failures.append("missing_corpus_sample_id:\(testCase.id)")
        }

        let sourceURI = provenance.sourceURI.trimmingCharacters(in: .whitespacesAndNewlines)
        if sourceURI.isEmpty {
            failures.append("missing_corpus_source_uri:\(testCase.id)")
        } else if corpus == .privateMeetingPack {
            if !Self.isRedactedPrivateCorpusURI(sourceURI) {
                failures.append("private_corpus_source_not_redacted:\(testCase.id)")
            }
        } else if !Self.isExternalCorpusURI(sourceURI) {
            failures.append("public_corpus_source_not_external_uri:\(testCase.id)")
        } else if !Self.isApprovedPublicCorpusSourceURI(sourceURI, corpus: corpus, policy: policy) {
            failures.append("public_corpus_source_not_approved:\(testCase.id):\(corpus.rawValue)")
        }

        switch corpus {
        case .privateMeetingPack:
            if provenance.origin != .privateMeetingRecording {
                failures.append("corpus_origin_mismatch:\(testCase.id):\(provenance.origin.rawValue)")
            }
            if policy.requirePrivateCorpusConsentVerification && provenance.consentVerified != true {
                failures.append("private_corpus_consent_not_verified:\(testCase.id)")
            }
        case .ami, .fleurs, .voxLingua107, .earnings21, .conec:
            if provenance.origin != .publicCorpusSample {
                failures.append("corpus_origin_mismatch:\(testCase.id):\(provenance.origin.rawValue)")
            }
            if (provenance.datasetVersion ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("missing_corpus_dataset_version:\(testCase.id)")
            }
            if (provenance.license ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("missing_corpus_license:\(testCase.id)")
            }
        case .internalCritical:
            break
        }

        return failures
    }

    private static func uniqueSampleCount(in cases: [TranscriptionBenchmarkCase]) -> Int {
        Set(cases.compactMap { testCase -> String? in
            guard let sampleID = testCase.corpusProvenance?.sampleID
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !sampleID.isEmpty else {
                return nil
            }
            return sampleID.lowercased()
        }).count
    }

    private static func uniqueAudioChecksumCount(in cases: [TranscriptionBenchmarkCase]) -> Int {
        Set(cases.compactMap { testCase -> String? in
            guard let checksum = testCase.audioSHA256?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  !checksum.isEmpty else {
                return nil
            }
            return checksum
        }).count
    }

    private static func totalAudioDurationMs(in cases: [TranscriptionBenchmarkCase]) -> Double {
        cases.reduce(0) { total, testCase in
            guard let duration = testCase.audioDurationMs, duration > 0 else {
                return total
            }
            return total + duration
        }
    }

    private static func audioSources(in cases: [TranscriptionBenchmarkCase]) -> Set<TranscriptAudioSource> {
        var sources = Set<TranscriptAudioSource>()
        for testCase in cases {
            guard let transcriptPath = testCase.hypothesisTranscriptFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !transcriptPath.isEmpty,
                  let evidence = hypothesisTranscriptEvidence(of: URL(fileURLWithPath: transcriptPath)) else {
                continue
            }
            if let conditioningSource = evidence.audioConditioning?.audioSource,
               isReleaseAudioSource(conditioningSource) {
                sources.insert(conditioningSource)
            }
            for segment in evidence.segments ?? [] where isReleaseAudioSource(segment.audioSource) {
                sources.insert(segment.audioSource)
            }
        }
        return sources
    }

    private struct LocalRefinerEvidenceCounts {
        var decisionCount: Int
        var acceptedCount: Int
        var rejectedCount: Int
    }

    private static func localRefinerEvidenceCounts(in cases: [TranscriptionBenchmarkCase]) -> LocalRefinerEvidenceCounts {
        cases.reduce(LocalRefinerEvidenceCounts(decisionCount: 0, acceptedCount: 0, rejectedCount: 0)) { total, testCase in
            guard let transcriptPath = testCase.hypothesisTranscriptFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !transcriptPath.isEmpty,
                  let evidence = hypothesisTranscriptEvidence(of: URL(fileURLWithPath: transcriptPath)) else {
                return total
            }
            var updated = total
            for segment in evidence.segments ?? [] where Self.isLocalRefinerEvidence(segment) {
                updated.decisionCount += 1
                if segment.retentionReason == .localRefinerAccepted {
                    updated.acceptedCount += 1
                } else if segment.retentionReason == .localRefinerRejected {
                    updated.rejectedCount += 1
                }
            }
            return updated
        }
    }

    private static func isLocalRefinerEvidence(_ segment: TranscriptionHypothesisTranscriptEvidence.SegmentEvidence) -> Bool {
        isLocalRefinerEvidenceMarker(segment) && localRefinerEvidenceFailures(for: segment, prefix: "").isEmpty
    }

    private static func isLocalRefinerEvidenceMarker(_ segment: TranscriptionHypothesisTranscriptEvidence.SegmentEvidence) -> Bool {
        segment.transcriptionEngine == .whisperKit ||
            segment.finalizedBy == .whisperKit ||
            segment.retentionReason == .localRefinerAccepted ||
            segment.retentionReason == .localRefinerRejected
    }

    private static func localRefinerEvidenceFailures(
        for segment: TranscriptionHypothesisTranscriptEvidence.SegmentEvidence,
        prefix: String
    ) -> [String] {
        guard isLocalRefinerEvidenceMarker(segment) else { return [] }
        var failures = [String]()
        if segment.revisionOfSegmentId == nil {
            failures.append("hypothesis_segment_local_refiner_missing_revision_root:\(prefix)")
        }
        if segment.revisionNumber <= 0 {
            failures.append("hypothesis_segment_local_refiner_invalid_revision_number:\(prefix)")
        }
        if !segment.isFinal && segment.transcriptionPhase != .final && segment.transcriptionPhase != .refined {
            failures.append("hypothesis_segment_local_refiner_not_committed:\(prefix)")
        }
        if segment.retentionReason == .localRefinerAccepted {
            if segment.transcriptionEngine != .whisperKit && segment.finalizedBy != .whisperKit {
                failures.append("hypothesis_segment_local_refiner_accepted_without_whisperkit:\(prefix)")
            }
        } else if segment.transcriptionEngine == .whisperKit || segment.finalizedBy == .whisperKit {
            failures.append("hypothesis_segment_whisperkit_missing_acceptance_reason:\(prefix)")
        }
        if segment.retentionReason == .localRefinerRejected,
           segment.transcriptionEngine == .whisperKit || segment.finalizedBy == .whisperKit {
            failures.append("hypothesis_segment_local_refiner_rejected_marked_as_whisperkit_final:\(prefix)")
        }
        return failures
    }

    private static func isReleaseAudioSource(_ source: TranscriptAudioSource) -> Bool {
        switch source {
        case .microphone, .system:
            return true
        case .mixed, .cloud, .unknown:
            return false
        }
    }

    private static func roundedMilliseconds(_ value: Double) -> String {
        String(format: "%.0f", value.rounded())
    }

    private static func audioEvidenceFailures(
        for testCase: TranscriptionBenchmarkCase,
        corpus: TranscriptionEvaluationCorpus,
        policy: TranscriptionReleaseGatePolicy
    ) -> [String] {
        var failures = [String]()
        let evidenceKind = testCase.evidenceKind ?? .synthetic
        if let allowed = policy.requiredEvidenceKindsByCorpus[corpus],
           !allowed.contains(evidenceKind) {
            failures.append("unsupported_evidence_kind:\(testCase.id):\(evidenceKind.rawValue)")
        }

        guard let audioFilePath = testCase.audioFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !audioFilePath.isEmpty else {
            failures.append("missing_audio_file:\(testCase.id)")
            if policy.requireAudioChecksumForRequiredCorpora {
                failures.append("missing_audio_checksum:\(testCase.id)")
            }
            return failures
        }

        let url = URL(fileURLWithPath: audioFilePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: audioFilePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            failures.append("audio_file_not_found:\(testCase.id)")
            if policy.requireAudioChecksumForRequiredCorpora {
                failures.append("missing_audio_checksum:\(testCase.id)")
            }
            return failures
        }

        if policy.requireNonTemporaryAudioEvidenceForExternalCorpora,
           corpus != .internalCritical,
           Self.isTemporaryAudioEvidencePath(audioFilePath) {
            failures.append("temporary_external_corpus_audio:\(testCase.id)")
        }

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if (values.fileSize ?? 0) <= 0 {
                failures.append("empty_audio_file:\(testCase.id)")
            }
        } catch {
            failures.append("unreadable_audio_file:\(testCase.id)")
        }

        if policy.requireAudioChecksumForRequiredCorpora {
            guard let expectedChecksum = testCase.audioSHA256?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !expectedChecksum.isEmpty else {
                failures.append("missing_audio_checksum:\(testCase.id)")
                return failures
            }
            guard let actualChecksum = sha256HexDigest(of: url) else {
                failures.append("unreadable_audio_checksum:\(testCase.id)")
                return failures
            }
            if actualChecksum.lowercased() != expectedChecksum.lowercased() {
                failures.append("audio_checksum_mismatch:\(testCase.id)")
            }
        }

        guard policy.requireDecodableAudioForRequiredCorpora else {
            return failures
        }
        guard let audioInfo = audioEvidenceInfo(of: url) else {
            failures.append("audio_file_not_decodable:\(testCase.id)")
            return failures
        }

        guard policy.requireAudioDurationMatchesEvidence else {
            return failures
        }
        guard let declaredDuration = testCase.audioDurationMs, declaredDuration > 0 else {
            failures.append("missing_audio_duration:\(testCase.id)")
            return failures
        }
        let allowedDrift = max(policy.maxAudioDurationMismatchMs, declaredDuration * 0.05)
        if abs(audioInfo.durationMs - declaredDuration) > allowedDrift {
            failures.append("audio_duration_mismatch:\(testCase.id)")
        }
        return failures
    }

    private static func hypothesisEvidenceFailures(
        for testCase: TranscriptionBenchmarkCase,
        corpus: TranscriptionEvaluationCorpus,
        policy: TranscriptionReleaseGatePolicy
    ) -> [String] {
        var failures = [String]()
        guard let source = testCase.hypothesisSource else {
            failures.append("missing_hypothesis_source:\(testCase.id)")
            if policy.requireHypothesisTranscriptChecksumForRequiredCorpora {
                failures.append("missing_hypothesis_transcript_checksum:\(testCase.id)")
            }
            return failures
        }
        if let allowed = policy.allowedHypothesisSourcesByCorpus[corpus],
           !allowed.contains(source) {
            failures.append("unsupported_hypothesis_source:\(testCase.id):\(source.rawValue)")
        }

        let engineIdentifier = testCase.hypothesisEngineIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if engineIdentifier.isEmpty {
            failures.append("missing_hypothesis_engine:\(testCase.id)")
        } else if isDisallowedHypothesisEngine(engineIdentifier, policy: policy) {
            failures.append("disallowed_hypothesis_engine:\(testCase.id):\(engineIdentifier)")
        }
        let runID = testCase.hypothesisRunID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if runID.isEmpty {
            failures.append("missing_hypothesis_run_id:\(testCase.id)")
        }

        guard let transcriptPath = testCase.hypothesisTranscriptFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcriptPath.isEmpty else {
            failures.append("missing_hypothesis_transcript_file:\(testCase.id)")
            if policy.requireHypothesisTranscriptChecksumForRequiredCorpora {
                failures.append("missing_hypothesis_transcript_checksum:\(testCase.id)")
            }
            return failures
        }

        let url = URL(fileURLWithPath: transcriptPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: transcriptPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            failures.append("hypothesis_transcript_file_not_found:\(testCase.id)")
            if policy.requireHypothesisTranscriptChecksumForRequiredCorpora {
                failures.append("missing_hypothesis_transcript_checksum:\(testCase.id)")
            }
            return failures
        }

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if (values.fileSize ?? 0) <= 0 {
                failures.append("empty_hypothesis_transcript_file:\(testCase.id)")
            }
        } catch {
            failures.append("unreadable_hypothesis_transcript_file:\(testCase.id)")
        }

        if policy.requireHypothesisTranscriptChecksumForRequiredCorpora {
            guard let expectedChecksum = testCase.hypothesisTranscriptSHA256?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !expectedChecksum.isEmpty else {
                failures.append("missing_hypothesis_transcript_checksum:\(testCase.id)")
                return failures
            }
            guard let actualChecksum = sha256HexDigest(of: url) else {
                failures.append("unreadable_hypothesis_transcript_checksum:\(testCase.id)")
                return failures
            }
            if actualChecksum.lowercased() != expectedChecksum.lowercased() {
                failures.append("hypothesis_transcript_checksum_mismatch:\(testCase.id)")
            }
        }

        guard let evidence = hypothesisTranscriptEvidence(of: url) else {
            failures.append("hypothesis_transcript_not_decodable:\(testCase.id)")
            return failures
        }
        if evidence.caseID != testCase.id {
            failures.append("hypothesis_transcript_case_mismatch:\(testCase.id)")
        }
        if evidence.source != source {
            failures.append("hypothesis_transcript_source_mismatch:\(testCase.id)")
        }
        if !engineIdentifier.isEmpty,
           evidence.engineIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) != engineIdentifier {
            failures.append("hypothesis_transcript_engine_mismatch:\(testCase.id)")
        }
        if !runID.isEmpty,
           evidence.runID?.trimmingCharacters(in: .whitespacesAndNewlines) != runID {
            failures.append("hypothesis_transcript_run_mismatch:\(testCase.id)")
        }
        if normalizedEvidenceText(evidence.hypothesis) != normalizedEvidenceText(testCase.hypothesis) {
            failures.append("hypothesis_transcript_text_mismatch:\(testCase.id)")
        }
        if policy.requireAudioChecksumForRequiredCorpora {
            let expectedAudioChecksum = testCase.audioSHA256?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let evidenceAudioChecksum = evidence.audioSHA256?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if expectedAudioChecksum.isEmpty {
                failures.append("missing_hypothesis_audio_checksum_reference:\(testCase.id)")
            } else if evidenceAudioChecksum.isEmpty {
                failures.append("missing_hypothesis_audio_checksum:\(testCase.id)")
            } else if evidenceAudioChecksum.lowercased() != expectedAudioChecksum.lowercased() {
                failures.append("hypothesis_audio_checksum_mismatch:\(testCase.id)")
            }
        }
        if policy.requireAudioDurationMatchesEvidence {
            guard let expectedDuration = testCase.audioDurationMs, expectedDuration > 0 else {
                failures.append("missing_hypothesis_audio_duration_reference:\(testCase.id)")
                return failures
            }
            guard let evidenceDuration = evidence.audioDurationMs, evidenceDuration > 0 else {
                failures.append("missing_hypothesis_audio_duration:\(testCase.id)")
                return failures
            }
            let allowedDrift = max(policy.maxAudioDurationMismatchMs, expectedDuration * 0.05)
            if abs(evidenceDuration - expectedDuration) > allowedDrift {
                failures.append("hypothesis_audio_duration_mismatch:\(testCase.id)")
            }
        }
        if let expectedLatencyMode = testCase.latencyMeasurementMode {
            guard let evidenceLatencyMode = evidence.latencyMeasurementMode else {
                failures.append("missing_hypothesis_latency_measurement_mode:\(testCase.id)")
                return failures
            }
            if evidenceLatencyMode != expectedLatencyMode {
                failures.append("hypothesis_latency_measurement_mode_mismatch:\(testCase.id)")
            }
        }
        if let expectedChunkDuration = testCase.replayChunkDurationMs {
            guard let evidenceChunkDuration = evidence.replayChunkDurationMs else {
                failures.append("missing_hypothesis_replay_chunk_duration:\(testCase.id)")
                return failures
            }
            if abs(evidenceChunkDuration - expectedChunkDuration) > 0.5 {
                failures.append("hypothesis_replay_chunk_duration_mismatch:\(testCase.id)")
            }
        }

        let tags = Set(testCase.evaluationTags ?? [])
        let isCriticalNonSpeech = tags.contains(.criticalNonSpeech)
        let expectedSpeech = !testCase.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCriticalNonSpeech
        let segmentCount = evidence.segmentCount ?? -1
        if expectedSpeech, segmentCount <= 0 {
            failures.append("hypothesis_transcript_missing_speech_segments:\(testCase.id)")
        }
        if isCriticalNonSpeech, segmentCount > 0 {
            failures.append("hypothesis_transcript_non_speech_segments:\(testCase.id)")
        }
        if policy.requireHypothesisSegmentEvidenceForRequiredCorpora,
           policy.requiredCorpora.contains(corpus) {
            failures.append(contentsOf: Self.hypothesisSegmentEvidenceFailures(
                for: testCase,
                evidence: evidence,
                expectedSpeech: expectedSpeech,
                isCriticalNonSpeech: isCriticalNonSpeech,
                segmentCount: segmentCount
            ))
        }
        if policy.requireAudioConditioningEvidenceForRequiredCorpora,
           policy.requiredCorpora.contains(corpus) {
            failures.append(contentsOf: Self.audioConditioningEvidenceFailures(
                for: testCase,
                evidence: evidence.audioConditioning,
                expectedSpeech: expectedSpeech,
                isCriticalNonSpeech: isCriticalNonSpeech
            ))
        }
        if let expectedProvenance = testCase.corpusProvenance,
           corpus != .internalCritical {
            guard let evidenceProvenance = evidence.corpusProvenance else {
                failures.append("missing_hypothesis_corpus_provenance:\(testCase.id)")
                return failures
            }
            if evidenceProvenance != expectedProvenance {
                failures.append("hypothesis_corpus_provenance_mismatch:\(testCase.id)")
            }
        }
        return failures
    }

    private static func audioConditioningEvidenceFailures(
        for testCase: TranscriptionBenchmarkCase,
        evidence: TranscriptionAudioConditioningEvidence?,
        expectedSpeech: Bool,
        isCriticalNonSpeech: Bool
    ) -> [String] {
        guard let evidence else {
            return ["missing_audio_conditioning_evidence:\(testCase.id)"]
        }
        var failures = [String]()
        if evidence.audioSource == .unknown || evidence.audioSource == .cloud {
            failures.append("audio_conditioning_missing_source:\(testCase.id)")
        }
        if let expectedAudioSource = testCase.audioSource,
           Self.isReleaseAudioSource(expectedAudioSource),
           evidence.audioSource != expectedAudioSource {
            failures.append("audio_conditioning_source_mismatch:\(testCase.id)")
        }
        if evidence.conditioningTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append("audio_conditioning_missing_target:\(testCase.id)")
        }
        failures.append(contentsOf: Self.audioConditioningCountFailures(for: testCase, evidence: evidence))
        if evidence.inputBufferCount <= 0 {
            failures.append("audio_conditioning_missing_input_buffers:\(testCase.id)")
        }
        if !evidence.advancedConditioningEnabled {
            failures.append("audio_conditioning_advanced_disabled:\(testCase.id)")
        }
        if !evidence.vadGatingEnabled {
            failures.append("audio_conditioning_vad_disabled:\(testCase.id)")
        }
        if evidence.vadEngineCounts.isEmpty {
            failures.append("audio_conditioning_missing_vad_engine:\(testCase.id)")
        }
        if evidence.vadEngineCounts[VoiceActivityDetectionEngine.vadDisabledPassthrough.rawValue, default: 0] > 0 {
            failures.append("audio_conditioning_vad_passthrough:\(testCase.id)")
        }
        if evidence.inputSampleRates.isEmpty {
            failures.append("audio_conditioning_missing_sample_rate:\(testCase.id)")
        }
        if evidence.inputSampleRates.contains(where: { !$0.isFinite || $0 < 8_000 || $0 > 192_000 }) {
            failures.append("audio_conditioning_invalid_sample_rate:\(testCase.id)")
        }
        if evidence.inputChannelCounts.isEmpty {
            failures.append("audio_conditioning_missing_channel_count:\(testCase.id)")
        }
        if evidence.inputChannelCounts.contains(where: { $0 <= 0 || $0 > 8 }) {
            failures.append("audio_conditioning_invalid_channel_count:\(testCase.id)")
        }
        if !evidence.averageRMS.isFinite || evidence.averageRMS < 0 || !evidence.peakMax.isFinite || evidence.peakMax < 0 {
            failures.append("audio_conditioning_invalid_energy:\(testCase.id)")
        }
        failures.append(contentsOf: Self.audioConditioningSNRFailures(for: testCase, evidence: evidence))
        if evidence.forwardedDecisionCount + evidence.droppedDecisionCount != evidence.inputBufferCount {
            failures.append("audio_conditioning_decision_count_mismatch:\(testCase.id)")
        }

        if expectedSpeech {
            if evidence.forwardedDecisionCount <= 0 || evidence.emittedBufferCount <= 0 {
                failures.append("audio_conditioning_no_speech_forwarded:\(testCase.id)")
            }
            if evidence.speechDecisionCount <= 0 {
                failures.append("audio_conditioning_no_speech_decision:\(testCase.id)")
            }
            if evidence.peakMax <= 0 || evidence.averageRMS <= 0 {
                failures.append("audio_conditioning_missing_energy:\(testCase.id)")
            }
        }
        if isCriticalNonSpeech {
            if evidence.forwardedDecisionCount > 0 || evidence.emittedBufferCount > 0 || evidence.speechDecisionCount > 0 {
                failures.append("audio_conditioning_forwarded_non_speech:\(testCase.id)")
            }
            if evidence.droppedDecisionCount <= 0 || evidence.nonSpeechDecisionCount <= 0 {
                failures.append("audio_conditioning_missing_non_speech_drop:\(testCase.id)")
            }
        }
        return failures
    }

    private static func audioConditioningCountFailures(
        for testCase: TranscriptionBenchmarkCase,
        evidence: TranscriptionAudioConditioningEvidence
    ) -> [String] {
        let counts = [
            evidence.inputBufferCount,
            evidence.emittedBufferCount,
            evidence.forwardedDecisionCount,
            evidence.droppedDecisionCount,
            evidence.speechDecisionCount,
            evidence.nonSpeechDecisionCount,
            evidence.clippingDecisionCount,
            evidence.lowEnergyDropCount,
            evidence.preRollReplayBufferCount
        ]
        var failures = [String]()
        if counts.contains(where: { $0 < 0 }) {
            failures.append("audio_conditioning_invalid_counts:\(testCase.id)")
        }
        if evidence.emittedBufferCount > evidence.inputBufferCount + evidence.preRollReplayBufferCount {
            failures.append("audio_conditioning_emitted_count_exceeds_source:\(testCase.id)")
        }
        if evidence.clippingDecisionCount > evidence.inputBufferCount ||
            evidence.lowEnergyDropCount > evidence.inputBufferCount ||
            evidence.speechDecisionCount > evidence.inputBufferCount ||
            evidence.nonSpeechDecisionCount > evidence.inputBufferCount {
            failures.append("audio_conditioning_decision_subcount_exceeds_input:\(testCase.id)")
        }
        if evidence.vadEngineCounts.values.contains(where: { $0 <= 0 }) {
            failures.append("audio_conditioning_invalid_vad_engine_count:\(testCase.id)")
        }
        return failures
    }

    private static func audioConditioningSNRFailures(
        for testCase: TranscriptionBenchmarkCase,
        evidence: TranscriptionAudioConditioningEvidence
    ) -> [String] {
        let snrValues = [evidence.snrP50Db, evidence.snrP95Db].compactMap { $0 }
        guard !snrValues.isEmpty else {
            return []
        }
        var failures = [String]()
        if snrValues.contains(where: { !$0.isFinite || $0 < -120 || $0 > 120 }) {
            failures.append("audio_conditioning_invalid_snr:\(testCase.id)")
        }
        if let snrP50 = evidence.snrP50Db,
           let snrP95 = evidence.snrP95Db,
           snrP50.isFinite,
           snrP95.isFinite,
           snrP95 < snrP50 {
            failures.append("audio_conditioning_snr_percentile_order:\(testCase.id)")
        }
        return failures
    }

    private static func hypothesisSegmentEvidenceFailures(
        for testCase: TranscriptionBenchmarkCase,
        evidence: TranscriptionHypothesisTranscriptEvidence,
        expectedSpeech: Bool,
        isCriticalNonSpeech: Bool,
        segmentCount: Int
    ) -> [String] {
        var failures = [String]()
        guard let segments = evidence.segments else {
            failures.append("missing_hypothesis_segments:\(testCase.id)")
            return failures
        }
        if segmentCount >= 0, segments.count != segmentCount {
            failures.append("hypothesis_segment_count_mismatch:\(testCase.id):\(segments.count)/\(segmentCount)")
        }
        if expectedSpeech, segments.isEmpty {
            failures.append("hypothesis_segments_missing_speech:\(testCase.id)")
        }
        if isCriticalNonSpeech, !segments.isEmpty {
            failures.append("hypothesis_segments_present_for_non_speech:\(testCase.id)")
        }

        let joinedSegmentText = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedEvidenceText(joinedSegmentText) != normalizedEvidenceText(evidence.hypothesis) {
            failures.append("hypothesis_segments_text_mismatch:\(testCase.id)")
        }

        var previousEnd: TimeInterval?
        var previousText: String?
        let expectedAudioSource = testCase.audioSource.flatMap {
            Self.isReleaseAudioSource($0) ? $0 : nil
        }
        let tags = Set(testCase.evaluationTags ?? [])
        var observedLanguageSpanCodes = Set<String>()
        var hasSpokenLanguageIDEvidence = false
        var previousSourceFrameEndBySource: [TranscriptAudioSource: Int64] = [:]
        for (index, segment) in segments.enumerated() {
            let prefix = "\(testCase.id):\(index)"
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("empty_hypothesis_segment:\(prefix)")
            }
            if segment.audioSource == .unknown || segment.audioSource == .cloud {
                failures.append("hypothesis_segment_missing_source_tag:\(prefix)")
            }
            if let expectedAudioSource, segment.audioSource != expectedAudioSource {
                failures.append("hypothesis_segment_source_mismatch:\(prefix)")
            }
            if !segment.startTime.isFinite || !segment.endTime.isFinite || segment.startTime < 0 || segment.endTime < segment.startTime {
                failures.append("hypothesis_segment_invalid_time_range:\(prefix)")
            }
            if let previousEnd, segment.startTime + 0.020 < previousEnd {
                failures.append("hypothesis_segment_time_regression:\(prefix)")
            }
            previousEnd = max(previousEnd ?? segment.endTime, segment.endTime)
            let normalizedText = normalizedEvidenceText(segment.text)
            if !normalizedText.isEmpty, normalizedText == previousText {
                failures.append("hypothesis_segment_adjacent_duplicate:\(prefix)")
            }
            previousText = normalizedText
            if expectedSpeech, !segment.isFinal && segment.transcriptionPhase != .refined && segment.transcriptionPhase != .final {
                failures.append("hypothesis_segment_not_committed:\(prefix)")
            }
            if expectedSpeech, !segment.confidence.isFinite || segment.confidence < 0 || segment.confidence > 1 {
                failures.append("hypothesis_segment_invalid_confidence:\(prefix)")
            }
            if let engineConfidence = segment.engineConfidence,
               !engineConfidence.isFinite || engineConfidence < 0 || engineConfidence > 1 {
                failures.append("hypothesis_segment_invalid_engine_confidence:\(prefix)")
            }
            if let languageConfidence = segment.languageConfidence,
               !languageConfidence.isFinite || languageConfidence < 0 || languageConfidence > 1 {
                failures.append("hypothesis_segment_invalid_language_confidence:\(prefix)")
            }
            if expectedSpeech,
               segment.languageCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                failures.append("hypothesis_segment_missing_language_code:\(prefix)")
            }
            failures.append(contentsOf: Self.hypothesisLanguageEvidenceFailures(
                for: segment,
                prefix: prefix,
                observedLanguageSpanCodes: &observedLanguageSpanCodes,
                hasSpokenLanguageIDEvidence: &hasSpokenLanguageIDEvidence
            ))
            if segment.revisionNumber < 0 {
                failures.append("hypothesis_segment_invalid_revision_number:\(prefix)")
            }
            if segment.wordTimestampCount < 0 {
                failures.append("hypothesis_segment_invalid_word_timestamp_count:\(prefix)")
            }
            if let sourceFrameRange = segment.sourceFrameRange,
               sourceFrameRange.start < 0 || sourceFrameRange.end <= sourceFrameRange.start {
                failures.append("hypothesis_segment_invalid_source_frame_range:\(prefix)")
            }
            if let sourceFrameRange = segment.sourceFrameRange,
               sourceFrameRange.start >= 0,
               sourceFrameRange.end > sourceFrameRange.start {
                if let previousSourceFrameEnd = previousSourceFrameEndBySource[segment.audioSource],
                   sourceFrameRange.start < previousSourceFrameEnd {
                    failures.append("hypothesis_segment_source_frame_regression:\(prefix)")
                }
                previousSourceFrameEndBySource[segment.audioSource] = max(
                    previousSourceFrameEndBySource[segment.audioSource] ?? sourceFrameRange.end,
                    sourceFrameRange.end
                )
            }
            if let audioDurationMs = testCase.audioDurationMs,
               audioDurationMs > 0,
               segment.endTime.isFinite,
               segment.endTime * 1_000 > audioDurationMs + 250 {
                failures.append("hypothesis_segment_exceeds_audio_duration:\(prefix)")
            }
            failures.append(contentsOf: localRefinerEvidenceFailures(for: segment, prefix: prefix))
        }
        if expectedSpeech, tags.contains(.spokenLanguageID), !hasSpokenLanguageIDEvidence {
            failures.append("missing_spoken_language_id_evidence:\(testCase.id)")
        }
        if expectedSpeech, tags.contains(.codeSwitching), observedLanguageSpanCodes.count < 2 {
            failures.append("missing_code_switch_language_span_evidence:\(testCase.id)")
        }
        return failures
    }

    private static func hypothesisLanguageEvidenceFailures(
        for segment: TranscriptionHypothesisTranscriptEvidence.SegmentEvidence,
        prefix: String,
        observedLanguageSpanCodes: inout Set<String>,
        hasSpokenLanguageIDEvidence: inout Bool
    ) -> [String] {
        var failures = [String]()
        let languageCodes = ([segment.languageCode] + (segment.languageSpanCodes ?? []).map(Optional.some)).compactMap { $0 }
        for code in languageCodes {
            let normalized = normalizedLocale(code)
            if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("hypothesis_segment_invalid_language_span_code:\(prefix)")
            } else {
                observedLanguageSpanCodes.insert(normalized)
            }
        }

        if let spanCodes = segment.languageSpanCodes,
           spanCodes.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            failures.append("hypothesis_segment_empty_language_span_code:\(prefix)")
        }

        if let source = segment.languageEvidenceSource {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                failures.append("hypothesis_segment_empty_language_evidence_source:\(prefix)")
            } else if isSpokenLanguageEvidenceSource(trimmed) {
                hasSpokenLanguageIDEvidence = true
                if segment.languageConfidence == nil {
                    failures.append("hypothesis_segment_missing_spoken_lid_confidence:\(prefix)")
                }
                guard let window = segment.languageDetectionWindowMs else {
                    failures.append("hypothesis_segment_missing_spoken_lid_window:\(prefix)")
                    return failures
                }
                if !window.isFinite || window <= 0 || window > 5_000 {
                    failures.append("hypothesis_segment_invalid_spoken_lid_window:\(prefix)")
                }
            }
        }

        if let window = segment.languageDetectionWindowMs,
           (!window.isFinite || window <= 0 || window > 30_000) {
            failures.append("hypothesis_segment_invalid_language_detection_window:\(prefix)")
        }
        return failures
    }

    private static func isSpokenLanguageEvidenceSource(_ source: String) -> Bool {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.contains("text") && !normalized.contains("requested-locale") else {
            return false
        }
        return normalized.contains("spoken") ||
            normalized.contains("audio") ||
            normalized.contains("lid") ||
            normalized.contains("voxlingua") ||
            normalized.contains("whisperkit-auto-language")
    }

    private struct AudioEvidenceInfo {
        var durationMs: Double
        var sampleRate: Double
        var channelCount: AVAudioChannelCount
    }

    private static func audioEvidenceInfo(of url: URL) -> AudioEvidenceInfo? {
        guard let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        let format = file.fileFormat
        guard format.sampleRate > 0, format.channelCount > 0, file.length > 0 else {
            return nil
        }
        return AudioEvidenceInfo(
            durationMs: (Double(file.length) / format.sampleRate) * 1_000,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount
        )
    }

    private static func sha256HexDigest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hypothesisTranscriptEvidence(of url: URL) -> TranscriptionHypothesisTranscriptEvidence? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return try? JSONDecoder().decode(TranscriptionHypothesisTranscriptEvidence.self, from: data)
    }

    private static func isDisallowedHypothesisEngine(
        _ engineIdentifier: String,
        policy: TranscriptionReleaseGatePolicy
    ) -> Bool {
        let normalizedEngine = engineIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return policy.disallowedHypothesisEnginePrefixesForRequiredCorpora.contains { prefix in
            let normalizedPrefix = prefix
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return !normalizedPrefix.isEmpty && normalizedEngine.hasPrefix(normalizedPrefix)
        }
    }

    private static func normalizedEvidenceText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedLocale(_ locale: String) -> String {
        SupportedLanguage.language(for: locale)?.rawValue ?? locale
    }

    private static func isExternalCorpusURI(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("https://") || lowercased.hasPrefix("doi:")
    }

    private static func isApprovedPublicCorpusSourceURI(
        _ value: String,
        corpus: TranscriptionEvaluationCorpus,
        policy: TranscriptionReleaseGatePolicy
    ) -> Bool {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let prefixes = policy.allowedPublicCorpusSourceURIPrefixes[corpus],
              !prefixes.isEmpty else {
            return true
        }
        return prefixes.contains { prefix in
            let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !normalizedPrefix.isEmpty && lowercased.hasPrefix(normalizedPrefix)
        }
    }

    private static func isTemporaryAudioEvidencePath(_ value: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: value)
            .standardizedFileURL
            .path
            .lowercased()
        let temporaryPrefixes = [
            FileManager.default.temporaryDirectory.standardizedFileURL.path,
            NSTemporaryDirectory(),
            "/private/tmp",
            "/tmp",
            "/private/var/tmp",
            "/var/tmp"
        ]
        return temporaryPrefixes.contains { prefix in
            let normalizedPrefix = URL(fileURLWithPath: prefix)
                .standardizedFileURL
                .path
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !normalizedPrefix.isEmpty else { return false }
            return normalizedPath == "/\(normalizedPrefix)" || normalizedPath.hasPrefix("/\(normalizedPrefix)/")
        }
    }

    private static func isRedactedPrivateCorpusURI(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("private://") || lowercased.hasPrefix("notchly-private://")
    }
}

struct TranscriptionEvaluationManifest: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var suiteName: String
    var generatedAt: String?
    var cases: [TranscriptionBenchmarkCase]
    var baselineCases: [TranscriptionBenchmarkCase]?

    init(
        schemaVersion: Int = 1,
        suiteName: String,
        generatedAt: String? = nil,
        cases: [TranscriptionBenchmarkCase],
        baselineCases: [TranscriptionBenchmarkCase]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.suiteName = suiteName
        self.generatedAt = generatedAt
        self.cases = cases
        self.baselineCases = baselineCases
    }

    func resolvedCases(relativeTo baseURL: URL?) -> [TranscriptionBenchmarkCase] {
        cases.map { testCase in
            Self.resolvedCase(testCase, relativeTo: baseURL)
        }
    }

    func resolvedBaselineCases(relativeTo baseURL: URL?) -> [TranscriptionBenchmarkCase] {
        (baselineCases ?? []).map { testCase in
            Self.resolvedCase(testCase, relativeTo: baseURL)
        }
    }

    private static func resolvedCase(_ testCase: TranscriptionBenchmarkCase, relativeTo baseURL: URL?) -> TranscriptionBenchmarkCase {
        var resolved = testCase
        if let path = testCase.audioFilePath {
            resolved.audioFilePath = Self.resolvedAudioPath(path, relativeTo: baseURL)
        }
        if let path = testCase.hypothesisTranscriptFilePath {
            resolved.hypothesisTranscriptFilePath = Self.resolvedAudioPath(path, relativeTo: baseURL)
        }
        return resolved
    }

    private static func resolvedAudioPath(_ path: String, relativeTo baseURL: URL?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            return trimmed
        }
        guard let baseURL else { return trimmed }
        return baseURL.appendingPathComponent(trimmed).standardizedFileURL.path
    }
}

struct TranscriptionEvaluationRunReport: Codable, Hashable, Sendable {
    var suiteName: String
    var schemaVersion: Int
    var manifestCaseCount: Int
    var baselineCaseCount: Int
    var audioEvidenceCaseCount: Int
    var hypothesisEvidenceCaseCount: Int
    var releaseGateReport: TranscriptionReleaseGateReport
    var improvementComparisonReport: TranscriptionBenchmarkComparisonReport?
    var improvementGateFailures: [String]

    var passed: Bool {
        releaseGateReport.passed && improvementGateFailures.isEmpty
    }
}

struct TranscriptionEvaluationRunner: Sendable {
    func evaluate(
        manifestAt url: URL,
        policy: TranscriptionReleaseGatePolicy = .topTierRelease
    ) throws -> TranscriptionEvaluationRunReport {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(TranscriptionEvaluationManifest.self, from: data)
        return evaluate(manifest: manifest, baseURL: url.deletingLastPathComponent(), policy: policy)
    }

    func evaluate(
        manifest: TranscriptionEvaluationManifest,
        baseURL: URL? = nil,
        policy: TranscriptionReleaseGatePolicy = .topTierRelease
    ) -> TranscriptionEvaluationRunReport {
        let cases = manifest.resolvedCases(relativeTo: baseURL)
        let baselineCases = manifest.resolvedBaselineCases(relativeTo: baseURL)
        let gateReport = TranscriptionReleaseGate().evaluate(cases: cases, policy: policy)
        let comparisonReport = baselineCases.isEmpty
            ? nil
            : TranscriptionBenchmarkComparator().compare(
                baseline: baselineCases,
                candidate: cases,
                benchmarkThresholds: policy.thresholds
            )
        let improvementFailures: [String]
        if baselineCases.isEmpty, policy.requireBaselineImprovementComparison {
            improvementFailures = ["missing_baseline_comparison_cases"]
        } else if let comparisonReport, !comparisonReport.passed {
            improvementFailures = comparisonReport.failures.map { "baseline_comparison_failed:\($0)" }
        } else {
            improvementFailures = []
        }
        return TranscriptionEvaluationRunReport(
            suiteName: manifest.suiteName,
            schemaVersion: manifest.schemaVersion,
            manifestCaseCount: manifest.cases.count,
            baselineCaseCount: baselineCases.count,
            audioEvidenceCaseCount: cases.filter {
                !($0.audioFilePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }.count,
            hypothesisEvidenceCaseCount: cases.filter {
                !($0.hypothesisTranscriptFilePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }.count,
            releaseGateReport: gateReport,
            improvementComparisonReport: comparisonReport,
            improvementGateFailures: improvementFailures
        )
    }
}

struct TranscriptionEvaluationReplayConfiguration: Codable, Hashable, Sendable {
    var runID: String
    var chunkDurationMs: Double
    var postAudioDrainMs: Double
    var replayInRealTime: Bool
    var audioSource: TranscriptAudioSource
    var hypothesisSource: TranscriptionHypothesisSource?
    var engineIdentifier: String
    var generatedAt: String

    init(
        runID: String = "notchly-replay-\(UUID().uuidString)",
        chunkDurationMs: Double = 120,
        postAudioDrainMs: Double = 850,
        replayInRealTime: Bool = false,
        audioSource: TranscriptAudioSource = .system,
        hypothesisSource: TranscriptionHypothesisSource? = nil,
        engineIdentifier: String = "notchly-local-asr-replay",
        generatedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.runID = runID
        self.chunkDurationMs = chunkDurationMs
        self.postAudioDrainMs = postAudioDrainMs
        self.replayInRealTime = replayInRealTime
        self.audioSource = audioSource
        self.hypothesisSource = hypothesisSource
        self.engineIdentifier = engineIdentifier
        self.generatedAt = generatedAt
    }
}

struct TranscriptionEvaluationReplayCaseReport: Codable, Hashable, Sendable {
    var caseID: String
    var audioFilePath: String
    var audioSource: TranscriptAudioSource?
    var hypothesisTranscriptFilePath: String
    var hypothesisTranscriptSHA256: String
    var audioSHA256: String
    var audioDurationMs: Double
    var processingDurationMs: Double
    var firstPartialLatencyMs: Double?
    var finalLatencyMs: Double?
    var latencyMeasurementMode: TranscriptionLatencyMeasurementMode
    var replayChunkDurationMs: Double
    var memoryResidentBytes: UInt64?
    var cpuUsagePercent: Double?
    var segmentCount: Int
    var audioConditioningEvidence: TranscriptionAudioConditioningEvidence?
    var hypothesisSource: TranscriptionHypothesisSource
    var engineIdentifier: String
}

struct TranscriptionEvaluationReplayRunReport: Codable, Hashable, Sendable {
    var runID: String
    var generatedAt: String
    var outputManifestPath: String
    var caseReports: [TranscriptionEvaluationReplayCaseReport]
    var manifest: TranscriptionEvaluationManifest
    var evaluationReport: TranscriptionEvaluationRunReport

    var passed: Bool {
        evaluationReport.passed
    }
}

enum TranscriptionEvaluationReplayError: LocalizedError, Sendable {
    case missingAudioFilePath(String)
    case audioFileNotFound(String)
    case audioFileUnreadable(String)
    case audioFileHasNoFrames(String)
    case outputDirectoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioFilePath(let id):
            "Benchmark case \(id) has no audio file path for ASR replay."
        case .audioFileNotFound(let path):
            "ASR replay audio file was not found: \(path)"
        case .audioFileUnreadable(let path):
            "ASR replay audio file could not be decoded: \(path)"
        case .audioFileHasNoFrames(let path):
            "ASR replay audio file has no readable frames: \(path)"
        case .outputDirectoryUnavailable(let path):
            "ASR replay output directory could not be created: \(path)"
        }
    }
}

@MainActor
struct TranscriptionEvaluationReplayRunner {
    typealias ServiceFactory = @MainActor (_ audioStream: AsyncStream<AudioBuffer>, _ source: TranscriptAudioSource) -> any TranscriptionService

    private let serviceFactory: ServiceFactory

    init(serviceFactory: ServiceFactory? = nil) {
        self.serviceFactory = serviceFactory ?? { audioStream, source in
            StreamingASRRouter(sources: [
                StreamingASRRouter.Source(
                    speakerLabel: Self.speakerLabel(for: source),
                    audioSource: source,
                    audioStream: audioStream
                )
            ])
        }
    }

    func replay(
        manifest: TranscriptionEvaluationManifest,
        baseURL: URL? = nil,
        outputDirectory: URL,
        baseConfig: TranscriptionConfig,
        policy: TranscriptionReleaseGatePolicy = .topTierRelease,
        configuration: TranscriptionEvaluationReplayConfiguration = TranscriptionEvaluationReplayConfiguration()
    ) async throws -> TranscriptionEvaluationReplayRunReport {
        guard (try? outputDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != false else {
            throw TranscriptionEvaluationReplayError.outputDirectoryUnavailable(outputDirectory.path)
        }
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw TranscriptionEvaluationReplayError.outputDirectoryUnavailable(outputDirectory.path)
        }

        var updatedCases = [TranscriptionBenchmarkCase]()
        var caseReports = [TranscriptionEvaluationReplayCaseReport]()
        let resolvedCases = manifest.resolvedCases(relativeTo: baseURL)

        for testCase in resolvedCases {
            let replayed = try await replayCase(
                testCase,
                outputDirectory: outputDirectory,
                baseConfig: baseConfig,
                configuration: configuration
            )
            updatedCases.append(replayed.case)
            caseReports.append(replayed.report)
        }

        let replayManifest = TranscriptionEvaluationManifest(
            schemaVersion: manifest.schemaVersion,
            suiteName: manifest.suiteName,
            generatedAt: configuration.generatedAt,
            cases: updatedCases,
            baselineCases: Self.baselineCasesWithReplayAudioIdentity(
                manifest.baselineCases,
                replayedCases: updatedCases
            )
        )
        let outputManifestURL = outputDirectory.appendingPathComponent("transcription-replay-manifest-\(configuration.runID).json")
        try JSONEncoder.prettyBenchmarkEncoder.encode(replayManifest).write(to: outputManifestURL, options: .atomic)
        let evaluationReport = TranscriptionEvaluationRunner().evaluate(
            manifest: replayManifest,
            baseURL: outputDirectory,
            policy: policy
        )
        return TranscriptionEvaluationReplayRunReport(
            runID: configuration.runID,
            generatedAt: configuration.generatedAt,
            outputManifestPath: outputManifestURL.path,
            caseReports: caseReports,
            manifest: replayManifest,
            evaluationReport: evaluationReport
        )
    }

    func replay(
        manifestAt url: URL,
        outputDirectory: URL,
        baseConfig: TranscriptionConfig,
        policy: TranscriptionReleaseGatePolicy = .topTierRelease,
        configuration: TranscriptionEvaluationReplayConfiguration = TranscriptionEvaluationReplayConfiguration()
    ) async throws -> TranscriptionEvaluationReplayRunReport {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(TranscriptionEvaluationManifest.self, from: data)
        return try await replay(
            manifest: manifest,
            baseURL: url.deletingLastPathComponent(),
            outputDirectory: outputDirectory,
            baseConfig: baseConfig,
            policy: policy,
            configuration: configuration
        )
    }

    private func replayCase(
        _ testCase: TranscriptionBenchmarkCase,
        outputDirectory: URL,
        baseConfig: TranscriptionConfig,
        configuration: TranscriptionEvaluationReplayConfiguration
    ) async throws -> (case: TranscriptionBenchmarkCase, report: TranscriptionEvaluationReplayCaseReport) {
        guard let audioPath = testCase.audioFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !audioPath.isEmpty else {
            throw TranscriptionEvaluationReplayError.missingAudioFilePath(testCase.id)
        }
        let audioURL = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionEvaluationReplayError.audioFileNotFound(audioURL.path)
        }
        let caseAudioSource = testCase.audioSource ?? configuration.audioSource
        let payload = try Self.audioPayload(
            from: audioURL,
            chunkDurationMs: configuration.chunkDurationMs,
            source: caseAudioSource
        )
        guard !payload.buffers.isEmpty else {
            throw TranscriptionEvaluationReplayError.audioFileHasNoFrames(audioURL.path)
        }

        var audioContinuation: AsyncStream<AudioBuffer>.Continuation?
        let audioStream = AsyncStream<AudioBuffer>(bufferingPolicy: .bufferingNewest(512)) { continuation in
            audioContinuation = continuation
        }
        guard let audioContinuation else {
            throw TranscriptionEvaluationReplayError.audioFileUnreadable(audioURL.path)
        }
        let service = serviceFactory(audioStream, caseAudioSource)

        var caseConfig = baseConfig
        caseConfig.languageCode = testCase.locale
        caseConfig.audioSource = caseAudioSource
        caseConfig.contextualStrings = testCase.activeVocabulary
        if caseConfig.speechContext == nil, !testCase.activeVocabulary.isEmpty || !testCase.namedEntities.isEmpty {
            let contextTerms = (testCase.activeVocabulary + testCase.namedEntities).map {
                SpeechContextTerm(
                    text: $0,
                    locale: testCase.locale,
                    category: .technicalTerm,
                    weight: 2.2,
                    pronunciationXSAMPA: nil,
                    source: "transcription-evaluation-replay"
                )
            }
            caseConfig.speechContext = SpeechRecognitionContext(
                locale: testCase.locale,
                terms: contextTerms,
                customLanguageModelEnabled: true,
                status: "Evaluation replay context"
            )
        }
        caseConfig.featureFlags.transcriptionMetricsEnabled = true

        let segmentStream = service.segments
        let collector = Task { @MainActor in
            var observations = [ReplaySegmentObservation]()
            for await segment in segmentStream {
                observations.append(ReplaySegmentObservation(segment: segment, observedAt: Date()))
            }
            return observations
        }

        await TranscriptionMetrics.shared.reset()
        let audioConditioningEvidence = Self.audioConditioningEvidence(
            from: payload,
            config: caseConfig,
            source: caseAudioSource
        )
        let startedAt = Date()
        do {
            try await service.startTranscription(audioStream: audioStream, config: caseConfig)
            for buffer in payload.buffers {
                audioContinuation.yield(buffer)
                if configuration.replayInRealTime {
                    let duration = Self.durationMs(of: buffer)
                    try await Task.sleep(nanoseconds: UInt64(max(1, duration) * 1_000_000))
                }
            }
            audioContinuation.finish()
            try await Task.sleep(nanoseconds: UInt64(max(0, configuration.postAudioDrainMs) * 1_000_000))
            await service.stop()
        } catch {
            audioContinuation.finish()
            await service.stop()
            collector.cancel()
            _ = await collector.value
            throw error
        }
        collector.cancel()
        let observations = await collector.value
        let processingDurationMs = Date().timeIntervalSince(startedAt) * 1_000
        let resourceSnapshot = await TranscriptionMetrics.shared.snapshot()
        let committedSegments = Self.committedSegments(from: observations)
        let hypothesis = Self.joinedTranscript(from: committedSegments)
        let source = configuration.hypothesisSource ?? Self.hypothesisSource(from: committedSegments)
        let firstPartialLatency = Self.firstObservedTextLatencyMs(in: observations, since: startedAt)
        let finalLatency = Self.finalObservedTextLatencyMs(in: observations, since: startedAt)
        let latencyMeasurementMode: TranscriptionLatencyMeasurementMode = configuration.replayInRealTime ? .realtimeReplay : .offlineReplay
        let memoryResidentBytes = resourceSnapshot.memoryResidentBytes
        let cpuUsagePercent = resourceSnapshot.cpuUsagePercent

        let evidence = TranscriptionHypothesisTranscriptEvidence(
            caseID: testCase.id,
            hypothesis: hypothesis,
            source: source,
            engineIdentifier: configuration.engineIdentifier,
            runID: configuration.runID,
            locale: testCase.locale,
            segmentCount: committedSegments.count,
            segments: Self.hypothesisSegmentEvidence(from: committedSegments),
            audioSHA256: payload.audioSHA256,
            audioDurationMs: payload.durationMs,
            audioConditioning: audioConditioningEvidence,
            latencyMeasurementMode: latencyMeasurementMode,
            replayChunkDurationMs: configuration.chunkDurationMs,
            postAudioDrainMs: configuration.postAudioDrainMs,
            generatedAt: configuration.generatedAt,
            corpusProvenance: testCase.corpusProvenance
        )
        let evidenceURL = outputDirectory.appendingPathComponent("\(Self.safeFileComponent(testCase.id)).hypothesis.json")
        try JSONEncoder.prettyBenchmarkEncoder.encode(evidence).write(to: evidenceURL, options: .atomic)
        let evidenceSHA256 = Self.sha256HexDigest(of: evidenceURL) ?? ""

        var updated = testCase
        updated.hypothesis = hypothesis
        updated.audioFilePath = audioURL.path
        updated.audioSource = caseAudioSource
        updated.audioSHA256 = payload.audioSHA256
        updated.audioDurationMs = payload.durationMs
        updated.hypothesisSource = source
        updated.hypothesisEngineIdentifier = configuration.engineIdentifier
        updated.hypothesisRunID = configuration.runID
        updated.hypothesisTranscriptFilePath = evidenceURL.path
        updated.hypothesisTranscriptSHA256 = evidenceSHA256
        updated.firstPartialLatencyMs = firstPartialLatency
        updated.finalLatencyMs = finalLatency
        updated.processingDurationMs = processingDurationMs
        updated.latencyMeasurementMode = latencyMeasurementMode
        updated.replayChunkDurationMs = configuration.chunkDurationMs
        updated.memoryResidentBytes = memoryResidentBytes
        updated.cpuUsagePercent = cpuUsagePercent
        updated.gapCount = Self.gapCount(in: committedSegments)
        updated.duplicateCount = Self.duplicateCount(in: committedSegments)
        updated.correctionChurnCount = Self.correctionChurnCount(in: observations.map { $0.segment })

        let report = TranscriptionEvaluationReplayCaseReport(
            caseID: testCase.id,
            audioFilePath: audioURL.path,
            audioSource: caseAudioSource,
            hypothesisTranscriptFilePath: evidenceURL.path,
            hypothesisTranscriptSHA256: evidenceSHA256,
            audioSHA256: payload.audioSHA256,
            audioDurationMs: payload.durationMs,
            processingDurationMs: processingDurationMs,
            firstPartialLatencyMs: firstPartialLatency,
            finalLatencyMs: finalLatency,
            latencyMeasurementMode: latencyMeasurementMode,
            replayChunkDurationMs: configuration.chunkDurationMs,
            memoryResidentBytes: memoryResidentBytes,
            cpuUsagePercent: cpuUsagePercent,
            segmentCount: committedSegments.count,
            audioConditioningEvidence: audioConditioningEvidence,
            hypothesisSource: source,
            engineIdentifier: configuration.engineIdentifier
        )
        return (updated, report)
    }

    private static func baselineCasesWithReplayAudioIdentity(
        _ baselineCases: [TranscriptionBenchmarkCase]?,
        replayedCases: [TranscriptionBenchmarkCase]
    ) -> [TranscriptionBenchmarkCase]? {
        guard let baselineCases else { return nil }
        let replayedCaseByID = Dictionary(uniqueKeysWithValues: replayedCases.map { ($0.id, $0) })
        return baselineCases.map { baselineCase in
            guard let replayedCase = replayedCaseByID[baselineCase.id] else {
                return baselineCase
            }
            var enriched = baselineCase
            if enriched.audioFilePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                enriched.audioFilePath = replayedCase.audioFilePath
            }
            if enriched.audioSource == nil {
                enriched.audioSource = replayedCase.audioSource
            }
            if enriched.audioSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                enriched.audioSHA256 = replayedCase.audioSHA256
            }
            if enriched.audioDurationMs?.isFinite != true || (enriched.audioDurationMs ?? 0) <= 0 {
                enriched.audioDurationMs = replayedCase.audioDurationMs
            }
            return enriched
        }
    }

    private struct ReplayAudioPayload {
        var buffers: [AudioBuffer]
        var durationMs: Double
        var audioSHA256: String
    }

    private struct ReplaySegmentObservation {
        var segment: TranscriptSegment
        var observedAt: Date
    }

    private static func speakerLabel(for source: TranscriptAudioSource) -> String {
        switch source {
        case .microphone:
            return "You"
        case .system:
            return "System"
        case .mixed:
            return "Mixed"
        case .cloud:
            return "Cloud"
        case .unknown:
            return "Audio"
        }
    }

    private static func audioConditioningEvidence(
        from payload: ReplayAudioPayload,
        config: TranscriptionConfig,
        source: TranscriptAudioSource
    ) -> TranscriptionAudioConditioningEvidence {
        var featureFlags = config.featureFlags
        featureFlags.transcriptionMetricsEnabled = false
        let target = AudioConditioningTarget.nativeSpeech
        let conditioningConfig = AudioConditioningConfig(
            accuracyMode: config.accuracyMode,
            target: target,
            audioSource: source
        )
        let conditioner = AudioConditioningService(source: source)
        var inputBufferCount = 0
        var emittedBufferCount = 0
        var forwardedDecisionCount = 0
        var droppedDecisionCount = 0
        var speechDecisionCount = 0
        var nonSpeechDecisionCount = 0
        var clippingDecisionCount = 0
        var lowEnergyDropCount = 0
        var preRollReplayBufferCount = 0
        var vadEngineCounts: [String: Int] = [:]
        var sampleRates = Set<Double>()
        var channelCounts = Set<Int>()
        var rmsTotal: Float = 0
        var peakMax: Float = 0
        var snrValues = [Double]()

        for buffer in payload.buffers {
            let trace = conditioner.conditionWithTrace(buffer, config: conditioningConfig, featureFlags: featureFlags)
            let decision = trace.vadDecision
            inputBufferCount += 1
            emittedBufferCount += trace.frames.count
            preRollReplayBufferCount += trace.frames.filter(\.isPreRollReplay).count
            if decision.shouldForwardToASR {
                forwardedDecisionCount += 1
            } else {
                droppedDecisionCount += 1
            }
            if decision.isSpeech {
                speechDecisionCount += 1
            } else {
                nonSpeechDecisionCount += 1
            }
            if decision.isClipping {
                clippingDecisionCount += 1
            }
            if !decision.shouldForwardToASR && decision.reason == "below_floor" {
                lowEnergyDropCount += 1
            }
            vadEngineCounts[decision.detectionEngine.rawValue, default: 0] += 1
            if let sampleRate = trace.conditionedBuffer.pcmBuffer?.format.sampleRate, sampleRate > 0 {
                sampleRates.insert(sampleRate)
            }
            if let channelCount = trace.conditionedBuffer.pcmBuffer.map({ Int($0.format.channelCount) }), channelCount > 0 {
                channelCounts.insert(channelCount)
            }
            rmsTotal += max(0, trace.conditionedBuffer.rms)
            peakMax = max(peakMax, max(0, trace.conditionedBuffer.peak))
            if decision.snrDb.isFinite {
                snrValues.append(decision.snrDb)
            }
        }

        return TranscriptionAudioConditioningEvidence(
            audioSource: source,
            conditioningTarget: target == .nativeSpeech ? "native-speech" : "cloud-realtime",
            advancedConditioningEnabled: featureFlags.advancedAudioConditioningEnabled,
            vadGatingEnabled: featureFlags.vadGatingEnabled,
            inputBufferCount: inputBufferCount,
            emittedBufferCount: emittedBufferCount,
            forwardedDecisionCount: forwardedDecisionCount,
            droppedDecisionCount: droppedDecisionCount,
            speechDecisionCount: speechDecisionCount,
            nonSpeechDecisionCount: nonSpeechDecisionCount,
            clippingDecisionCount: clippingDecisionCount,
            lowEnergyDropCount: lowEnergyDropCount,
            preRollReplayBufferCount: preRollReplayBufferCount,
            vadEngineCounts: vadEngineCounts,
            inputSampleRates: sampleRates.sorted(),
            inputChannelCounts: channelCounts.sorted(),
            averageRMS: inputBufferCount == 0 ? 0 : rmsTotal / Float(inputBufferCount),
            peakMax: peakMax,
            snrP50Db: percentile(snrValues, 0.50),
            snrP95Db: percentile(snrValues, 0.95)
        )
    }

    private static func audioPayload(
        from url: URL,
        chunkDurationMs: Double,
        source: TranscriptAudioSource
    ) throws -> ReplayAudioPayload {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw TranscriptionEvaluationReplayError.audioFileUnreadable(url.path)
        }
        let format = file.processingFormat
        guard format.sampleRate > 0, file.length > 0 else {
            throw TranscriptionEvaluationReplayError.audioFileHasNoFrames(url.path)
        }
        let chunkFrames = AVAudioFrameCount(max(1, (format.sampleRate * max(20, chunkDurationMs) / 1_000).rounded()))
        var buffers = [AudioBuffer]()

        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(min(Int64(chunkFrames), file.length - file.framePosition))
            guard remaining > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining) else {
                break
            }
            let startFrame = file.framePosition
            try file.read(into: buffer, frameCount: remaining)
            guard buffer.frameLength > 0 else { break }
            let metrics = amplitudeMetrics(buffer)
            let mediaTime = CMTime(seconds: Double(startFrame) / format.sampleRate, preferredTimescale: 1_000_000)
            let time = AVAudioTime(sampleTime: startFrame, atRate: format.sampleRate)
            buffers.append(AudioBuffer(
                pcmBuffer: buffer.copiedForAsyncUse() ?? buffer,
                time: time,
                mediaTime: mediaTime,
                rms: metrics.rms,
                peak: metrics.peak,
                createdAt: Date(),
                audioSource: source
            ))
        }

        let durationMs = (Double(file.length) / format.sampleRate) * 1_000
        return ReplayAudioPayload(
            buffers: buffers,
            durationMs: durationMs,
            audioSHA256: sha256HexDigest(of: url) ?? ""
        )
    }

    private static func committedSegments(from observations: [ReplaySegmentObservation]) -> [TranscriptSegment] {
        let observedSegments = observations.map(\.segment).filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let finals = observedSegments.filter { segment in
            segment.isFinal || segment.transcriptionPhase == .final || segment.transcriptionPhase == .refined
        }
        let candidates = finals.isEmpty ? observedSegments : finals
        var selectedByRootID: [UUID: TranscriptSegment] = [:]
        for segment in candidates {
            let rootID = segment.revisionOfSegmentId ?? segment.id
            guard let existing = selectedByRootID[rootID] else {
                selectedByRootID[rootID] = segment
                continue
            }
            if isBetterCommittedSegment(segment, than: existing) {
                selectedByRootID[rootID] = segment
            }
        }
        let sorted = selectedByRootID.values.sorted {
            if $0.startTime == $1.startTime {
                return $0.createdAt < $1.createdAt
            }
            return $0.startTime < $1.startTime
        }
        var deduped = [TranscriptSegment]()
        for segment in sorted {
            let normalized = normalizedEvidenceText(segment.text)
            if normalized.isEmpty { continue }
            if let previous = deduped.last,
               normalizedEvidenceText(previous.text) == normalized {
                continue
            }
            deduped.append(segment)
        }
        return deduped
    }

    private static func isBetterCommittedSegment(_ candidate: TranscriptSegment, than existing: TranscriptSegment) -> Bool {
        if candidate.revisionNumber != existing.revisionNumber {
            return candidate.revisionNumber > existing.revisionNumber
        }
        if candidate.transcriptionPhase == .refined, existing.transcriptionPhase != .refined {
            return true
        }
        if candidate.isFinal != existing.isFinal {
            return candidate.isFinal
        }
        return candidate.createdAt > existing.createdAt
    }

    private static func joinedTranscript(from segments: [TranscriptSegment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hypothesisSegmentEvidence(from segments: [TranscriptSegment]) -> [TranscriptionHypothesisTranscriptEvidence.SegmentEvidence] {
        segments.map { segment in
            TranscriptionHypothesisTranscriptEvidence.SegmentEvidence(
                text: segment.text,
                audioSource: segment.audioSource,
                speakerLabel: segment.speakerLabel,
                startTime: segment.startTime,
                endTime: segment.endTime,
                isFinal: segment.isFinal,
                transcriptionPhase: segment.transcriptionPhase,
                transcriptionEngine: segment.transcriptionEngine,
                finalizedBy: segment.finalizedBy,
                confidence: segment.confidence,
                engineConfidence: segment.engineConfidence,
                languageCode: segment.originalLanguage ?? segment.sourceLanguage,
                languageConfidence: segment.languageConfidence,
                languageEvidenceSource: segment.languageEvidenceSource,
                languageDetectionWindowMs: segment.languageDetectionWindowMs,
                languageSpanCodes: segment.languageSpanCodes.isEmpty ? nil : segment.languageSpanCodes,
                revisionOfSegmentId: segment.revisionOfSegmentId,
                revisionNumber: segment.revisionNumber,
                retentionReason: segment.retentionReason,
                sourceFrameRange: segment.sourceFrameRange,
                wordTimestampCount: segment.wordTimestamps.count
            )
        }
    }

    private static func hypothesisSource(from segments: [TranscriptSegment]) -> TranscriptionHypothesisSource {
        if segments.contains(where: { $0.transcriptionEngine == .whisperKit || $0.finalizedBy == .whisperKit }) {
            return .whisperKit
        }
        if segments.contains(where: { $0.transcriptionEngine == .speechAnalyzer || $0.finalizedBy == .speechAnalyzer }) {
            return .speechAnalyzer
        }
        if segments.contains(where: { $0.transcriptionEngine == .appleSpeech || $0.finalizedBy == .appleSpeech }) {
            return .sfSpeech
        }
        if segments.contains(where: { $0.transcriptionEngine == .elevenLabs || $0.finalizedBy == .elevenLabs }) {
            return .cloudFallback
        }
        return .speechAnalyzer
    }

    private static func firstObservedTextLatencyMs(in observations: [ReplaySegmentObservation], since start: Date) -> Double? {
        observations
            .filter { !$0.segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.observedAt.timeIntervalSince(start) * 1_000 }
            .min()
    }

    private static func finalObservedTextLatencyMs(in observations: [ReplaySegmentObservation], since start: Date) -> Double? {
        observations
            .filter { observation in
                let segment = observation.segment
                return !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    (segment.isFinal || segment.transcriptionPhase == .final || segment.transcriptionPhase == .refined)
            }
            .map { $0.observedAt.timeIntervalSince(start) * 1_000 }
            .max()
    }

    private static func amplitudeMetrics(_ buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float) {
        guard let channelData = buffer.floatChannelData else {
            return (0, 0)
        }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0 else { return (0, 0) }
        var sumSquares: Float = 0
        var peak: Float = 0
        for channelIndex in 0..<channels {
            let channel = channelData[channelIndex]
            for frameIndex in 0..<frames {
                let value = channel[frameIndex]
                sumSquares += value * value
                peak = max(peak, abs(value))
            }
        }
        let sampleCount = max(1, channels * frames)
        return (sqrt(sumSquares / Float(sampleCount)), min(max(peak, 0), 1))
    }

    private static func durationMs(of buffer: AudioBuffer) -> Double {
        guard let pcmBuffer = buffer.pcmBuffer, pcmBuffer.format.sampleRate > 0 else { return 20 }
        return (Double(pcmBuffer.frameLength) / pcmBuffer.format.sampleRate) * 1_000
    }

    private static func gapCount(in segments: [TranscriptSegment]) -> Int {
        guard segments.count > 1 else { return 0 }
        var count = 0
        for pair in zip(segments, segments.dropFirst()) where pair.1.startTime - pair.0.endTime > 1.5 {
            count += 1
        }
        return count
    }

    private static func duplicateCount(in segments: [TranscriptSegment]) -> Int {
        guard segments.count > 1 else { return 0 }
        var count = 0
        var seen = Set<String>()
        for segment in segments {
            let normalized = normalizedEvidenceText(segment.text)
            if !normalized.isEmpty, !seen.insert(normalized).inserted {
                count += 1
            }
        }
        return count
    }

    private static func correctionChurnCount(in segments: [TranscriptSegment]) -> Int {
        segments.filter { $0.revisionOfSegmentId != nil || ($0.revisionNumber > 0 && $0.transcriptionPhase == .refined) }.count
    }

    private static func safeFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let joined = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return joined.isEmpty ? UUID().uuidString : joined
    }

    private static func normalizedEvidenceText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard let first = sorted.first else { return nil }
        guard sorted.count > 1 else { return first }
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * percentile)) - 1))
        return sorted[index]
    }

    private static func sha256HexDigest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct TranscriptionBenchmarkSuite: Sendable {
    func evaluate(
        _ cases: [TranscriptionBenchmarkCase],
        thresholds: TranscriptionBenchmarkThresholds = .default
    ) -> [TranscriptionBenchmarkResult] {
        cases.map { testCase in
            let wordErrorRate = Self.wordErrorRate(reference: testCase.reference, hypothesis: testCase.hypothesis)
            let characterErrorRate = Self.characterErrorRate(reference: testCase.reference, hypothesis: testCase.hypothesis)
            let vocabularyRecognitionRate = Self.vocabularyRecognitionRate(
                terms: testCase.activeVocabulary,
                hypothesis: testCase.hypothesis,
                locale: testCase.locale
            )
            let namedEntityRecognitionRate = Self.vocabularyRecognitionRate(
                terms: testCase.namedEntities,
                hypothesis: testCase.hypothesis,
                locale: testCase.locale
            )
            let realTimeFactor = Self.realTimeFactor(
                audioDurationMs: testCase.audioDurationMs,
                processingDurationMs: testCase.processingDurationMs
            )
            let failedGates = Self.failedGates(
                wordErrorRate: wordErrorRate,
                characterErrorRate: characterErrorRate,
                vocabularyRecognitionRate: vocabularyRecognitionRate,
                namedEntityRecognitionRate: namedEntityRecognitionRate,
                firstPartialLatencyMs: testCase.firstPartialLatencyMs,
                finalLatencyMs: testCase.finalLatencyMs,
                realTimeFactor: realTimeFactor,
                languageSwitchLatencyMs: testCase.languageSwitchLatencyMs,
                memoryResidentBytes: testCase.memoryResidentBytes,
                cpuUsagePercent: testCase.cpuUsagePercent,
                correctionChurnCount: testCase.correctionChurnCount,
                thresholds: thresholds
            )
            return TranscriptionBenchmarkResult(
                id: testCase.id,
                locale: testCase.locale,
                wordErrorRate: wordErrorRate,
                characterErrorRate: characterErrorRate,
                vocabularyRecognitionRate: vocabularyRecognitionRate,
                namedEntityRecognitionRate: namedEntityRecognitionRate,
                firstPartialLatencyMs: testCase.firstPartialLatencyMs,
                finalLatencyMs: testCase.finalLatencyMs,
                realTimeFactor: realTimeFactor,
                languageSwitchLatencyMs: testCase.languageSwitchLatencyMs,
                memoryResidentBytes: testCase.memoryResidentBytes,
                cpuUsagePercent: testCase.cpuUsagePercent,
                gapCount: testCase.gapCount,
                duplicateCount: testCase.duplicateCount,
                correctionChurnCount: testCase.correctionChurnCount,
                passedQualityGate: failedGates.isEmpty,
                failedGates: failedGates
            )
        }
    }

    func summarize(_ results: [TranscriptionBenchmarkResult]) -> TranscriptionBenchmarkSummary {
        TranscriptionBenchmarkSummary(
            caseCount: results.count,
            passedCaseCount: results.filter(\.passedQualityGate).count,
            averageWordErrorRate: Self.average(results.map(\.wordErrorRate)),
            averageCharacterErrorRate: Self.average(results.map(\.characterErrorRate)),
            averageVocabularyRecognitionRate: Self.average(results.map(\.vocabularyRecognitionRate)),
            averageNamedEntityRecognitionRate: Self.average(results.map(\.namedEntityRecognitionRate)),
            firstPartialP95Ms: Self.percentile(results.compactMap(\.firstPartialLatencyMs), 0.95),
            finalLatencyP95Ms: Self.percentile(results.compactMap(\.finalLatencyMs), 0.95),
            realTimeFactorP95: Self.percentile(results.compactMap(\.realTimeFactor), 0.95),
            languageSwitchP95Ms: Self.percentile(results.compactMap(\.languageSwitchLatencyMs), 0.95),
            memoryResidentMaxBytes: results.compactMap(\.memoryResidentBytes).max(),
            cpuUsageP95Percent: Self.percentile(results.compactMap(\.cpuUsagePercent), 0.95),
            totalGapCount: results.reduce(0) { $0 + $1.gapCount },
            totalDuplicateCount: results.reduce(0) { $0 + $1.duplicateCount },
            totalCorrectionChurnCount: results.reduce(0) { $0 + $1.correctionChurnCount }
        )
    }

    func summary(
        for cases: [TranscriptionBenchmarkCase],
        thresholds: TranscriptionBenchmarkThresholds = .default
    ) -> TranscriptionBenchmarkSummary {
        summarize(evaluate(cases, thresholds: thresholds))
    }

    func jsonReport(
        for cases: [TranscriptionBenchmarkCase],
        thresholds: TranscriptionBenchmarkThresholds = .default
    ) throws -> Data {
        try JSONEncoder.prettyBenchmarkEncoder.encode(evaluate(cases, thresholds: thresholds))
    }

    func jsonSummary(
        for cases: [TranscriptionBenchmarkCase],
        thresholds: TranscriptionBenchmarkThresholds = .default
    ) throws -> Data {
        try JSONEncoder.prettyBenchmarkEncoder.encode(summary(for: cases, thresholds: thresholds))
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

    private static func realTimeFactor(audioDurationMs: Double?, processingDurationMs: Double?) -> Double? {
        guard let audioDurationMs, let processingDurationMs, audioDurationMs > 0, processingDurationMs >= 0 else {
            return nil
        }
        return processingDurationMs / audioDurationMs
    }

    private static func failedGates(
        wordErrorRate: Double,
        characterErrorRate: Double,
        vocabularyRecognitionRate: Double,
        namedEntityRecognitionRate: Double,
        firstPartialLatencyMs: Double?,
        finalLatencyMs: Double?,
        realTimeFactor: Double?,
        languageSwitchLatencyMs: Double?,
        memoryResidentBytes: UInt64?,
        cpuUsagePercent: Double?,
        correctionChurnCount: Int,
        thresholds: TranscriptionBenchmarkThresholds
    ) -> [String] {
        var failures = [String]()
        if wordErrorRate > thresholds.maxWordErrorRate { failures.append("word_error_rate") }
        if characterErrorRate > thresholds.maxCharacterErrorRate { failures.append("character_error_rate") }
        if vocabularyRecognitionRate < thresholds.minVocabularyRecognitionRate { failures.append("vocabulary_recall") }
        if namedEntityRecognitionRate < thresholds.minNamedEntityRecognitionRate { failures.append("named_entity_recall") }
        if let firstPartialLatencyMs {
            if !firstPartialLatencyMs.isFinite || firstPartialLatencyMs < 0 {
                failures.append("invalid_first_partial_latency")
            } else if firstPartialLatencyMs > thresholds.maxFirstPartialLatencyMs {
                failures.append("first_partial_latency")
            }
        }
        if let finalLatencyMs {
            if !finalLatencyMs.isFinite || finalLatencyMs < 0 {
                failures.append("invalid_final_latency")
            } else if finalLatencyMs > thresholds.maxFinalLatencyMs {
                failures.append("final_latency")
            }
        }
        if let firstPartialLatencyMs,
           let finalLatencyMs,
           firstPartialLatencyMs.isFinite,
           finalLatencyMs.isFinite,
           firstPartialLatencyMs >= 0,
           finalLatencyMs >= 0,
           finalLatencyMs < firstPartialLatencyMs {
            failures.append("final_latency_before_first_partial")
        }
        if let realTimeFactor {
            if !realTimeFactor.isFinite || realTimeFactor < 0 {
                failures.append("invalid_real_time_factor")
            } else if realTimeFactor > thresholds.maxRealTimeFactor {
                failures.append("real_time_factor")
            }
        }
        if let languageSwitchLatencyMs {
            if !languageSwitchLatencyMs.isFinite || languageSwitchLatencyMs < 0 {
                failures.append("invalid_language_switch_latency")
            } else if languageSwitchLatencyMs > thresholds.maxLanguageSwitchLatencyMs {
                failures.append("language_switch_latency")
            }
        }
        if let memoryResidentBytes,
           let maxMemoryResidentBytes = thresholds.maxMemoryResidentBytes,
           memoryResidentBytes > maxMemoryResidentBytes {
            failures.append("memory_resident_bytes")
        }
        if let memoryResidentBytes, memoryResidentBytes == 0 {
            failures.append("invalid_memory_resident_bytes")
        }
        if let cpuUsagePercent {
            if !cpuUsagePercent.isFinite || cpuUsagePercent < 0 {
                failures.append("invalid_cpu_usage_percent")
            } else if let maxCPUUsagePercent = thresholds.maxCPUUsagePercent,
                      cpuUsagePercent > maxCPUUsagePercent {
                failures.append("cpu_usage_percent")
            }
        }
        if correctionChurnCount > thresholds.maxCorrectionChurnCount {
            failures.append("correction_churn")
        }
        return failures
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * percentile)) - 1))
        return sorted[index]
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

    func deduplicatedPreservingOrder() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
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
    var featureFlags: TranscriptionFeatureFlags
    var localASRRefinerModel: String
    var allowLocalASRModelDownload: Bool

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
        sourceSeparationRequired: Bool = false,
        featureFlags: TranscriptionFeatureFlags = .default,
        localASRRefinerModel: String = "distil-large-v3",
        allowLocalASRModelDownload: Bool = false
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
        self.featureFlags = featureFlags
        let trimmedLocalRefinerModel = localASRRefinerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.localASRRefinerModel = trimmedLocalRefinerModel.isEmpty ? "distil-large-v3" : trimmedLocalRefinerModel
        self.allowLocalASRModelDownload = allowLocalASRModelDownload
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
