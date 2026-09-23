import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit, .dolbyVision))
struct MPVVideoFeatureCapabilitiesTests {
    @Test
    func `native DV blocks frame modification but preserves inline UI`() {
        let capabilities = resolve(.sampleBuffer, profile: 5)
        for feature in [MPVVideoFeature.nativeSubtitles, .bakedOverlays, .zoomAndPan, .pictureInPictureSubtitles] {
            #expect(capabilities[feature].availability == .unavailable)
            #expect(capabilities[feature].restriction == .nativeDolbyVisionPreservesRPU)
        }
        #expect(capabilities.inlineSwiftUIOverlays.availability == .available)
    }

    @Test
    func `validated native DV without container tags still protects RPU frames`() {
        let capabilities = MPVVideoFeatureCapabilities(
            backend: .sampleBuffer,
            dolbyVision: MPVDolbyVisionStatus(nativeValidation: .validated),
            hasVideo: true,
            pictureInPictureRequiresNativeOutput: true,
            supportsPictureInPicture: true
        )
        #expect(capabilities.bakedOverlays.restriction == .nativeDolbyVisionPreservesRPU)
    }

    @Test
    func `Metal enables composition but cannot keep iOS PiP`() {
        let capabilities = resolve(.metal, profile: 7)
        #expect(capabilities.nativeSubtitles.availability == .available)
        #expect(capabilities.bakedOverlays.availability == .available)
        #expect(capabilities.zoomAndPan.availability == .available)
        #expect(capabilities.pictureInPictureSubtitles.restriction == .pictureInPictureRequiresNativeOutput)
    }

    @Test
    func `unknown media is not prematurely claimed to support native composition`() {
        let capabilities = MPVVideoFeatureCapabilities(
            backend: .sampleBuffer, dolbyVision: .unknown, hasVideo: false,
            pictureInPictureRequiresNativeOutput: true, supportsPictureInPicture: true
        )
        #expect(capabilities.nativeSubtitles.availability == .unknown)
        #expect(capabilities.zoomAndPan.availability == .unknown)
    }

    @MainActor
    @Test
    func `explicit feature fallback changes backend and next item restores defaults`() {
        let player = MPVPlayer(configuration: .init(autoPlay: false, videoOutput: .sampleBuffer))
        player.updateDolbyVisionStatus(MPVDolbyVisionStatus(sourceProfile: 5, nativeValidation: .validated))
        let preserved = player.requestVideoFeatures([.nativeSubtitles, .zoomAndPan])
        #expect(preserved.outcome == .requiresMetalFallback)
        #expect(preserved.requiresReload)
        #expect(player.videoOutput == .sampleBuffer)
        let accepted = player.requestVideoFeatures([.nativeSubtitles, .zoomAndPan], policy: .preferFeatures)
        #expect(accepted.outcome == .switchedToMetal)
        #expect(accepted.unavailableFeatures.isEmpty)
        #expect(player.videoOutput == .metal)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        #expect(accepted.losesPictureInPicture)
        #else
        #expect(!accepted.losesPictureInPicture)
        #endif
        player.load(TestPaths.baselineMedia, autoPlay: false)
        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.videoFeatureRequestResult == nil)
        #expect(player.dolbyVisionStatus.sourceProfile == nil)
    }

    @MainActor
    @Test
    func `configured feature policy defers decision until native DV is identified`() {
        let player = MPVPlayer(configuration: .init(
            autoPlay: false,
            nativeVideoFeaturePolicy: .preferFeatures,
            videoOutput: .sampleBuffer
        ))
        #expect(player.requestVideoFeatures([.bakedOverlays]).outcome == .awaitingVideoMetadata)
        player.updateDolbyVisionStatus(MPVDolbyVisionStatus(sourceProfile: 8))
        #expect(player.videoOutput == .metal)
        #expect(player.videoFeatureRequestResult?.outcome == .switchedToMetal)
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    @MainActor
    @Test
    func `requesting only PiP subtitles never switches to a backend without PiP`() {
        let player = MPVPlayer(configuration: .init(
            autoPlay: false,
            nativeVideoFeaturePolicy: .preferFeatures,
            videoOutput: .sampleBuffer
        ))
        player.updateDolbyVisionStatus(MPVDolbyVisionStatus(sourceProfile: 5, nativeValidation: .validated))
        let result = player.requestVideoFeatures([.pictureInPictureSubtitles])
        #expect(result.outcome == .unavailable)
        #expect(!result.requiresReload)
        #expect(player.videoOutput == .sampleBuffer)
    }
    #endif

    private func resolve(_ backend: MPVPlayerConfiguration.VideoOutput, profile: Int) -> MPVVideoFeatureCapabilities {
        MPVVideoFeatureCapabilities(
            backend: backend, dolbyVision: MPVDolbyVisionStatus(sourceProfile: profile), hasVideo: true,
            pictureInPictureRequiresNativeOutput: true, supportsPictureInPicture: true
        )
    }
}
