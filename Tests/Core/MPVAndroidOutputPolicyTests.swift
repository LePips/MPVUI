import Foundation
import MPVCore
import Testing

struct MPVAndroidOutputPolicyTests {

    @Test
    func `automatic Android output honors display and GPU requirements`() {
        let hdr = MPVDisplayCapabilities(supportsHDR10: true)

        #expect(MPVAndroidOutputPolicy.output(.init(videoOutput: .automaticAndroid), display: .unknown) == .gpu)

        for display in [hdr, .init(supportsHLG: true), .init(supportsDolbyVision: true)] {
            #expect(MPVAndroidOutputPolicy.output(.init(videoOutput: .automaticAndroid), display: display) == .nativeSurface)
        }

        for configuration in [
            MPVSessionConfiguration(hardwareDecoding: .disabled, videoOutput: .automaticAndroid),
            .init(hdrPolicy: .disabled, videoOutput: .automaticAndroid),
            .init(deinterlace: .init(mode: .automatic), videoOutput: .automaticAndroid),
            .init(renderingQuality: .init(preset: .highQuality), videoOutput: .automaticAndroid),
            .init(additionalOptions: ["video-zoom": "1"], videoOutput: .automaticAndroid)
        ] {
            #expect(MPVAndroidOutputPolicy.output(configuration, display: hdr) == .gpu)
        }

        #expect(MPVAndroidOutputPolicy.output(.init(videoOutput: .nativeSurface), display: .unknown) == .nativeSurface)
        #expect(MPVAndroidOutputPolicy.output(.init(videoOutput: .gpu), display: hdr) == .gpu)

        #expect(MPVAndroidOutputPolicy
            .output(.init(additionalOptions: ["audio-delay": "1"], videoOutput: .automaticAndroid), display: hdr) == .nativeSurface)
    }

    @Test
    func `decoder options preserve explicit hardware and Profile 7 permission`() {
        #expect(MPVAndroidOutputPolicy.hardware(.init(hardwareDecoding: .disabled), output: .nativeSurface) == "no")
        #expect(MPVAndroidOutputPolicy.hardware(.init(), output: .nativeSurface) == "mediacodec")
        #expect(MPVAndroidOutputPolicy.hardware(.init(hardwareDecoding: .mediaCodec), output: .gpu) == "mediacodec")
        #expect(MPVAndroidOutputPolicy.hardware(.init(), output: .gpu) == "mediacodec,mediacodec-copy")
        #expect(MPVAndroidOutputPolicy.hardware(.init(deinterlace: .init(mode: .automatic)), output: .gpu) == "mediacodec-copy")
        #expect(MPVAndroidOutputPolicy.hardware(.init(additionalOptions: ["vf": "hflip"]), output: .gpu) == "mediacodec-copy")

        let display = MPVDisplayCapabilities(supportsDolbyVision: true)

        #expect(MPVAndroidOutputPolicy
            .decoderOptions(.init(), output: .nativeSurface, display: display) == "native_dovi=yes,convert_dovi_p7=no")

        #expect(MPVAndroidOutputPolicy.decoderOptions(
            .init(dolbyVisionPolicy: .profile7Compatibility),
            output: .nativeSurface,
            display: display
        ) == "native_dovi=yes,convert_dovi_p7=yes")

        #expect(MPVAndroidOutputPolicy.decoderOptions(
            .init(additionalOptions: ["vd-lavc-o": "threads=2"], dolbyVisionPolicy: .profile7Compatibility),
            output: .gpu,
            display: display
        ) == "threads=2,native_dovi=no,convert_dovi_p7=no")

        #expect(MPVAndroidOutputPolicy
            .decoderOptions(.init(), output: .nativeSurface, display: .unknown) == "native_dovi=no,convert_dovi_p7=no")
    }

    @Test
    func `only automatic output can replace a failed native decoder and only once`() {
        for output in [MPVVideoOutput.automaticAndroid, .nativeSurface] {
            let player = session(output: output)
            defer { player.close() }

            player.queue.sync {
                player.videoOutput = .nativeSurface
                player.createHandle()
                player.sourceURL = URL(fileURLWithPath: "/missing-fallback-test.mp4")
                player.isFileLoaded = true
                player.hasPlaybackStarted = true
                player.renderTarget = target()
                player.latestSnapshot.mediaInformation = .init(tracks: [.init(id: 1, type: .video)])
                #expect(player.checkAndroidVideoPresentation())

                if output == .automaticAndroid {
                    #expect(player.videoOutput == .gpu)
                    #expect(player.desiredProperties["vid"] != "no")
                    #expect(player.desiredProperties["hwdec"] == "no")
                    #expect(player.androidNativeFallbackReason != nil)
                    #expect(!player.fallbackFromAndroidNative(reason: "retry", decoderFailed: true))
                } else {
                    #expect(player.videoOutput == .nativeSurface)
                    #expect(player.fatalPlaybackError != nil)
                }
            }
        }
    }

    @Test
    func `subtitle composition fallback retains hardware decoding and requires opt in`() {
        let player = session(output: .automaticAndroid, features: .preferFeatures)
        defer { player.close() }

        player.queue.sync {
            player.videoOutput = .nativeSurface
            #expect(!player.checkAndroidVideoPresentation())
            player.sourceURL = URL(fileURLWithPath: "/pending-subtitle-test.mkv")
            player.isFileLoaded = true
            player.hasPlaybackStarted = true
            player.renderTarget = target()
            player.latestSnapshot.mediaInformation = .init(tracks: [.init(id: 1, type: .subtitle, codec: "webvtt", isSelected: true)])
            #expect(!player.checkAndroidVideoPresentation())
            player.latestSnapshot.mediaInformation = .init(tracks: [.init(id: 2, type: .subtitle, codec: "ass", isSelected: true)])
            #expect(player.checkAndroidVideoPresentation())
            #expect(player.videoOutput == .gpu && player.desiredProperties["hwdec"] == nil)
            #expect(player.androidNativeFallbackReason == "Selected subtitles require GPU composition")
        }

        #expect(MPVMediaTrack(id: 1, type: .subtitle, codec: "dvd_subtitle").requiresSubtitleRenderer)
        #expect(!MPVMediaTrack(id: 1, type: .audio, codec: "aac").requiresSubtitleRenderer)
    }

    private func session(output: MPVVideoOutput, features: MPVNativeVideoFeaturePolicy = .preserveDolbyVision) -> MPVSession {
        var platform = MPVPlatformServices()
        platform.initialOptions = { _, _, _ in [("ao", "null"), ("hwdec", "no")] }
        platform.videoOutputName = { _ in "null" }

        return MPVSession(
            settings: .init(automaticallyPlays: false, nativeVideoFeaturePolicy: features, videoOutput: output),
            platform: platform
        ) { _ in }
    }

    private func target() -> MPVRenderTarget {
        .init(
            layerAddress: 1,
            layerOwner: NSObject(),
            drawableWidth: 100,
            drawableHeight: 100,
            usesExtendedDynamicRange: false,
            displaySupportsExtendedDynamicRange: false,
            outputHeadroom: 1
        )
    }
}
