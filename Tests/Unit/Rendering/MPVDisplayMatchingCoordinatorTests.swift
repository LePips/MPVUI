import CoreMedia
import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVDisplayMatchingCoordinatorTests {
    private func media(
        fps: Double = 24,
        source: MPVVideoSignal = .init(primaries: "bt.2020", transferFunction: .pq),
        decoded: MPVVideoSignal = .unknown
    ) -> MPVMediaInformation {
        MPVMediaInformation(
            videoCodec: "hevc",
            dimensions: .init(width: 3840, height: 2160),
            framesPerSecond: fps,
            hdr: .init(source: source, decoded: decoded)
        )
    }

    @Test(arguments: [(Double, Double)]([
        (23.976, 24000.0 / 1001), (24, 24),
        (29.97, 30000.0 / 1001), (30, 30),
        (50, 50), (59.94, 60000.0 / 1001), (60, 60),
    ]))
    func `content refresh rates preserve fractional and integer HDMI families`(
        input: Double, expected: Double
    ) throws {
        let content = try #require(MPVDisplayMatchingContent(
            media: media(fps: input), outputUsesHDR: true
        ))
        #expect(content.refreshRate == Float(expected))
    }

    @Test
    func `unknown timing cannot choose a guessed HDMI refresh rate`() {
        for value: Double? in [nil, 0, -1, .nan, .infinity, 241] {
            #expect(MPVDisplayMatchingContent.refreshRate(for: value) == nil)
        }
        #expect(MPVDisplayMatchingContent.refreshRate(for: 27.5) == 27.5)
        #expect(MPVDisplayMatchingContent(media: .empty, outputUsesHDR: true) == nil)
    }

    @Test
    func `selected track codec identifies content when display codec is a human label`() throws {
        let information = MPVMediaInformation(
            videoCodec: "H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10",
            dimensions: .init(width: 1920, height: 1080),
            framesPerSecond: 24,
            tracks: [.init(id: 1, type: .video, codec: "h264", isSelected: true)]
        )
        let content = try #require(MPVDisplayMatchingContent(media: information, outputUsesHDR: false))
        #expect(content.codec == kCMVideoCodecType_H264)
    }

    @Test(arguments: ["dvhe", "dvh1"])
    func `Dolby codec aliases retain frame rate matching without implying validation`(codec: String) throws {
        let content = try #require(MPVDisplayMatchingContent(
            media: .init(
                videoCodec: codec, dimensions: .init(width: 3840, height: 2160),
                framesPerSecond: 23.976
            ), outputUsesHDR: true, videoOutput: .sampleBuffer
        ))
        #expect(content.refreshRate == Float(24000.0 / 1001))
        #expect(content.codec == kCMVideoCodecType_HEVC)
        #expect(content.dolbyVision == nil)
    }

    @Test
    func `changing HDR scene metadata does not restart HDMI matching`() throws {
        let first = try #require(MPVDisplayMatchingContent(
            media: media(source: .init(
                primaries: "bt.2020", transferFunction: .pq,
                signalPeak: 10, hdr10PlusMetadata: ["scene-max": 1000]
            )), outputUsesHDR: true
        ))
        let next = try #require(MPVDisplayMatchingContent(
            media: media(source: .init(
                primaries: "bt.2020", transferFunction: .pq,
                signalPeak: 4, hdr10PlusMetadata: ["scene-max": 400]
            )), outputUsesHDR: true
        ))
        var state = MPVDisplayMatchingState()
        #expect(update(&state, first) == .apply(first))
        #expect(update(&state, next) == .keep)
    }

    @Test
    func `format description carries content geometry and corrected HDR signal`() throws {
        let decoded = MPVVideoSignal(
            primaries: "bt.2020", transferFunction: .hlg,
            matrix: "bt.2020-ncl", range: "limited", bitDepth: 10
        )
        let content = try #require(MPVDisplayMatchingContent(
            media: media(decoded: decoded), outputUsesHDR: true
        ))
        let format = try #require(content.makeFormatDescription())
        #expect(CMVideoFormatDescriptionGetDimensions(format).width == 3840)
        #expect(CMVideoFormatDescriptionGetDimensions(format).height == 2160)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        let extensions = try #require(CMFormatDescriptionGetExtensions(format) as? [String: Any])
        #expect(extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        #expect(extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
            == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
        #expect(extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int == 10)
        #expect(extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool == false)
    }

    @Test
    func `SDR conversion drops HDR mode hints and content light metadata`() throws {
        let source = MPVVideoSignal(
            primaries: "bt.2020", transferFunction: .pq,
            maxContentLightLevel: 1000, maxFrameAverageLightLevel: 400
        )
        let content = try #require(MPVDisplayMatchingContent(
            media: media(source: source), outputUsesHDR: false
        ))
        let format = try #require(content.makeFormatDescription())
        let extensions = try #require(CMFormatDescriptionGetExtensions(format) as? [String: Any])
        #expect(extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            == kCMFormatDescriptionTransferFunction_sRGB as String)
        #expect(extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
            == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        #expect(extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] == nil)
        #expect(extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] == nil)
    }

    @Test
    func `unknown color metadata stays absent`() throws {
        let content = try #require(MPVDisplayMatchingContent(
            media: media(source: .unknown), outputUsesHDR: true
        ))
        let format = try #require(content.makeFormatDescription())
        let extensions = try #require(CMFormatDescriptionGetExtensions(format) as? [String: Any])
        #expect(extensions[kCMFormatDescriptionExtension_TransferFunction as String] == nil)
        #expect(extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] == nil)
        #expect(extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] == nil)
    }

    @Test(arguments: [(5, 0, "dvcC"), (8, 1, "dvvC"), (8, 4, "dvvC")])
    func `validated native Dolby Vision advertises its effective configuration`(
        profile: Int, compatibility: Int, atom: String
    ) throws {
        let content = try #require(MPVDisplayMatchingContent(
            media: media(fps: 24000.0 / 1001, source: .init(
                primaries: "bt.2020", transferFunction: compatibility == 4 ? .hlg : .pq,
                dolbyVisionProfile: profile, dolbyVisionLevel: 6,
                dolbyVisionBaseLayerCompatibilityID: compatibility
            )),
            outputUsesHDR: true, videoOutput: .sampleBuffer,
            dolbyVisionStatus: .init(
                effectiveProfile: profile, effectiveBaseLayerCompatibilityID: compatibility,
                nativeValidation: .validated
            )
        ))
        let format = try #require(content.makeFormatDescription())
        #expect(content.refreshRate == Float(24000.0 / 1001))
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_DolbyVisionHEVC)
        let extensions = try #require(CMFormatDescriptionGetExtensions(format) as? [String: Any])
        let atoms = try #require(extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Data])
        let record = try #require(atoms[atom])
        #expect(atoms.count == 1)
        #expect(record.count == 24)
        #expect(Array(record.prefix(5)) == [1, 0, UInt8(profile * 2), 53, UInt8(compatibility * 16)])
        #expect(record.dropFirst(5).allSatisfy { $0 == 0 })
    }

    @Test
    func `Profile 7 conversion advertises validated Profile 8 point 1`() throws {
        let content = try #require(MPVDisplayMatchingContent(
            media: media(source: .init(
                transferFunction: .pq, dolbyVisionProfile: 7, dolbyVisionLevel: 6,
                dolbyVisionBaseLayerCompatibilityID: 6
            )), outputUsesHDR: true, videoOutput: .sampleBuffer,
            dolbyVisionStatus: .init(
                requestedPolicy: .profile7Compatibility, sourceProfile: 7,
                effectiveProfile: 8, effectiveBaseLayerCompatibilityID: 1,
                nativeValidation: .validated, conversion: .converted, enhancementLayer: .discarded
            )
        ))
        #expect(content.dolbyVision?.profile == 8)
        #expect(content.dolbyVision?.compatibilityID == 1)
        #expect(content.dolbyVision?.configurationRecord[3] == 53, "EL-present must remain clear.")
    }

    @Test
    func `source tags and conversion intent cannot advertise native Dolby Vision`() throws {
        let source = MPVVideoSignal(
            transferFunction: .pq, dolbyVisionProfile: 8, dolbyVisionLevel: 6,
            dolbyVisionBaseLayerCompatibilityID: 1
        )
        for status: MPVDolbyVisionStatus in [
            .unknown,
            .init(sourceProfile: 8),
            .init(requestedPolicy: .profile7Compatibility, sourceProfile: 7, conversion: .pending),
            .init(effectiveProfile: 8, effectiveBaseLayerCompatibilityID: 1, nativeValidation: .rejected),
            .init(effectiveProfile: 7, effectiveBaseLayerCompatibilityID: 6, nativeValidation: .validated),
            .init(effectiveProfile: 8, nativeValidation: .validated),
        ] {
            let content = try #require(MPVDisplayMatchingContent(
                media: media(source: source), outputUsesHDR: true,
                videoOutput: .sampleBuffer, dolbyVisionStatus: status
            ))
            #expect(content.dolbyVision == nil)
            #expect(content.codec == kCMVideoCodecType_HEVC)
        }
    }

    @Test(arguments: [nil, 0, -1, 16])
    func `missing or invalid Dolby level does not invent a configuration record`(level: Int?) {
        #expect(MPVDisplayMatchingContent.DolbyVision(status: .init(
            effectiveProfile: 8, effectiveBaseLayerCompatibilityID: 1,
            nativeValidation: .validated
        ), level: level) == nil)
    }

    @Test
    func `Dolby validation and backend fallback each update the display criteria`() throws {
        let information = media(source: .init(
            primaries: "bt.2020", transferFunction: .pq,
            dolbyVisionProfile: 8, dolbyVisionLevel: 6,
            dolbyVisionBaseLayerCompatibilityID: 1
        ))
        let validated = MPVDolbyVisionStatus(
            effectiveProfile: 8, effectiveBaseLayerCompatibilityID: 1, nativeValidation: .validated
        )
        let pending = try #require(MPVDisplayMatchingContent(
            media: information, outputUsesHDR: true, videoOutput: .sampleBuffer
        ))
        let native = try #require(MPVDisplayMatchingContent(
            media: information, outputUsesHDR: true, videoOutput: .sampleBuffer,
            dolbyVisionStatus: validated
        ))
        let metal = try #require(MPVDisplayMatchingContent(
            media: information, outputUsesHDR: true, videoOutput: .metal,
            dolbyVisionStatus: validated
        ))
        let sdr = try #require(MPVDisplayMatchingContent(
            media: information, outputUsesHDR: false, videoOutput: .sampleBuffer,
            dolbyVisionStatus: validated
        ))
        var state = MPVDisplayMatchingState()
        #expect(update(&state, pending) == .apply(pending))
        #expect(update(&state, native) == .apply(native))
        #expect(update(&state, native) == .keep)
        #expect(update(&state, metal) == .apply(metal))
        #expect(metal.dolbyVision == nil)
        #expect(sdr.dolbyVision == nil)
        #expect(sdr.convertsHDRToSDR)
        let format = try #require(sdr.makeFormatDescription())
        let extensions = try #require(CMFormatDescriptionGetExtensions(format) as? [String: Any])
        #expect(extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] == nil)
    }

    @Test
    func `user disabling Match Content releases criteria and reenabling restores them`() throws {
        let content = try #require(MPVDisplayMatchingContent(media: media(), outputUsesHDR: true))
        var state = MPVDisplayMatchingState()
        #expect(update(&state, content, enabled: false) == .keep)
        #expect(update(&state, content) == .apply(content))
        #expect(update(&state, content, enabled: false) == .clear)
        #expect(update(&state, content, enabled: false) == .keep)
        #expect(update(&state, content) == .apply(content))
    }

    @Test
    func `seeks and buffering retain the last criteria without HDMI churn`() throws {
        let first = try #require(MPVDisplayMatchingContent(media: media(), outputUsesHDR: true))
        let next = try #require(MPVDisplayMatchingContent(media: media(fps: 60), outputUsesHDR: true))
        var state = MPVDisplayMatchingState()
        #expect(update(&state, first) == .apply(first))
        #expect(update(&state, nil, playback: .seeking) == .keep)
        #expect(update(&state, next, playback: .buffering) == .keep)
        #expect(state.content == first)
        #expect(update(&state, first, playback: .paused) == .keep)
    }

    @Test
    func `blackout defers next item criteria until switch completes`() throws {
        let first = try #require(MPVDisplayMatchingContent(media: media(), outputUsesHDR: true))
        let next = try #require(MPVDisplayMatchingContent(media: media(fps: 60), outputUsesHDR: true))
        var state = MPVDisplayMatchingState()
        #expect(update(&state, first) == .apply(first))
        #expect(update(&state, nil, generation: 2, playback: .loading) == .keep)
        #expect(update(&state, next, generation: 2, switching: true) == .keep)
        #expect(state.content == first)
        #expect(update(&state, next, generation: 2) == .apply(next))
        #expect(update(&state, next, generation: 2) == .keep)
    }

    @Test
    func `same URL next item generation with no video releases previous mode`() throws {
        let content = try #require(MPVDisplayMatchingContent(media: media(), outputUsesHDR: true))
        var state = MPVDisplayMatchingState()
        #expect(update(&state, content) == .apply(content))
        #expect(update(&state, nil, generation: 2, playback: .loading) == .keep)
        #expect(update(&state, nil, generation: 2, playback: .ready) == .clear)
    }

    @Test
    func `completion stop failure and inactive surfaces release criteria`() throws {
        let content = try #require(MPVDisplayMatchingContent(media: media(), outputUsesHDR: true))
        for playback: MPVPlaybackState in [
            .idle, .ended, .stopped,
            .failed(.playbackFailed(code: -1, message: "Test failure")),
        ] {
            var state = MPVDisplayMatchingState()
            #expect(update(&state, content) == .apply(content))
            #expect(update(&state, content, playback: playback) == .clear)
            #expect(update(&state, content, playback: playback) == .keep)
        }
        var state = MPVDisplayMatchingState()
        #expect(update(&state, content) == .apply(content))
        #expect(update(&state, content, active: false, switching: true) == .clear)
    }

    @Test
    func `handoff preserves matching content but invalidates player-local generation`() throws {
        let content = try #require(MPVDisplayMatchingContent(media: media(), outputUsesHDR: true))
        var state = MPVDisplayMatchingState()
        #expect(update(&state, content) == .apply(content))
        state.ownershipDidChange()
        #expect(state.content == content)
        #expect(update(&state, content) == .keep)
        state.ownershipDidChange()
        #expect(update(&state, nil) == .clear)
    }

    private func update(
        _ state: inout MPVDisplayMatchingState,
        _ candidate: MPVDisplayMatchingContent?,
        generation: UInt64 = 1,
        playback: MPVPlaybackState = .playing,
        enabled: Bool = true,
        active: Bool = true,
        switching: Bool = false
    ) -> MPVDisplayMatchingState.Action {
        state.update(
            candidate: candidate, mediaGeneration: generation,
            playbackState: playback, matchingEnabled: enabled,
            isActive: active, modeSwitchInProgress: switching
        )
    }
}
