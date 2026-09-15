#if os(macOS)
import AppKit
@testable import MPVUI
import Testing

@Suite(.tags(.integration, .hdr), .serialized)
@MainActor
struct MPVIdleColorUpdateTests {
    @Test
    func `idle color changes configure the first frame without recreating the handle`() async throws {
        let player = MPVPlayer(configuration: .init(autoPlay: false, hdrPolicy: .disabled))
        let surface = MPVPlatformVideoPlayer(player: player)
        surface.wideGamutOverrideForTesting = false
        surface.edrHeadroomOverrideForTesting = (current: 1, potential: 1)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.activateRenderingSurface()
        defer {
            player.stop()
            surface.detach()
            window.contentView = nil
        }
        for _ in 0 ..< 100 {
            if await player.lifecycleDiagnostics().handlesCreated == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let before = await player.lifecycleDiagnostics()
        try #require(before.handlesCreated == 1)
        #expect(before.loadCommands == 0)
        #expect(surface.metalLayer.pixelFormat == .bgra8Unorm)
        surface.wideGamutOverrideForTesting = true
        surface.updateRenderingConfiguration()
        #expect(surface.metalLayer.pixelFormat == .rgba16Float)
        let changed = await player.lifecycleDiagnostics()
        #expect(changed.handlesCreated == 1)
        #expect(changed.loadCommands == 0)
        #expect(changed.liveColorUpdates > before.liveColorUpdates)
        #expect(player.lastError == nil)

        player.load(TestPaths.baselineMedia, autoPlay: false)
        for _ in 0 ..< 150 {
            if player.state == .paused, player.mediaInformation.hdr.output.pixelFormat != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(player.state == .paused)
        #expect(player.mediaInformation.hdr.output.primaries == "display-p3")
        #expect(player.mediaInformation.hdr.output.pixelFormat?.contains("16") == true)
        #expect(await player.lifecycleDiagnostics().handlesCreated == 1)
        #expect(player.lastError == nil)
        let outputSize = await player.renderOutputSize()
        #expect(outputSize?.width == Int(surface.metalLayer.drawableSize.width))
        #expect(outputSize?.height == Int(surface.metalLayer.drawableSize.height))
    }
}
#endif
