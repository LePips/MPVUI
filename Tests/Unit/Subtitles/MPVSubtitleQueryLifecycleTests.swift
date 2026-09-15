import Foundation
import Libmpv
@testable import MPVUI
import Testing

@Suite(.tags(.unit, .subtitles), .serialized)
struct MPVSubtitleQueryLifecycleTests {
    @Test
    func `query before media is loaded reports a precise recoverable error`() async {
        let engine = MPVEngine(configuration: .init()) { _ in }
        do {
            _ = try await engine.textSubtitleSnapshots(for: .init(type: .subtitle, mpvID: 1))
            Issue.record("An unloaded query must fail")
        } catch let error as MPVPlayerError {
            #expect(error == .commandFailed(
                context: "Read text subtitles", code: MPV_ERROR_INVALID_PARAMETER.rawValue,
                message: "A loaded text subtitle track is required."
            ))
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(engine.queue.sync { engine.subtitleQueries.isEmpty && engine.lastState == .idle })
    }

    @Test
    func `cancelled caller never leaves a pending subtitle continuation`() async {
        let engine = MPVEngine(configuration: .init()) { _ in }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.textSubtitleSnapshots(for: .init(type: .subtitle, mpvID: 1))
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled query must throw")
        } catch { #expect(error is CancellationError) }
        #expect(engine.queue.sync { engine.subtitleQueries.isEmpty })
    }

    @Test
    func `targeted cancellation leaves unrelated subtitle queries pending`() async {
        let engine = MPVEngine(configuration: .init()) { _ in }
        let selected = MPVSubtitleQueryCancellation()
        let unrelated = MPVSubtitleQueryCancellation()
        let (registrations, registered) = AsyncStream<Void>.makeStream()
        defer { registered.finish() }
        let first = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TimedTextSubtitleSnapshot], any Error>) in
                engine.queue.sync {
                    engine.subtitleQueries[1] = .init(cancellation: selected, continuation: continuation)
                    registered.yield(())
                }
            }
        }
        var readiness = registrations.makeAsyncIterator()
        await readiness.next()
        do {
            let result: [TimedTextSubtitleSnapshot] = try await withCheckedThrowingContinuation { continuation in
                engine.queue.sync {
                    engine.subtitleQueries[2] = .init(cancellation: unrelated, continuation: continuation)
                    engine.cancelSubtitleQueries(matching: selected)
                    #expect(engine.subtitleQueries[1] == nil)
                    #expect(engine.subtitleQueries[2] != nil)
                    engine.subtitleQueries.removeValue(forKey: 2)?.continuation.resume(returning: [])
                }
            }
            #expect(result.isEmpty)
        } catch { Issue.record("Unrelated query was cancelled: \(error)") }
        do { _ = try await first.value
            Issue.record("Selected query was not cancelled")
        } catch { #expect(error is CancellationError) }
        #expect(engine.queue.sync { engine.subtitleQueries.isEmpty })
    }
}
