import Foundation

final class AudioMixerService {
    func merge(_ streams: [AsyncStream<AudioBuffer>]) -> AsyncStream<AudioBuffer> {
        AsyncStream { continuation in
            let group = DispatchGroup()
            for stream in streams {
                group.enter()
                Task {
                    for await buffer in stream {
                        continuation.yield(buffer)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .global()) {
                continuation.finish()
            }
        }
    }
}
