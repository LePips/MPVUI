#if os(macOS)
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import MPVUI
import SwiftUI
import Testing
import VideoToolbox

/// Generated Profile 5 and 8 media covers output decisions and metadata.
/// Unvalidated Profile 5 frames must never reach AVFoundation.
@Suite(.tags(.integration, .dolbyVision), .serialized)
struct MPVDolbyVisionRegressionTests {
    @MainActor
    @Test
    func `software profile 5 fails without switching and a later SDR load recovers`() async throws {
        let profile5 = try TestPaths.testMedia("dolby-vision-p5.mp4")
        let host = Host(hardwareDecoding: .disabled, startTime: .seconds(1), playbackRate: 1.5)
        defer { host.close() }
        let player = host.player
        var logs: [MPVLogMessage] = []
        player.logHandler = { logs.append($0) }
        let pictureInPicture = player.pictureInPicture
        pictureInPicture.allowsAutomaticStartFromInline = true
        pictureInPicture.restoreUserInterface = { true }
        let rejectedLayer = player.sampleBufferDisplayLayer
        player.load(profile5)
        var exposedUnvalidatedFrame = false
        try await eventually("software Profile 5 fallback") {
            exposedUnvalidatedFrame = exposedUnvalidatedFrame || rejectedLayer.isReadyForDisplay
            if case .failed(.nativeVideoOutputUnavailable) = player.state {
                return true
            }
            return false
        }
        #expect(!exposedUnvalidatedFrame)
        #expect(rejectedLayer.sampleBufferRenderer.displayedPixelBuffer() == nil)
        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.configuration.videoOutput == .sampleBuffer)
        #expect(player.isPaused)
        #expect(player.playbackRate == 1.5)
        #expect(player.mediaInformation.sourceURL == profile5)
        #expect(player.lastError != nil)
        #expect(player.pictureInPicture === pictureInPicture)
        #expect(pictureInPicture.allowsAutomaticStartFromInline)
        #expect(await pictureInPicture.restoreUserInterface?() == true)
        #expect(logs.isEmpty, "Internal native capability errors must not enable public log forwarding.")
        let fallback = await player.lifecycleDiagnostics()
        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(0.4))
        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.pictureInPicture === pictureInPicture)
        try await eventually("SDR native restoration") {
            player.state == .paused && player.sampleBufferDisplayLayer.isReadyForDisplay
                && player.sampleBufferDisplayLayer.sampleBufferRenderer.displayedPixelBuffer() != nil
                && abs(player.position.seconds - 0.4) < 0.15
        }
        #expect(player.playbackRate == 1.5)
        #expect(player.isPaused)
        #expect(player.lastError == nil)
        #expect(logs.isEmpty)
        let restored = await player.lifecycleDiagnostics()
        #expect(restored.loadCommands == fallback.loadCommands + 1)
        #expect(player.pictureInPicture === pictureInPicture)
        #expect(pictureInPicture.allowsAutomaticStartFromInline)
        #expect(await pictureInPicture.restoreUserInterface?() == true)
    }

    @MainActor
    @Test
    func `hardware profile 5 requires a validated session or reports native failure`() async throws {
        let startTime: Duration = .seconds(1.25)
        let host = Host(hardwareDecoding: .videoToolbox, startTime: startTime, logLevel: .debug)
        defer { host.close() }
        let player = host.player
        let layer = player.sampleBufferDisplayLayer
        try player.load(TestPaths.testMedia("dolby-vision-p5.mp4"))
        try await eventually("hardware Profile 5 output decision") {
            if case .failed(.nativeVideoOutputUnavailable) = player.state {
                return true
            }
            return player.state == .paused && layer.sampleBufferRenderer.displayedPixelBuffer() != nil
        }
        #expect(player.isPaused)
        #expect(abs(player.position.seconds - startTime.seconds) < 0.15)
        #expect(player.videoOutput == .sampleBuffer)
        if player.lastError == nil {
            let buffer = try #require(layer.sampleBufferRenderer.displayedPixelBuffer())
            let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] ?? [:]
            let internalAttachments = CVBufferCopyAttachments(buffer, .shouldNotPropagate) as? [String: Any] ?? [:]
            print(
                "DOLBY_VISION native readback: format=\(CVPixelBufferGetPixelFormatType(buffer)), propagated=\(attachments.keys.sorted()), nonpropagated=\(internalAttachments.keys.sorted()), RPU bytes=\((attachments["DolbyVisionRPUData"] as? Data)?.count ?? 0)"
            )
            // The native VO requires its private decoder-session marker before
            // enqueue. AVFoundation drops that private key from readback, while
            // retaining the per-frame Dolby Vision data used for presentation.
            let rpu = try #require(attachments["DolbyVisionRPUData"] as? Data)
            try #require(!rpu.isEmpty)
            #expect(player.mediaInformation.hardwareDecoder == "videotoolbox")
            #expect(layer.sampleBufferRenderer.status == .rendering)
            let overlay = ImageRenderer(content: Color.white.frame(width: 32, height: 32))
            let bitmap = try #require(overlay.cgImage.flatMap(MPVVideoOverlayBitmap.init))
            #expect(
                await player.setPictureInPictureOverlay(bitmap) == false,
                "The overlay API must not claim composition on unchanged Dolby Vision RPU frames."
            )
            print(
                "DOLBY_VISION hardware: validated native session, RPU bytes=\(rpu.count), format=\(CVPixelBufferGetPixelFormatType(buffer)), attachments=\(attachments.keys.sorted())"
            )
        } else {
            guard case .nativeVideoOutputUnavailable = player.lastError else {
                Issue.record("Expected a native output error: \(String(describing: player.lastError))")
                return
            }
            #expect(!layer.isReadyForDisplay)
            #expect(layer.sampleBufferRenderer.displayedPixelBuffer() == nil)
        }
    }

    /// Declared or actual RPU compression must not block native output. VideoToolbox
    /// rejects compressed configurations, so every submitted RPU is standalone.
    @MainActor
    @Test(
        .enabled(
            if: VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC),
            "Requires a hardware Dolby Vision HEVC decoder."
        ),
        arguments: ["dolby-vision-p81.mp4", "dolby-vision-p84.mp4", "dolby-vision-p81-declared-extended.ts", "dolby-vision-p81-extended.ts"]
    )
    func `hardware profile 8 plays every frame as native Dolby Vision`(name: String) async throws {
        let host = Host(hardwareDecoding: .videoToolbox, startTime: .seconds(1.25))
        defer { host.close() }
        let player = host.player
        let layer = player.sampleBufferDisplayLayer
        try player.load(TestPaths.testMedia(name))
        try await eventually("native Profile 8 frame after a keyframe seek in \(name)") {
            player.lastError != nil
                || player.state == .paused && layer.sampleBufferRenderer.displayedPixelBuffer() != nil
                && abs(player.position.seconds - 1.25) < 0.05
        }
        try #require(player.lastError == nil, "\(String(describing: player.lastError))")
        #expect(player.mediaInformation.hardwareDecoder == "videotoolbox")
        let buffer = try #require(layer.sampleBufferRenderer.displayedPixelBuffer())
        let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] ?? [:]
        #expect((attachments["DolbyVisionRPUData"] as? Data)?.isEmpty == false)

        // Frames after the seek keyframe carry RPUs that reference earlier ones.
        player.play()
        try await eventually("native Profile 8 playback to the end of \(name)") {
            player.lastError != nil || player.state == .ended || player.position.seconds > 1.9
        }
        #expect(player.lastError == nil, "\(String(describing: player.lastError))")
    }

    @MainActor
    private final class Host {
        let player: MPVPlayer
        let surface: MPVPlatformVideoPlayer
        let window: NSWindow

        init(
            hardwareDecoding: MPVPlayerConfiguration.HardwareDecoding,
            startTime: Duration,
            playbackRate: Double = 1,
            logLevel: MPVPlayerConfiguration.LogLevel = .none
        ) {
            player = MPVPlayer(configuration: .init(
                additionalOptions: ["ao": "null", "sid": "no", "osd-level": "0"],
                autoPlay: false,
                hardwareDecoding: hardwareDecoding,
                hdrPolicy: .disabled,
                logLevel: logLevel,
                playbackRate: playbackRate,
                startTime: startTime,
                videoOutput: .sampleBuffer
            ))
            player.logHandler = { message in
                if [.fatal, .error].contains(message.level)
                    || message.message.contains("Native Dolby Vision metadata:")
                    || message.message.contains("Using Dolby Vision HEVC VideoToolbox format")
                {
                    print("DOLBY_VISION log[\(message.prefix)] \(message.message)")
                }
            }
            surface = MPVPlatformVideoPlayer(player: player)
            window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = surface
            window.orderFront(nil)
            surface.activateRenderingSurface()
        }

        func close() {
            player.stop()
            surface.detach()
            window.orderOut(nil)
            window.contentView = nil
        }
    }
}
#endif
