import Foundation

/// Multi-consumer, replaying delivery for current-value subtitle snapshots.
///
/// Every subscriber owns an independent newest-one buffer. Producing a cue
/// therefore never waits for a renderer, and a slow renderer cannot accumulate
/// subtitle states that are already obsolete.
final class TextSubtitleSnapshotBroadcaster: @unchecked Sendable {
    private struct State {
        var latest = TextSubtitleSnapshot()
        var continuations: [UUID: AsyncStream<TextSubtitleSnapshot>.Continuation] = [:]
        var isTerminated = false
    }

    private let lock = NSLock()
    private var state = State()

    func subscribe() -> AsyncStream<TextSubtitleSnapshot> {
        let (stream, continuation) = AsyncStream<TextSubtitleSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()

        lock.lock()
        guard !state.isTerminated else {
            lock.unlock()
            continuation.finish()
            return stream
        }

        state.continuations[id] = continuation
        // Replay while holding the same lock used by `publish(_:)`. The new
        // continuation is not yet visible outside this object, so this cannot
        // call client code and guarantees that replay precedes a racing update.
        continuation.yield(state.latest)
        lock.unlock()

        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(id)
        }
        return stream
    }

    func publish(_ snapshot: TextSubtitleSnapshot) {
        lock.lock()
        guard !state.isTerminated, state.latest != snapshot else {
            lock.unlock()
            return
        }
        state.latest = snapshot
        let continuations = Array(state.continuations.values)
        lock.unlock()

        for continuation in continuations {
            continuation.yield(snapshot)
        }
    }

    func clear() {
        publish(TextSubtitleSnapshot())
    }

    /// Clears an active cue, finishes every subscription, and permanently
    /// prevents new subscriptions from waiting on a player that no longer
    /// exists.
    func terminate() {
        lock.lock()
        guard !state.isTerminated else {
            lock.unlock()
            return
        }
        let shouldClear = !state.latest.isEmpty
        state.latest = TextSubtitleSnapshot()
        state.isTerminated = true
        let continuations = Array(state.continuations.values)
        state.continuations.removeAll()
        lock.unlock()

        for continuation in continuations {
            if shouldClear {
                continuation.yield(TextSubtitleSnapshot())
            }
            continuation.finish()
        }
    }

    private func removeSubscriber(_ id: UUID) {
        lock.lock()
        state.continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
