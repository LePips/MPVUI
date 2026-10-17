import Foundation
@testable import MPVCore
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
        #expect(capabilities.inlineOverlays.availability == .available)
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
            backend: .sampleBuffer,
            dolbyVision: .unknown,
            hasVideo: false,
            pictureInPictureRequiresNativeOutput: true,
            supportsPictureInPicture: true
        )

        #expect(capabilities.nativeSubtitles.availability == .unknown)
        #expect(capabilities.zoomAndPan.availability == .unknown)
    }

    @Test
    func `platforms without picture in picture preserve inline composition`() {
        let capabilities = MPVVideoFeatureCapabilities(
            backend: .gpu,
            dolbyVision: .unknown,
            hasVideo: true,
            pictureInPictureRequiresNativeOutput: false,
            supportsPictureInPicture: false
        )

        #expect(capabilities.pictureInPictureSubtitles.availability == .unavailable)
        #expect(capabilities.pictureInPictureSubtitles.restriction == .pictureInPictureUnavailableOnPlatform)
        #expect(capabilities.inlineOverlays.availability == .available)
        #expect(capabilities.nativeSubtitles.availability == .available)
        let result = capabilities.resolve([.pictureInPictureSubtitles, .inlineOverlays])
        #expect(result.outcome == .unavailable)
        #expect(result.unavailableFeatures == [.pictureInPictureSubtitles])
        #expect(result.reason?.contains("picture-in-picture") == true)
    }

    private func resolve(_ backend: MPVPlayerConfiguration.VideoOutput, profile: Int) -> MPVVideoFeatureCapabilities {
        MPVVideoFeatureCapabilities(
            backend: backend.coreValue,
            dolbyVision: MPVDolbyVisionStatus(sourceProfile: profile),
            hasVideo: true,
            pictureInPictureRequiresNativeOutput: true,
            supportsPictureInPicture: true
        )
    }
}
