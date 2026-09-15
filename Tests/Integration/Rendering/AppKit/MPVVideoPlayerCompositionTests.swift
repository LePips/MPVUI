#if os(macOS)
import AppKit
@testable import MPVUI
import SwiftUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVVideoPlayerCompositionTests {
    @Test
    func `repeated overlay modifiers present only the latest content`() async throws {
        let player = MPVPlayer(configuration: .init(autoPlay: false, videoOutput: .sampleBuffer))
        var appeared: [String] = []
        let view = MPVVideoPlayer(player: player)
            .videoOverlay { Text("First").onAppear { appeared.append("first") } }
            .videoOverlay(alignment: .bottom) { Text("Second").onAppear { appeared.append("second") } }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer {
            findSurface(in: host)?.detach()
            window.orderOut(nil)
            window.contentView = nil
        }
        try await eventually("latest overlay mounted") { appeared.contains("second") }
        #expect(!appeared.contains("first"))
        let surface = try #require(findSurface(in: host))
        #expect(surface.player === player)
        #expect(surface.videoOverlayHost != nil)
    }

    @Test
    func `replacing the SwiftUI player transfers rendering ownership to the new player`() async throws {
        let first = MPVPlayer(configuration: .init(autoPlay: false, videoOutput: .sampleBuffer))
        let second = MPVPlayer(configuration: .init(autoPlay: false, videoOutput: .sampleBuffer))
        let host = NSHostingView(rootView: MPVVideoPlayer(player: first))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer {
            findSurface(in: host)?.detach()
            window.orderOut(nil)
            window.contentView = nil
        }
        try await eventually("first player attached") { first.hasActiveRenderSurface }
        host.rootView = MPVVideoPlayer(player: second)
        host.layoutSubtreeIfNeeded()
        try await eventually("replacement player attached") {
            second.hasActiveRenderSurface && !first.hasActiveRenderSurface
        }
        let surface = try #require(findSurface(in: host))
        #expect(surface.player === second)
        #expect(surface.videoOverlayHost == nil)
    }

    private func findSurface(in view: NSView) -> MPVPlatformVideoPlayer? {
        if let surface = view as? MPVPlatformVideoPlayer {
            return surface
        }
        return view.subviews.lazy.compactMap { findSurface(in: $0) }.first
    }
}
#endif
