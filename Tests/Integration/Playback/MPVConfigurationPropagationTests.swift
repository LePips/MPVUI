import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVConfigurationPropagationTests {
    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases)
    func `typed quality reaches the renderer or reports native limitations`(
        output: MPVPlayerConfiguration.VideoOutput
    ) async throws {
        let quality = MPVRenderingQuality(
            antiringing: 0.25, chromaScaling: .bicubic, debanding: false,
            dithering: .ordered, gamutMapping: .relative, peakDetection: .disabled,
            preset: .battery, scaling: .lanczos, toneMapping: .reinhard
        )
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null", "sid": "no", "scale": "bilinear", "deband": "yes"],
            autoPlay: false, renderingQuality: quality, videoOutput: output
        ))
        defer { fixture.close() }
        try await fixture.loadPaused(TestPaths.testMedia("feature-hdr10.mkv"))
        let player = fixture.player
        try await eventually("accepted rendering quality diagnostics") {
            player.playbackDiagnostics.renderingQuality.requested == quality
        }
        let status = player.playbackDiagnostics.renderingQuality
        #expect(status.resolvedPreset == .battery)
        #expect(status.backend == output)
        if output == .sampleBuffer {
            #expect(status.effectiveOptions.isEmpty)
            #expect(!status.unsupportedFeatures.isEmpty)
        } else {
            let options = status.effectiveOptions
            #expect(options["scale"] == "lanczos")
            #expect(options["cscale"] == "bicubic")
            #expect(options["scale-antiring"].flatMap(Double.init) == 0.25)
            #expect(options["deband"] == "no")
            #expect(options["dither"] == "ordered")
            #expect(options["gamut-mapping-mode"] == "relative")
            #expect(options["hdr-compute-peak"] == "no")
            #expect(options["tone-mapping"] == "reinhard")
            #expect(status.unsupportedFeatures.isEmpty)
        }
        #expect(player.lastError == nil)
    }

    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases)
    func `public defaults and additional overrides reach mpv and survive recreation`(
        output: MPVPlayerConfiguration.VideoOutput
    ) async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: [
                "ao": "null", "sid": "no", "cache-secs": "7", "audio-spdif": "",
                "ao-avfoundation-spatial-audio": "multichannel", "sub-font": "sans-serif",
                "vo": "invalid-output", "volume": "99", "speed": "2", "target-contrast": "invalid-contrast",
            ],
            audio: .init(audioSession: .hostManaged, spatialization: .disabled),
            autoPlay: false,
            hardwareDecoding: .disabled,
            initialBufferSeconds: .milliseconds(250),
            logLevel: .info,
            loop: true,
            networkCacheSeconds: .seconds(21),
            playbackRate: 1.25,
            startTime: .milliseconds(400),
            videoOutput: output,
            volume: 37
        ))
        defer { fixture.close() }
        let player = fixture.player
        player.load(TestPaths.baselineMedia)
        try await eventually("configured initial position and pause", timeout: .seconds(15)) {
            player.state == .paused && abs(player.position.seconds - 0.4) < 0.1
        }
        let expectedOutput = output
        #expect(player.videoOutput == expectedOutput)

        let properties = [
            "vo", "hwdec", "cache-secs", "cache-pause-wait", "cache-pause-initial",
            "loop-file", "speed", "volume", "audio-spdif", "ao-avfoundation-spatial-audio",
            "ao-avfoundation-manage-audio-session", "sub-font",
        ]
        var observed: [String: String] = [:]
        player.logHandler = { message in
            guard let marker = message.message.range(of: "CONFIG_AUDIT|") else { return }
            for field in message.message[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|") {
                let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 {
                    observed[String(parts[0])] = String(parts[1])
                }
            }
        }
        for recreate in [false, true] {
            if recreate {
                let previous = await player.lifecycleDiagnostics()
                player.stop()
                try await eventually("configured player stopped") { player.state == .stopped }
                player.load(TestPaths.baselineMedia)
                try await eventually("configuration restored after recreation") {
                    let current = await player.lifecycleDiagnostics()
                    return current.handlesCreated == previous.handlesCreated + 1
                        && player.state == .paused && player.isSeekable
                        && abs(player.position.seconds - 0.4) < 0.1
                }
            }
            observed = [:]
            let query = "CONFIG_AUDIT|" + properties.map { "\($0)=${=options/\($0)}" }.joined(separator: "|")
            player.command("expand-properties", arguments: ["print-text", query])
            try await eventually("real mpv option readback") { observed.count == properties.count }
            #expect(observed["vo"] == (expectedOutput == .metal ? "gpu-next" : "avfoundation"))
            #expect(observed["hwdec"] == "no")
            #expect(observed["cache-secs"].flatMap(Double.init) == 7)
            #expect(observed["cache-pause-wait"].flatMap(Double.init) == 0.25)
            #expect(observed["cache-pause-initial"] == "yes")
            #expect(observed["loop-file"] == "inf")
            #expect(observed["speed"].flatMap(Double.init) == 1.25)
            #expect(observed["volume"].flatMap(Double.init) == 37)
            #expect(observed["audio-spdif"] == "")
            #expect(observed["ao-avfoundation-spatial-audio"] == "multichannel")
            #expect(observed["ao-avfoundation-manage-audio-session"] == "no")
            #expect(observed["sub-font"] == "sans-serif")
            #expect(player.videoOutput == expectedOutput)
            #expect(player.lastError == nil)
        }
    }
}
