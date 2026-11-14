import Foundation

/// Keeps non-Sendable resources actor-isolated while their owner transfers
/// cleanup to the main actor. Capture the backing storage in deinit, then
/// call `release()` after cleanup to destroy its value on the main actor.
@propertyWrapper
@MainActor
final class MPVMainActorResource<Value> {

    private var storage: Value?

    var wrappedValue: Value {
        get { storage! }
        set { storage = .some(newValue) }
    }

    init(wrappedValue: Value) {
        storage = .some(wrappedValue)
    }

    nonisolated deinit {}
    /// Ends access and releases the value even if the retiring owner still
    /// retains this storage on another thread.
    func release() {
        storage = nil
    }
}

/// Runs resource cleanup without the back-deployed isolated-deinit runtime.
/// Capture owned resources, never the object whose deinit is executing.
func performMainActorCleanup(_ cleanup: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { cleanup() }
    } else {
        Task { @MainActor in cleanup() }
    }
}
