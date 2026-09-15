#if os(macOS)
import AppKit
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVPlaybackDiagnosticsIntegrationTests {
    @Test
    func `decoder diagnostics follow their player when the first player closes`() async throws {
        var first: DiagnosticHost? = DiagnosticHost(hardwareDecoding: .disabled)
        first?.player.load(TestPaths.baselineMedia, autoPlay: false)
        for _ in 0 ..< 120 {
            if first?.player.playbackDiagnostics.decoder.session == .software {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(first?.player.playbackDiagnostics.decoder.session == .software)
        let second = DiagnosticHost(hardwareDecoding: .videoToolbox)
        defer {
            first?.close()
            second.close()
        }
        second.player.load(TestPaths.baselineMedia, autoPlay: false)
        for _ in 0 ..< 120 {
            if second.player.playbackDiagnostics.decoder.videoToolboxSessionUsesHardware != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(second.player.playbackDiagnostics.decoder.selectedDecoder == "videotoolbox")
        #expect(second.player.playbackDiagnostics.decoder.videoToolboxSessionUsesHardware != nil)
        #expect(first?.player.playbackDiagnostics.decoder.session == .software)
        #expect(first?.player.playbackDiagnostics.decoder.videoToolboxSessionUsesHardware == nil)

        // Destroy the first mpv instance while the second decoder is registered.
        // A process-global FFmpeg logger would now lose the second player's logs.
        first?.close()
        first = nil
        second.player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .milliseconds(300))
        #expect(second.player.playbackDiagnostics.decoder.videoToolboxSessionUsesHardware == nil)
        for _ in 0 ..< 120 {
            if second.player.playbackDiagnostics.decoder.videoToolboxSessionUsesHardware != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(second.player.playbackDiagnostics.decoder.selectedDecoder == "videotoolbox")
        #expect(second.player.playbackDiagnostics.decoder.videoToolboxSessionUsesHardware != nil)
        #expect(second.player.lastError == nil)
        second.player.seek(to: .milliseconds(700))
        for _ in 0 ..< 100 {
            if second.player.playbackDiagnostics.seekLatencySeconds != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(second.player.playbackDiagnostics.seekLatencySeconds != nil)
        #expect(second.player.isPaused)
    }

    @Test(arguments: [MPVPlayerConfiguration.HardwareDecoding.disabled, .videoToolbox])
    func `native statistics and decoder session`(hardwareDecoding: MPVPlayerConfiguration.HardwareDecoding) async throws {
        let player = MPVPlayer(configuration: .init(
            autoPlay: false, hardwareDecoding: hardwareDecoding,
            videoOutput: .sampleBuffer, logLevel: .none, additionalOptions: ["ao": "null"]
        ))
        let surface = MPVPlatformVideoPlayer(player: player)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
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
        player.load(TestPaths.baselineMedia, autoPlay: false)
        for _ in 0 ..< 120 {
            if let statistics = player.playbackDiagnostics.nativeOutputStatistics,
               (statistics.sampleBuildCount ?? 0) > 0,
               hardwareDecoding == .disabled || player.playbackDiagnostics.decoder.videoToolboxSessionUsesHardware != nil
            {
                break
            }
            if player.lastError != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let observed = player.playbackDiagnostics
        let statistics = try #require(observed.nativeOutputStatistics)
        #expect((statistics.sampleBuildCount ?? 0) > 0)
        #expect((statistics.totalSampleBuildNanoseconds ?? 0) > 0)
        #expect(observed.freshRenderPasses == nil)
        #expect(observed.frameCopyCount == nil)
        #expect(observed.startLatencySeconds != nil)
        if hardwareDecoding == .disabled {
            #expect((statistics.pixelBufferCopies ?? 0) > 0)
            #expect(observed.decoder.session == .software)
            #expect(observed.decoder.videoToolboxSessionUsesHardware == nil)
        } else {
            #expect(observed.decoder.selectedDecoder == "videotoolbox")
            // True/false are both valid session outcomes. The point is that a
            // codec-level probe or selected API cannot fabricate this readback.
            #expect(observed.decoder.videoToolboxSessionUsesHardware != nil)
        }
        player.seek(to: .milliseconds(500))
        for _ in 0 ..< 100 {
            if player.playbackDiagnostics.seekLatencySeconds != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(player.playbackDiagnostics.seekLatencySeconds != nil)
        #expect(player.isPaused)
        #expect(player.lastError == nil)
    }

    @MainActor
    private final class DiagnosticHost {
        let player: MPVPlayer
        let surface: MPVPlatformVideoPlayer
        let window: NSWindow

        init(hardwareDecoding: MPVPlayerConfiguration.HardwareDecoding) {
            player = MPVPlayer(configuration: .init(
                autoPlay: false, hardwareDecoding: hardwareDecoding,
                videoOutput: .sampleBuffer, logLevel: .none, additionalOptions: ["ao": "null"]
            ))
            surface = MPVPlatformVideoPlayer(player: player)
            window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = surface
            surface.layoutSubtreeIfNeeded()
            surface.activateRenderingSurface()
        }

        func close() {
            player.stop()
            surface.detach()
            window.contentView = nil
        }
    }
}
#endif
