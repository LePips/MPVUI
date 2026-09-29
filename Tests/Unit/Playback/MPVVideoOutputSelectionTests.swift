import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
@MainActor
struct MPVVideoOutputSelectionTests {
    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases)
    func `raw properties and commands never change output across loads`(output: MPVPlayerConfiguration.VideoOutput) {
        let player = MPVPlayer(configuration: .init(autoPlay: false, videoOutput: output))
        for property in ["video-zoom", "options/video-pan-x", "video-scale-y", "video-rotate", "brightness", "unknown-property"] {
            player.setProperty(property, to: "2")
            #expect(player.videoOutput == output)
        }
        player.setProperty("video-zoom", to: "0")
        player.command("add", arguments: ["video-zoom", "0.25"])
        player.command("expand-properties", arguments: ["set", "video-zoom", "0.25"])
        for command in ["vf", "overlay-add", "unknown-command"] {
            player.command(command)
            #expect(player.videoOutput == output)
        }
        for _ in 0 ..< 2 {
            player.load(TestPaths.baselineMedia, autoPlay: false)
            #expect(player.videoOutput == output)
        }
    }

    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases)
    func `feature requests report capabilities without selecting a renderer`(output: MPVPlayerConfiguration.VideoOutput) {
        let player = MPVPlayer(configuration: .init(autoPlay: false, videoOutput: output))
        let features: Set<MPVVideoFeature> = [.nativeSubtitles, .bakedOverlays, .zoomAndPan]
        #expect(player.requestVideoFeatures(features).outcome == .awaitingVideoMetadata)
        #expect(player.videoOutput == output)
        player.updateDolbyVisionStatus(.init(sourceProfile: 5, nativeValidation: .validated))
        #expect(player.videoOutput == output)
        #expect(player.videoFeatureRequestResult?.outcome == (output == .metal ? .available : .unavailable))
        #expect(player.videoFeatureRequestResult?.unavailableFeatures == (output == .metal ? [] : features))
        player.load(TestPaths.baselineMedia)
        #expect(player.videoOutput == output)
        #expect(player.videoFeatureRequestResult == nil)
    }

    @Test
    func `ordinary native video supports subtitles overlays and geometry`() {
        let player = MPVPlayer()
        player.apply(.init(generation: nil, update: .media(.init(videoCodec: "h264"))))
        let result = player.requestVideoFeatures([.nativeSubtitles, .bakedOverlays, .zoomAndPan])
        #expect(result.outcome == .available)
        #expect(result.unavailableFeatures.isEmpty)
        #expect(player.videoOutput == .sampleBuffer)
    }

    @Test(arguments: ["vo", "options/vo", "file-local-options/vo", "gpu-api", "gpu-context", "wid"])
    func `raw commands cannot override renderer wiring`(property: String) async throws {
        let player = MPVPlayer()
        player.command("expand-properties", arguments: ["set", property, "null"])
        try await eventually("reserved renderer property") {
            player.lastError == .reservedProperty(name: property)
        }
        #expect(player.videoOutput == .sampleBuffer)
    }

    @Test
    func `unsupported native HDR override leaves the renderer unchanged`() {
        let player = MPVPlayer(configuration: .init(hdrPolicy: .disabled))
        player.updateSampleBufferOutput(
            displayCapabilities: .unknown, configuredDynamicRange: .automatic,
            policyFallbackReason: .unsupportedPolicy
        )
        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.lastError == nil)
    }
}
