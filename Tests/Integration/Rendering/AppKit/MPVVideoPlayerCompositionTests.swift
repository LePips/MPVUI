#if os(macOS)
import AppKit
@testable import MPVCore
@testable import MPVUI
import SwiftUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVVideoPlayerCompositionTests {

    @Test
    func `repeated overlay modifiers present only the latest content`() async throws {
        let player = MPVPlayer(configuration: .init(automaticallyPlays: false, videoOutput: .sampleBuffer))
        var appeared: [String] = []

        let view = MPVVideoPlayer(player: player)
            .videoOverlay { Text("First")
                .onAppear { appeared.append("first") }
            }
            .videoOverlay(alignment: .bottom) { Text("Second")
                .onAppear { appeared.append("second") }
            }

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
        let first = MPVPlayer(configuration: .init(automaticallyPlays: false, videoOutput: .sampleBuffer))
        let second = MPVPlayer(configuration: .init(automaticallyPlays: false, videoOutput: .sampleBuffer))
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

    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases)
    func `track discovery controls surface attachment across media changes`(
        output: MPVPlayerConfiguration.VideoOutput
    ) async throws {
        let player = MPVPlayer(configuration: .init(
            additionalOptions: ["ao": "null"],
            automaticallyPlays: false,
            videoOutput: output
        ))

        let host = NSHostingView(rootView: TrackDrivenPlayerView(player: player))

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)

        defer {
            player.stop()
            findSurface(in: host)?.detach()
            window.orderOut(nil)
            window.contentView = nil
        }

        for media in ["audio-pcm-stereo.mka", "video-hevc-8bit.mkv", "audio-pcm-stereo.mka", "baseline.mp4"] {
            try player.load(TestPaths.testMedia(media))

            let hasVideo = media != "audio-pcm-stereo.mka"

            try await eventually("surface follows tracks for \(media)") {
                player.state == .paused
                    && player.hasActiveRenderSurface == hasVideo
                    && (findSurface(in: host) != nil) == hasVideo
                    && (player.mediaInformation.dimensions != nil) == hasVideo
            }

            #expect(player.lastError == nil)
            #expect(player.videoTracks.isEmpty == !hasVideo)
        }
    }

    private func findSurface(in view: NSView) -> MPVPlatformVideoPlayer? {
        if let surface = view as? MPVPlatformVideoPlayer {
            return surface
        }

        return view.subviews.lazy.compactMap { findSurface(in: $0) }.first
    }
}

@MainActor
private struct TrackDrivenPlayerView {

    let player: MPVPlayer
}

extension TrackDrivenPlayerView: View {

    var body: some View {
        if player.videoTracks.isEmpty {
            Image(systemName: "music.note")
        } else {
            MPVVideoPlayer(player: player)
        }
    }
}
#endif
