import Foundation

// Android output decisions are shared domain behavior, independent of JNI/UI.
package enum MPVAndroidOutputPolicy {

    package static func output(_ configuration: MPVSessionConfiguration, display: MPVDisplayCapabilities) -> MPVVideoOutput {
        guard configuration.videoOutput == .automaticAndroid else { return configuration.videoOutput }
        let requiresGPU = configuration.hdrPolicy == .disabled || configuration.hardwareDecoding == .disabled
            || configuration.deinterlace.mode != .disabled || configuration.renderingQuality != .init()
            || configuration.additionalOptions.keys.contains { [
                "vf",
                "glsl-shaders",
                "glsl-shaders-append",
                "lut",
                "scale",
                "cscale",
                "deband",
                "tone-mapping",
                "gamut-mapping-mode",
                "video-rotate",
                "video-zoom",
                "video-pan-x",
                "video-pan-y"
            ].contains($0) }
        return !requiresGPU && (display.supportsHDR10 == true || display.supportsHLG == true || display.supportsDolbyVision == true) ?
            .nativeSurface : .gpu
    }

    package static func hardware(_ configuration: MPVSessionConfiguration, output: MPVVideoOutput) -> String {
        if configuration.hardwareDecoding == .disabled {
            return "no"
        }
        if output == .nativeSurface {
            return "mediacodec"
        }
        if configuration.deinterlace.mode != .disabled || configuration.additionalOptions["vf"] != nil {
            return "mediacodec-copy"
        }
        return configuration.hardwareDecoding == .mediaCodec ? "mediacodec" : "mediacodec,mediacodec-copy"
    }

    package static func decoderOptions(
        _ configuration: MPVSessionConfiguration,
        output: MPVVideoOutput,
        display: MPVDisplayCapabilities
    ) -> String {
        let native = output == .nativeSurface && display.supportsDolbyVision == true
        let convert = native && configuration.dolbyVisionPolicy == .profile7Compatibility
        return [
            configuration.additionalOptions["vd-lavc-o"],
            "native_dovi=\(native ? "yes" : "no"),convert_dovi_p7=\(convert ? "yes" : "no")"
        ]
            .compactMap(\.self)
            .joined(separator: ",")
    }
}

package extension MPVSession {

    var usesAndroidOutput: Bool {
        [.gpu, .nativeSurface, .automaticAndroid].contains(configuration.videoOutput)
    }

    @discardableResult
    func fallbackFromAndroidNative(reason: String, decoderFailed: Bool) -> Bool {
        guard configuration.videoOutput == .automaticAndroid, videoOutput == .nativeSurface,
              !didFallbackFromAndroidNative, sourceURL != nil else { return false }
        let videoSelection = desiredProperties["vid"]
        destroyHandle(preservePlayback: true)
        // A failed decoder can report vid=no. Restore the user's selection,
        // rather than carrying that failure into the replacement renderer.
        desiredProperties["vid"] = videoSelection
        didFallbackFromAndroidNative = true
        androidNativeFallbackReason = reason
        videoOutput = .gpu
        playbackDiagnostics.fallbackReasons.append(reason)
        if decoderFailed {
            desiredProperties["hwdec"] = "no"
        }
        createHandle()
        return true
    }

    @discardableResult
    func checkAndroidVideoPresentation() -> Bool {
        guard usesAndroidOutput, videoOutput == .nativeSurface, isFileLoaded, hasPlaybackStarted,
              renderTarget != nil, desiredProperties["vid"] != "no", configuration.additionalOptions["vid"] != "no" else { return false }
        let tracks = latestSnapshot.mediaInformation.tracks
        if getString("current-vo") == nil, tracks.contains(where: { $0.type == .video }),
           !tracks.contains(where: { $0.type == .video && $0.isSelected })
        {
            if !fallbackFromAndroidNative(reason: "Native video decoder unavailable; continuing with GPU output", decoderFailed: true) {
                publishFatalError(.nativeVideoOutputUnavailable("The configured native decoder cannot present this source"))
            }
            return true
        } else if configuration.nativeVideoFeaturePolicy == .preferFeatures,
                  tracks.contains(where: { $0.type == .subtitle && $0.isSelected && !$0.isSemanticTextSubtitle })
        {
            return fallbackFromAndroidNative(reason: "Selected subtitles require GPU composition", decoderFailed: false)
        }
        return false
    }
}

package extension MPVMediaTrack {

    var isSemanticTextSubtitle: Bool {
        type == .subtitle && [
            "subrip",
            "srt",
            "text",
            "webvtt",
            "mov_text",
            "ttml",
            "microdvd",
            "subviewer",
            "subviewer1",
            "sami",
            "realtext",
            "jacosub",
            "mpl2",
            "vplayer",
            "pjs",
            "stl",
            "scc",
            "eia_608"
        ].contains(codec?.lowercased() ?? "")
    }
}

public extension MPVMediaTrack {

    /// Whether this subtitle format requires composition in the native renderer.
    var requiresSubtitleRenderer: Bool {
        type == .subtitle && !isSemanticTextSubtitle
    }
}
