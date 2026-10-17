import CMPV
import Foundation
import MPVCore

/// Creates the shared session with Android native output and audio options.
public enum MPVAndroidSession {

    /// Consumes one retained C session reference supplied by an Android adapter.
    /// The adapter and Swift UI then address the same session and native client.
    public static func consumeRetainedHandle(_ address: Int64) -> MPVSession? {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: Int(truncatingIfNeeded: address)) else { return nil }
        return Unmanaged<MPVSession>.fromOpaque(pointer).takeRetainedValue()
    }

    /// Creates one session, with no Skip or Java dependency. A platform adapter
    /// supplies content access and surfaces separately.
    public static func create(configuration: MPVSessionConfiguration = .init(videoOutput: .gpu), lowPowerMode: Bool = false) -> MPVSession {
        create(configuration: configuration, lowPowerMode: lowPowerMode, prepareHandle: { _ in 0 })
    }

    package static func create(
        configuration: MPVSessionConfiguration,
        lowPowerMode: Bool,
        prepareHandle: @escaping @Sendable (OpaquePointer) -> Int32
    ) -> MPVSession {
        var platform = MPVPlatformServices()
        platform.lowPowerMode = { lowPowerMode }
        platform.prepareHandle = prepareHandle
        platform.mediaPath = { url in
            let path = url.isFileURL ? url.path : url.absoluteString
            if url.scheme == "content" {
                return "mpvui-content" + path.dropFirst("content".count)
            }
            if url.scheme == "asset" {
                return "mpvui-asset://" + path.dropFirst("asset:".count).drop(while: { $0 == "/" })
            }
            return path
        }
        platform.videoOutputName = { $0 == .nativeSurface ? "mediacodec_embed" : "gpu-next" }
        platform.initialOptions = { settings, target, output in
            let display = target?.displayCapabilities ?? .unknown
            return [
                ("ao", "audiotrack,opensles,"),
                ("hwdec", MPVAndroidOutputPolicy.hardware(settings, output: output)),
                ("vd-lavc-o", MPVAndroidOutputPolicy.decoderOptions(settings, output: output, display: display)),
                ("hwdec-software-fallback", "1"),
                ("config", "no"),
                ("terminal", "no"),
                ("idle", "yes"),
                ("keep-open", "yes"),
                ("gpu-api", "opengl"),
                ("gpu-context", "android"),
                ("opengl-es", "yes"),
                ("target-colorspace-hint", "no"),
                ("target-prim", "bt.709"),
                ("target-trc", "bt.1886"),
                ("tls-verify", "yes"),
                ("sub-fonts-dir", "/system/fonts"),
                ("osd-level", "0"),
                ("input-vo-keyboard", "no"),
                ("input-default-bindings", "no")
            ]
        }
        return MPVSession(settings: configuration, platform: platform) { _ in }
    }
}
