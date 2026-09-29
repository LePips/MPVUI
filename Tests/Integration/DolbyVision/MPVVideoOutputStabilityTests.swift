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
struct MPVVideoOutputStabilityTests {
    @MainActor
    @Test
    func `display headroom updates retain the native handle and paused position`() async throws {
        let player = MPVPlayer(configuration: .init(
            additionalOptions: ["ao": "null"],
            autoPlay: false,
            hardwareDecoding: .disabled,
            videoOutput: .sampleBuffer
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
            additionalOptions: ["ao": "null"],
            hardwareDecoding: .disabled,
            videoOutput: .sampleBuffer
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
    private func waitUntil(_ context: String, _ predicate: () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "Video output timed out: \(context)")
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
