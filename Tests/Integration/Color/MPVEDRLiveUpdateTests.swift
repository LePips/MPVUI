#if os(macOS)
import AppKit
@testable import MPVUI
import Testing

@Suite(.tags(.integration, .hdr), .serialized)
@MainActor
struct MPVEDRLiveUpdateTests {
    @Test
    func `constrained Metal HDR permits the requested compositor adaptation`() {
        guard #available(macOS 26.0, *) else { return }
        let player = MPVPlayer(configuration: .init(autoPlay: false, hdrPolicy: .constrained))
        let surface = MPVPlatformVideoPlayer(player: player)
        surface.configureMetalLayer(usesExtendedDynamicRange: true, scale: 1, outputHeadroom: 2)
        #expect(surface.metalLayer.preferredDynamicRange == .constrainedHigh)
        #expect(surface.metalLayer.toneMapMode == .ifSupported)
        surface.configureMetalLayer(usesExtendedDynamicRange: false, scale: 1, outputHeadroom: 1)
        #expect(surface.metalLayer.preferredDynamicRange == .standard)
        #expect(surface.metalLayer.toneMapMode == .never)
    }

    @Test
    func `native sample buffer layer receives the explicit dynamic range policy`() {
        guard #available(macOS 26.0, *) else { return }
        for policy in MPVPlayerConfiguration.HDRPolicy.allCases {
            let player = MPVPlayer(configuration: .init(
                autoPlay: false,
                hdrPolicy: policy,
                videoOutput: .sampleBuffer
            ))
            let surface = MPVPlatformVideoPlayer(player: player)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = surface
            surface.layoutSubtreeIfNeeded()
            surface.activateRenderingSurface()
            let expected: CALayer.DynamicRange = switch policy {
            case .automatic: .automatic
            case .always: .high
            case .disabled: .standard
            case .constrained: .constrainedHigh
            }
            #expect(player.sampleBufferDisplayLayer.preferredDynamicRange == expected)
            #expect(player.sampleBufferDisplayLayer.toneMapMode == .ifSupported)
            #expect(player.videoOutput == .sampleBuffer)
            surface.detach()
            window.contentView = nil
        }
    }

    @Test
    func `brightness changes use current headroom without reloading playback`() async throws {
        let player = MPVPlayer(configuration: .init(autoPlay: false, hdrPolicy: .always))
        let surface = MPVPlatformVideoPlayer(player: player)
        surface.edrHeadroomOverrideForTesting = (current: 2, potential: 8)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.activateRenderingSurface()
        defer {
            surface.detach()
            window.contentView = nil
        }
        for _ in 0 ..< 100 {
            if await player.lifecycleDiagnostics().handlesCreated > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .milliseconds(400))
        for _ in 0 ..< 100 {
            if player.state == .paused {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(player.state == .paused)
        let before = await player.lifecycleDiagnostics()
        try #require(before.handlesCreated == 1)
        let layer = surface.metalLayer
        if #available(macOS 26.0, *) {
            #expect(layer.contentsHeadroom == 2)
        }

        surface.edrHeadroomOverrideForTesting = (current: 1.5, potential: 8)
        surface.updateRenderingConfiguration()
        for _ in 0 ..< 100 {
            if await player.lifecycleDiagnostics().liveColorUpdates > before.liveColorUpdates {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let changed = await player.lifecycleDiagnostics()
        #expect(changed.liveColorUpdates > before.liveColorUpdates)
        #expect(changed.handlesCreated == before.handlesCreated)
        #expect(changed.handlesDestroyed == before.handlesDestroyed)
        #expect(changed.loadCommands == before.loadCommands)
        #expect(player.state == .paused)
        #expect(abs(player.position.seconds - 0.4) < 0.15)
        #expect(player.lastError == nil)
        #expect(surface.metalLayer === layer)
        if #available(macOS 26.0, *) {
            #expect(layer.contentsHeadroom == 1.5)
        }

        // Small fluctuations stay in the same quantization bucket.
        surface.edrHeadroomOverrideForTesting = (current: 1.504, potential: 8)
        surface.updateRenderingConfiguration()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await player.lifecycleDiagnostics().liveColorUpdates == changed.liveColorUpdates)
    }
}
#endif
