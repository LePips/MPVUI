import AVFoundation
import CoreMedia
import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing
import VideoToolbox
#if os(tvOS)
import AVKit
#endif

/// Uses the generated 23.976 fps Profile 8.4 clip. MPVUI_DISPLAY_MATCHING_FIXTURE
/// may instead name a local path or an HTTP URL for another 23.976 fps
/// native-supported Dolby Vision HEVC clip. HDMI mode and the TV's Dolby Vision
/// indicator still require physical checks.
@Suite(.tags(.system, .dolbyVision), .serialized)
@MainActor
struct MPVDisplayMatchingPlaybackTests {

    @Test(.enabled(
        if: VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC),
        "Requires a hardware Dolby Vision HEVC decoder."
    ))

    func `native reference playback produces Dolby Vision and fractional cadence criteria`() async throws {
        let url: URL = switch ProcessInfo.processInfo.environment["MPVUI_DISPLAY_MATCHING_FIXTURE"] {
        case let location? where location.hasPrefix("http"):
            try #require(URL(string: location))
        case let location?:
            URL(fileURLWithPath: location)
        case nil:
            try TestPaths.testMedia("dolby-vision-p84.mp4")
        }

        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null", "sid": "no"],
            automaticallyPlays: false,
            videoOutput: .sampleBuffer
        ))
        defer { fixture.close() }
        try await fixture.loadPaused(url)

        try await eventually("native Dolby Vision validation; fallback=\(fixture.player.lastError?.message ?? "none")") {
            fixture.player.dolbyVisionStatus.nativeValidation == .validated
        }

        let player = fixture.player

        let content = try #require(MPVDisplayMatchingContent(
            media: player.mediaInformation,
            outputUsesHDR: true,
            videoOutput: player.videoOutput,
            dolbyVisionStatus: player.dolbyVisionStatus
        ))

        let format = try #require(content.makeFormatDescription())
        #expect(player.videoOutput == .sampleBuffer)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_DolbyVisionHEVC)
        #expect(content.refreshRate == Float(24000.0 / 1001))
        #expect(content.dolbyVision?.profile == player.dolbyVisionStatus.effectiveProfile)

        print(
            """
            DISPLAY_MATCHING_REFERENCE: fps=\(content.refreshRate) source=\(player.mediaInformation.hdr.source) \
            decoded=\(player.mediaInformation.hdr.decoded) native=\(player.dolbyVisionStatus) hint=\(format)
            """
        )
        #if os(tvOS)
        let manager = fixture.window.avDisplayManager

        print(
            """
            DISPLAY_MATCHING_TV: enabled=\(manager.isDisplayCriteriaMatchingEnabled) \
            switching=\(manager.isDisplayModeSwitchInProgress) criteria=\(String(describing: manager.preferredDisplayCriteria))
            """
        )

        if manager.isDisplayCriteriaMatchingEnabled {
            try await eventually("active surface submits native Dolby Vision TV criteria", timeout: .seconds(30)) {
                fixture.surface.displayMatchingContent == content && !manager.isDisplayModeSwitchInProgress
            }

            #expect(manager.preferredDisplayCriteria != nil)

            print(
                """
                DISPLAY_MATCHING_TV_SETTLED: fps=\(content.refreshRate) \
                DolbyVision=\(String(describing: fixture.surface.displayMatchingContent?.dolbyVision))
                """
            )

            fixture.surface.detach()

            #expect(manager.preferredDisplayCriteria == nil)
        }
        #endif
    }
}
