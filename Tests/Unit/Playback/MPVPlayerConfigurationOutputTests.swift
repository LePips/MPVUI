import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVPlayerConfigurationOutputTests {
    @Test
    func `default output is sample buffers without implicit selection state`() {
        #expect(MPVPlayerConfiguration().videoOutput == .sampleBuffer)
        #expect(MPVPlayerConfiguration() == MPVPlayerConfiguration(videoOutput: .sampleBuffer))
    }

    @Test
    func `rendering options never choose the default renderer`() {
        let shader = URL(fileURLWithPath: "/tmp/benchmark-shader.glsl")
        let configurations = [
            MPVPlayerConfiguration(additionalOptions: ["vf": "hflip"]),
            MPVPlayerConfiguration(additionalOptions: ["unknown-rendering-option": "yes"]),
            MPVPlayerConfiguration(colorManagement: .init(referenceWhite: 250)),
            MPVPlayerConfiguration(colorManagement: .init(sdrViewing: .legacyDisplay)),
            MPVPlayerConfiguration(renderingQuality: .init(preset: .battery)),
            MPVPlayerConfiguration(renderingQuality: .init(preset: .balanced)),
            MPVPlayerConfiguration(renderingQuality: .init(preset: .highQuality)),
            MPVPlayerConfiguration(renderingQuality: .init(scaling: .lanczos)),
            MPVPlayerConfiguration(renderingQuality: .init(shaders: [shader])),
            MPVPlayerConfiguration(deinterlace: .init(mode: .automatic)),
            MPVPlayerConfiguration(deinterlace: .init(algorithm: .bwdif, mode: .forced)),
            MPVPlayerConfiguration(sdrOutput: .compatibility8Bit),
            MPVPlayerConfiguration(sdrOutput: .highPrecision),
        ]
        for configuration in configurations {
            #expect(configuration.videoOutput == .sampleBuffer)
        }
    }

    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases, MPVPlayerConfiguration.HDRPolicy.allCases)
    func `only the output option chooses the renderer`(
        output: MPVPlayerConfiguration.VideoOutput, hdrPolicy: MPVPlayerConfiguration.HDRPolicy
    ) {
        let configuration = MPVPlayerConfiguration(
            additionalOptions: ["vf": "hflip", "vo": "invalid", "unknown-rendering-option": "yes"],
            colorManagement: .init(referenceWhite: 250),
            deinterlace: .init(mode: .forced), hdrPolicy: hdrPolicy,
            renderingQuality: .init(preset: .highQuality), sdrOutput: .highPrecision,
            videoOutput: output
        )
        #expect(configuration.videoOutput == output)
        #expect(MPVPlayerConfiguration(hdrPolicy: hdrPolicy).videoOutput == .sampleBuffer)
    }
}
