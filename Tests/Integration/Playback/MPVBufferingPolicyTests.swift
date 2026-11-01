import Foundation
import Libmpv
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVBufferingPolicyTests {

    @Test(arguments: [false, true], [Duration.zero, .seconds(1)])
    func `initial cache pause retains startup target until filled`(paused: Bool, initial: Duration) async throws {
        let bytesPerSecond: Int64 = 48000 * 2 * 2
        let stream = SyntheticCacheStream(length: bytesPerSecond * 60, deliveryBytesPerSecond: Double(bytesPerSecond * 4))
        let engine = MPVSession(configuration: .init(
            additionalOptions: [
                "ao": "null",
                "demuxer": "rawaudio",
                "demuxer-rawaudio-channels": "stereo",
                "demuxer-rawaudio-format": "s16le",
                "demuxer-rawaudio-rate": "48000",
            ],
            automaticallyPlays: !paused,
            cache: .init(mode: .enabled),
            initialBufferDuration: initial,
            rebufferDuration: .milliseconds(250)
        )) { _ in }
        defer {
            engine.shutdownSynchronously()
            withExtendedLifetime(stream) {}
        }
        try engine.queue.sync {
            engine.createHandle()
            let handle = try #require(engine.handle)
            try #require(mpv_stream_cb_add_ro(
                handle,
                "bufferpolicy",
                Unmanaged.passUnretained(stream).toOpaque(),
                SyntheticCacheStream.open
            ) >= 0)
        }

        for generation in UInt64(1) ... 2 {
            try engine.load(
                #require(URL(string: "bufferpolicy://audio")),
                playAutomatically: !paused,
                startTime: nil,
                generation: generation
            )
            try await eventually("initial playback restart before cache completion", pollInterval: .milliseconds(5)) {
                try engine.queue.sync {
                    try #require(engine.fatalPlaybackError == nil)
                    return engine.currentGeneration == generation && engine.hasPlaybackStarted
                }
            }

            if initial > .zero {
                engine.queue.sync {
                    #expect(engine.getFlag("paused-for-cache") == true)
                    #expect(engine.isInitialBufferingPending)
                    #expect(engine.getDouble("cache-pause-wait") == initial.seconds)
                }
            }

            try await eventually("initial fill enables recovery policy") {
                engine.queue.sync {
                    !engine.isInitialBufferingPending && engine.getFlag("paused-for-cache") == false
                        && engine.getDouble("cache-pause-wait") == 0.25
                }
            }
            engine.queue.sync { #expect(engine.isPaused == paused) }

            engine.seek(to: .seconds(30))
            try await eventually("uncached seek fills the independent recovery target") {
                engine.queue.sync {
                    !engine.isSeeking && engine.getFlag("paused-for-cache") == false
                        && abs(engine.lastPosition.seconds - 30) < 0.2
                        && engine.getDouble("cache-pause-wait") == 0.25
                }
            }
        }
    }

    @Test(arguments: [Duration.zero, .seconds(3)])
    func `startup and recovery targets are independent across seeks and replacement loads`(initial: Duration) async throws {
        let engine = MPVSession(configuration: .init(
            additionalOptions: ["ao": "null"],
            automaticallyPlays: false,
            cache: .init(mode: .enabled),
            initialBufferDuration: initial,
            rebufferDuration: .milliseconds(250)
        )) { _ in }
        defer { engine.shutdownSynchronously() }

        for generation in UInt64(1) ... 2 {
            engine.load(TestPaths.baselineMedia, playAutomatically: false, startTime: nil, generation: generation)
            try await eventually("new source held before decoder startup") {
                try engine.queue.sync {
                    try #require(engine.fatalPlaybackError == nil)
                    return engine.currentGeneration == generation && engine.pendingPreloadHookID != nil
                }
            }

            engine.queue.sync {
                #expect(engine.getDouble("cache-pause-wait") == initial.seconds)
                #expect(engine.getFlag("cache-pause-initial") == (initial > .zero))
            }

            // Disable video to release discovery without needing a display.
            engine.setProperty("vid", to: "no")
            try await eventually("first restart installs the recovery policy") {
                try engine.queue.sync {
                    try #require(engine.fatalPlaybackError == nil)
                    return engine.hasPlaybackStarted && engine.getDouble("cache-pause-wait") == 0.25
                        && engine.getFlag("cache-pause-initial") == true
                }
            }

            engine.seek(to: .milliseconds(500))
            try await eventually("paused seek resumes with the recovery target") {
                engine.queue.sync {
                    !engine.isSeeking && abs(engine.lastPosition.seconds - 0.5) < 0.1
                        && engine.getDouble("cache-pause-wait") == 0.25
                }
            }
        }
    }

    @Test
    func `native buffer overrides remain authoritative across startup and recovery`() async throws {
        let engine = MPVSession(configuration: .init(
            additionalOptions: ["ao": "null", "vid": "no", "cache-pause-wait": "2", "cache-pause-initial": "no"],
            automaticallyPlays: false,
            initialBufferDuration: .zero,
            rebufferDuration: .milliseconds(250)
        )) { _ in }
        defer { engine.shutdownSynchronously() }

        for generation in UInt64(1) ... 2 {
            engine.load(TestPaths.baselineMedia, playAutomatically: false, startTime: nil, generation: generation)
            try await eventually("native override source restarted") {
                try engine.queue.sync {
                    try #require(engine.fatalPlaybackError == nil)
                    return engine.currentGeneration == generation && engine.hasPlaybackStarted
                }
            }

            engine.queue.sync {
                #expect(engine.getDouble("cache-pause-wait") == (generation == 1 ? 2 : 4))
                #expect(engine.getFlag("cache-pause-initial") == false)
            }

            if generation == 1 {
                engine.setProperty("cache-pause-wait", to: "4")
                try await eventually("runtime override applied") {
                    engine.queue.sync { engine.getDouble("cache-pause-wait") == 4 }
                }
            }
        }
    }

    @Test(arguments: ["command", "options-command", "file-local-command", "file-local-property"])
    func `runtime overrides retain their native scope across policy transitions and replacement loads`(mutation: String) async throws {
        let engine = MPVSession(configuration: .init(
            additionalOptions: ["ao": "null", "vid": "no"],
            automaticallyPlays: false,
            initialBufferDuration: .seconds(3),
            rebufferDuration: .milliseconds(250)
        )) { _ in }
        defer { engine.shutdownSynchronously() }

        engine.load(TestPaths.baselineMedia, playAutomatically: false, startTime: nil, generation: 1)
        try await eventually("runtime override source started") {
            try engine.queue.sync {
                try #require(engine.fatalPlaybackError == nil)
                return engine.hasPlaybackStarted
            }
        }

        let fileLocal = mutation.hasPrefix("file-local")
        let prefix = fileLocal ? "file-local-options/" : mutation == "options-command" ? "options/" : ""

        if !fileLocal {
            // A later raw command must supersede an earlier property API value.
            engine.setProperty("cache-pause-wait", to: "2")
        }

        for (name, value) in [("cache-pause-wait", "4"), ("cache-pause-initial", "no")] {
            if mutation == "file-local-property" {
                engine.setProperty(prefix + name, to: value)
            } else {
                engine.performCommand("set", arguments: [prefix + name, value])
            }
        }

        try await eventually("runtime override applied") {
            engine.queue.sync { engine.getDouble("cache-pause-wait") == 4 && engine.getFlag("cache-pause-initial") == false }
        }

        engine.queue.sync {
            for initial in [true, false] {
                engine.applyBufferingPolicy(initial: initial)
                #expect(engine.getDouble("cache-pause-wait") == 4)
                #expect(engine.getFlag("cache-pause-initial") == false)
            }
        }

        engine.load(TestPaths.baselineMedia, playAutomatically: false, startTime: nil, generation: 2)
        try await eventually("replacement source retains only persistent overrides") {
            try engine.queue.sync {
                try #require(engine.fatalPlaybackError == nil)
                return engine.currentGeneration == 2 && engine.hasPlaybackStarted
            }
        }

        engine.queue.sync {
            #expect(engine.lifecycleDiagnostics.handlesCreated == 1)
            #expect(engine.getDouble("cache-pause-wait") == (fileLocal ? 0.25 : 4))
            #expect(engine.getFlag("cache-pause-initial") == fileLocal)
        }
    }
}
