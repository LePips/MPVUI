/// Audio output observations from ``MPVPlaybackDiagnostics/audio``.
///
/// Missing observations are `nil`. Spatialization eligibility does not confirm
/// audible spatialization, head tracking, or Dolby Atmos rendering.
public struct MPVAudioStatus: Equatable, Sendable {
    /// mpv's active audio output, including any fallback from AVFoundation.
    public var output: String?
    /// The source codec reported by mpv.
    public var codec: String?
    /// Source speaker layout reported by the demuxer, such as `stereo` or `5.1`.
    public var sourceChannels: String?
    /// Layout presented to the audio output. Compressed transport uses a
    /// two-channel IEC carrier; this does not describe the Dolby speaker layout.
    public var outputChannels: String?
    /// mpv's output sample format, such as `float`, `spdif-ac3`, or `spdif-eac3`.
    public var outputFormat: String?
    /// AVFoundation renderer: `sample-buffer` for PCM or `avplayer` for Dolby.
    /// Unavailable when another audio output is active.
    public var nativePath: String?
    /// Whether the active Apple renderer allows mono/stereo spatialization.
    /// Read from the renderer; `nil` when unavailable.
    public var allowsStereoSpatialization: Bool?
    /// Whether the active Apple renderer allows surround spatialization.
    /// Read from the renderer; `nil` when unavailable.
    public var allowsMultichannelSpatialization: Bool?
    /// Whether any current iOS/tvOS output supports Spatial Audio and the user enables it.
    /// `nil` on macOS or when unavailable; does not distinguish Fixed from Head Tracked.
    public var routeSpatialAudioEnabled: Bool?

    /// Creates audio status with no observations.
    public init() {}
}
