import CoreMedia
import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVRenderingOptionsTests {

    @Test(arguments: [MPVVideoOutput.gpu, .metal])
    func `low power GPU defaults avoid dithering while explicit overrides remain honored`(backend: MPVVideoOutput) {
        let battery = MPVRenderingOptions.resolve(.init(), backend: backend, lowPowerMode: true)
        #expect(battery.preset == .battery)
        #expect(battery.options["dither"] == "no")

        for dithering in [MPVRenderingQuality.Dithering.ordered, .fruit, .errorDiffusion] {
            let requested = MPVRenderingOptions.resolve(.init(dithering: dithering), backend: backend, lowPowerMode: true)
            #expect(requested.options["dither"] == dithering.rawValue)
        }

        let explicit = MPVRenderingOptions.resolve(.init(preset: .battery), backend: backend, lowPowerMode: false)
        #expect(explicit.options["dither"] == "no")
        let balanced = MPVRenderingOptions.resolve(.init(), backend: backend, lowPowerMode: false)
        #expect(balanced.options["dither"] == "fruit")
    }

    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases)
    func `automatic decoder prefers Apple interop only for Metal`(output: MPVPlayerConfiguration.VideoOutput) {
        #expect(MPVRenderingOptions.hardwareDecodingOptions(.automatic, backend: output.coreValue)["hwdec"]
            == (output == .metal ? "videotoolbox,auto-safe" : "auto-safe"))

        #expect(MPVRenderingOptions.hardwareDecodingOptions(.videoToolbox, backend: output.coreValue)["hwdec"] == "videotoolbox")
        #expect(MPVRenderingOptions.hardwareDecodingOptions(.disabled, backend: output.coreValue) == ["hwdec": "no"])
    }

    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases)
    func `Metal bounds hardware decoder threads without changing software or native output`(output: MPVPlayerConfiguration.VideoOutput) {
        for decoding in [MPVPlayerConfiguration.HardwareDecoding.automatic, .videoToolbox] {
            #expect(MPVRenderingOptions.hardwareDecodingOptions(decoding.coreValue, backend: output.coreValue)["hwdec-threads"]
                == (output == .metal ? "2" : nil))
        }

        #expect(!MPVOptionOwnership.isManaged("hwdec-threads", deinterlace: .init()))
    }

    @Test(arguments: MPVRenderingQuality.Preset.allCases)
    func `Metal presets retain presentation pipelining`(preset: MPVRenderingQuality.Preset) {
        let result = MPVRenderingOptions.resolve(.init(preset: preset), backend: .metal, lowPowerMode: false)

        #expect(result.options["swapchain-depth"] == "2")
        #expect(!MPVOptionOwnership.isManaged("swapchain-depth", deinterlace: .init()))
    }

    @Test
    func `automatic uses power state and explicit overrides`() {
        let requested = MPVRenderingQuality(antiringing: 9, preset: .automatic, scaling: .lanczos)
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
        let policy = MPVDeinterlacePolicy(algorithm: .yadif, analyzesFieldOrder: true, fieldOrder: .bottomFirst, mode: .forced)
        let result = MPVRenderingOptions.deinterlaceOptions(policy)

        #expect(result["deinterlace"] == "no")
        #expect(result["vf"] == "lavfi=[idet,yadif=mode=send_field:parity=bff:deint=all]")
    }

    @Test(arguments: [MPVDeinterlacePolicy.Algorithm.automatic, .bwdif, .yadif])
    func `frame cadence limits software output while field cadence stays default`(algorithm: MPVDeinterlacePolicy.Algorithm) {
        let policy = MPVDeinterlacePolicy(algorithm: algorithm, mode: .automatic, outputCadence: .frame)
        let filter = algorithm == .yadif ? "yadif" : "bwdif"
        let options = MPVRenderingOptions.deinterlaceOptions(policy)
        #expect(options["vf"] == "lavfi=[\(filter)=mode=send_frame:parity=auto:deint=interlaced]")
        #expect(options["deinterlace"] == "no")
        #expect(MPVDeinterlacePolicy().outputCadence == .field)
        let status = MPVRenderingOptions.deinterlaceStatus(policy: policy, interlaced: true, hardwareDecoder: "videotoolbox")
        #expect(status.requiresSoftwareFrames == true)
        #expect(status.effectiveFilter == filter)
    }
}
