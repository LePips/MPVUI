import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVPreciseSeekPolicyTests {

    @Test
    func `only transport demuxers need earlier packets`() {
        for format in ["mpegts", "mpegtsraw", "hls", "hls,applehttp"] {
            #expect(MPVSession.preciseSeekDemuxerOffset(for: format) == 0.5)
        }
        for format in [nil, "", "matroska,webm", "mov,mp4,m4a,3gp,3g2,mj2", "mpeg", "mp3"] {
            #expect(MPVSession.preciseSeekDemuxerOffset(for: format) == 0)
        }
    }

    @Test(arguments: [false, true])
    func `seek policy follows detected format across sources and preserves explicit overrides`(override: Bool) async throws {
        var options = ["ao": "null", "vid": "no"]
        if override {
            options["hr-seek-demuxer-offset"] = "0.125"
        }
        let engine = MPVSession(configuration: .init(additionalOptions: options, automaticallyPlays: false)) { _ in }
        defer { engine.shutdownSynchronously() }

        for (index, ext) in ["mp4", "ts", "mkv", "ts", "mp4"].enumerated() {
            try engine.load(
                TestPaths.testMedia("video-h264-long-gop.\(ext)"),
                playAutomatically: false,
                startTime: .seconds(1),
                generation: UInt64(index + 1)
            )
            try await eventually("seek-policy source discovery") {
                engine.queue.sync { engine.hasPlaybackStarted && engine.currentGeneration == UInt64(index + 1) }
            }
            engine.queue.sync {
                #expect(engine.getDouble("hr-seek-demuxer-offset") == (override ? 0.125 : (ext == "ts" ? 0.5 : 0)))
                #expect(engine.fatalPlaybackError == nil)
            }
            #expect(await engine.seekForPictureInPicture(to: .seconds(8)))
            engine.queue.sync {
                #expect(abs((engine.getDouble("time-pos") ?? -1) - 8) < 0.15)
                #expect(engine.isPaused)
            }
        }
    }

    @Test(arguments: ["hr-seek-demuxer-offset", "options/hr-seek-demuxer-offset"])
    func `resolved command overrides survive replacing a source on the same client`(property: String) async throws {
        let engine = MPVSession(configuration: .init(additionalOptions: ["ao": "null", "vid": "no"], automaticallyPlays: false)) { _ in }
        defer { engine.shutdownSynchronously() }
        try engine.load(TestPaths.testMedia("video-h264-long-gop.ts"), playAutomatically: false, startTime: nil, generation: 1)
        try await eventually("transport source uses automatic seek offset") {
            engine.queue.sync { engine.hasPlaybackStarted && engine.getDouble("hr-seek-demuxer-offset") == 0.5 }
        }

        let handles = engine.queue.sync {
            engine.setPropertyImmediatelyOrDefer(property, to: "0.125")
            #expect(engine.runCommand(["add", property, "0.125"]) >= 0)
            #expect(engine.getDouble("hr-seek-demuxer-offset") == 0.25)
            return engine.lifecycleDiagnostics.handlesCreated
        }
        try engine.load(TestPaths.testMedia("video-h264-long-gop.mp4"), playAutomatically: false, startTime: nil, generation: 2)
        try await eventually("replacement source preserves the resolved user override") {
            engine.queue.sync { engine.currentGeneration == 2 && engine.hasPlaybackStarted }
        }
        engine.queue.sync {
            #expect(engine.getDouble("hr-seek-demuxer-offset") == 0.25)
            #expect(engine.lifecycleDiagnostics.handlesCreated == handles)
        }
    }

    @Test(arguments: [false, true])
    func `file local seek overrides during held preload apply only to that source`(command: Bool) async throws {
        let engine = MPVSession(configuration: .init(additionalOptions: ["ao": "null"], automaticallyPlays: false)) { _ in }
        defer { engine.shutdownSynchronously() }

        for (index, ext) in ["ts", "mp4"].enumerated() {
            let generation = UInt64(index + 1)
            try engine.load(
                TestPaths.testMedia("video-h264-long-gop.\(ext)"),
                playAutomatically: false,
                startTime: nil,
                generation: generation
            )
            try await eventually("source waits at preload") {
                engine.queue.sync { engine.currentGeneration == generation && engine.pendingPreloadHookID != nil }
            }
            engine.queue.sync {
                if index == 0 {
                    let property = "file-local-options/hr-seek-demuxer-offset"
                    if command {
                        #expect(engine.runCommand(["set", property, "0.125"]) >= 0)
                    } else {
                        engine.setPropertyImmediatelyOrDefer(property, to: "0.125")
                    }
                }
                engine.setPropertyImmediatelyOrDefer("vid", to: "no")
            }
            try await eventually("source completes preload with its seek policy") {
                engine.queue.sync { engine.hasPlaybackStarted }
            }
            engine.queue.sync {
                #expect(engine.getDouble("hr-seek-demuxer-offset") == (index == 0 ? 0.125 : 0))
                #expect(engine.fatalPlaybackError == nil)
            }
        }
    }
}
