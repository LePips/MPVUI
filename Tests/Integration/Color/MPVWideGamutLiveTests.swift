#if os(macOS)
import AppKit
import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration, .hdr), .serialized)
@MainActor
struct MPVWideGamutLiveTests {
    @Test
    func `calibrated ICC and LUT open the declared SDR renderer`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let icc = directory.appendingPathComponent("display.icc")
        let profile = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        try (#require(profile.copyICCData()) as Data).write(to: icc)
        let lut = directory.appendingPathComponent("identity.cube")
        try "LUT_3D_SIZE 2\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
            .write(to: lut, atomically: true, encoding: .utf8)
        for (mode, owner) in [
            (MPVColorManagement.DisplayProfile.calibratedICC(icc), MPVRenderColorStatus.ConversionOwner.libplaceboCalibratedICC),
            (.calibratedLUT(lut), .libplaceboCalibratedLUT),
        ] {
            let player = MPVPlayer(configuration: .init(
                autoPlay: false,
                colorManagement: .init(displayProfile: mode),
                hdrPolicy: .disabled
            ))
            let surface = MPVPlatformVideoPlayer(player: player)
            let window = makeWindow(surface)
            defer { surface.detach()
                window.contentView = nil
                window.orderOut(nil)
            }
            player.load(TestPaths.baselineMedia, autoPlay: false)
            try await eventually("live color configuration") {
                player.state == .paused && player.mediaInformation.hdr.output.pixelFormat != nil
            }
            #expect(player.renderColorStatus.conversionOwner == owner)
            #expect(player.renderColorStatus.fallbackReason == nil)
            #expect(player.mediaInformation.hdr.output.pixelFormat?.contains("8") == true)
            #expect(CFEqual(surface.metalLayer.colorspace, window.screen?.colorSpace?.cgColorSpace))
            #expect(player.lastError == nil)
        }
    }

    @Test
    func `initial SDR swapchain matches precision and gamut`() async throws {
        for policy in [MPVSDROutputPolicy.automatic, .compatibility8Bit] {
            let player = MPVPlayer(configuration: .init(autoPlay: false, hdrPolicy: .disabled, sdrOutput: policy))
            let surface = MPVPlatformVideoPlayer(player: player)
            surface.wideGamutOverrideForTesting = true
            surface.edrHeadroomOverrideForTesting = (current: 1, potential: 1)
            let window = makeWindow(surface)
            defer { surface.detach()
                window.contentView = nil
                window.orderOut(nil)
            }
            player.load(TestPaths.baselineMedia, autoPlay: false)
            try await eventually("live color configuration") {
                player.state == .paused && player.mediaInformation.hdr.output.pixelFormat != nil
            }
            let output = player.mediaInformation.hdr.output
            let expectedFloat = policy == .automatic
            #expect(player.mediaInformation.hdr.presentation.configuredDynamicRange == .sdr)
            #expect(player.renderColorStatus.precision == (expectedFloat ? .float16 : .unorm8))
            #expect(output.primaries == (expectedFloat ? "display-p3" : "bt.709"))
            #expect(
                output.pixelFormat?.contains(expectedFloat ? "16" : "8") == true,
                "Actual renderer output format: \(String(describing: output.pixelFormat))"
            )
            #expect(player.lastError == nil)
        }
    }

    @Test
    func `SDR gamut transition preserves paused decoder and position`() async throws {
        let player = MPVPlayer(configuration: .init(autoPlay: false, hdrPolicy: .disabled))
        let surface = MPVPlatformVideoPlayer(player: player)
        surface.wideGamutOverrideForTesting = true
        surface.edrHeadroomOverrideForTesting = (current: 1, potential: 1)
        let window = makeWindow(surface)
        defer { surface.detach()
            window.contentView = nil
            window.orderOut(nil)
        }
        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .milliseconds(400))
        try await eventually("live color configuration") { player.state == .paused && player.mediaInformation.hdr.output.pixelFormat != nil
        }
        let before = await player.lifecycleDiagnostics()
        surface.wideGamutOverrideForTesting = false
        surface.updateRenderingConfiguration()
        try await eventually("live color configuration") {
            player.renderColorStatus.precision == .unorm8 && player.mediaInformation.hdr.output.primaries == "bt.709"
        }
        let after = await player.lifecycleDiagnostics()
        #expect(after.handlesCreated == before.handlesCreated)
        #expect(after.handlesDestroyed == before.handlesDestroyed)
        #expect(after.loadCommands == before.loadCommands)
        #expect(after.liveColorUpdates > before.liveColorUpdates)
        #expect(player.state == .paused)
        #expect(abs(player.position.seconds - 0.4) < 0.15)
        #expect(surface.metalLayer.pixelFormat == .bgra8Unorm)
        #expect(player.mediaInformation.hdr.output.pixelFormat?.contains("8") == true)
        #expect(player.lastError == nil)
        // Reverse the contract on the same decoder to exercise swapchain reuse.
        surface.wideGamutOverrideForTesting = true
        surface.updateRenderingConfiguration()
        try await eventually("live color configuration") {
            player.renderColorStatus.precision == .float16 && player.mediaInformation.hdr.output.primaries == "display-p3"
        }
        #expect(player.mediaInformation.hdr.output.pixelFormat?.contains("16") == true)
        #expect(await player.lifecycleDiagnostics().handlesCreated == before.handlesCreated)
    }

    private func makeWindow(_ surface: MPVPlatformVideoPlayer) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = surface
        window.orderFront(nil)
        surface.layoutSubtreeIfNeeded()
        surface.activateRenderingSurface()
        return window
    }
}
#endif
