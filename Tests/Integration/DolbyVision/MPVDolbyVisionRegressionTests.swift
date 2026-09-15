#if os(macOS)
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
@testable import MPVUI
import SwiftUI
import Testing

private let dolbyVisionFixture = TestPaths.dolbyVisionMedia

/// Uses the optional local Profile 5 sample for decoder and color regressions.
/// Set MPVUI_DOLBY_VISION_FIXTURE to supply the sample in another checkout.
/// Buffer delivery alone cannot validate Dolby Vision: unvalidated Profile 5
/// frames must never reach AVFoundation, where they appear pink/green/purple.
@Suite(.tags(.integration, .dolbyVision), .serialized, .disabled(
    if: !FileManager.default.fileExists(atPath: dolbyVisionFixture.path),
    "Provide the local Profile 5 sample or MPVUI_DOLBY_VISION_FIXTURE."
))
struct MPVDolbyVisionRegressionTests {
    @MainActor
    @Test
    func `software profile 5 falls back without public logging and restores native for SDR`() async throws {
        let host = Host(hardwareDecoding: .disabled, startTime: .seconds(1), playbackRate: 1.5)
        defer { host.close() }
        let player = host.player
        var logs: [MPVLogMessage] = []
        player.logHandler = { logs.append($0) }
        let pictureInPicture = player.pictureInPicture
        pictureInPicture.allowsAutomaticStartFromInline = true
        pictureInPicture.restoreUserInterface = { true }
        let rejectedLayer = player.sampleBufferDisplayLayer
        player.load(dolbyVisionFixture)
        var exposedUnvalidatedFrame = false
        try await eventually("software Profile 5 fallback") {
            exposedUnvalidatedFrame = exposedUnvalidatedFrame || rejectedLayer.isReadyForDisplay
            return player.videoOutput == .metal && player.state == .paused
                && abs(player.position.seconds - 1) < 0.15
        }
        #expect(!exposedUnvalidatedFrame)
        #expect(rejectedLayer.sampleBufferRenderer.displayedPixelBuffer() == nil)
        #expect(player.videoOutputFallbackReason?.contains("Dolby Vision") == true)
        #expect(player.configuration.videoOutput == .sampleBuffer)
        #expect(player.isPaused)
        #expect(player.playbackRate == 1.5)
        #expect(player.mediaInformation.sourceURL == dolbyVisionFixture)
        #expect(player.lastError == nil)
        #expect(player.pictureInPicture === pictureInPicture)
        #expect(pictureInPicture.allowsAutomaticStartFromInline)
        #expect(await pictureInPicture.restoreUserInterface?() == true)
        #expect(logs.isEmpty, "Internal native capability errors must not enable public log forwarding.")
        let fallback = await player.lifecycleDiagnostics()
        // Check the replacement engine really resumes the same timeline.
        player.play()
        try await eventually("fallback playback advancing") {
            player.state == .playing && player.position.seconds > 1.2
        }
        #expect(player.playbackRate == 1.5)
        player.pause()
        try await eventually("fallback pause") { player.state == .paused }

        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(0.4))
        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.videoOutputFallbackReason == nil)
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
    func `hardware profile 5 requires real dolby vision session and RPU or falls back`() async throws {
        let host = Host(hardwareDecoding: .videoToolbox, startTime: .seconds(5), logLevel: .debug)
        defer { host.close() }
        let player = host.player
        let layer = player.sampleBufferDisplayLayer
        player.load(dolbyVisionFixture)
        try await eventually("hardware Profile 5 output decision") {
            player.state == .paused && (player.videoOutput == .metal
                || layer.sampleBufferRenderer.displayedPixelBuffer() != nil)
        }
        #expect(player.isPaused)
        #expect(abs(player.position.seconds - 5) < 0.15)
        #expect(player.lastError == nil)
        if player.videoOutput == .sampleBuffer {
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
            #expect(player.videoOutputFallbackReason == nil)
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
            try await host.holdNativeWindowForVisualValidationIfRequested()
        } else {
            #expect(player.videoOutputFallbackReason?.contains("Dolby Vision") == true)
            #expect(!layer.isReadyForDisplay)
            #expect(layer.sampleBufferRenderer.displayedPixelBuffer() == nil)
            print("DOLBY_VISION hardware: safe Metal fallback, reason=\(player.videoOutputFallbackReason ?? "missing")")
            let image = try await host.screenshot(named: "hardware-fallback")
            let actual = try pixels(image)
            #expect(actual.meanBrightness > 0.02)
            expectCoastalColors(actual)
        }
    }

    @MainActor
    @Test
    func `software fallback colors match GPU and known coastal frame`() async throws {
        let fallback = Host(hardwareDecoding: .disabled, startTime: .seconds(5))
        defer { fallback.close() }
        fallback.player.load(dolbyVisionFixture)
        try await eventually("software fallback color frame") {
            fallback.player.videoOutput == .metal && fallback.player.state == .paused
        }
        let fallbackImage = try await fallback.screenshot(named: "software-fallback")
        let reference = Host(hardwareDecoding: .disabled, videoOutput: .metal, startTime: .seconds(5))
        defer { reference.close() }
        reference.player.load(dolbyVisionFixture)
        try await eventually("direct gpu-next color frame") { reference.player.state == .paused }
        let gpuImage = try await reference.screenshot(named: "direct-gpu-next")
        let actual = try pixels(fallbackImage)
        let gpu = try pixels(gpuImage)
        let gpuDifference = actual.meanAbsoluteDifference(from: gpu)
        print(
            "DOLBY_VISION color: fallback-vs-gpu RGB mean error=\(gpuDifference), brightness=\(actual.meanBrightness), images=\(fallback.artifactDirectory.path), gpu=\(reference.artifactDirectory.path)"
        )
        #expect(actual.meanBrightness > 0.02, "A black screenshot cannot validate color.")
        #expect(gpuDifference < 0.02, "Fallback must render the same colors as direct gpu-next.")
        expectCoastalColors(actual)
        #expect(fallback.player.lastError == nil)
        #expect(reference.player.lastError == nil)
    }

    private func expectCoastalColors(_ actual: Pixels) {
        // The known five-second frame has green vegetation and blue sea. These
        // broad channel relationships reject the original pink/purple cast even
        // if both renderer paths accidentally regress together. They avoid
        // prescribing a particular tone map or exact HDR display luminance.
        let hills = actual.meanRGB(x: 32 ..< 56, y: 30 ..< 40)
        let sea = actual.meanRGB(x: 110 ..< 130, y: 55 ..< 70)
        print("DOLBY_VISION coastal colors: hills=\(hills), sea=\(sea)")
        #expect(hills[1] > hills[0] * 1.1 && hills[1] > hills[2] * 1.05)
        #expect(sea[2] > sea[0] * 2 && sea[1] > sea[0] * 1.8 && sea[2] > sea[1] * 1.05)
    }

    private struct Pixels {
        let rgba: [UInt8]
        var meanBrightness: Double {
            stride(from: 0, to: rgba.count, by: 4).reduce(0.0) {
                $0 + (Double(rgba[$1]) + Double(rgba[$1 + 1]) + Double(rgba[$1 + 2])) / 765
            } / Double(rgba.count / 4)
        }

        func meanAbsoluteDifference(from other: Self) -> Double {
            var total = 0.0
            for i in stride(from: 0, to: rgba.count, by: 4) {
                for channel in 0 ..< 3 {
                    total += abs(Double(rgba[i + channel]) - Double(other.rgba[i + channel])) / 255
                }
            }
            return total / Double(rgba.count / 4 * 3)
        }

        func meanRGB(x: Range<Int>, y: Range<Int>) -> [Double] {
            var channels = [Double](repeating: 0, count: 3)
            for row in y {
                for column in x {
                    let index = (row * 160 + column) * 4
                    for channel in 0 ..< 3 {
                        channels[channel] += Double(rgba[index + channel]) / 255
                    }
                }
            }
            return channels.map { $0 / Double(x.count * y.count) }
        }
    }

    private func pixels(_ image: CGImage) throws -> Pixels {
        let width = 160
        let height = 90
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(rgba: bytes)
    }

    @MainActor
    private final class Host {
        let player: MPVPlayer
        let surface: MPVPlatformVideoPlayer
        let window: NSWindow
        let artifactDirectory: URL

        init(
            hardwareDecoding: MPVPlayerConfiguration.HardwareDecoding,
            videoOutput: MPVPlayerConfiguration.VideoOutput = .sampleBuffer,
            startTime: Duration,
            playbackRate: Double = 1,
            logLevel: MPVPlayerConfiguration.LogLevel = .none
        ) {
            artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MPVUI-DolbyVision-\(UUID().uuidString)")
            player = MPVPlayer(configuration: .init(
                autoPlay: false, startTime: startTime, playbackRate: playbackRate,
                hardwareDecoding: hardwareDecoding, videoOutput: videoOutput,
                hdrPolicy: .disabled, logLevel: logLevel,
                additionalOptions: ["ao": "null", "sid": "no", "osd-level": "0", "screenshot-sw": "no"]
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

        /// Opt-in inspection of the actual AVFoundation presentation. A layer
        /// bitmap or the unconverted YUV buffer cannot prove Dolby Vision colors.
        func holdNativeWindowForVisualValidationIfRequested() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard environment["MPVUI_HOLD_NATIVE_DV_WINDOW"] == "1" else { return }
            window.title = "MPVUI Native Dolby Vision Validation"
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApplication.shared.activate()
            if let path = environment["MPVUI_NATIVE_DV_READY_FILE"] {
                let marker = try JSONSerialization.data(withJSONObject: [
                    "title": window.title,
                    "windowNumber": window.windowNumber,
                    "processIdentifier": ProcessInfo.processInfo.processIdentifier,
                    "readyAt": Date().timeIntervalSince1970,
                ], options: [.sortedKeys])
                try marker.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            print(
                "DOLBY_VISION native window ready: title=\(window.title), window=\(window.windowNumber); holding 45 seconds for actual display inspection"
            )
            fflush(nil)
            try await Task.sleep(for: .seconds(45))
            #expect(player.videoOutput == .sampleBuffer)
            #expect(player.isPaused)
            #expect(player.lastError == nil)
        }

        func screenshot(named name: String) async throws -> CGImage {
            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
            let url = artifactDirectory.appendingPathComponent(name + ".png")
            for _ in 0 ..< 500 {
                if let frame = await player.renderedScreenshotForTesting()?.mapValue,
                   let width = frame["w"]?.integerValue,
                   let height = frame["h"]?.integerValue,
                   let stride = frame["stride"]?.integerValue,
                   case let .data(data) = frame["data"],
                   width > 0, height > 0, stride >= width * 4,
                   data.count >= stride * height
                {
                    try #require(frame["format"]?.stringValue == "bgr0")
                    let provider = try #require(CGDataProvider(data: data as CFData))
                    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
                    let image = try #require(CGImage(
                        width: Int(width), height: Int(height), bitsPerComponent: 8,
                        bitsPerPixel: 32, bytesPerRow: Int(stride), space: colorSpace,
                        bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                        ), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                    ))
                    try Self.write(image, to: url)
                    return image
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            print(
                "DOLBY_VISION screenshot timeout: state=\(player.state), position=\(player.position), duration=\(player.duration), error=\(String(describing: player.lastError)), media=\(player.mediaInformation)"
            )
            throw NSError(
                domain: "MPVUIDolbyVisionTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "GPU screenshot did not arrive: \(url.path)"]
            )
        }

        static func write(_ image: CGImage, to url: URL) throws {
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            try #require(CGImageDestinationFinalize(destination))
        }
    }
}
#endif
