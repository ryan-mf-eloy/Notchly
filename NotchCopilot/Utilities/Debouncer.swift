import Foundation

final class Debouncer {
    private var task: Task<Void, Never>?

    func schedule(delay: Duration, operation: @escaping @Sendable () async -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

