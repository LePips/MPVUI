import Foundation
import Libmpv
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVSeekCompletionTests {

    @Test
    func `audio readiness and operation events distinguish repeated loads of the same URL`() async throws {
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"], automaticallyPlays: false))
        let stream = player.makeEventStream()
        var received: [MPVPlaybackEvent] = []
        let observation = Task {
            for await event in stream {
                received.append(event)
            }
        }
        defer {
            observation.cancel()
            player.stop()
        }

        let source = try TestPaths.testMedia("audio-pcm-stereo.mka")
        var generations: [UInt64] = []

        for _ in 0 ..< 2 {
            player.load(source, playAutomatically: false)
            generations.append(player.generation)

            #expect(!player.isPlaybackReady)

            try await eventually("audio-only playback becomes ready") {
                player.isPlaybackReady
            }

            #expect(!player.hasVideoFrame && player.isPaused)

            let result = try await player.seekAndWait(to: .seconds(1))

            #expect(result.generation == player.generation)

            try await eventually("seek completion reaches the ordered stream") {
                received.contains { event in
                    if case .seekCompleted = event.change {
                        return event.generation == result.generation
                    }
                    return false
                }
            }
        }
        let ready = received.filter {
            if case .readinessChanged(true) = $0.change {
                true
            } else {
                false
            }
        }

        #expect(ready.map(\.generation) == generations)
        #expect(generations[0] != generations[1])
    }

    @Test(arguments: [false, true])
    func `awaited seeks resolve on restart and preserve playback intent including EOF`(playing: Bool) async throws {
        let fixture = PlaybackFixture()
        defer {
            fixture.close()
        }

        try await fixture.loadPaused(TestPaths.multitrackMedia)
        let player = fixture.player
        if playing {
            player.play()
        }
        let result = try await player.seekAndWait(to: .seconds(4))

        #expect(result.generation == player.mediaGeneration)
        #expect(result.target == .seconds(4))
        #expect(abs(result.position.seconds - 4) < 0.2)
        #expect(abs(player.position.seconds - result.position.seconds) < 0.2)
        #expect(player.isPlaybackReady)

        try await eventually("seek preserves playback intent") {
            player.isPaused != playing
        }

        let end = try await player.seekAndWait(to: player.duration + .seconds(20))

        #expect(end.target == player.duration)
        #expect(abs((end.position - player.duration).seconds) < 0.2)

        try await eventually("endpoint becomes ended") {
            player.state == .ended
        }

        let resumed = try await player.seekAndWait(to: .seconds(2))

        #expect(abs(resumed.position.seconds - 2) < 0.2)

        try await eventually("backward seek restores playback intent") {
            player.isPaused != playing
        }

        #expect(player.lastError == nil)
    }

    @Test
    func `deferred seek completes when its surface attaches`() async throws {
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"], automaticallyPlays: false))

        player.load(TestPaths.multitrackMedia, playAutomatically: false)
        let request = Task {
            try await player.seekAndWait(to: .seconds(7))
        }
        // Fence native submission before the renderer becomes available.
        await Task.yield()
        _ = await player.lifecycleDiagnostics()
        let fixture = PlaybackFixture(player: player)
        defer {
            fixture.close()
        }

        let result = try await request.value

        #expect(abs(result.position.seconds - 7) < 0.2)
        #expect(result.target == .seconds(7))
    }

    @Test(arguments: ["superseded", "cancel", "stop", "replace", "timeout", "overflow"])
    func `pending seeks terminate for lifecycle changes and deadlines`(action: String) async throws {
        let session = MPVSession(configuration: .init(additionalOptions: ["ao": "null"], automaticallyPlays: false)) { _ in }
        defer {
            session.close()
        }

        session.load(TestPaths.multitrackMedia, playAutomatically: false, startTime: nil, generation: 1)
        let task = Task {
            try await session.seekAndWait(to: .seconds(6), timeout: action == "timeout" ? .milliseconds(100) : .seconds(8))
        }
        try await eventually("seek is awaiting source readiness") {
            session.queue.sync { session.pendingSeek != nil }
        }

        var replacement: Task<MPVSeekResult, any Error>?
        switch action {
        case "superseded":
            replacement = Task {
                try await session.seekAndWait(to: .seconds(3))
            }

        case "overflow":
            session.queue.sync {
                var event = mpv_event()
                event.event_id = MPV_EVENT_QUEUE_OVERFLOW
                session.handleEvent(event)
            }

        case "cancel":
            task.cancel()

        case "stop":
            session.stop()

        case "replace":
            session.load(TestPaths.baselineMedia, playAutomatically: false, startTime: nil, generation: 2)

        default:
            break
        }
        do {
            _ = try await task.value

            Issue.record("Pending seek unexpectedly succeeded")
        } catch is CancellationError {
            #expect(action != "timeout" && action != "overflow")
        } catch {
            #expect(
                (action == "timeout" && (error as? MPVPlayerError) == .seekTimedOut)
                    || (action == "overflow" && (error as? MPVPlayerError) == .eventQueueOverflow)
            )
        }
        if let replacement {
            #expect(session.queue.sync { session.pendingSeek?.target == .seconds(3) })

            replacement.cancel()
            _ = try? await replacement.value
        }

        #expect(session.queue.sync { session.pendingSeek == nil })
    }

    @Test
    func `awaited seeking without a source fails explicitly`() async {
        let player = MPVPlayer()

        await #expect(throws: MPVPlayerError.seekUnavailable) {
            try await player.seekAndWait(to: .seconds(1))
        }
    }
}
