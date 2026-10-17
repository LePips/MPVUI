import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import MPVCore
@testable import MPVUI
import Observation
import SwiftUI
import Testing

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Verifies decoded pixels, filter output, and native presentation formats.
/// Pixel assertions cover format/range tags and composition, not display fidelity.
// The iOS Simulator can report a rendering, ready AVFoundation output while
// copyDisplayedPixelBuffer remains unavailable. Keep clock/readiness integration
// tests running there; inspect pixels on macOS and physical iOS instead.
private let nativePixelReadbackUnavailable: Bool = {
    #if targetEnvironment(simulator)
    true
    #else
    false
    #endif
}()

@Suite(.tags(.integration, .nativePatch), .serialized)
struct MPVNativeVideoFormatTests {

    #if os(macOS)
    @MainActor
    @Test(arguments: [false, true], [60, 120])
    func `software presentation keeps uploads available at high frame rates`(overlay: Bool, frameRate: Int) async throws {
        let fixture = NativeFormatFixture(options: [
            "vf": "lavfi=[fps=\(frameRate)],scale=1920:1080,format=fmt=nv12",
            "loop-file": "inf",
            "sub-visibility": "no",
            "osd-level": "0",
        ])
        defer { fixture.close() }
        fixture.player.setDiagnosticsEnabled(true)
        fixture.player.load(TestPaths.baselineMedia, autoPlay: true)
        try await eventually("software presentation starts") {
            fixture.player.state == .playing
                && (fixture.player.playbackDiagnostics.nativeOutputStatistics?.sampleBuildCount ?? 0) > 0
        }
        if overlay {
            fixture.player.command("show-text", arguments: ["Persistent native overlay", "100000", "1"])
        }
        for cycle in 0 ..< 2 {
            if cycle > 0 {
                fixture.player.play()
            }
            // Startup can miss a presentation deadline while the media clock is
            // anchoring. Measure pool reuse after a second of scheduled frames.
            let warmupStart = fixture.player.playbackDiagnostics.nativeOutputStatistics?.sampleBuildCount ?? 0
            try await eventually("software presentation warms up") {
                (fixture.player.playbackDiagnostics.nativeOutputStatistics?.sampleBuildCount ?? 0) >= warmupStart + Int64(frameRate)
            }

            let initial = try #require(fixture.player.playbackDiagnostics.nativeOutputStatistics)
            let initialSamples = try #require(initial.sampleBuildCount)
            let initialUploads = try #require(initial.pixelBufferCopies)
            let initialDrops = try #require(fixture.player.playbackDiagnostics.outputDroppedFrames)
            if initialUploads != initialSamples || initialDrops > 0 {
                print(
                    """
                    Native \(frameRate) fps warmup, overlay=\(overlay): uploads=\(initialUploads), samples=\(initialSamples), \
                    drops=\(initialDrops)
                    """
                )
            }
            fixture.nativeLogs.removeAll()
            try await eventually("several native buffer reuse cycles", timeout: .seconds(8)) {
                (fixture.player.playbackDiagnostics.nativeOutputStatistics?.sampleBuildCount ?? 0) >= initialSamples + 180
            }

            let statistics = try #require(fixture.player.playbackDiagnostics.nativeOutputStatistics)
            let samples = try #require(statistics.sampleBuildCount) - initialSamples
            let uploads = try #require(statistics.pixelBufferCopies) - initialUploads
            #expect(
                uploads == samples,
                "Every software sample must upload once without exhausting the presentation pool: \(uploads)/\(samples)."
            )

            #expect(!fixture.nativeLogs.contains { $0.contains("Failed to get upload buffer") }, "\(fixture.nativeLogs.suffix(5))")
            #expect(fixture.player.playbackDiagnostics.outputDroppedFrames == initialDrops)
            #expect(fixture.player.lastError == nil)

            // A paused seek must replace queued presentation buffers even when the
            // upload pool was full immediately before the media clock stopped.
            fixture.player.pause()
            try await eventually("pause after sustained software playback") { fixture.player.isPaused }
            // Leave enough media after the first seek for the next steady interval.
            let target = fixture.player.duration.seconds * (cycle == 0 ? 0.25 : 0.75)
            defer {
                if fixture.layer.controlTimebase.map({ abs(CMTimebaseGetTime($0).seconds - target) >= 0.15 }) != false {
                    print(
                        """
                        Paused native seek: target=\(target), \
                        clock=\(fixture.layer.controlTimebase.map { CMTimebaseGetTime($0).seconds } ?? -1),\u{20}
                        """
                            + "statistics=\(String(describing: fixture.player.playbackDiagnostics.nativeOutputStatistics)), "
                            + "drops=\(String(describing: fixture.player.playbackDiagnostics.outputDroppedFrames))"
                    )
                    for message in fixture.nativeLogs {
                        print("Native seek: \(message)")
                    }
                }
            }
            let completed = await fixture.player.seekForPictureInPicture(to: .seconds(target))
            try #require(completed)
            try await eventually("paused seek presents a fresh native frame") {
                fixture.layer.isReadyForDisplay && fixture.buffer != nil
                    && fixture.layer.controlTimebase.map {
                        CMTimebaseGetRate($0) == 0 && abs(CMTimebaseGetTime($0).seconds - target) < 0.15
                    } == true
            }
            // Diagnostics poll independently of seek completion. Observe the
            // reset before the next cycle can use a cached pre-seek count.

            let preSeekSamples = try #require(statistics.sampleBuildCount)
            try await eventually("native statistics reflect the paused seek") {
                guard let count = fixture.player.playbackDiagnostics.nativeOutputStatistics?.sampleBuildCount else { return false }
                return count > 0 && count < preSeekSamples
            }
        }
    }
    #endif

    @MainActor
    @Test(.disabled(
        if: nativePixelReadbackUnavailable,
        "AVFoundation displayed-pixel readback is unavailable in the iOS Simulator; run on macOS or physical iOS."
    ), arguments: [0.0, 0.25], [
        "format=fmt=nv12:colorlevels=limited:convert=yes",
        "format=fmt=nv12:colorlevels=full:convert=yes",
        "format=fmt=p010:colorlevels=limited:convert=yes",
        "format=fmt=p010:colorlevels=full:convert=yes",
    ])

    func `SwiftUI bitmap updates and clears on the same paused native frame`(zoom: Double, filter: String) async throws {
        let fixture = NativeFormatFixture(options: [
            "vf": filter,
            "sub-visibility": "no",
            "osd-level": "0",
            // Repeat the overlay checks with zoom configured. Native frame-space
            // OSD can bypass geometry; this does not prove the CI cache path ran.
            "video-zoom": String(zoom),
        ])
        defer { fixture.close() }
        fixture.player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(1))
        try await eventually("paused overlay source") {
            fixture.player.isPaused && fixture.buffer != nil
                && fixture.layer.controlTimebase.map { CMTimebaseGetRate($0) == 0 } == true
        }
        let source = try fixture.snapshot()
        let model = BitmapOverlayModel()
        var accepted = false
        let renderer = MPVVideoOverlayRenderer(
            content: AnyView(BitmapOverlayProbe(model: model)),
            submit: { await fixture.player.setPictureInPictureOverlay($0) },
            availabilityChanged: { accepted = $0 }
        )
        defer {
            renderer.invalidate()
            fixture.player.clearPictureInPictureOverlay()
        }
        renderer.updateSize(CGSize(width: 320, height: 180))
        try await eventually("SwiftUI overlay composited into the upper band") {
            accepted && (try? fixture.snapshot().upperBand).map { $0 != source.upperBand } == true
        }
        let upperOverlay = try fixture.snapshot()

        #expect(upperOverlay.lowerBand == source.lowerBand)
        #expect(upperOverlay.width == source.width && upperOverlay.height == source.height)

        // This changes an observable child without replacing the root view.
        model.isAtBottom = true
        try await eventually("observable overlay update while paused") {
            guard let frame = try? fixture.snapshot() else { return false }
            return frame.upperBand == source.upperBand && frame.lowerBand != source.lowerBand
        }
        renderer.invalidate()
        fixture.player.clearPictureInPictureOverlay()
        try await eventually("overlay removal restores every source pixel") {
            guard let frame = try? fixture.snapshot() else { return false }
            return frame.luma == source.luma && frame.chroma == source.chroma
        }

        #expect(fixture.player.isPaused)
        #expect(fixture.player.lastError == nil)
        let timebase = try #require(fixture.layer.controlTimebase)
        #expect(CMTimebaseGetRate(timebase) == 0)
        #expect(abs(CMTimebaseGetTime(timebase).seconds - 1) < 0.15)
    }

    @MainActor
    @Test(.disabled(
        if: nativePixelReadbackUnavailable,
        "AVFoundation displayed-pixel readback is unavailable in the iOS Simulator; run on macOS or physical iOS."
    ), arguments: [
        "format=fmt=nv12:colorlevels=limited:convert=yes",
        "format=fmt=nv12:colorlevels=full:convert=yes",
        "format=fmt=p010:colorlevels=limited:convert=yes",
        "format=fmt=p010:colorlevels=full:convert=yes",
    ])

    func `software buffer formats`(filter: String) async throws {
        let fixture = NativeFormatFixture(options: [
            "vf": filter,
            "sub-visibility": "no",
            "osd-level": "0",
        ])
        defer { fixture.close() }
        fixture.player.load(TestPaths.baselineMedia, autoPlay: false)
        try await eventually("software displayed pixels") {
            fixture.player.state == .paused && fixture.buffer != nil
        }

        let buffer = try #require(fixture.buffer)
        let isTenBit = filter.contains("p010")
        let isFullRange = filter.contains("colorlevels=full")
        let expected: OSType = isTenBit
            ? (isFullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            : (isFullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        #expect(CVPixelBufferGetPixelFormatType(buffer) == expected)
        #expect(CVPixelBufferGetPlaneCount(buffer) == 2)
        #expect(CVPixelBufferGetIOSurface(buffer) != nil)
        #expect(CVPixelBufferGetWidth(buffer) > 0)
        #expect(CVPixelBufferGetHeight(buffer) > 0)
        #expect(fixture.layer.sampleBufferRenderer.status != .failed)
        #expect(fixture.player.lastError == nil)
        #expect(fixture.player.mediaInformation.hardwareDecoder == nil
            || fixture.player.mediaInformation.hardwareDecoder == "no")

        // P010 stores each 10-bit component in the high bits of a 16-bit word.
        // Inspect actual visible luma bytes, excluding unspecified row padding.
        if isTenBit {
            try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            var hasNonzeroLuma = false
            var hasInvalidLowBits = false
            for y in 0 ..< height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0 ..< width {
                    hasNonzeroLuma = hasNonzeroLuma || row[x] != 0
                    hasInvalidLowBits = hasInvalidLowBits || row[x] & 0x3F != 0
                }
            }

            #expect(hasNonzeroLuma)
            #expect(!hasInvalidLowBits)
        }
    }

    @MainActor
    @Test(.disabled(
        if: nativePixelReadbackUnavailable,
        "AVFoundation displayed-pixel readback is unavailable in the iOS Simulator; run on macOS or physical iOS."
    ), arguments: 0 ..< 5)

    func `subtitle and OSD groups remain visible together on paused frame`(repetition: Int) async throws {
        let media = try TestPaths.testMedia("subtitles.mkv")
        let fixture = NativeFormatFixture(options: [
            "vf": "format=fmt=nv12",
            "sid": "1",
            "sub-visibility": "no",
            "osd-duration": "0",
            "osd-level": "1",
            "osd-align-x": "left",
            "osd-align-y": "top",
        ])
        defer { fixture.close() }
        let player = fixture.player
        player.setDiagnosticsEnabled(true)
        player.load(media, autoPlay: false, startTime: .seconds(1))
        try await eventually("subtitle fixture initial frame") {
            guard player.state == .paused, fixture.buffer != nil,
                  fixture.layer.isReadyForDisplay,
                  let clock = fixture.layer.controlTimebase,
                  CMTimebaseGetRate(clock) == 0,
                  abs(CMTimebaseGetTime(clock).seconds - 1) < 0.15
            else { return false }
            return player.mediaInformation.tracks.contains { $0.type == .subtitle && $0.codec == "ass" }
        }

        let selectedTrack = try #require(player.mediaInformation.tracks.first {
            $0.type == .subtitle && $0.isSelected
        })
        try #require(selectedTrack.codec == "ass")
        let source = try fixture.snapshot()
        var stage = "source"
        var restoredSource = false
        defer {
            if !restoredSource {
                let latest = try? fixture.snapshot()
                let clock = fixture.layer.controlTimebase
                print("Native paused OSD iteration \(repetition), stage \(stage): "
                    + "clock=\(clock.map { CMTimebaseGetTime($0).seconds } ?? -.infinity), "
                    + "rate=\(clock.map(CMTimebaseGetRate) ?? -.infinity), "
                    + "upper restored=\(latest?.upperBand == source.upperBand), "
                    + "lower restored=\(latest?.lowerBand == source.lowerBand), "
                    + "all pixels restored=\(latest?.luma == source.luma)")
                for message in fixture.nativeLogs {
                    print("Native paused OSD: \(message)")
                }
            }
        }
        // The fixture's first subtitle track is already decoded but hidden.
        // Only change visibility; changing tracks/seeking can select a different
        // video frame and invalidate byte-for-byte comparisons of source pixels.
        player.setProperty("sub-visibility", to: "yes")
        stage = "subtitle add"
        try await eventually("selected ASS subtitle redraw") { (try? fixture.snapshot().lowerBand).map { $0 != source.lowerBand } ?? false }
        let subtitleOnly = try fixture.snapshot()

        #expect(subtitleOnly.upperBand == source.upperBand)
        #expect(subtitleOnly.lowerBand != source.lowerBand)

        player.command("show-text", arguments: ["Native OSD group", "100000", "1"])
        stage = "OSD add"
        try await eventually("combined OSD and subtitle redraw") {
            (try? fixture.snapshot().upperBand).map { $0 != subtitleOnly.upperBand } ?? false
        }
        let combined = try fixture.snapshot()

        #expect(combined.upperBand != subtitleOnly.upperBand)
        #expect(combined.lowerBand == subtitleOnly.lowerBand)

        player.setProperty("sub-visibility", to: "no")
        stage = "subtitle removal"
        try await eventually("subtitle removal preserving OSD") { (try? fixture.snapshot().lowerBand) == source.lowerBand }
        let osdOnly = try fixture.snapshot()

        #expect(osdOnly.upperBand == combined.upperBand)
        #expect(osdOnly.lowerBand == source.lowerBand)

        player.command("show-text", arguments: ["", "0", "1"])
        stage = "OSD clear"
        try await eventually("OSD clear restoring source pixels") { (try? fixture.snapshot().luma) == source.luma }
        restoredSource = true

        #expect(player.isPaused)
        #expect(player.lastError == nil)
        let timebase = try #require(fixture.layer.controlTimebase)
        #expect(CMTimebaseGetRate(timebase) == 0)
        #expect(abs(CMTimebaseGetTime(timebase).seconds - 1) < 0.15)
    }

    @MainActor
    @Test
    func `WebP still image decodes losslessly`() async throws {
        let session = try NativePlaybackSession()
        defer { session.close() }
        try await session.load(TestPaths.testMedia("image-webp-still.webp"))
        try await expectWebPFrame(session, time: 0, left: [255, 0, 0], right: [255, 0, 0])
    }

    @MainActor
    @Test
    func `animated WebP preserves partial frames and variable timing`() async throws {
        let session = try NativePlaybackSession()
        defer { session.close() }
        try await session.load(TestPaths.testMedia("image-webp-animated.webp"))
        try await expectWebPFrame(session, time: 0, left: [255, 0, 0], right: [255, 0, 0])
        try session.command(["frame-step"])
        try await expectWebPFrame(session, time: 0.25, left: [255, 0, 0], right: [0, 0, 255])
        try session.command(["frame-step"])
        try await expectWebPFrame(session, time: 0.75, left: [0, 255, 0], right: [0, 255, 0])

        #expect(abs((session.property("duration")?.doubleValue ?? -1) - 1.5) < 0.001)
    }

    @MainActor
    @Test(arguments: [8, 10])
    func `ten bit deinterlacing preserves narrow short frames`(height: Int) async throws {
        let session = try NativePlaybackSession(options: [
            "vf": "lavfi=[scale=34:\(height),format=pix_fmts=yuv420p10le,bwdif=mode=send_frame:parity=tff:deint=all]",
        ])
        defer { session.close() }
        try await session.load(TestPaths.baselineMedia)
        for _ in 0 ..< 3 {
            let previous = try #require(session.property("time-pos")?.doubleValue)
            try session.command(["frame-step"])
            try await eventually("next deinterlaced frame") { (session.property("time-pos")?.doubleValue ?? -1) > previous }

            let frame = try #require(try session.command(["screenshot-raw", "video", "rgba"])?.mapValue)
            #expect(frame["w"]?.integerValue == 34)
            #expect(session.property("video-out-params/h")?.integerValue == Int64(height))
        }
    }

    @MainActor
    @Test
    func `equirectangular projection produces requested viewport dimensions`() async throws {
        let session = try NativePlaybackSession(options: [
            "vf": "lavfi=[v360=input=e:output=flat:w=16:h=16]",
        ])
        defer { session.close() }
        try await session.load(TestPaths.baselineMedia)
        try await eventually("projected viewport dimensions") { session.property("video-out-params/w")?.integerValue == 16 }

        #expect(session.property("video-out-params/h")?.integerValue == 16)
        let frame = try #require(try session.command(["screenshot-raw", "video", "rgba"])?.mapValue)
        #expect(frame["w"]?.integerValue == 16)
        #expect(frame["h"]?.integerValue == 16)
    }

    @MainActor
    private func expectWebPFrame(_ session: NativePlaybackSession, time: Double, left: [UInt8], right: [UInt8]) async throws {
        try await eventually("WebP frame at \(time) seconds") {
            abs((session.property("time-pos")?.doubleValue ?? -1) - time) < 0.001
        }

        let frame = try #require(try session.command(["screenshot-raw", "video", "rgba"])?.mapValue)
        try #require(frame["w"]?.integerValue == 32 && frame["h"]?.integerValue == 24)
        try #require(frame["format"]?.stringValue == "rgba")

        let stride = try Int(#require(frame["stride"]?.integerValue))
        guard case let .data(pixels) = frame["data"] else {
            Issue.record("Screenshot has no pixel data")
            return
        }
        for (x, expected) in [(8, left), (24, right)] {
            let offset = 12 * stride + x * 4
            try #require(offset + 4 <= pixels.count)

            #expect(Array(pixels[offset ..< offset + 3]) == expected)
            #expect(pixels[offset + 3] == 255)
        }
    }
}

@MainActor
@Observable
private final class BitmapOverlayModel {

    var isAtBottom = false
}

private struct BitmapOverlayProbe {

    let model: BitmapOverlayModel
}

extension BitmapOverlayProbe: View {

    var body: some View {
        Color.white
            .opacity(0.75)
            .frame(height: 32)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: model.isAtBottom ? .bottom : .top
            )
    }
}

@MainActor
private final class NativeFormatFixture {

    struct Frame {

        let width: Int
        let height: Int
        let bytesPerPixel: Int
        let luma: Data
        let chroma: Data

        var upperBand: Data {
            luma.subdata(in: 0 ..< width * bytesPerPixel * (height / 3))
        }

        var lowerBand: Data {
            luma.subdata(in: width * bytesPerPixel * (2 * height / 3) ..< luma.count)
        }
    }

    private enum SnapshotError: Error {

        case frameUnavailable
    }

    var nativeLogs: [String] = []
    private let playback: PlaybackFixture

    var player: MPVPlayer {
        playback.player
    }

    var surface: MPVPlatformVideoPlayer {
        playback.surface
    }

    var layer: AVSampleBufferDisplayLayer {
        player.sampleBufferDisplayLayer
    }

    var buffer: CVPixelBuffer? {
        layer.sampleBufferRenderer.displayedPixelBuffer()
    }

    init(options: [String: String]) {
        playback = PlaybackFixture(configuration: .init(
            additionalOptions: options.merging(["ao": "null"]) { _, new in new },
            autoPlay: false,
            hardwareDecoding: .disabled,
            logLevel: .verbose,
            videoOutput: .sampleBuffer
        ))
        player.logHandler = { [weak self] message in
            guard let self, message.prefix.contains("avfoundation") else { return }
            nativeLogs.append(message.message)
            if nativeLogs.count > 100 {
                nativeLogs.removeFirst()
            }
        }
    }

    func close() {
        if buffer == nil {
            print("Native pixel readback unavailable: \(playback.presentationContext), "
                + "state=\(player.state), rate=\(layer.controlTimebase.map(CMTimebaseGetRate) ?? -.infinity), "
                + "ready=\(layer.isReadyForDisplay), status=\(layer.sampleBufferRenderer.status.rawValue), "
                + "error=\(String(describing: layer.sampleBufferRenderer.error))")
            for message in nativeLogs {
                print("Native readback: \(message)")
            }
        }
        playback.close()
    }

    func snapshot() throws -> Frame {
        // A redraw can briefly expose no buffer. Polling callers retry this
        // condition; #require would record a failure even when try? catches it.
        guard let buffer else { throw SnapshotError.frameUnavailable }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        try #require([
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        ].contains(format))
        let bytesPerPixel = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ? 2 : 1
        try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)

        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        var luma = Data(capacity: width * height * bytesPerPixel)
        for row in 0 ..< height {
            luma.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width * bytesPerPixel)
        }
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        let chromaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        let chromaRowBytes = chromaWidth * 2 * bytesPerPixel
        var chroma = Data(capacity: chromaRowBytes * chromaHeight)
        for row in 0 ..< chromaHeight {
            chroma.append(chromaBase.advanced(by: row * chromaStride).assumingMemoryBound(to: UInt8.self), count: chromaRowBytes)
        }
        return Frame(width: width, height: height, bytesPerPixel: bytesPerPixel, luma: luma, chroma: chroma)
    }
}
