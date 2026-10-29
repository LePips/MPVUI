import AVFoundation
import CoreVideo
import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing
import VideoToolbox

@Suite(.tags(.integration, .dolbyVision), .serialized)
struct MPVDolbyVisionRemuxTests {

    @MainActor
    @Test(
        .enabled(
            if: VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC),
            "Requires a hardware Dolby Vision HEVC decoder."
        ),
        arguments: [
            ("dolby-vision-p5.mp4", 5, 0),
            ("dolby-vision-p5-untagged.mp4", 5, 0),
            ("dolby-vision-p7.mp4", 7, 1),
            ("dolby-vision-p7-untagged.mp4", 7, 1),
            ("dolby-vision-p81.mp4", 8, 1),
            ("dolby-vision-p81-untagged.mp4", 8, 1),
            ("dolby-vision-p84.mp4", 8, 4),
            ("dolby-vision-p84-untagged.mp4", 8, 4),
        ]
    )

    func `remuxed video preserves native Dolby Vision playback`(name: String, sourceProfile: Int, compatibility: Int) async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"],
            automaticallyPlays: false,
            dolbyVisionPolicy: sourceProfile == 7 ? .profile7Compatibility : .strict,
            hardwareDecoding: .videoToolbox,
            logLevel: .debug,
            videoOutput: .sampleBuffer
        ))
        defer { fixture.close() }

        let player = fixture.player

        player.logHandler = { message in
            if [.fatal, .error, .warning].contains(message.level)
                || message.message.contains("Dolby Vision")
            {
                print("DOVI_REMUX [\(message.prefix)] \(message.message)")
            }
        }

        let layer = player.sampleBufferDisplayLayer

        for position in [0.25, 1.25] {
            try player.load(TestPaths.testMedia(name), playAutomatically: false, startTime: .seconds(position))

            try await eventually("native remuxed frame in \(name)") {
                player.lastError != nil || player.state == .paused
                    && layer.sampleBufferRenderer.displayedPixelBuffer() != nil
                    && abs(player.position.seconds - position) < 0.1
            }

            try #require(player.lastError == nil, "\(String(describing: player.lastError))")

            let buffer = try #require(layer.sampleBufferRenderer.displayedPixelBuffer())
            let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] ?? [:]
            #expect((attachments["DolbyVisionRPUData"] as? Data)?.isEmpty == false)
            #expect(player.mediaInformation.hardwareDecoder == "videotoolbox")
            #expect(player.videoOutput == .sampleBuffer)

            try await eventually("validated Dolby Vision profile") {
                player.dolbyVisionStatus.nativeValidation == .validated
            }

            #expect(player.dolbyVisionStatus.effectiveProfile == (sourceProfile == 7 ? 8 : sourceProfile))
            #expect(player.dolbyVisionStatus.effectiveBaseLayerCompatibilityID == compatibility)
            #expect(player.dolbyVisionStatus.conversion == (sourceProfile == 7 ? .converted : .notRequested))
            #expect(player.dolbyVisionStatus.enhancementLayer == (sourceProfile == 7 ? .discarded : .unknown))
            player.play()

            try await eventually("remuxed playback advances") {
                player.lastError != nil || player.position.seconds > position + 0.3
            }

            try #require(player.lastError == nil)
        }

        // A later HDR10 item must not inherit the recovered Dolby Vision session.
        try player.load(TestPaths.testMedia("color-hdr10.mkv"), playAutomatically: false, startTime: .seconds(1))

        try await eventually("ordinary HDR10 after Dolby Vision") {
            if player.lastError != nil {
                return true
            }

            guard player.state == .paused,
                  abs(player.position.seconds - 1) < 0.1,
                  let buffer = layer.sampleBufferRenderer.displayedPixelBuffer()
            else { return false }

            // Playback state can arrive before AVFoundation presents the new item.
            return CVBufferCopyAttachment(buffer, "DolbyVisionRPUData" as CFString, nil) == nil
        }

        try #require(player.lastError == nil)

        let buffer = try #require(layer.sampleBufferRenderer.displayedPixelBuffer())
        #expect(CVBufferCopyAttachment(buffer, "DolbyVisionRPUData" as CFString, nil) == nil)

        try await eventually("Dolby Vision status cleared for HDR10") {
            player.dolbyVisionStatus.nativeValidation == .unknown && player.dolbyVisionStatus.effectiveProfile == nil
        }

        #expect(player.dolbyVisionStatus.nativeValidation == .unknown)
        #expect(player.dolbyVisionStatus.effectiveProfile == nil)
    }

    @MainActor
    @Test(
        .enabled(
            if: VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC),
            "Requires a hardware Dolby Vision HEVC decoder."
        ),
        arguments: [
            ("dolby-vision-p7.mp4", MPVDolbyVisionPolicy.strict),
            ("dolby-vision-p7-untagged.mp4", .strict),
            ("dolby-vision-p7-invalid-base.mp4", .strict),
            ("dolby-vision-p7-invalid-base.mp4", .profile7Compatibility),
        ]
    )

    func `Profile 7 requires valid HDR10 base and explicit compatibility policy`(name: String, policy: MPVDolbyVisionPolicy) async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"],
            automaticallyPlays: false,
            dolbyVisionPolicy: policy,
            hardwareDecoding: .videoToolbox,
            videoOutput: .sampleBuffer
        ))
        defer { fixture.close() }

        let player = fixture.player
        try player.load(TestPaths.testMedia(name), playAutomatically: false)
        try await eventually("unsupported Profile 7 is rejected") { player.lastError != nil }

        guard case .nativeVideoOutputUnavailable = player.lastError else {
            Issue.record("Expected native Dolby Vision rejection, got \(String(describing: player.lastError))")
            return
        }

        try await eventually("rejected output releases its displayed image") {
            player.sampleBufferDisplayLayer.sampleBufferRenderer.displayedPixelBuffer() == nil
        }

        #expect(player.dolbyVisionStatus.nativeValidation == .rejected)
        #expect(player.dolbyVisionStatus.effectiveProfile == nil)
        #expect(player.dolbyVisionStatus.conversion != .converted)
    }
}
