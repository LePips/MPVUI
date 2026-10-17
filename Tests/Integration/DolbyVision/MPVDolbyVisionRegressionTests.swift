#if os(macOS)
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
@testable import MPVCore
@testable import MPVUI
import SwiftUI
import Testing
import VideoToolbox

/// Generated Profile 5 and 8 media covers output decisions; the optional
/// Profile 5 chart covers colors. Buffer delivery alone cannot validate Dolby
/// Vision: unvalidated Profile 5 frames must never reach AVFoundation, where
/// they appear pink/green/purple.
@Suite(.tags(.integration, .dolbyVision), .serialized)
struct MPVDolbyVisionRegressionTests {

    /// Generated Profile 5 media covers the output contract. The optional chart
    /// also allows visual inspection of native presentation.
    struct Profile5Clip: CustomTestStringConvertible {

        static var available: [Self] {
            [Self(isChart: false)] + (TestPaths.hasDolbyVisionChart ? [Self(isChart: true)] : [])
        }

        let isChart: Bool

        var testDescription: String {
            isChart ? "chart" : "generated"
        }

        var startTime: Duration {
            isChart ? .seconds(25) : .seconds(1.25)
        }

        func url() throws -> URL {
            isChart ? TestPaths.dolbyVisionChart : try TestPaths.testMedia("dolby-vision-p5.mp4")
        }
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
            artifactDirectory = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("MPVUI-DolbyVision-\(UUID().uuidString)")
            player = MPVPlayer(configuration: .init(
                additionalOptions: ["ao": "null", "sid": "no", "osd-level": "0", "screenshot-sw": "no"],
                autoPlay: false,
                hardwareDecoding: hardwareDecoding,
                hdrPolicy: .disabled,
                logLevel: logLevel,
                playbackRate: playbackRate,
                startTime: startTime,
                videoOutput: videoOutput
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

        static func write(_ image: CGImage, to url: URL) throws {
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            try #require(CGImageDestinationFinalize(destination))
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
                """
                DOLBY_VISION native window ready: title=\(window.title), window=\(window.windowNumber); holding 45 seconds for actual \
                display inspection
                """
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
                        width: Int(width),
                        height: Int(height),
                        bitsPerComponent: 8,
                        bitsPerPixel: 32,
                        bytesPerRow: Int(stride),
                        space: colorSpace,
                        bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                        ),
                        provider: provider,
                        decode: nil,
                        shouldInterpolate: false,
                        intent: .defaultIntent
                    ))
                    try Self.write(image, to: url)
                    return image
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            print(
                """
                DOLBY_VISION screenshot timeout: state=\(player.state), position=\(player.position), duration=\(player.duration), \
                error=\(String(describing: player.lastError)), media=\(player.mediaInformation)
                """
            )
            throw NSError(
                domain: "MPVUIDolbyVisionTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "GPU screenshot did not arrive: \(url.path)"]
            )
        }
    }

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
    @Test(arguments: Profile5Clip.available)
    func `hardware profile 5 requires a validated session or reports native failure`(clip: Profile5Clip) async throws {
        let host = Host(hardwareDecoding: .videoToolbox, startTime: clip.startTime, logLevel: .debug)
        defer { host.close() }
        let player = host.player
        let layer = player.sampleBufferDisplayLayer
        try player.load(clip.url())
        try await eventually("hardware Profile 5 output decision") {
            if case .failed(.nativeVideoOutputUnavailable) = player.state {
                return true
            }
            return player.state == .paused && layer.sampleBufferRenderer.displayedPixelBuffer() != nil
        }

        #expect(player.isPaused)
        #expect(abs(player.position.seconds - clip.startTime.seconds) < 0.15)
        #expect(player.videoOutput == .sampleBuffer)
        if player.lastError == nil {
            let buffer = try #require(layer.sampleBufferRenderer.displayedPixelBuffer())
            let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] ?? [:]
            let internalAttachments = CVBufferCopyAttachments(buffer, .shouldNotPropagate) as? [String: Any] ?? [:]
            print(
                """
                DOLBY_VISION native readback: format=\(CVPixelBufferGetPixelFormatType(buffer)), \
                propagated=\(attachments.keys.sorted()), nonpropagated=\(internalAttachments.keys.sorted()), RPU \
                bytes=\((attachments["DolbyVisionRPUData"] as? Data)?.count ?? 0)
                """
            )
            // The native VO requires its private decoder-session marker before
            // enqueue. AVFoundation drops that private key from readback, while
            // retaining the per-frame Dolby Vision data used for presentation.

            let rpu = try #require(attachments["DolbyVisionRPUData"] as? Data)
            try #require(!rpu.isEmpty)

            #expect(player.mediaInformation.hardwareDecoder == "videotoolbox")
            #expect(layer.sampleBufferRenderer.status == .rendering)
            let overlay = ImageRenderer(content: Color.white
                .frame(width: 32, height: 32))

            let bitmap = try #require(overlay.cgImage.flatMap(MPVVideoOverlayBitmap.init))
            #expect(
                await player.setPictureInPictureOverlay(bitmap) == false,
                "The overlay API must not claim composition on unchanged Dolby Vision RPU frames."
            )
            print(
                """
                DOLBY_VISION hardware: validated native session, RPU bytes=\(rpu.count), \
                format=\(CVPixelBufferGetPixelFormatType(buffer)), attachments=\(attachments.keys.sorted())
                """
            )
            if clip.isChart {
                try await host.holdNativeWindowForVisualValidationIfRequested()
            }
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
        // Exercise both a fresh client and replacements of actively playing media.
        // Keep logging disabled: forwarding debug messages changes load timing.
        for _ in 0 ..< 5 {
            try player.load(TestPaths.testMedia(name), autoPlay: false, startTime: .seconds(1.25))
            try await eventually("native Profile 8 frame after a keyframe seek in \(name)") {
                player.lastError != nil
                    || player.state == .paused && layer.sampleBufferRenderer.displayedPixelBuffer() != nil
                    && abs(player.position.seconds - 1.25) < 0.05
                    && layer.controlTimebase.map {
                        CMTimebaseGetRate($0) == 0 && abs(CMTimebaseGetTime($0).seconds - 1.25) < 0.05
                    } == true
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
    }

    @MainActor
    @Test(.enabled(if: TestPaths.hasDolbyVisionChart, "Add the optional Profile 5 chart; see Documentation/TEST_MEDIA.md."))
    func `explicit Metal software colors match known chart patches`() async throws {
        let host = Host(hardwareDecoding: .disabled, videoOutput: .metal, startTime: .seconds(25))
        defer { host.close() }
        host.player.load(TestPaths.dolbyVisionChart)
        try await eventually("explicit Metal color frame") { host.player.state == .paused }
        let image = try await host.screenshot(named: "explicit-metal")
        let actual = try pixels(image)

        #expect(actual.meanBrightness > 0.02, "A black screenshot cannot validate color.")
        expectChartColors(actual)

        #expect(host.player.lastError == nil)
    }

    private func expectChartColors(_ actual: Pixels) {
        // At 25 seconds, the 1920x1080 chart has red/green/blue patch centers at
        // (182, 470), (439, 470), (696, 470). Sample inside each patch after the
        // 160x90 readback. Channel dominance rejects an IPT-as-YUV color cast
        // even if both renderers regress together, without fixing a tone map.
        for (channel, x) in [12 ..< 18, 33 ..< 39, 55 ..< 61].enumerated() {
            let color = actual.meanRGB(x: x, y: 36 ..< 42)

            #expect(color[channel] > 0.2, "Chart primary must be visible: \(color)")
            for other in 0 ..< 3 where other != channel {
                #expect(color[channel] > color[other] * 2, "Chart primary has the wrong hue: \(color)")
            }
        }
    }

    private func pixels(_ image: CGImage) throws -> Pixels {
        let width = 160
        let height = 90
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(rgba: bytes)
    }
}
#endif
