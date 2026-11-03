import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
@MainActor
struct MPVPlaybackEventTests {

    @Test
    func `slow timing consumers coalesce without losing lifecycle transitions`() async {
        let broadcaster = MPVPlaybackEventBroadcaster()
        let events = broadcaster.subscribe()
        let timing = broadcaster.subscribeToTiming()
        var snapshot = MPVSessionSnapshot()
        snapshot.generation = 4
        snapshot.duration = .seconds(100)
        snapshot.state = .loading
        broadcaster.reset(snapshot)
        snapshot.state = .paused
        snapshot.isPlaybackReady = true
        broadcaster.update(snapshot, features: snapshot.videoFeatureCapabilities)
        for index in 1 ... 1000 {
            snapshot.position = .milliseconds(index)
            broadcaster.update(snapshot, features: snapshot.videoFeatureCapabilities)
        }
        snapshot.state = .ended
        snapshot.isPlaybackReady = false
        broadcaster.update(snapshot, features: snapshot.videoFeatureCapabilities)
        snapshot.state = .failed(.seekUnavailable)
        broadcaster.update(snapshot, features: snapshot.videoFeatureCapabilities)
        broadcaster.publish(.error(.seekUnavailable, fatal: true))
        broadcaster.terminate()

        var states: [MPVPlaybackState] = []
        var readiness: [Bool] = []
        var errors = 0
        var count = 0

        for await event in events {
            count += 1
            switch event.change {
            case let .stateChanged(state):
                states.append(state)
            case let .readinessChanged(ready):
                readiness.append(ready)
            case .error:
                errors += 1
            default:
                break
            }
        }

        #expect(states == [.paused, .ended, .failed(.seekUnavailable)])
        #expect(readiness == [true, false])
        #expect(errors == 1 && count < 12)

        var ticks: [MPVPlaybackTiming] = []

        for await tick in timing {
            ticks.append(tick)
        }

        #expect(ticks.count == 1 && ticks[0].position == .seconds(1) && ticks[0].generation == 4)
    }

    @Test
    func `play pause intent is delivered even when buffering masks the transport state`() async {
        let broadcaster = MPVPlaybackEventBroadcaster()
        var snapshot = MPVSessionSnapshot()
        snapshot.state = .buffering
        broadcaster.reset(snapshot)
        let events = broadcaster.subscribe()
        snapshot.isPaused = false
        broadcaster.update(snapshot, features: snapshot.videoFeatureCapabilities)
        snapshot.isPaused = true
        broadcaster.update(snapshot, features: snapshot.videoFeatureCapabilities)
        broadcaster.terminate()
        var pauses: [Bool] = []

        for await event in events {
            if case let .pauseChanged(paused) = event.change {
                pauses.append(paused)
            }
        }

        #expect(pauses == [false, true])
    }

    @Test
    func `subscriptions finish without retaining the player`() async throws {
        var player: MPVPlayer? = MPVPlayer()
        weak var owner: MPVPlayer?
        owner = player
        let events = try #require(player?.makeEventStream())
        let timing = try #require(player?.makeTimingStream())
        player = nil

        #expect(owner == nil)

        var count = 0

        for await _ in events {
            count += 1
        }

        #expect(count == 1)

        count = 0
        for await _ in timing {
            count += 1
        }

        #expect(count == 1)
    }

    @Test
    func `stale emissions cannot change readiness or emit operation results after stop`() async {
        let player = MPVPlayer()
        let generation = player.generation
        player.stop()
        var snapshot = MPVSessionSnapshot()
        snapshot.generation = generation
        snapshot.isPlaybackReady = true
        snapshot.state = .playing
        player.apply(.init(generation: generation, update: .playbackReady(true), snapshot: snapshot))

        #expect(player.generation != generation)
        #expect(!player.isPlaybackReady && player.state == .stopped)

        var iterator = player.makeEventStream().makeAsyncIterator()
        let initial = await iterator.next()

        #expect(initial?.generation == player.generation)

        guard case let .snapshot(value) = initial?.change else {
            Issue.record("Missing initial snapshot")

            return
        }

        #expect(!value.isPlaybackReady)
    }
}
