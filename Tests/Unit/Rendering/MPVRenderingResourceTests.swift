import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVRenderingResourceTests {
    @Test(arguments: [MPVRenderingQuality.LUT.Domain.native, .normalized])
    func `readable local LUT and ordered shaders survive option resolution`(domain: MPVRenderingQuality.LUT.Domain) throws {
        let files = try TemporaryTestDirectory()
        defer { files.remove() }
        let first = try files.write("first shader.glsl", contents: "//!HOOK MAIN\n")
        let second = try files.write("second.glsl", contents: "//!HOOK OUTPUT\n")
        let lut = try files.write("grade.cube", contents: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        let result = MPVRenderingOptions.resolve(
            .init(shaders: [first, second], lut: .init(url: lut, domain: domain)),
            backend: .metal, lowPowerMode: false
        )
        #expect(result.shaderPaths == [first.path, second.path])
        #expect(result.options["lut"] == lut.path)
        #expect(result.options["lut-type"] == domain.rawValue)
        #expect(result.unsupportedFeatures.isEmpty)
    }

    @Test
    func `unreadable LUT and shader are diagnosed while valid shaders remain ordered`() throws {
        let files = try TemporaryTestDirectory()
        defer { files.remove() }
        let valid = try files.write("valid.glsl", contents: "//!HOOK MAIN\n")
        let missing = files.url.appendingPathComponent("missing.glsl")
        let remote = try #require(URL(string: "https://example.invalid/grade.cube"))
        let result = MPVRenderingOptions.resolve(
            .init(shaders: [missing, valid], lut: .init(url: remote)),
            backend: .metal, lowPowerMode: false
        )
        #expect(result.shaderPaths == [valid.path])
        #expect(result.options["lut"] == nil)
        #expect(result.options["lut-type"] == nil)
        #expect(result.unsupportedFeatures == ["Unreadable local shader: missing.glsl", "Unreadable local LUT: grade.cube"])
    }

    @Test(arguments: [MPVRenderingQuality.Dithering.disabled, .ordered, .fruit, .errorDiffusion])
    func `explicit dithering overrides the preset`(dithering: MPVRenderingQuality.Dithering) {
        let result = MPVRenderingOptions.resolve(.init(dithering: dithering), backend: .metal, lowPowerMode: false)
        #expect(result.options["dither"] == (dithering == .disabled ? "no" : dithering.rawValue))
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func `nonfinite antiringing uses preset defaults`(value: Double) {
        let result = MPVRenderingOptions.resolve(
            .init(preset: .highQuality, antiringing: value, chromaAntiringing: value),
            backend: .metal, lowPowerMode: true
        )
        #expect(result.preset == .highQuality)
        #expect(result.options["scale-antiring"] == "0.7")
        #expect(result.options["cscale-antiring"] == "0.7")
    }
}
