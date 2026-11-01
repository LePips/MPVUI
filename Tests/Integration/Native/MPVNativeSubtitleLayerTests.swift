import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing
import VideoToolbox

private let subtitleLayerReadbackUnavailable: Bool = {
    #if targetEnvironment(simulator)
    true
    #else
    false
    #endif
}()

@Suite(.tags(.integration, .nativePatch), .serialized)
@MainActor
struct MPVNativeSubtitleLayerTests {

    private enum ReadbackError: Error {

        case unavailable
    }

    @Test(.disabled(if: subtitleLayerReadbackUnavailable, "Displayed subtitle pixels require macOS or a physical Apple device."))
    func `inline subtitles preserve video pixels and switch to composited PiP frames`() async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: [
                "ao": "null",
                "vf": "format=fmt=nv12",
                "sid": "1",
                "sub-visibility": "no",
                "osd-level": "0",
                "avfoundation-osd-max-height": "90",
            ],
            automaticallyPlays: false,
            hardwareDecoding: .disabled,
            videoOutput: .sampleBuffer
        ))
        defer { fixture.close() }
        let player = fixture.player
        try await fixture.loadPaused(TestPaths.testMedia("subtitles.mkv"))
        let video = player.sampleBufferDisplayLayer
        let overlay = player.sampleBufferOSDLayer
        try await eventually("separate native subtitle layers ready") {
            video.sampleBufferRenderer.displayedPixelBuffer() != nil && overlay.sampleBufferRenderer.displayedPixelBuffer() != nil
        }
        let original = try luma(video)
        #expect(try alpha(overlay).visible == 0)
        #expect(overlay.superlayer === video.superlayer)
        #expect(overlay.bounds == video.bounds)
        #expect(overlay.videoGravity == video.videoGravity)
        #expect(!overlay.isOpaque)
        let videoClock = try #require(video.controlTimebase)
        let subtitleClock = try #require(overlay.controlTimebase)
        #expect(CFEqual(videoClock, subtitleClock))

        player.setProperty("sub-visibility", to: "yes")
        try await eventually("visible pixels in separate subtitle layer") { ((try? alpha(overlay).visible) ?? 0) > 0 }
        let subtitle = try alpha(overlay)
        #expect(subtitle.height == 90)
        #expect(subtitle.visible < subtitle.width * subtitle.height)
        #expect(try luma(video) == original)

        // Acknowledgment requires a frame from the new route, including when
        // playback is paused. AVKit only consumes the video layer's samples.
        try #require(await player.setNativePictureInPictureComposition(true))
        try await eventually("PiP source contains subtitle pixels") { (try? luma(video)).map { $0 != original } ?? false }
        // Removal is asynchronous even after the new video sample is enqueued.
        try await eventually("composited mode retires separate subtitle pixels") { subtitleIsClear(overlay) }

        try #require(await player.setNativePictureInPictureComposition(false))
        try await eventually("inline source restored without baked pixels") {
            (try? luma(video)) == original && ((try? alpha(overlay).visible) ?? 0) > 0
        }

        // Full video resolution and host display resolution are both live
        // choices. The fixed height cap remains independent of either policy.
        player.setProperty("avfoundation-osd-video-res", to: "yes")
        player.setProperty("avfoundation-osd-max-height", to: "0")
        let sourceHeight = try #require(player.mediaInformation.dimensions?.height)
        try await eventually("video resolution subtitle raster") { (try? alpha(overlay).height) == sourceHeight }
        player.setProperty("avfoundation-osd-max-height", to: "90")
        try await eventually("capped subtitle raster restored") { (try? alpha(overlay).height) == 90 }

        player.setProperty("sub-visibility", to: "no")
        try await eventually("timed clear removes subtitle alpha") { (try? alpha(overlay).visible) == 0 }
        #expect(try luma(video) == original)
        #expect(player.isPaused)
        #expect(player.lastError == nil)
    }

    @Test(.disabled(if: subtitleLayerReadbackUnavailable, "Displayed subtitle pixels require macOS or a physical Apple device."))
    func `seeking and replacing media cannot retain a previous subtitle`() async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null", "sid": "no", "sub-auto": "no", "osd-level": "0"],
            automaticallyPlays: false,
            hardwareDecoding: .disabled,
            videoOutput: .sampleBuffer
        ))
        defer { fixture.close() }
        let subtitle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ass")
        try """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 320
        PlayResY: 180
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Helvetica,24,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,Timed subtitle
        """.write(to: subtitle, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: subtitle) }
        try await fixture.loadPaused(TestPaths.testMedia("subtitles.mkv"))
        let player = fixture.player
        let overlay = player.sampleBufferOSDLayer
        player.loadExternalTrack(subtitle, type: .subtitle, select: true)
        try await eventually("first cue in separate layer") { ((try? alpha(overlay).visible) ?? 0) > 0 }

        player.seek(to: .seconds(3))
        try await eventually("seek clears elapsed cue") {
            abs(player.position.seconds - 3) < 0.1 && (try? alpha(overlay).visible) == 0
        }
        player.seek(to: .seconds(1))
        try await eventually("backward seek restores cue") {
            abs(player.position.seconds - 1) < 0.1 && ((try? alpha(overlay).visible) ?? 0) > 0
        }
        try await fixture.loadPaused(TestPaths.baselineMedia)
        try #require(player.subtitleTracks.isEmpty, "Replacement source must have no embedded, external, or auto-loaded subtitle tracks.")
        // A removed image and a timed transparent sample both represent a
        // cleared layer. Neither may retain any visible pixels from the cue.
        try await eventually("source replacement removes old cue") { subtitleIsClear(overlay) }
        #expect(player.lastError == nil)
    }

    @Test(
        .disabled(if: subtitleLayerReadbackUnavailable, "Displayed subtitle pixels require macOS or a physical Apple device."),
        .enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC), "Requires a hardware Dolby Vision HEVC decoder.")
    )
    func `refused Dolby Vision PiP restores inline subtitles without modifying pixels`() async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null", "osd-level": "0"],
            automaticallyPlays: false,
            dolbyVisionPolicy: .strict,
            hardwareDecoding: .videoToolbox,
            videoOutput: .sampleBuffer
        ))
        defer { fixture.close() }
        let subtitle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".srt")
        try "1\n00:00:00,000 --> 00:00:05,000\nPreserved Dolby Vision subtitle\n".write(to: subtitle, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: subtitle) }
        try await fixture.loadPaused(TestPaths.testMedia("dolby-vision-p5.mp4"))
        let player = fixture.player
        let video = player.sampleBufferDisplayLayer
        let overlay = player.sampleBufferOSDLayer
        try await eventually("validated Dolby Vision source") {
            player.dolbyVisionStatus.nativeValidation == .validated && video.sampleBufferRenderer.displayedPixelBuffer() != nil
        }
        let original = try dolbyVisionPixels(video)
        player.loadExternalTrack(subtitle, type: .subtitle, select: true)
        try await eventually("Dolby Vision inline subtitle") { ((try? alpha(overlay).visible) ?? 0) > 0 }
        #expect(try dolbyVisionPixels(video) == original)

        // RPU metadata requires the source planes to remain untouched. A
        // rejected composition request must roll back before returning false.
        #expect(await player.setNativePictureInPictureComposition(true) == false)
        try await eventually("failed PiP restores inline subtitle layer") { ((try? alpha(overlay).visible) ?? 0) > 0 }
        #expect(try dolbyVisionPixels(video) == original)
        #expect(player.isPaused)
        #expect(player.lastError == nil)
    }

    private func dolbyVisionPixels(_ layer: AVSampleBufferDisplayLayer) throws -> [Data] {
        guard let buffer = layer.sampleBufferRenderer.displayedPixelBuffer(),
              [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
                  .contains(CVPixelBufferGetPixelFormatType(buffer)),
                  CVPixelBufferGetPlaneCount(buffer) == 2,
                  let rpu = CVBufferCopyAttachment(buffer, "DolbyVisionRPUData" as CFString, nil) as? Data,
                  !rpu.isEmpty,
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw ReadbackError.unavailable }

        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var result = [rpu]
        for plane in 0 ..< 2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { throw ReadbackError.unavailable }

            let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 2 : 4)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            var bytes = Data()
            for y in 0 ..< height {
                bytes.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: rowBytes)
            }
            result.append(bytes)
        }
        return result
    }

    private func luma(_ layer: AVSampleBufferDisplayLayer) throws -> Data {
        guard let buffer = layer.sampleBufferRenderer.displayedPixelBuffer(),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw ReadbackError.unavailable }

        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { throw ReadbackError.unavailable }

        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var result = Data()
        for y in 0 ..< height {
            result.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: width)
        }
        return result
    }

    private func subtitleIsClear(_ layer: AVSampleBufferDisplayLayer) -> Bool {
        if layer.sampleBufferRenderer.displayedPixelBuffer() == nil {
            return true
        }
        return (try? alpha(layer).visible) == 0
    }

    private func alpha(_ layer: AVSampleBufferDisplayLayer) throws -> (width: Int, height: Int, visible: Int) {
        guard let buffer = layer.sampleBufferRenderer.displayedPixelBuffer(),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw ReadbackError.unavailable }

        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw ReadbackError.unavailable }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var visible = 0
        for y in 0 ..< height {
            for x in 0 ..< width where base[y * stride + x * 4 + 3] > 0 {
                visible += 1
            }
        }
        return (width, height, visible)
    }
}
