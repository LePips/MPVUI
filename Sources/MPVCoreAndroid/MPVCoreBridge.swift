import CMPV
import Foundation
import MPVCore

private struct NativePreparation: @unchecked Sendable {

    let context: UnsafeMutableRawPointer?
    let prepare: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32)?
}

/// Returns the stable C transport ABI version.
@_cdecl("mpvcore_abi_version")
public func coreABIVersion() -> UInt32 {
    UInt32(MPVCORE_ABI_VERSION)
}

/// Retains a shared Swift session configured from a versioned C value.
@_cdecl("mpvcore_session_create")
public func coreSessionCreate(_ configuration: UnsafePointer<MPVCoreConfiguration>?) -> UnsafeMutableRawPointer? {
    guard let value = configuration?.pointee,
          value.version == MPVCORE_ABI_VERSION,
          value.size == MemoryLayout<MPVCoreConfiguration>.size,
          (0 ... 2).contains(value.video_output), (0 ... 2).contains(value.hardware_decoding),
          value.volume.isFinite, value.playback_rate.isFinite,
          let initialBuffer = Duration(mpvSeconds: value.initial_buffer_seconds),
          let networkCache = Duration(mpvSeconds: value.network_cache_seconds)
    else { return nil }

    let preparation = NativePreparation(context: value.platform_context, prepare: value.prepare_handle)
    guard value.settings.length == 0 || copiedRecord(value.settings)?.isRecord == true else { return nil }

    let fields = copiedRecord(value.settings)?.fields ?? [:]
    let render = fields["rendering"]?.fields ?? [:]
    let deinterlace = fields["deinterlace"]?.fields ?? [:]
    let cache = fields["cache"]?.fields ?? [:]

    func setting<T: RawRepresentable>(_ type: T.Type, _ key: String, in fields: [String: CoreValue]) -> T? where T.RawValue == String {
        fields[key]?.text.flatMap(T.init(rawValue:))
    }

    let lut: MPVRenderingQuality.LUT? = render["lut"]?.fields["path"]?.text.map {
        .init(
            url: URL(fileURLWithPath: $0),
            domain: setting(MPVRenderingQuality.LUT.Domain.self, "domain", in: render["lut"]?.fields ?? [:]) ?? .native
        )
    }

    let options = fields["additionalOptions"]?.fields.compactMapValues(\.text) ?? [:]

    guard !options
        .contains(where: {
            $0.key.contains("\0") || $0.value.contains("\0") || MPVOptionOwnership.rendererProperties
                .contains(MPVOptionOwnership.normalizedProperty($0.key))
        }) else { return nil }

    let settings = MPVSessionConfiguration(
        additionalOptions: options,
        automaticallyPlays: fields["autoPlay"]?.bool ?? (value.auto_play != 0),
        cache: .init(
            mode: setting(MPVCacheConfiguration.Mode.self, "mode", in: cache) ?? .automatic,
            maximumBytes: cache["maximumBytes"]?.int ?? 64 * 1024 * 1024,
            maximumBackBytes: cache["maximumBackBytes"]?.int ?? 16 * 1024 * 1024
        ),
        deinterlace: .init(
            algorithm: setting(MPVDeinterlacePolicy.Algorithm.self, "algorithm", in: deinterlace) ??
                .automatic,
            analyzesFieldOrder: deinterlace["analyzeFieldOrder"]?.bool ?? false,
            fieldOrder: setting(MPVDeinterlacePolicy.FieldOrder.self, "fieldOrder", in: deinterlace) ??
                .automatic,
            mode: setting(MPVDeinterlacePolicy.Mode.self, "mode", in: deinterlace) ?? .disabled
        ),
        dolbyVisionPolicy: value.profile7_compatibility != 0 ? .profile7Compatibility : .strict,
        hardwareDecoding: value.hardware_decoding == 2 ? .disabled : value
            .hardware_decoding == 1 ? .mediaCodec : .automatic,
        hdrPolicy: setting(MPVHDRPolicy.self, "hdrPolicy", in: fields) ?? .automatic,
        initialBufferDuration: fields["initialBufferSeconds"]?.double
            .flatMap(Duration.init(mpvSeconds:)) ?? initialBuffer,
        logLevel: setting(MPVLogLevel.self, "logLevel", in: fields) ?? .warning,
        isLoopingEnabled: fields["loop"]?.bool ?? (value.loop != 0),
        networkCacheDuration: fields["networkCacheSeconds"]?.double
            .flatMap(Duration.init(mpvSeconds:)) ?? networkCache,
        nativeVideoFeaturePolicy: setting(
            MPVNativeVideoFeaturePolicy.self,
            "nativeVideoFeaturePolicy",
            in: fields
        ) ?? .preserveDolbyVision,
        playbackRate: fields["playbackRate"]?.double ?? value.playback_rate,
        renderingQuality: .init(
            antiringing: render["antiringing"]?.double,
            chromaAntiringing: render["chromaAntiringing"]?.double,
            chromaScaling: setting(MPVRenderingQuality.Scaling.self, "chromaScaling", in: render),
            isDebandingEnabled: render["debanding"]?.bool,
            dithering: setting(MPVRenderingQuality.Dithering.self, "dithering", in: render),
            gamutMapping: setting(MPVRenderingQuality.GamutMapping.self, "gamutMapping", in: render),
            lut: lut,
            peakDetection: setting(MPVRenderingQuality.PeakDetection.self, "peakDetection", in: render),
            preset: setting(MPVRenderingQuality.Preset.self, "preset", in: render) ?? .automatic,
            scaling: setting(MPVRenderingQuality.Scaling.self, "scaling", in: render),
            shaders: render["shaders"]?.items
                .compactMap { $0.text.map { URL(fileURLWithPath: $0) } } ?? [],
            toneMapping: setting(MPVRenderingQuality.ToneMapping.self, "toneMapping", in: render)
        ),
        startTime: fields["startTime"]?.double.flatMap(Duration.init(mpvSeconds:)),
        videoOutput: value.video_output == 2 ? .automaticAndroid : value
            .video_output == 1 ? .nativeSurface : .gpu,
        volume: fields["volume"]?.double ?? value.volume
    )

    let session = MPVAndroidSession.makeSession(configuration: settings, isLowPowerModeEnabled: value.low_power != 0) { handle in
        preparation.prepare?(preparation.context, UnsafeMutableRawPointer(handle)) ?? 0
    }

    return Unmanaged.passRetained(session).toOpaque()
}

/// Initializes the session's sole native client on its serialized queue.
@_cdecl("mpvcore_session_initialize")
public func coreSessionInitialize(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let handle else { return MPV_ERROR_INVALID_PARAMETER.rawValue }

    let session = Unmanaged<MPVSession>.fromOpaque(handle).takeUnretainedValue()

    return session.queue.sync {
        guard !session.isClosed else { return MPV_ERROR_UNINITIALIZED.rawValue }

        session.createHandle()
        return session.handle == nil ? MPV_ERROR_GENERIC.rawValue : 0
    }
}

/// Closes the native client before a platform adapter releases its resources.
@_cdecl("mpvcore_session_close")
public func coreSessionClose(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }

    Unmanaged<MPVSession>.fromOpaque(handle).takeUnretainedValue().close()
}

/// Adds a retained owner of the same session; it never creates a new client.
@_cdecl("mpvcore_session_retain")
public func coreSessionRetain(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }

    _ = Unmanaged<MPVSession>.fromOpaque(handle).retain()
}

/// Releases one retained owner of a session.
@_cdecl("mpvcore_session_release")
public func coreSessionRelease(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }

    Unmanaged<MPVSession>.fromOpaque(handle).release()
}

/// Releases memory returned in an owned C snapshot or error buffer.
@_cdecl("mpvcore_buffer_release")
public func coreBufferRelease(_ buffer: MPVCoreBuffer) {
    buffer.data?.deallocate()
}
