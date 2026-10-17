import Foundation

/// Records cancellation even when it races with registering the native command.
package final class MPVSubtitleQueryCancellation: @unchecked Sendable {

    private let lock = NSLock()
    private var cancelled = false

    package var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    package func cancel() {
        lock.withLock { cancelled = true }
    }
}
