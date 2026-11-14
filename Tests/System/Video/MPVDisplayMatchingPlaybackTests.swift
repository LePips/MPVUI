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

    #if os(tvOS) && !targetEnvironment(simulator)
    @Test(arguments: ["baseline.mp4", "color-hdr10.mkv", "dolby-vision-p84.mp4"])
    func `ordinary autoplay settles the TV display before advancing`(file: String) async throws {
        let fixture = PlaybackFixture(configuration: .init(volume: 0))
        defer { fixture.close() }
        let player = fixture.player
        let manager = fixture.window.avDisplayManager
        var lastSwitch: ContinuousClock.Instant?
        let began = ContinuousClock.now
        try player.load(TestPaths.testMedia(file))
        try await eventually("autoplay begins", timeout: .seconds(25)) {
            if manager.isDisplayModeSwitchInProgress {
                lastSwitch = .now
            }
            return player.state == .playing || player.position > .milliseconds(150)
        }
        if manager.isDisplayCriteriaMatchingEnabled {
            #expect(manager.preferredDisplayCriteria != nil)
            #expect(!manager.isDisplayModeSwitchInProgress)
            if let lastSwitch {
                #expect(lastSwitch.duration(to: .now) >= .milliseconds(500))
            }
        }
        print(
            "Display autoplay \(file): matching=\(manager.isDisplayCriteriaMatchingEnabled) switched=\(lastSwitch != nil) start=\(began.duration(to: .now))"
        )
        try await eventually("autoplay advances") { !player.isPaused && player.position > .milliseconds(500) }
    }

    @Test(arguments: ["video-hevc-8bit.mkv", "color-hdr10.mkv", "dolby-vision-p84.mp4"])
    func `physical TV prepares paused media before the caller starts playback`(file: String) async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        let player = fixture.player
        try player.load(TestPaths.testMedia(file), playAutomatically: false)
        let began = ContinuousClock.now
        let result = await player.prepareDisplayMatching(timeout: .seconds(20))
        let manager = fixture.window.avDisplayManager
        let report: [String: Any] = [
            "fixture": file,
            "result": String(describing: result),
            "elapsedSeconds": began.duration(to: .now).seconds,
            "matchingEnabled": manager.isDisplayCriteriaMatchingEnabled,
            "switching": manager.isDisplayModeSwitchInProgress,
            "paused": player.isPaused,
            "positionSeconds": player.position.seconds,
            "refreshRate": fixture.surface.displayMatchingContent?.refreshRate as Any? ?? NSNull(),
            "dolbyVisionValidation": String(describing: player.dolbyVisionStatus.nativeValidation),
            "audioPorts": AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue),
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("DISPLAY_PREPARATION_RESULT: \(String(decoding: data, as: UTF8.self))")
        #expect(player.isPaused)
        #expect(player.position < .milliseconds(200))
        if manager.isDisplayCriteriaMatchingEnabled {
            #expect(result == .switchCompleted || result == .noSwitchObserved)
            #expect(manager.preferredDisplayCriteria != nil)
            #expect(!player.isDisplayModeSwitchInProgress)
        } else {
            #expect(result == .disabled)
        }
        player.play()
        try await eventually("physical playback resumes after preparation", timeout: .seconds(20)) {
            player.position > .milliseconds(500) && !player.isPaused
        }
        fixture.surface.detach()
        #expect(manager.preferredDisplayCriteria == nil)
    }
    #endif

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
