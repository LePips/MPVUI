#if os(macOS)
import Darwin
import Foundation
import Libmpv
@testable import MPVCore
@testable import MPVUI
import Testing

/// Measures actual demux packet capacity without disk or network throughput noise.
@MainActor
enum MPVCachePerformanceWorkloads {

    static func measure(repetitions: Int) async throws -> [[String: Any]] {
        let policies: [(String, MPVCacheConfiguration)] = [
            ("cache_64mib", .init(mode: .enabled, maximumBytes: 64 * 1024 * 1024, maximumBackBytes: 16 * 1024 * 1024)),
            ("cache_default", .init(mode: .enabled)),
        ]
        var samples: [String: [[String: Double]]] = [:]

        for repetition in 0 ..< repetitions {
            for (id, policy) in repetition.isMultiple(of: 2) ? policies : Array(policies.reversed()) {
                try await samples[id, default: []].append(sample(policy))
            }
        }

        let capacity = policies.map { id, policy -> [String: Any] in
            let collected = samples[id] ?? []
            let metrics: [String: Any] = [
                "bufferedSeconds": ["unit": "seconds", "direction": "higher", "samples": collected.compactMap { $0["bufferedSeconds"] }],
                "forwardPacketBytes": [
                    "unit": "bytes",
                    "direction": "neutral",
                    "samples": collected.compactMap { $0["forwardPacketBytes"] }
                ],
                "totalPacketBytes": ["unit": "bytes", "direction": "neutral", "samples": collected.compactMap { $0["totalPacketBytes"] }],
                "fillSeconds": ["unit": "seconds", "direction": "neutral", "samples": collected.compactMap { $0["fillSeconds"] }],
            ]

            return [
                "id": id,
                "parameters": [
                    "maximumBytes": policy.maximumBytes,
                    "maximumBackBytes": policy.maximumBackBytes,
                    "requestedCacheSeconds": 10,
                    "packetBitrateBitsPerSecond": SyntheticCacheStream.bytesPerSecond * 8,
                    "media": "synthetic seekable 384 kHz 7.1 s32le PCM",
                    "backend": "null",
                    "scope": "Packet capacity only. Does not model network stalls or encoded-video decoding cost.",
                ],
                "metrics": metrics,
                "observations": [],
            ]
        }

        return try await capacity + bufferingWorkloads(repetitions: repetitions)
    }

    private static func bufferingWorkloads(repetitions: Int) async throws -> [[String: Any]] {
        let policies: [(String, Duration)] = [
            ("buffering_coupled_reference", .seconds(3)),
            ("buffering_independent_recovery", .milliseconds(250)),
        ]
        var samples: [String: [[String: Double]]] = [:]

        for repetition in 0 ..< repetitions {
            for (id, recovery) in repetition.isMultiple(of: 2) ? policies : Array(policies.reversed()) {
                try await samples[id, default: []].append(bufferingSample(recovery: recovery))
            }
        }

        return policies.map { id, recovery in
            let collected = samples[id] ?? []
            return [
                "id": id,
                "parameters": [
                    "initialBufferSeconds": 3,
                    "rebufferSeconds": recovery.seconds,
                    "requestedCacheSeconds": 10,
                    "media": "synthetic seekable 48 kHz stereo s16le PCM",
                    "deliverySpeed": "4x media rate",
                    "seekTargetSeconds": 30,
                    "scope": "Controlled input delivery through production MPVSession. Does not model a real network.",
                ],
                "metrics": [
                    "startupSeconds": ["unit": "seconds", "direction": "lower", "samples": collected.compactMap { $0["startupSeconds"] }],
                    "uncachedSeekSeconds": [
                        "unit": "seconds",
                        "direction": "lower",
                        "samples": collected.compactMap { $0["uncachedSeekSeconds"] }
                    ],
                ],
                "observations": collected.enumerated().map { index, sample in
                    sample.filter { !["startupSeconds", "uncachedSeekSeconds"].contains($0.key) }
                        .merging(["repetition": Double(index + 1)], uniquingKeysWith: { _, latest in latest })
                },
            ]
        }
    }

    private static func bufferingSample(recovery: Duration) async throws -> [String: Double] {
        let pcmBytesPerSecond: Int64 = 48000 * 2 * 2
        let stream = SyntheticCacheStream(length: pcmBytesPerSecond * 60, deliveryBytesPerSecond: Double(pcmBytesPerSecond * 4))
        let engine = MPVSession(configuration: .init(
            additionalOptions: [
                "ao": "null",
                "demuxer": "rawaudio",
                "demuxer-rawaudio-channels": "stereo",
                "demuxer-rawaudio-format": "s16le",
                "demuxer-rawaudio-rate": "48000",
            ],
            automaticallyPlays: true,
            cache: .init(mode: .enabled),
            initialBufferDuration: .seconds(3),
            logLevel: .none,
            rebufferDuration: recovery
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
                "cacheaudio",
                Unmanaged.passUnretained(stream).toOpaque(),
                SyntheticCacheStream.open
            ) >= 0)
        }

        let start = ContinuousClock.now
        var sawStartupCachePause = false
        engine.load(URL(string: "cacheaudio://sample")!, playAutomatically: true, startTime: nil, generation: 1)
        try await eventually("controlled stream completes initial buffering", timeout: .seconds(10), pollInterval: .milliseconds(5)) {
            let state = try engine.queue.sync {
                try #require(engine.fatalPlaybackError == nil)
                return (
                    ready: engine.hasPlaybackStarted && !engine.isInitialBufferingPending,
                    paused: engine.getFlag("paused-for-cache"),
                    target: engine.getDouble("cache-pause-wait")
                )
            }
            if state.paused == true {
                sawStartupCachePause = true
                try #require(state.target == 3, "The initial target must remain in force throughout the initial cache pause.")
            }
            return state.ready && state.paused == false
        }
        let startup = start.duration(to: .now).seconds
        try #require(sawStartupCachePause)
        // Input callbacks deliver at most four media seconds per wall second.
        // Completion must therefore include delivery of the full startup target.
        try #require(startup >= 3.0 / 4.0)

        let startupDemuxSeconds = try engine.queue.sync {
            let cache = engine.getNode("demuxer-cache-state")?.mapValue
            try #require(engine.getFlag("paused-for-cache") == false)
            try #require(engine.getDouble("cache-pause-wait") == recovery.seconds)
            try #require(engine.getFlag("cache-pause-initial") == true)
            let ranges = MPVSession.parseSeekableRanges(engine.getNode("demuxer-cache-state")?.mapValue?["seekable-ranges"])
            try #require(!ranges.contains { $0.contains(.seconds(30)) }, "Seek target must be outside the initial packet cache.")
            return try #require(cache?["cache-duration"]?.doubleValue)
        }

        let seekStart = ContinuousClock.now
        var sawSeekCachePause = false
        engine.seek(to: .seconds(30))
        try await eventually("controlled stream completes uncached seek", timeout: .seconds(10), pollInterval: .milliseconds(5)) {
            let state = try engine.queue.sync {
                try #require(engine.fatalPlaybackError == nil)
                return (
                    ready: !engine.isSeeking && abs(engine.lastPosition.seconds - 30) < 0.2,
                    paused: engine.getFlag("paused-for-cache"),
                    target: engine.getDouble("cache-pause-wait")
                )
            }
            if state.paused == true {
                sawSeekCachePause = true
                try #require(state.target == recovery.seconds)
            }
            return state.ready && state.paused == false
        }
        let seek = seekStart.duration(to: .now).seconds
        try #require(sawSeekCachePause)
        try #require(seek >= recovery.seconds / 4)

        let seekDemuxSeconds = try engine.queue.sync {
            let cache = engine.getNode("demuxer-cache-state")?.mapValue
            try #require(engine.getFlag("paused-for-cache") == false)
            return try #require(cache?["cache-duration"]?.doubleValue)
        }

        // Demux duration excludes packets already decoded or queued to the AO.
        // Record it, but prove refill through the native cache-pause transition
        // and paced input delivery instead of an arbitrary packet tolerance.
        return [
            "startupSeconds": startup,
            "uncachedSeekSeconds": seek,
            "startupDemuxSecondsAtCompletion": startupDemuxSeconds,
            "seekDemuxSecondsAtCompletion": seekDemuxSeconds,
            "startupCachePauseObserved": sawStartupCachePause ? 1 : 0,
            "seekCachePauseObserved": sawSeekCachePause ? 1 : 0,
        ]
    }

    private static func sample(_ policy: MPVCacheConfiguration) async throws -> [String: Double] {
        let stream = SyntheticCacheStream()
        let session = try NativePlaybackSession(options: [
            "terminal": "yes",
            "audio": "auto",
            "demuxer": "rawaudio",
            "demuxer-rawaudio-channels": "7.1",
            "demuxer-rawaudio-format": "s32le",
            "demuxer-rawaudio-rate": "384000",
            "cache": "yes",
            "cache-secs": "10",
            "demuxer-max-bytes": String(policy.maximumBytes),
            "demuxer-max-back-bytes": String(policy.maximumBackBytes),
            "cache-pause-initial": "no",
        ])
        defer {
            session.close()
            withExtendedLifetime(stream) {}
        }
        try session.registerStream(
            protocol: "cachebench",
            userData: Unmanaged.passUnretained(stream).toOpaque(),
            open: SyntheticCacheStream.open
        )
        let start = ContinuousClock.now
        try session.command(["loadfile", "cachebench://audio"])

        do {
            try await eventually("demuxer reaches the configured packet or duration limit", timeout: .seconds(10)) {
                guard let state = session.property("demuxer-cache-state")?.mapValue else { return false }

                return session.property("time-pos")?.doubleValue != nil
                    && state["idle"]?.boolValue == true
                    && (state["cache-duration"]?.doubleValue ?? 0) > 1
            }
        } catch {
            print("Cache capacity failure: state=\(String(describing: session.property("demuxer-cache-state"))) "
                + "position=\(String(describing: session.property("time-pos"))) "
                + "tracks=\(String(describing: session.property("track-list")))")
            throw error
        }

        let elapsed = start.duration(to: .now).seconds
        let state = try #require(session.property("demuxer-cache-state")?.mapValue)
        let duration = try #require(state["cache-duration"]?.doubleValue)
        let forwardBytes = try #require(state["fw-bytes"]?.integerValue)
        let totalBytes = try #require(state["total-bytes"]?.integerValue)
        try #require(state["eof"]?.boolValue == false, "Capacity measurement must not be shortened by end of input.")
        try #require(forwardBytes <= policy.maximumBytes + SyntheticCacheStream.packetBytes * 2)

        if policy.maximumBytes >= 128 * 1024 * 1024 {
            try #require(duration >= 9.5, "The enlarged cache should reach the requested ten-second target.")
        } else {
            try #require(duration < 6, "The 64 MiB reference should remain byte-limited at this packet bitrate.")
        }

        return [
            "bufferedSeconds": duration,
            "forwardPacketBytes": Double(forwardBytes),
            "totalPacketBytes": Double(totalBytes),
            "fillSeconds": elapsed,
        ]
    }
}

#endif
