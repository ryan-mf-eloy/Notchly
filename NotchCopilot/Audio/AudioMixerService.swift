import CoreMedia
import Foundation

final class AudioMixerService {
    func merge(_ streams: [AsyncStream<AudioBuffer>]) -> AsyncStream<AudioBuffer> {
        merge(streams.enumerated().map { index, stream in
            AudioMixerInput(
                source: index == 0 ? .microphone : .system,
                stream: stream
            )
        })
    }

    func merge(_ streams: [TranscriptAudioSource: AsyncStream<AudioBuffer>]) -> AsyncStream<AudioBuffer> {
        merge(streams.map { AudioMixerInput(source: $0.key, stream: $0.value) })
    }

    func merge(_ inputs: [AudioMixerInput]) -> AsyncStream<AudioBuffer> {
        AsyncStream { continuation in
            guard !inputs.isEmpty else {
                continuation.finish()
                return
            }

            let state = AudioMixerState(expectedInputs: inputs.count)
            var tasks: [Task<Void, Never>] = []
            for input in inputs {
                let task = Task {
                    for await var buffer in input.stream {
                        if Task.isCancelled { break }
                        if buffer.audioSource == .unknown {
                            buffer.audioSource = input.source
                        }
                        await state.push(buffer)
                        let ready = await state.flushReady()
                        for buffer in ready {
                            if Task.isCancelled { break }
                            continuation.yield(buffer)
                        }
                    }
                    await state.markFinished()
                }
                tasks.append(task)
            }

            let flushTask = Task {
                while await !state.isFinished {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    let ready = await state.flushReady()
                    for buffer in ready {
                        if Task.isCancelled { break }
                        continuation.yield(buffer)
                    }
                }
                if !Task.isCancelled {
                    let remaining = await state.flushAll()
                    for buffer in remaining {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                }
            }
            tasks.append(flushTask)

            let cancellationTasks = tasks
            continuation.onTermination = { @Sendable _ in
                cancellationTasks.forEach { $0.cancel() }
            }
        }
    }
}

struct AudioMixerInput: Sendable {
    var source: TranscriptAudioSource
    var stream: AsyncStream<AudioBuffer>
}

private actor AudioMixerState {
    private struct PendingAudioBuffer {
        var buffer: AudioBuffer
        var receivedAt: Date
    }

    private let expectedInputs: Int
    private var finishedInputs = 0
    private var pending: [PendingAudioBuffer] = []
    private var lastEmittedSortKey: TimeInterval = 0
    private let jitterDelay: TimeInterval = 0.08

    init(expectedInputs: Int) {
        self.expectedInputs = expectedInputs
    }

    var isFinished: Bool {
        finishedInputs >= expectedInputs
    }

    func push(_ buffer: AudioBuffer) {
        pending.append(PendingAudioBuffer(buffer: buffer, receivedAt: Date()))
    }

    func markFinished() {
        finishedInputs += 1
    }

    func flushReady() -> [AudioBuffer] {
        guard !pending.isEmpty else { return [] }
        pending.sort { sortKey($0.buffer) < sortKey($1.buffer) }
        let now = Date()
        var ready: [AudioBuffer] = []
        while let first = pending.first {
            let age = now.timeIntervalSince(first.receivedAt)
            guard age >= jitterDelay || pending.count > 24 else { break }
            ready.append(monotonic(first.buffer))
            pending.removeFirst()
        }
        return ready
    }

    func flushAll() -> [AudioBuffer] {
        pending.sort { sortKey($0.buffer) < sortKey($1.buffer) }
        let ready = pending.map { monotonic($0.buffer) }
        pending.removeAll()
        return ready
    }

    private func monotonic(_ buffer: AudioBuffer) -> AudioBuffer {
        var output = buffer
        let originalKey = sortKey(buffer)
        let key = max(originalKey, lastEmittedSortKey)
        lastEmittedSortKey = key + 0.000001
        if output.mediaTime == nil || !(output.mediaTime?.isValid ?? false) || originalKey < key {
            output.mediaTime = CMTime(seconds: key, preferredTimescale: 1_000_000)
        }
        return output
    }

    private func sortKey(_ buffer: AudioBuffer) -> TimeInterval {
        if let mediaTime = buffer.mediaTime, mediaTime.isValid {
            let seconds = CMTimeGetSeconds(mediaTime)
            if seconds.isFinite {
                return seconds
            }
        }
        if let audioTime = buffer.time, audioTime.isSampleTimeValid, audioTime.sampleRate > 0 {
            return Double(audioTime.sampleTime) / audioTime.sampleRate
        }
        return buffer.createdAt.timeIntervalSinceReferenceDate
    }
}
