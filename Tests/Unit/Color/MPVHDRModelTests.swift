@testable import MPVUI
import Testing

@Suite(.tags(.unit, .hdr))
struct MPVHDRModelTests {
    @Test(arguments: [(1, 0, 0, 0), (64, 10, 15, 15)])
    func `signal metadata preserves valid boundary values`(depth: Int, profile: Int, level: Int, compatibility: Int) {
        let signal = MPVVideoSignal(
            bitDepth: depth, minimumLuminance: 0, maximumLuminance: 1000,
            masteringDisplayPrimaries: ["prim-red-x": 0, "prim-white-y": 1],
            hdr10PlusMetadata: ["scene-avg": 0],
            dolbyVisionProfile: profile, dolbyVisionLevel: level,
            dolbyVisionBaseLayerCompatibilityID: compatibility
        )
        #expect(signal.bitDepth == depth)
        #expect(signal.minimumLuminance == 0 && signal.maximumLuminance == 1000)
        #expect(signal.masteringDisplayPrimaries == ["prim-red-x": 0, "prim-white-y": 1])
        #expect(signal.hdr10PlusMetadata == ["scene-avg": 0])
        #expect(signal.dolbyVisionProfile == profile)
        #expect(signal.dolbyVisionLevel == level)
        #expect(signal.dolbyVisionBaseLayerCompatibilityID == compatibility)
        #expect(!signal.isHDR, "Dolby Vision fields alone do not substitute for transfer metadata.")
    }

    @Test(arguments: [(0, -1, -1, -1), (65, 11, 16, 16)])
    func `invalid signal fields remain unknown without discarding valid metadata`(
        depth: Int,
        profile: Int,
        level: Int,
        compatibility: Int
    ) {
        let signal = MPVVideoSignal(
            transferFunction: .pq, bitDepth: depth,
            minimumLuminance: .nan, maximumLuminance: .infinity,
            maxContentLightLevel: -1, maxFrameAverageLightLevel: 400,
            masteringDisplayPrimaries: ["prim-red-x": .nan, "prim-red-y": -0.1, "prim-white-y": 0.33],
            hdr10PlusMetadata: ["scene-max-r": .infinity, "scene-max-g": -1, "scene-avg": 100],
            dolbyVisionProfile: profile, dolbyVisionLevel: level,
            dolbyVisionBaseLayerCompatibilityID: compatibility
        )
        #expect(signal.bitDepth == nil)
        #expect(signal.minimumLuminance == nil && signal.maximumLuminance == nil)
        #expect(signal.maxContentLightLevel == nil && signal.maxFrameAverageLightLevel == 400)
        #expect(signal.masteringDisplayPrimaries == ["prim-white-y": 0.33])
        #expect(signal.hdr10PlusMetadata == ["scene-avg": 100])
        #expect(signal.dolbyVisionProfile == nil && signal.dolbyVisionLevel == nil)
        #expect(signal.dolbyVisionBaseLayerCompatibilityID == nil)
        #expect(signal.isHDR)
    }

    @Test
    func `HDR pipeline configuration does not claim actual presentation`() {
        for backend in MPVPlayerConfiguration.VideoOutput.allCases {
            let status = MPVHDRStatus(
                source: MPVVideoSignal(transferFunction: .pq),
                displayCapabilities: MPVDisplayCapabilities(
                    hdrSupport: .supported,
                    currentEDRHeadroom: 4
                ),
                presentation: MPVPresentationStatus(
                    requestedPolicy: .hdrWhenAvailable,
                    backend: backend,
                    configuredDynamicRange: .hdr
                )
            )
            #expect(status.isHDRContent)
            #expect(status.isDisplayHDRCapable)
            #expect(!status.isHDRActive)
            #expect(status.presentation.actualDynamicRange == .unknown)
        }
    }

    @Test
    func `display headroom is finite and stable at hundredth precision`() {
        let capability = MPVDisplayCapabilities(
            hdrSupport: .supported,
            currentEDRHeadroom: 2.0001,
            potentialEDRHeadroom: .infinity
        )
        #expect(capability.currentEDRHeadroom == 2)
        #expect(capability.potentialEDRHeadroom == nil)
        #expect(MPVDisplayCapabilities(currentEDRHeadroom: 0.5).currentEDRHeadroom == nil)
        #expect(MPVDisplayCapabilities(currentEDRHeadroom: .greatestFiniteMagnitude).currentEDRHeadroom == nil)
    }

    @Test
    func `native subtitle luminance is normalized and desired policies keep compatibility`() {
        #expect(MPVPlayerConfiguration(subtitleLuminance: .nan).subtitleLuminance == 203)
        #expect(MPVPlayerConfiguration(subtitleLuminance: 1500).subtitleLuminance == 1000)
        #expect(MPVPlayerConfiguration(subtitleLuminance: -1).subtitleLuminance == 1)
        #expect(MPVPlayerConfiguration.HDRPolicy.sdr == .disabled)
        #expect(MPVPlayerConfiguration.HDRPolicy.hdrWhenAvailable == .always)
    }

    @Test
    func `hdr detection uses transfer function rather than primaries`() {
        let wideGamutSDR = MPVHDRStatus(
            primaries: "bt.2020",
            transferFunction: .bt709
        )
        #expect(!wideGamutSDR.isHDRContent)

        #expect(MPVHDRStatus(transferFunction: .pq).isHDRContent)
        #expect(MPVHDRStatus(transferFunction: .hlg).isHDRContent)
        #expect(MPVTransferFunction(mpvValue: "smpte-st-2084") == .pq)
        #expect(MPVTransferFunction(mpvValue: "arib-std-b67") == .hlg)
    }
}
