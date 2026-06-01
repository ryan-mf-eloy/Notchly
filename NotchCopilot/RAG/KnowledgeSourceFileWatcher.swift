import CoreServices
import Foundation

final class KnowledgeSourceFileWatcher: @unchecked Sendable {
    private final class SourceWatchContext {
        weak var watcher: KnowledgeSourceFileWatcher?
        let sourceId: UUID

        init(watcher: KnowledgeSourceFileWatcher, sourceId: UUID) {
            self.watcher = watcher
            self.sourceId = sourceId
        }
    }

    private let queue = DispatchQueue(label: "com.notchly.knowledge-source-watcher", qos: .utility)
    private var streams: [UUID: FSEventStreamRef] = [:]
    private var contexts: [UUID: SourceWatchContext] = [:]
    private var watchedPaths: [UUID: String] = [:]
    private var pendingReindexes: [UUID: DispatchWorkItem] = [:]
    private var onChange: (@Sendable (UUID) -> Void)?

    func update(sources: [SourceConnectionViewModel], onChange: @escaping @Sendable (UUID) -> Void) {
        let desiredPaths = Dictionary(uniqueKeysWithValues: sources.compactMap { source -> (UUID, String)? in
            guard source.isEnabled,
                  source.status != .failed,
                  source.kind == .directory || source.kind == .obsidian,
                  FileManager.default.fileExists(atPath: source.subtitle) else {
                return nil
            }
            return (source.id, source.subtitle)
        })

        queue.async { [weak self] in
            guard let self else { return }
            self.onChange = onChange

            for sourceId in self.streams.keys where desiredPaths[sourceId] == nil {
                self.stopWatching(sourceId)
            }

            for (sourceId, path) in desiredPaths where self.watchedPaths[sourceId] != path {
                self.stopWatching(sourceId)
                self.startWatching(sourceId: sourceId, path: path)
            }
        }
    }

    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for sourceId in Array(self.streams.keys) {
                self.stopWatching(sourceId)
            }
            self.onChange = nil
        }
    }

    private func startWatching(sourceId: UUID, path: String) {
        let contextBox = SourceWatchContext(watcher: self, sourceId: sourceId)
        contexts[sourceId] = contextBox
        watchedPaths[sourceId] = path

        var streamContext = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(contextBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &streamContext,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.25,
            flags
        ) else {
            contexts[sourceId] = nil
            watchedPaths[sourceId] = nil
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        if FSEventStreamStart(stream) {
            streams[sourceId] = stream
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            contexts[sourceId] = nil
            watchedPaths[sourceId] = nil
        }
    }

    private func stopWatching(_ sourceId: UUID) {
        pendingReindexes[sourceId]?.cancel()
        pendingReindexes[sourceId] = nil

        if let stream = streams.removeValue(forKey: sourceId) {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        contexts[sourceId] = nil
        watchedPaths[sourceId] = nil
    }

    private func scheduleChange(for sourceId: UUID) {
        pendingReindexes[sourceId]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingReindexes[sourceId] = nil
            self?.onChange?(sourceId)
        }
        pendingReindexes[sourceId] = work
        queue.asyncAfter(deadline: .now() + .seconds(2), execute: work)
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let context = Unmanaged<SourceWatchContext>.fromOpaque(info).takeUnretainedValue()
        context.watcher?.scheduleChange(for: context.sourceId)
    }
}
