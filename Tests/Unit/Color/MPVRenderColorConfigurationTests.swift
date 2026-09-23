import CoreGraphics
import Foundation
import Metal
@testable import MPVUI
import Testing

@Suite(.tags(.unit, .hdr))
struct MPVRenderColorConfigurationTests {
    private func resolve(
        _ configuration: MPVPlayerConfiguration = .init(),
        wide: Bool = true,
        hdr: Bool = false,
        native: Bool = false,
        mac: Bool = true,
        display: CGColorSpace? = CGColorSpace(name: CGColorSpace.displayP3)
    ) -> MPVRenderColorConfiguration {
        .resolve(
            configuration: configuration,
            native: native,
            usesExtendedDynamicRange: hdr,
            outputHeadroom: 2,
            supportsWideGamut: wide,
            systemDisplayProfile: display,
            displayProfileName: "Test display",
            calibratedProfile: MPVCalibratedDisplayProfile(policy: configuration.colorManagement.displayProfile),
            supportsCalibratedICC: mac
        )
    }

    @Test
    func `p 3 SDR does not require HDR`() {
        let color = resolve(.init(hdrPolicy: .disabled))
        #expect(color.status.targetPrimaries == "display-p3")
        #expect(color.status.targetTransfer == "linear")
        #expect(color.pixelFormat == .rgba16Float)
        #expect(!color.usesExtendedDynamicRange)
        #expect(color.outputHeadroom == 1)
        #expect(color.layerColorSpace.name == CGColorSpace.extendedLinearDisplayP3)
        let options = Dictionary(uniqueKeysWithValues: color.options)
        #expect(options["icc-profile-auto"] == "no")
        #expect(options["icc-profile"] == "")
        #expect(options["treat-srgb-as-power22"] == "no")
    }

    @Test
    func `compatibility and precision are explicit`() {
        let compatibility = resolve(.init(sdrOutput: .compatibility8Bit))
        #expect(compatibility.pixelFormat == .bgra8Unorm)
        #expect(compatibility.status.targetPrimaries == "bt.709")
        #expect(Dictionary(uniqueKeysWithValues: compatibility.options)["dither-depth"] == "8")
        let preciseNarrow = resolve(.init(sdrOutput: .highPrecision), wide: false)
        #expect(preciseNarrow.pixelFormat == .rgba16Float)
        #expect(preciseNarrow.layerColorSpace.name == CGColorSpace.extendedLinearSRGB)
        #expect(resolve(wide: false).pixelFormat == .bgra8Unorm)
    }

    @Test
    func `reference viewing is explicit and normalized`() {
        let legacy = resolve(.init(
            colorManagement: .init(sdrViewing: .legacyDisplay),
            sdrOutput: .compatibility8Bit
        ))
        #expect(Dictionary(uniqueKeysWithValues: legacy.options)["sdr-adjust-gamma"] == "no")
        let reference = resolve(.init(colorManagement: .init(referenceWhite: 100)), hdr: true)
        #expect(Dictionary(uniqueKeysWithValues: reference.options)["target-peak"] == "200")
        #expect(MPVColorManagement(referenceWhite: .nan).referenceWhite == 203)
        #expect(MPVColorManagement(referenceWhite: 0).referenceWhite == 10)
        #expect(MPVColorManagement(referenceWhite: 1500).referenceWhite == 1000)
        #expect(MPVColorManagement(referenceWhite: 100.6).referenceWhite == 101)
    }

    @Test
    func `unavailable calibration does not pretend to apply`() {
        let config = MPVPlayerConfiguration(colorManagement: .init(
            displayProfile: .calibratedICC(URL(fileURLWithPath: "/missing/profile.icc"))
        ))
        #expect(resolve(config).status.fallbackReason == .invalidRGBDisplayProfile)
        #expect(resolve(config, hdr: true).status.fallbackReason == .calibratedICCRequiresSDRMetal)
        #expect(resolve(config, mac: false).status.fallbackReason == .calibratedICCRequiresMacOS)
        #expect(resolve(config).status.conversionOwner == .colorSync)
        #expect(resolve(.init(sdrOutput: .highPrecision), native: true).status.fallbackReason == .nativeManagesPrecision)
    }

    @Test
    func `calibrated ICC uses one device conversion`() throws {
        let profile = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let data = try #require(profile.copyICCData()) as Data
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("icc")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let config = MPVPlayerConfiguration(colorManagement: .init(displayProfile: .calibratedICC(url)))
        let result = resolve(config)
        #expect(result.status.conversionOwner == .libplaceboCalibratedICC)
        #expect(result.status.calibratedProfileURL == url)
        #expect(CFEqual(result.layerColorSpace, profile))
        let options = Dictionary(uniqueKeysWithValues: result.options)
        #expect(options["icc-profile"] == url.path)
        #expect(options["icc-profile-auto"] == "no")
        #expect(options["target-colorspace-hint"] == "no")
        #expect(resolve(config, display: nil).status.fallbackReason == .currentDisplayProfileUnavailable)
    }

    @MainActor @Test
    func `native swapchain cannot replace host profile`() throws {
        let layer = MPVMetalLayer()
        let profile = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        layer.configureHostColorSpace(profile, pixelFormat: .rgba16Float)
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.pixelFormat = .bgra8Unorm
        #expect(layer.pixelFormat == .rgba16Float)
        #expect(CFEqual(layer.colorspace, profile))
        try layer.configureHostColorSpace(#require(CGColorSpace(name: CGColorSpace.sRGB)), pixelFormat: .bgra8Unorm)
        #expect(layer.pixelFormat == .bgra8Unorm)
    }

    @Test
    func `calibrated LUT has declared input and exclusive output conversion`() throws {
        let cube = """
        TITLE "Identity validation"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cube")
        try cube.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let config = MPVPlayerConfiguration(colorManagement: .init(displayProfile: .calibratedLUT(url)))
        let color = resolve(config)
        #expect(color.status.conversionOwner == .libplaceboCalibratedLUT)
        let options = Dictionary(uniqueKeysWithValues: color.options)
        #expect(options["target-lut"] == url.path)
        #expect(options["target-trc"] == "gamma2.4")
        #expect(options["icc-profile"] == "")
        let invalidCubes = [
            "LUT_3D_SIZE 2\n0 0 0", // Truncated table.
            cube.replacingOccurrences(of: "DOMAIN_MIN 0.0 0.0 0.0", with: "DOMAIN_MIN invalid"),
            cube.replacingOccurrences(of: "DOMAIN_MAX 1.0 1.0 1.0", with: "DOMAIN_MAX 2 2 2"),
            cube.replacingOccurrences(of: "DOMAIN_MIN 0.0 0.0 0.0", with: "DOMAIN_MIN  0 0 0"),
            cube.replacingOccurrences(of: "DOMAIN_MIN 0.0 0.0 0.0", with: "DOMAIN_MIN 0 0 0\nDOMAIN_MIN 0 0 0"),
            cube.replacingOccurrences(of: "0 0 0\n1 0 0", with: "0 0 0\n# Body comment\n1 0 0"),
            cube.replacingOccurrences(of: "1 0 0", with: "1E0 0 0"),
            cube.replacingOccurrences(of: "1 0 0", with: "1e100 0 0"),
            cube.replacingOccurrences(of: "\n0 0 0", with: "\n 0 0 0"),
            cube.replacingOccurrences(of: "0 0 0\n1 0 0", with: "0 0 0\nTITLE \"Late header\"\n1 0 0"),
        ]
        for invalid in invalidCubes {
            try invalid.write(to: url, atomically: true, encoding: .utf8)
            #expect(resolve(config).status.fallbackReason == .invalidCalibrationLUT)
        }
    }
}
