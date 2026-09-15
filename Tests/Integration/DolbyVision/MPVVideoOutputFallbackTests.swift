import AVFoundation
import Foundation
@testable import MPVUI
import Testing

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Exercise renderer replacement after the engine reports an unsupported
/// native frame. Real Dolby Vision capability tests cover that detection path.
@Suite(.tags(.integration, .dolbyVision), .serialized)
struct MPVVideoOutputFallbackTests {
    @MainActor
    @Test
    func `feature fallback reload preserves a real item with simulated native DV evidence`() async throws {
        let player = MPVPlayer(configuration: .init(
            autoPlay: false, hardwareDecoding: .disabled,
            videoOutput: .sampleBuffer, additionalOptions: ["ao": "null"]
        ))
        let host = Host(player: player)
        defer { host.close() }
        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(0.5))
        try await waitUntil("feature test native pause") {
            player.state == .paused && abs(player.position.seconds - 0.5) < 0.15
        }
        let before = await player.lifecycleDiagnostics()
        // Only the restriction evidence is simulated. This exercises an actual
        // native-to-Metal decoder reload; it does not validate Dolby Vision pixels.
        player.updateDolbyVisionStatus(MPVDolbyVisionStatus(sourceProfile: 5, nativeValidation: .validated))
        let result = player.requestVideoFeatures([.nativeSubtitles, .zoomAndPan], policy: .preferFeatures)
        #expect(result.outcome == .switchedToMetal)
        #expect(result.requiresReload)
        do {
            try await waitUntil("feature test Metal pause") {
                player.videoOutput == .metal && player.state == .paused
                    && abs(player.position.seconds - 0.5) < 0.15
            }
        } catch {
            await print(
                "Feature fallback: state=\(player.state) position=\(player.position) error=\(String(describing: player.lastError)) color=\(player.renderColorStatus) diagnostics=\(player.lifecycleDiagnostics())"
            )
            throw error
        }
        let after = await player.lifecycleDiagnostics()
        #expect(after.handlesCreated == before.handlesCreated + 1)
        #expect(after.loadCommands == before.loadCommands + 1)
        #expect(player.isPaused)
        #expect(player.lastError == nil)
        #expect(player.mediaInformation.sourceURL == TestPaths.baselineMedia)
    }

    @MainActor
    @Test
    func `display headroom updates retain the native handle and paused position`() async throws {
        let player = MPVPlayer(configuration: .init(
            autoPlay: false,
            hardwareDecoding: .disabled,
            videoOutput: .sampleBuffer,
            additionalOptions: ["ao": "null"]
        ))
        let host = Host(player: player)
        defer { host.close() }
        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(0.4))
        try await waitUntil("native video is paused") { player.state == .paused }
        let before = await player.lifecycleDiagnostics()
        for headroom in [4.0, 2.5, 1.0, 3.0] {
            player.updateSampleBufferOutput(
                displayCapabilities: MPVDisplayCapabilities(
                    hdrSupport: .supported,
                    currentEDRHeadroom: headroom,
                    potentialEDRHeadroom: 5
                ),
                configuredDynamicRange: .automatic
            )
        }
        let after = await player.lifecycleDiagnostics()
        #expect(after.handlesCreated == before.handlesCreated)
        #expect(after.handlesDestroyed == before.handlesDestroyed)
        #expect(after.loadCommands == before.loadCommands)
        #expect(after.seekCommands == before.seekCommands)
        #expect(abs(player.position.seconds - 0.4) < 0.15)
        #expect(player.isPaused)
        #expect(player.lastError == nil)
    }

    @MainActor
    @Test
    func `display switch suspends the clock and preserves a user pause during blackout`() async throws {
        let player = MPVPlayer(configuration: .init(
            hardwareDecoding: .disabled,
            videoOutput: .sampleBuffer,
            additionalOptions: ["ao": "null"]
        ))
        let host = Host(player: player)
        defer { host.close() }
        player.load(TestPaths.baselineMedia)
        try await waitUntil("native video is playing") {
            player.state == .playing && player.position > .milliseconds(100)
        }
        player.setDisplaySwitchInProgress(true)
        _ = await player.lifecycleDiagnostics()
        try await Task.sleep(for: .milliseconds(50))
        let position = player.position
        #expect(!player.isPaused)
        try await Task.sleep(for: .milliseconds(150))
        #expect(abs((player.position - position).seconds) < 0.05)
        player.pause()
        _ = await player.lifecycleDiagnostics()
        player.setDisplaySwitchInProgress(false)
        try await waitUntil("user pause survives display recovery") { player.state == .paused }
        #expect(player.isPaused)
        #expect(abs((player.position - position).seconds) < 0.05)
        player.play()
        try await waitUntil("playback resumes after user request") {
            player.position > position + .milliseconds(100)
        }
        #expect(player.lastError == nil)
    }

    @MainActor
    @Test
    func `unsupported native SDR policy selects Metal with a structured reason`() {
        let player = MPVPlayer(configuration: .init(
            autoPlay: false,
            videoOutput: .sampleBuffer,
            hdrPolicy: .sdr
        ))
        player.updateSampleBufferOutput(
            displayCapabilities: .unknown,
            configuredDynamicRange: .automatic,
            policyFallbackReason: .unsupportedPolicy
        )
        #expect(player.videoOutput == .metal)
        #expect(player.presentationFallbackReason == .unsupportedPolicy)
        #expect(player.configuration.hdrPolicy == .disabled)
    }

    @MainActor
    @Test
    func `fallback preserves paused playback and the next load restores native output`() async throws {
        let player = MPVPlayer(configuration: .init(
            autoPlay: false, hardwareDecoding: .disabled,
            videoOutput: .sampleBuffer, additionalOptions: ["ao": "null"]
        ))
        let host = Host(player: player)
        defer { host.close() }
        let pictureInPicture = player.pictureInPicture
        pictureInPicture.allowsAutomaticStartFromInline = true
        pictureInPicture.restoreUserInterface = { true }
        let displayLayer = player.sampleBufferDisplayLayer
        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(0.6))
        try await waitUntil("initial native pause") {
            player.state == .paused && displayLayer.isReadyForDisplay
                && abs(player.position.seconds - 0.6) < 0.15
        }
        let before = await player.lifecycleDiagnostics()

        player.handleNativeVideoOutputUnavailable("Test unsupported native color format")
        #expect(player.videoOutput == .metal)
        #expect(player.configuration.videoOutput == .sampleBuffer)
        #expect(player.videoOutputFallbackReason == "Test unsupported native color format")
        #expect(player.presentationFallbackReason == .nativeOutputUnavailable("Test unsupported native color format"))
        #expect(displayLayer.superlayer == nil)
        #expect(player.pictureInPicture === pictureInPicture)
        #expect(pictureInPicture.allowsAutomaticStartFromInline)
        #expect(await pictureInPicture.restoreUserInterface?() == true)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        #expect(!pictureInPicture.isSupported)
        #expect(!pictureInPicture.isPossible)
        #endif
        try await waitUntil("Metal resumes the paused source") {
            player.state == .paused && abs(player.position.seconds - 0.6) < 0.15
        }
        let metalSize = await player.renderOutputSize()
        #expect(metalSize?.width == Int(host.surface.metalLayer.drawableSize.width))
        #expect(metalSize?.height == Int(host.surface.metalLayer.drawableSize.height))
        #expect(player.isPaused)
        #expect(player.lastError == nil)
        let fallback = await player.lifecycleDiagnostics()
        #expect(fallback.handlesCreated == before.handlesCreated + 1)
        #expect(fallback.handlesDestroyed == before.handlesDestroyed + 1)
        #expect(fallback.loadCommands == before.loadCommands + 1)

        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(0.2))
        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.videoOutputFallbackReason == nil)
        #expect(player.presentationFallbackReason == nil)
        #expect(player.pictureInPicture === pictureInPicture)
        #expect(pictureInPicture.allowsAutomaticStartFromInline)
        try await waitUntil("next load returns to native playback") {
            player.state == .paused && displayLayer.superlayer === host.surface.metalLayer
                && displayLayer.isReadyForDisplay && abs(player.position.seconds - 0.2) < 0.15
        }
        let restored = await player.lifecycleDiagnostics()
        #expect(restored.handlesCreated == fallback.handlesCreated + 1)
        // Reattaching native output must never issue a load of the previous URL.
        #expect(restored.loadCommands == fallback.loadCommands + 1)
        #expect(player.lastError == nil)
    }

    @MainActor
    @Test
    func `next load after an unhosted fallback does not reopen the previous source`() async throws {
        let player = MPVPlayer(configuration: .init(
            autoPlay: false, hardwareDecoding: .disabled,
            videoOutput: .sampleBuffer, additionalOptions: ["ao": "null"]
        ))
        player.load(URL(fileURLWithPath: "/mpvui-previous-source-must-not-open.mp4"))
        player.handleNativeVideoOutputUnavailable("Test unavailable output before attachment")
        #expect(player.videoOutput == .metal)
        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(0.3))
        #expect(player.videoOutput == .sampleBuffer)
        let host = Host(player: player)
        defer { host.close() }
        try await waitUntil("only the new queued source loads") {
            player.state == .paused && player.sampleBufferDisplayLayer.isReadyForDisplay
        }
        let diagnostics = await player.lifecycleDiagnostics()
        #expect(diagnostics.handlesCreated == 1)
        #expect(diagnostics.loadCommands == 1)
        #expect(player.mediaInformation.sourceURL == TestPaths.baselineMedia)
        #expect(player.videoOutputFallbackReason == nil)
        #expect(player.lastError == nil)
    }

    @MainActor
    private func waitUntil(_ context: String, _ predicate: () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "Video output fallback timed out: \(context)")
    }

    @MainActor
    private final class Host {
        let player: MPVPlayer
        let surface: MPVPlatformVideoPlayer
        #if os(macOS)
        let window: NSWindow
        #else
        let window: UIWindow
        #endif

        init(player: MPVPlayer) {
            self.player = player
            surface = MPVPlatformVideoPlayer(player: player)
            #if os(macOS)
            window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = surface
            window.orderFront(nil)
            #else
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
            let controller = UIViewController()
            controller.view.addSubview(surface)
            surface.frame = window.bounds
            window.rootViewController = controller
            window.makeKeyAndVisible()
            surface.setNeedsLayout()
            surface.layoutIfNeeded()
            #endif
            surface.activateRenderingSurface()
        }

        func close() {
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
    }
}
