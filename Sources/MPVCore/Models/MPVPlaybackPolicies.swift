/// Requested native decoder strategy.
public enum MPVHardwareDecoding: String, CaseIterable, Equatable, Sendable {

    /// Selects a safe hardware decoder, preferring VideoToolbox for Metal output.
    case automatic = "auto-safe"

    /// Requests Apple's VideoToolbox decoder.
    case videoToolbox = "videotoolbox"

    /// Requests Android MediaCodec decoding.
    case mediaCodec = "mediacodec"

    /// Decodes video in software.
    case disabled = "no"
}

/// Requested high dynamic range presentation policy.
public enum MPVHDRPolicy: String, CaseIterable, Equatable, Sendable {

    /// Matches the source, display capabilities, and current output route.
    case automatic

    /// Requests HDR output whenever the platform permits it.
    case always

    /// Disables HDR output and tone-map HDR sources to SDR.
    case disabled

    /// Requests HDR with the system's constrained brightness policy when supported.
    case constrained
}

/// Minimum severity of forwarded native log messages.
public enum MPVLogLevel: String, CaseIterable, Equatable, Sendable {

    /// Disables mpv log forwarding.
    case none = "no"

    /// Forwards fatal errors only.
    case fatal

    /// Forwards errors and more severe messages.
    case error

    /// Forwards warnings and more severe messages.
    case warning = "warn"

    /// Forwards informational messages and more severe messages.
    case info

    /// Also forwards playback status updates.
    case status

    /// Also forwards verbose diagnostics.
    case verbose = "v"

    /// Also forwards debugging diagnostics.
    case debug

    /// Forwards all trace messages.
    case trace
}

/// Resolved platform video presentation backend.
public enum MPVVideoOutput: String, CaseIterable, Equatable, Sendable {

    /// Full `gpu-next` rendering through Metal and MoltenVK.
    case metal

    /// Native AVFoundation output with iOS PiP. Requires the native-output Libmpv build.
    /// AVFoundation handles color conversion, bypassing `gpu-next` shaders and tone mapping.
    /// Unsupported native formats report a playback error.
    case sampleBuffer

    /// Android gpu-next rendering through OpenGL ES.
    case gpu

    /// Android MediaCodec direct surface presentation.
    case nativeSurface

    /// Selects compatible Android native HDR output, permitting a bounded GPU fallback.
    case automaticAndroid
}

/// Whether automatic native output may switch to GPU for subtitle composition.
public enum MPVNativeVideoFeaturePolicy: String, Equatable, Sendable {

    /// Retains native Dolby Vision output when it cannot composite subtitles.
    case preserveDolbyVision
    /// Selects GPU output for subtitles that require native composition.
    case preferFeatures
}

/// Requested platform display matching policy.
public enum MPVDisplayMatching: String, Equatable, Sendable {

    /// Leaves display mode selection to the host.
    case disabled
    /// Supplies supported frame-rate and dynamic-range criteria on tvOS.
    case automatic
}
