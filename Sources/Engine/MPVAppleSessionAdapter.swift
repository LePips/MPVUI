import Foundation
import MPVCore

// These imports preserve native GPU autolinking without introducing platform
// frameworks into the shared core.
#if canImport(OpenGLES)
import OpenGLES
#endif
#if targetEnvironment(macCatalyst)
import IOKit
#endif

extension MPVSession {

    convenience init(configuration: MPVPlayerConfiguration, sink: @escaping @MainActor @Sendable (MPVEngineEmission) -> Void) {
        var platform = MPVPlatformServices()
        platform.initialOptions = Self.appleInitialOptions

        platform.optionalInitialOptions = { configuration in
            configuration.videoOutput == .sampleBuffer ? [("avfoundation-subtitle-luminance", String(configuration.subtitleLuminance))] : []
        }

        platform.videoOutputName = { $0 == .metal ? "gpu-next" : "avfoundation" }
        platform.lowPowerMode = { ProcessInfo.processInfo.isLowPowerModeEnabled }
        platform.beginSourceAccess = { $0.isFileURL && $0.startAccessingSecurityScopedResource() }
        platform.endSourceAccess = { $0.stopAccessingSecurityScopedResource() }
        platform.codecSupportsHardware = { MPVAppleHardwareProbe.supports($0) }

        self.init(settings: configuration.sessionConfiguration, platform: platform, sink: { emission in
            await sink(emission)
        })
    }

    private static func appleInitialOptions(configuration: MPVSessionConfiguration, target: MPVRenderTarget?, output: MPVVideoOutput) -> [(
        String,
        String
    )] {
        var options: [(String, String)] = [("ao", "avfoundation,")]
        options += configuration.audio.mpvOptions.map { ($0.key, $0.value) }

        options += MPVRenderingOptions.hardwareDecodingOptions(configuration.hardwareDecoding, backend: configuration.videoOutput).map { (
            $0.key,
            $0.value
        ) }

        if configuration.videoOutput == .sampleBuffer {
            #if os(tvOS)
            // Follow mpv's audio-slaved host deadlines without media-clock drift.
            let presentationMode = "host"
            #else
            // Picture in picture uses media timestamps and a pausable timebase.
            let presentationMode = "media"
            #endif

            options += [
                ("avfoundation-presentation", presentationMode),
                ("avfoundation-native-dovi-profile7", configuration.dolbyVisionPolicy == .strict ? "no" : "p8.1"),
                ("avfoundation-pip-composite-osd", "yes"),
                ("avfoundation-osd-layer", String(target?.osdLayerAddress ?? 0)),
                ("avfoundation-osd-display-width", String(target?.drawableWidth ?? 0)),
                ("avfoundation-osd-display-height", String(target?.drawableHeight ?? 0))
            ]
        } else {
            options += [("gpu-api", "vulkan"), ("gpu-context", "moltenvk"), ("target-colorspace-hint", "no")]

            if let target {
                options.append(("external-surface-size", "\(target.drawableWidth)x\(target.drawableHeight)"))
            }
        }

        return options
    }
}

extension MPVMetalLayer: MPVNativeSurfaceOwner {}

extension MPVRenderColorConfiguration {

    var sessionConfiguration: MPVSurfaceColorConfiguration {
        MPVSurfaceColorConfiguration(options: options, pixelFormat: pixelFormat.rawValue, status: status)
    }
}

extension MPVAudioConfiguration {

    var mpvOptions: [String: String] {
        [
            "ao-avfoundation-spatial-audio": spatialization.mpvValue,
            "ao-avfoundation-manage-audio-session": audioSession == .automatic ? "yes" : "no",
            "audio-spdif": dolbyDecoding == .automatic ? "ac3,eac3" : "",
        ]
    }
}
