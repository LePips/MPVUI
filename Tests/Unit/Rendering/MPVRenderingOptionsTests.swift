import CoreMedia
import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVRenderingOptionsTests {
    @Test
    func `automatic uses power state and explicit overrides`() {
        let requested = MPVRenderingQuality(preset: .automatic, scaling: .lanczos, antiringing: 9)
        let battery = MPVRenderingOptions.resolve(requested, backend: .metal, lowPowerMode: true)
        #expect(battery.preset == .battery)
        #expect(battery.options["scale"] == "lanczos")
        #expect(battery.options["scale-antiring"] == "1.0")
        #expect(battery.options["hdr-compute-peak"] == "no")
        let balanced = MPVRenderingOptions.resolve(.init(), backend: .metal, lowPowerMode: false)
        #expect(balanced.preset == .balanced)
        #expect(balanced.options["hdr-compute-peak"] == "auto")
    }

    @Test
    func `native does not claim GPU settings`() {
        let result = MPVRenderingOptions.resolve(.init(preset: .highQuality), backend: .sampleBuffer, lowPowerMode: false)
        #expect(result.options.isEmpty)
        #expect(!result.unsupportedFeatures.isEmpty)
    }

    @Test
    func `invalid files do not enter renderer`() throws {
        let quality = try MPVRenderingQuality(shaders: [#require(URL(string: "https://example.com/shader.glsl"))])
        let result = MPVRenderingOptions.resolve(quality, backend: .metal, lowPowerMode: false)
        #expect(result.options["glsl-shaders"] == nil)
        #expect(result.unsupportedFeatures.count == 1)
    }

    @Test
    func `deinterlacing does not download progressive automatic frames`() {
        let policy = MPVDeinterlacePolicy(mode: .automatic)
        #expect(MPVRenderingOptions.deinterlaceOptions(policy)["deinterlace"] == "auto")
        let progressive = MPVRenderingOptions.deinterlaceStatus(
            policy: policy,
            interlaced: false,
            hardwareDecoder: "videotoolbox",
            automaticFilterIsActive: false
        )
        #expect(progressive.requiresSoftwareFrames == false)
        let interlaced = MPVRenderingOptions.deinterlaceStatus(
            policy: policy,
            interlaced: false,
            hardwareDecoder: "videotoolbox",
            automaticFilterIsActive: true
        )
        #expect(interlaced.requiresSoftwareFrames == true)
        #expect(interlaced.reason?.contains("downloaded") == true)
        let unknown = MPVRenderingOptions.deinterlaceStatus(policy: policy, interlaced: nil, hardwareDecoder: "videotoolbox")
        #expect(unknown.requiresSoftwareFrames == nil)
    }

    @Test
    func `explicit field order and detection use double rate software graph`() {
        let policy = MPVDeinterlacePolicy(mode: .forced, algorithm: .yadif, fieldOrder: .bottomFirst, analyzeFieldOrder: true)
        let result = MPVRenderingOptions.deinterlaceOptions(policy)
        #expect(result["deinterlace"] == "no")
        #expect(result["vf"] == "lavfi=[idet,yadif=mode=send_field:parity=bff:deint=all]")
    }
}
