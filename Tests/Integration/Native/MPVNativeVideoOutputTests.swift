import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import MPVUI
import Testing

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Exercises actual decoded native frames and the VO's clock. System PiP and
/// background GPU permissions still require separate device validation.
@Suite(.tags(.integration, .nativePatch), .serialized)
struct MPVNativeVideoOutputTests {
    @MainActor @Test
    func `animated WebP reaches the Apple sample buffer output`() async throws {
        let fixture = PlaybackFixture(configuration: .init(
            autoPlay: false, hardwareDecoding: .disabled, videoOutput: .sampleBuffer,
            additionalOptions: ["ao": "null", "keep-open": "yes"]
        ))
        defer { fixture.close() }
        try fixture.player.load(TestPaths.testMedia("webp-animation.webp"), autoPlay: true)
        try await eventually("WebP animation rendered by AVFoundation") {
            fixture.player.position.seconds >= 0.75
                && fixture.player.sampleBufferDisplayLayer.isReadyForDisplay
        }
        #expect(fixture.player.lastError == nil)
        #expect(fixture.player.sampleBufferDisplayLayer.sampleBufferRenderer.status != .failed)
    }

    @MainActor
    @Test(arguments: [MPVPlayerConfiguration.HardwareDecoding.disabled, .videoToolbox])
    func `native frames and seek`(hardwareDecoding: MPVPlayerConfiguration.HardwareDecoding) async throws {
        let player = MPVPlayer(configuration: .init(
            autoPlay: false, hardwareDecoding: hardwareDecoding,
            videoOutput: .sampleBuffer, additionalOptions: ["ao": "null"]
        ))
        let surface = MPVPlatformVideoPlayer(player: player)
        #if os(macOS)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = surface
        window.orderFront(nil)
        #else
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let host = UIViewController()
        host.view.addSubview(surface)
        surface.frame = window.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        #endif
        surface.activateRenderingSurface()
        defer {
            player.stop()
            surface.detach()
            #if os(macOS)
            window.orderOut(nil)
            window.contentView = nil
            #else
            window.isHidden = true
            window.rootViewController = nil
            #endif
        }

        let layer = player.sampleBufferDisplayLayer
        player.load(TestPaths.baselineMedia, autoPlay: false)
        try await waitUntil(
            "initial paused frame; state=\(player.state), bounds=\(surface.bounds), ready=\(layer.isReadyForDisplay), status=\(layer.sampleBufferRenderer.status.rawValue), error=\(String(describing: layer.sampleBufferRenderer.error))"
        ) {
            guard player.state == .paused, layer.isReadyForDisplay,
                  let clock = layer.controlTimebase, CMTimebaseGetRate(clock) == 0
            else { return false }
            #if targetEnvironment(simulator)
            return true
            #else
            return layer.sampleBufferRenderer.displayedPixelBuffer() != nil
            #endif
        }
        // This unhosted simulator runner reports image readiness but does not
        // expose its pixels. Inspect allocation on macOS/device; verify the
        // native clock and transport in all runners.
        #if !targetEnvironment(simulator)
        let buffer = try #require(layer.sampleBufferRenderer.displayedPixelBuffer())
        #expect(CVPixelBufferGetWidth(buffer) > 0)
        #expect(CVPixelBufferGetHeight(buffer) > 0)
        #expect(CVPixelBufferGetIOSurface(buffer) != nil)
        #endif
        #expect(layer.sampleBufferRenderer.status != .failed)
        #expect(player.lastError == nil)
        #if !targetEnvironment(simulator)
        if hardwareDecoding == .videoToolbox {
            #expect(player.mediaInformation.hardwareDecoder == "videotoolbox")
        }
        #endif
        let timebase = try #require(layer.controlTimebase)
        #expect(abs(CMTimebaseGetTime(timebase).seconds - player.position.seconds) < 0.3)
        #expect(CMTimebaseGetRate(timebase) == 0)

        let lifecycle = await player.lifecycleDiagnostics()
        // Repeated direction changes exercise reset/draw ordering while paused.
        for destination in (0 ..< 5).flatMap({ _ in [0.6, 1.2, 0.3] }) {
            #expect(await player.seekForPictureInPicture(to: .seconds(destination)))
            try await waitUntil(
                "seek clock \(destination); clock=\(CMTimebaseGetTime(timebase).seconds), "
                    + "position=\(player.position.seconds), rate=\(CMTimebaseGetRate(timebase)), "
                    + "state=\(player.state), ready=\(layer.isReadyForDisplay)"
            ) { abs(CMTimebaseGetTime(timebase).seconds - destination) < 0.15 }
            #expect(player.isPaused)
            #expect(CMTimebaseGetRate(timebase) == 0)
        }

        // Retiring the inline view must not tear down or reload the native VO.
        surface.detach()
        #expect(layer.superlayer == nil)
        player.play()
        try await waitUntil("detached playback") { player.state == .playing && CMTimebaseGetRate(timebase) > 0 }
        player.pause()
        try await waitUntil("detached pause") { player.isPaused && CMTimebaseGetRate(timebase) == 0 }
        surface.activateRenderingSurface()
        #expect(player.sampleBufferDisplayLayer === layer)
        let after = await player.lifecycleDiagnostics()
        #expect(after.handlesCreated == lifecycle.handlesCreated)
        #expect(after.handlesDestroyed == lifecycle.handlesDestroyed)
        #expect(after.loadCommands == lifecycle.loadCommands)
        #expect(player.lastError == nil)
    }

    @MainActor
    private func waitUntil(_ context: @autoclosure () -> String, _ predicate: () -> Bool) async throws {
        for _ in 0 ..< 250 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "Native video output timed out: \(context())")
    }
}
