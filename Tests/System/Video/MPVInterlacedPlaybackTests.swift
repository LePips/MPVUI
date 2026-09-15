#if os(macOS)
import AppKit
import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.system), .serialized)
@MainActor
struct MPVInterlacedPlaybackTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MPVUI_RUN_INTERLACE_VALIDATION"] == "1"))
    func `automatic deinterlacing retains field cadence`() async throws {
        let cases: [(String, Double, MPVDeinterlacePolicy)] = [
            ("480i-bottom-59.94", 60000.0 / 1001, .init(mode: .automatic)),
            ("576i-top-50", 50, .init(mode: .automatic)),
            ("1080i-top-59.94", 60000.0 / 1001, .init(mode: .automatic)),
            ("576i-top-50", 50, .init(mode: .forced, algorithm: .yadif, fieldOrder: .topFirst)),
        ]
        for (name, expectedCadence, policy) in cases {
            let source = try TestPaths.testMedia(name + ".mkv")
            let player = MPVPlayer(configuration: .init(
                hardwareDecoding: .disabled, hdrPolicy: .disabled, deinterlace: policy
            ))
            let surface = MPVPlatformVideoPlayer(player: player)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = surface
            surface.layoutSubtreeIfNeeded()
            surface.activateRenderingSurface()
            player.load(source)
            for _ in 0 ..< 120 {
                if let fps = player.playbackDiagnostics.estimatedFilterFramesPerSecond,
                   abs(fps - expectedCadence) < 0.4
                {
                    break
                }
                if player.lastError != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let status = player.playbackDiagnostics
            #expect(player.lastError == nil)
            #expect(abs((status.estimatedFilterFramesPerSecond ?? 0) - expectedCadence) < 0.4)
            #expect(status.deinterlace.requiresSoftwareFrames == true)
            if policy.algorithm == .automatic {
                #expect(status.deinterlace.isActive == true)
            }
            #expect(status.estimatedDecodedFramesPerSecond == nil)
            player.stop()
            surface.detach()
            window.contentView = nil
        }
    }
}
#endif
