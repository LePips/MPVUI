import Libmpv
@testable import MPVUI
import Testing

@Suite(.tags(.unit, .hdr))
struct MPVHDRSignalParsingTests {
    @Test
    func `unsupported HDR policy is not hidden by a legacy subtitle option`() {
        #expect(MPVEngine.resolvedPresentationFallback(
            backend: .unsupportedSubtitleLuminance,
            policy: .unsupportedPolicy,
            liveFailure: nil
        ) == .unsupportedPolicy)
        #expect(MPVEngine.resolvedPresentationFallback(
            backend: .nativeOutputUnavailable("unsupported matrix"),
            policy: .displayDoesNotSupportHDR,
            liveFailure: nil
        ) == .nativeOutputUnavailable("unsupported matrix"))
        #expect(MPVEngine.resolvedPresentationFallback(
            backend: nil, policy: .insufficientCurrentHeadroom,
            liveFailure: "target-trc"
        ) == .liveConfigurationFailed("target-trc"))
    }

    @Test
    func `native color and Dolby rejections use the renderer fallback contract`() {
        for prefix in ["MPVUI_NATIVE_DOLBY_VISION_UNSUPPORTED:", "MPVUI_NATIVE_VIDEO_UNSUPPORTED:"] {
            #expect(MPVEngine.nativeOutputRejectionReason(MPVLogMessage(
                prefix: "vo/avfoundation", level: .error,
                message: "\(prefix) unsupported transfer\n"
            )) == "unsupported transfer")
        }
        #expect(MPVEngine.nativeOutputRejectionReason(MPVLogMessage(
            prefix: "demux", level: .error,
            message: "MPVUI_NATIVE_VIDEO_UNSUPPORTED: unrelated\n"
        )) == nil)
        #expect(MPVEngine.nativeOutputRejectionReason(MPVLogMessage(
            prefix: "ffmpeg/video", level: .error,
            message: "hevc: MPVUI_NATIVE_DOLBY_VISION_UNSUPPORTED: declared profile=7 cannot use the requested native Dolby Vision policy\n"
        )) == "declared profile=7 cannot use the requested native Dolby Vision policy")
        for channel in ["demux", "ffmpeg/demuxer", "vd"] {
            #expect(MPVEngine.nativeOutputRejectionReason(MPVLogMessage(
                prefix: channel, level: .error,
                message: "MPVUI_NATIVE_DOLBY_VISION_UNSUPPORTED: unrelated source\n"
            )) == nil)
        }
        #expect(MPVEngine.nativeOutputRejectionReason(MPVLogMessage(
            prefix: "ffmpeg/video", level: .error,
            message: "hevc: Error opening a filename containing MPVUI_NATIVE_DOLBY_VISION_UNSUPPORTED: quoted text\n"
        )) == nil)
    }

    @Test
    func `decoder diagnostics from a superseded playlist entry are ignored`() {
        #expect(!MPVEngine.nativeDiagnosticMatchesCurrentEntry(requested: 102, active: 101))
        #expect(!MPVEngine.nativeDiagnosticMatchesCurrentEntry(requested: 102, active: nil))
        #expect(MPVEngine.nativeDiagnosticMatchesCurrentEntry(requested: 102, active: 102))
        // A rejected native file can end before its diagnostic is drained.
        #expect(MPVEngine.nativeDiagnosticMatchesCurrentEntry(requested: nil, active: nil))
    }

    @Test
    func `hdr target peak preserves extended linear headroom`() {
        #expect(MPVEngine.targetPeakNits(forOutputHeadroom: 4) == 812)
        #expect(MPVEngine.targetPeakNits(forOutputHeadroom: .nan) == 203)
        #expect(MPVEngine.targetPeakNits(forOutputHeadroom: .infinity) == 203)
    }

    @Test
    func `signal parsing preserves color and mastering metadata without conflating packing and depth`() {
        let signal = MPVVideoSignalParser.parse(.map([
            "pixelformat": .string("videotoolbox"),
            "hw-pixelformat": .string("p010"),
            "average-bpp": .integer(15),
            "primaries": .string("bt.2020"),
            "gamma": .string("pq"),
            "colormatrix": .string("bt.2020-ncl"),
            "colorlevels": .string("limited"),
            "chroma-location": .string("left"),
            "max-luma": .string("1000"),
            "max-cll": .integer(800),
            "prim-red-x": .double(0.68),
            "scene-max-r": .double(500),
        ]), track: .map(["dolby-vision-profile": .integer(8)]))
        #expect(signal.bitDepth == 10)
        #expect(signal.chromaSubsampling == "4:2:0")
        #expect(signal.transferFunction == .pq)
        #expect(signal.matrix == "bt.2020-ncl")
        #expect(signal.range == "limited")
        #expect(signal.chromaLocation == "left")
        #expect(signal.maximumLuminance == 1000)
        #expect(signal.maxContentLightLevel == 800)
        #expect(signal.masteringDisplayPrimaries["prim-red-x"] == 0.68)
        #expect(signal.hasHDR10PlusMetadata == true)
        #expect(signal.dolbyVisionProfile == 8)
    }

    @Test
    func `unknown and malformed signal metadata stays unknown`() {
        let signal = MPVVideoSignalParser.parse(.map([
            "pixelformat": .string("videotoolbox"),
            "average-bpp": .integer(15),
            "gamma": .string("unknown"),
            "min-luma": .double(.nan),
            "max-luma": .double(-1),
            "max-cll": .string("inf"),
            "bit-depth": .double(10.5),
            "dolby-vision-profile": .integer(1000),
            "scene-max-r": .double(-4),
            "prim-white-y": .double(2),
        ]))
        #expect(signal.transferFunction == .unknown)
        #expect(signal.bitDepth == nil)
        #expect(signal.chromaSubsampling == nil)
        #expect(signal.minimumLuminance == nil)
        #expect(signal.maximumLuminance == nil)
        #expect(signal.maxContentLightLevel == nil)
        #expect(signal.dolbyVisionProfile == nil)
        #expect(signal.hasHDR10PlusMetadata == nil)
        #expect(signal.masteringDisplayPrimaries.isEmpty)
        #expect(MPVVideoSignalParser.parse(nil) == .unknown)
    }

    @Test
    func `HDR source metadata never leaks into SDR renderer output`() {
        let source = MPVVideoSignalParser.parse(.map([
            "gamma": .string("pq"), "max-luma": .double(1000),
        ]))
        let output = MPVVideoSignalParser.parse(.map([
            "gamma": .string("srgb"), "primaries": .string("bt.709"),
        ]))
        let hdr = MPVHDRStatus(source: source, output: output)
        #expect(hdr.isHDRContent)
        #expect(hdr.output.transferFunction == .sRGB)
        #expect(hdr.output.maximumLuminance == nil)
        #expect(hdr.decoded == .unknown)
        #expect(!hdr.isHDRActive)
        #expect(hdr.presentation.actualDynamicRange == .unknown)
    }

    @Test
    func `headroom fallback uses current budget rather than potential capability`() {
        let reason = MPVEngine.hdrFallbackReason(
            source: MPVVideoSignal(transferFunction: .pq),
            display: MPVDisplayCapabilities(
                hdrSupport: .supported,
                currentEDRHeadroom: 1,
                potentialEDRHeadroom: 5
            ),
            configuredDynamicRange: .hdr,
            requestedPolicy: .automatic
        )
        #expect(reason == .insufficientCurrentHeadroom)
    }
}
