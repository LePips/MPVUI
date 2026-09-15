import CoreMedia
import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVPlaybackDiagnosticsParsingTests {
    @Test
    func `codec probe does not override actual software session`() {
        let result = MPVPlaybackDiagnosticsParser.decoder(
            codec: "hevc", hardwareDecoder: "no", interop: nil,
            pixelFormat: "yuv420p10", requested: .automatic, probe: { _ in true }
        )
        #expect(result.videoToolboxSupportsCodec == true)
        #expect(result.session == .software)
        #expect(result.fallbackReason != nil)
        let unknown = MPVPlaybackDiagnosticsParser.decoder(
            codec: "not-a-codec", hardwareDecoder: nil, interop: nil,
            pixelFormat: nil, requested: .automatic, probe: { _ in false }
        )
        #expect(unknown.videoToolboxSupportsCodec == nil)
        #expect(unknown.session == .unknown)
        let selectedOnly = MPVPlaybackDiagnosticsParser.decoder(
            codec: "hevc", hardwareDecoder: "videotoolbox", interop: "videotoolbox",
            pixelFormat: "videotoolbox", requested: .automatic, probe: { _ in true }
        )
        #expect(selectedOnly.selectedDecoder == "videotoolbox")
        #expect(selectedOnly.session == .unknown)
        let observedSession = MPVPlaybackDiagnosticsParser.decoder(
            codec: "hevc", hardwareDecoder: "videotoolbox", interop: "videotoolbox",
            pixelFormat: "videotoolbox", requested: .automatic,
            sessionUsesHardware: true, probe: { _ in true }
        )
        #expect(observedSession.session == .hardware("videotoolbox"))
    }

    @Test
    func `native statistics and session logs keep unknowns explicit`() {
        let native = MPVPlaybackDiagnosticsParser.nativeStatistics(.map([
            "pixel-buffer-copies": .integer(8), "sample-build-count": .integer(3),
            "last-sample-build-ns": .integer(4000), "total-sample-build-ns": .integer(19000),
        ]))
        #expect(native?.pixelBufferCopies == 8)
        #expect(native?.sampleBuildCount == 3)
        let valid = MPVLogMessage(
            prefix: "ffmpeg/video",
            level: .info,
            message: "MPVUI_VIDEOTOOLBOX_SESSION: hardware=yes native-dovi=no\n"
        )
        #expect(MPVPlaybackDiagnosticsParser.videoToolboxSession(valid) == .hardware)
        let unsupported = MPVLogMessage(
            prefix: "ffmpeg/video",
            level: .info,
            message: "MPVUI_VIDEOTOOLBOX_SESSION: hardware=unknown native-dovi=no\n"
        )
        #expect(MPVPlaybackDiagnosticsParser.videoToolboxSession(unsupported) == .unknown)
    }

    @Test
    func `absent and invalid timing is unknown`() {
        #expect(MPVPlaybackDiagnosticsParser.renderPasses(nil) == nil)
        let passes = MPVPlaybackDiagnosticsParser.renderPasses(.array([
            .map(["desc": .string("scale"), "last": .integer(300), "avg": .integer(-1), "peak": .double(.infinity)])
        ]))
        #expect(passes?.first?.lastNanoseconds == 300)
        #expect(passes?.first?.averageNanoseconds == nil)
        #expect(passes?.first?.peakNanoseconds == nil)
        #expect(MPVPlaybackDiagnosticsParser.finite(.nan) == nil)
        #expect(MPVPlaybackDiagnostics().frameCopyCount == nil)
    }
}
