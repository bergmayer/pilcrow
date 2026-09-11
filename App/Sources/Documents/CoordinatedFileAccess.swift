import Foundation

/// One bounded file-provider operation. Access, including encoding and
/// validation before a write, stays on Foundation's accessor queue.
enum CoordinatedFileAccess {
    static func perform<Value: Sendable>(
        at url: URL,
        writing: Bool = false,
        timeout: Duration = .seconds(120),
        _ operation: @escaping @Sendable (URL) throws -> Value
    ) async throws -> Value {
        let intent = writing ? NSFileAccessIntent.writingIntent(with: url, options: [])
                             : NSFileAccessIntent.readingIntent(with: url, options: [])
        return try await perform(Request(intents: [intent]) { urls, _ in try operation(urls[0]) }, timeout: timeout)
    }

    static func move(from source: URL, to destination: URL) async throws -> URL {
        let intents = [NSFileAccessIntent.writingIntent(with: source, options: .forMoving),
                       NSFileAccessIntent.writingIntent(with: destination, options: .forReplacing)]
        return try await perform(Request(intents: intents) { urls, coordinator in
            coordinator.item(at: urls[0], willMoveTo: urls[1])
            try FileManager.default.moveItem(at: urls[0], to: urls[1])
            coordinator.item(at: urls[0], didMoveTo: urls[1])
            return urls[1]
        }, timeout: .seconds(120))
    }

    private static func perform<Value: Sendable>(_ request: Request<Value>, timeout: Duration) async throws -> Value {
        let deadline = Task {
            try await Task.sleep(for: timeout)
            request.cancel(with: URLError(.timedOut))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { request.start($0) }
        } onCancel: {
            request.cancel(with: CancellationError())
        }
    }

    // NSFileCoordinator explicitly permits cancel() from any thread.
    // The lock serializes cancellation with scheduling; the intent and
    // operation are used only by the coordinator's single accessor.
    private final class Request<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let coordinator = NSFileCoordinator()
        private let intents: [NSFileAccessIntent]
        private let queue = OperationQueue()
        private let operation: @Sendable ([URL], NSFileCoordinator) throws -> Value
        private var cancellation: (any Error)?

        init(intents: [NSFileAccessIntent], operation: @escaping @Sendable ([URL], NSFileCoordinator) throws -> Value) {
            self.intents = intents
            self.operation = operation
            queue.qualityOfService = .userInitiated
        }

        func cancel(with error: any Error) {
            lock.withLock {
                cancellation = cancellation ?? error
                coordinator.cancel()
            }
        }

        func start(_ continuation: CheckedContinuation<Value, any Error>) {
            lock.withLock {
                if let cancellation {
                    continuation.resume(throwing: cancellation)
                    return
                }
                let scoped = intents.map(\.url).filter { $0.startAccessingSecurityScopedResource() }
                coordinator.coordinate(with: intents, queue: queue) { [self] error in
                    defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
                    let failure = lock.withLock { cancellation } ?? error
                    if let failure {
                        continuation.resume(throwing: failure)
                        return
                    }
                    // Once a write starts, return its actual outcome even
                    // if cancellation arrives during the atomic write.
                    continuation.resume(with: Result { try operation(intents.map(\.url), coordinator) })
                }
            }
        }
    }
}
