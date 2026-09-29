#if os(macOS)
@testable import MPVUI
import Testing

@Suite(.tags(.integration, .hdr), .serialized)
@MainActor
struct MPVEDRBlackLevelTests {
    @Test(arguments: ["01-h264-aac-baseline.mp4", "feature-hdr10.mkv", "feature-hlg.mkv"])
    func `EDR black survives live headroom changes and replay`(media: String) async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"], autoPlay: false,
            hdrPolicy: .always, videoOutput: .metal
        ))
        defer { fixture.close() }
        let player = fixture.player
        fixture.surface.edrHeadroomOverrideForTesting = (current: 4, potential: 4)
        fixture.surface.updateRenderingConfiguration()
        try await fixture.loadPaused(TestPaths.testMedia(media))
        try await eventually("linear EDR target") {
            player.mediaInformation.hdr.output.maximumLuminance == 812
        }
        let before = await player.lifecycleDiagnostics()
        #expect(player.mediaInformation.hdr.output.transferFunction == .linear)
        // mpv uses 1e-7 nits for infinite contrast; zero means unspecified.
        #expect(try #require(player.mediaInformation.hdr.output.minimumLuminance) < 0.000001)

        fixture.surface.edrHeadroomOverrideForTesting = (current: 2, potential: 4)
        fixture.surface.updateRenderingConfiguration()
        try await eventually("reduced EDR target") {
            player.mediaInformation.hdr.output.maximumLuminance == 406
        }
        #expect(try #require(player.mediaInformation.hdr.output.minimumLuminance) < 0.000001)

        // This bounded correction restores automatic contrast in SDR. Linear
        // SDR/calibrated output needs separate pixel and viewing validation.
        fixture.surface.edrHeadroomOverrideForTesting = (current: 1, potential: 1)
        fixture.surface.updateRenderingConfiguration()
        try await eventually("SDR contrast restored") {
            player.mediaInformation.hdr.presentation.configuredDynamicRange == .sdr
                && (player.mediaInformation.hdr.output.minimumLuminance ?? 0) > 0.001
        }
        fixture.surface.edrHeadroomOverrideForTesting = (current: 4, potential: 4)
        fixture.surface.updateRenderingConfiguration()
        try await eventually("EDR contrast restored") {
            player.mediaInformation.hdr.output.maximumLuminance == 812
        }
        #expect(try #require(player.mediaInformation.hdr.output.minimumLuminance) < 0.000001)
        let after = await player.lifecycleDiagnostics()
        #expect(after.handlesCreated == before.handlesCreated)
        #expect(after.loadCommands == before.loadCommands)
        #expect(player.state == .paused)

        player.stop()
        try await eventually("renderer stopped") { player.state == .stopped }
        try await fixture.loadPaused(TestPaths.testMedia(media))
        try await eventually("recreated EDR target") {
            player.mediaInformation.hdr.output.maximumLuminance == 812
        }
        #expect(try #require(player.mediaInformation.hdr.output.minimumLuminance) < 0.000001)
        #expect(player.lastError == nil)
    }
}
#endif
