import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVPlayerConfigurationOutputTests {
    @Test
    func `default output uses sample buffers on every platform`() {
        let configuration = MPVPlayerConfiguration()
        #expect(configuration.usesAutomaticVideoOutput)
        #expect(configuration.videoOutput == .sampleBuffer)
        #expect(configuration.nativeVideoFeaturePolicy == .preferFeatures)
        #expect(MPVPlayerConfiguration.default == configuration)
        #expect(MPVPlayerConfiguration(videoOutput: nil) == configuration)
    }

    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases)
    func `explicit backend remains authoritative`(output: MPVPlayerConfiguration.VideoOutput) {
        let configuration = MPVPlayerConfiguration(videoOutput: output)
        #expect(!configuration.usesAutomaticVideoOutput)
        #expect(configuration.videoOutput == output)
        #expect(configuration.nativeVideoFeaturePolicy == .preserveDolbyVision)
        let customized = MPVPlayerConfiguration(
            additionalOptions: ["scale": "lanczos"],
            renderingQuality: .init(preset: .highQuality),
            sdrOutput: .highPrecision,
            videoOutput: output
        )
        #expect(customized.videoOutput == output)
    }

    @Test
    func `rendering customizations retain Metal`() {
        let shader = URL(fileURLWithPath: "/tmp/benchmark-shader.glsl")
        let configurations = [
            MPVPlayerConfiguration(additionalOptions: ["sub-font": "Example Font"]),
            MPVPlayerConfiguration(colorManagement: .init(referenceWhite: 250)),
            MPVPlayerConfiguration(colorManagement: .init(sdrViewing: .legacyDisplay)),
            MPVPlayerConfiguration(renderingQuality: .init(preset: .battery)),
            MPVPlayerConfiguration(renderingQuality: .init(preset: .balanced)),
            MPVPlayerConfiguration(renderingQuality: .init(preset: .highQuality)),
            MPVPlayerConfiguration(renderingQuality: .init(scaling: .lanczos)),
            MPVPlayerConfiguration(renderingQuality: .init(shaders: [shader])),
            MPVPlayerConfiguration(deinterlace: .init(mode: .automatic)),
            MPVPlayerConfiguration(deinterlace: .init(algorithm: .bwdif, mode: .forced)),
            MPVPlayerConfiguration(hdrPolicy: .always),
            MPVPlayerConfiguration(hdrPolicy: .disabled),
            MPVPlayerConfiguration(hdrPolicy: .constrained),
            MPVPlayerConfiguration(sdrOutput: .compatibility8Bit),
            MPVPlayerConfiguration(sdrOutput: .highPrecision),
        ]
        for configuration in configurations {
            #expect(configuration.usesAutomaticVideoOutput)
            #expect(configuration.videoOutput == .metal)
            #expect(configuration.nativeVideoFeaturePolicy == .preserveDolbyVision)
        }
    }

    @Test
    func `unrelated playback options preserve automatic output selection`() {
        let configuration = MPVPlayerConfiguration(
            autoPlay: false,
            initialBufferSeconds: .seconds(2),
            networkCacheSeconds: .seconds(20),
            playbackRate: 1.5,
            volume: 75
        )
        #expect(configuration.videoOutput == MPVPlayerConfiguration.default.videoOutput)
        #expect(configuration.nativeVideoFeaturePolicy == MPVPlayerConfiguration.default.nativeVideoFeaturePolicy)
    }

    @Test(arguments: [MPVNativeVideoFeaturePolicy.preserveDolbyVision, .preferFeatures])
    func `explicit feature policy is retained`(policy: MPVNativeVideoFeaturePolicy) {
        #expect(MPVPlayerConfiguration(nativeVideoFeaturePolicy: policy).nativeVideoFeaturePolicy == policy)
        for output in MPVPlayerConfiguration.VideoOutput.allCases {
            let configuration = MPVPlayerConfiguration(nativeVideoFeaturePolicy: policy, videoOutput: output)
            #expect(configuration.nativeVideoFeaturePolicy == policy)
        }
    }

    @MainActor
    @Test
    func `implicit native output preserves selected authored subtitles when DV arrives`() {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        let subtitle = MPVMediaTrack(id: 1, type: .subtitle, codec: "ass", isSelected: true)
        player.apply(.init(generation: nil, update: .media(.init(tracks: [subtitle]))))
        player.updateDolbyVisionStatus(.init(sourceProfile: 8))
        #expect(player.videoOutput == .metal)
        #expect(player.videoFeatureRequestResult?.outcome == .switchedToMetal)
        #expect(player.videoFeatureRequestResult?.requestedFeatures == [.nativeSubtitles])
    }
}
