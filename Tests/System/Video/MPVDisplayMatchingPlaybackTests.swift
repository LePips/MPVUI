import AVFoundation
import CoreMedia
import Foundation
@testable import MPVUI
import Testing
#if os(tvOS)
import AVKit
#endif

/// Opt-in real media check. MPVUI_DISPLAY_MATCHING_FIXTURE accepts a local path
/// or an HTTP URL for a 23.976 fps native-supported Dolby Vision HEVC reference
/// clip. `bundle:filename` selects a clip bundled in a device test host.
/// HDMI mode and the TV's Dolby Vision indicator still require physical checks.
@Suite(.tags(.system, .dolbyVision), .serialized)
@MainActor
struct MPVDisplayMatchingPlaybackTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MPVUI_DISPLAY_MATCHING_FIXTURE"] != nil))
    func `native reference playback produces Dolby Vision and fractional cadence criteria`() async throws {
        let location = try #require(ProcessInfo.processInfo.environment["MPVUI_DISPLAY_MATCHING_FIXTURE"])
        let url: URL = if location.hasPrefix("bundle:") {
            try TestPaths.testMedia(String(location.dropFirst("bundle:".count)))
        } else if location.hasPrefix("http") {
            try #require(URL(string: location))
        } else {
            URL(fileURLWithPath: location)
        }
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null", "sid": "no"],
            autoPlay: false, videoOutput: .sampleBuffer
        ))
        defer { fixture.close() }
        try await fixture.loadPaused(url)
        try await eventually("native Dolby Vision validation; fallback=\(fixture.player.lastError?.localizedDescription ?? "none")") {
            fixture.player.dolbyVisionStatus.nativeValidation == .validated
        }
        let player = fixture.player
        let content = try #require(MPVDisplayMatchingContent(
            media: player.mediaInformation, outputUsesHDR: true,
            videoOutput: player.videoOutput, dolbyVisionStatus: player.dolbyVisionStatus
        ))
        let format = try #require(content.makeFormatDescription())
        #expect(player.videoOutput == .sampleBuffer)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_DolbyVisionHEVC)
        #expect(content.refreshRate == Float(24000.0 / 1001))
        #expect(content.dolbyVision?.profile == player.dolbyVisionStatus.effectiveProfile)
        print(
            "DISPLAY_MATCHING_REFERENCE: fps=\(content.refreshRate) source=\(player.mediaInformation.hdr.source) decoded=\(player.mediaInformation.hdr.decoded) native=\(player.dolbyVisionStatus) hint=\(format)"
        )
        #if os(tvOS)
        let manager = fixture.window.avDisplayManager
        print(
            "DISPLAY_MATCHING_TV: enabled=\(manager.isDisplayCriteriaMatchingEnabled) switching=\(manager.isDisplayModeSwitchInProgress) criteria=\(String(describing: manager.preferredDisplayCriteria))"
        )
        if manager.isDisplayCriteriaMatchingEnabled {
            try await eventually("active surface submits native Dolby Vision TV criteria", timeout: .seconds(30)) {
                fixture.surface.displayMatchingContent == content && !manager.isDisplayModeSwitchInProgress
            }
            #expect(manager.preferredDisplayCriteria != nil)
            print(
                "DISPLAY_MATCHING_TV_SETTLED: fps=\(content.refreshRate) DolbyVision=\(String(describing: fixture.surface.displayMatchingContent?.dolbyVision))"
            )
            fixture.surface.detach()
            #expect(manager.preferredDisplayCriteria == nil)
        }
        #endif
    }
}
