/// Playback observations. Missing instrumentation is nil, never an inferred zero.
public struct MPVPlaybackDiagnostics: Equatable, Sendable {
    /// Timing observations for one renderer pass.
    public struct RenderPass: Equatable, Sendable {
        /// The renderer's name for this pass.
        public var name: String
        /// The most recent pass duration in nanoseconds.
        public var lastNanoseconds: Int64?
        /// The renderer's rolling average pass duration in nanoseconds.
        public var averageNanoseconds: Int64?
        /// The renderer's peak pass duration in nanoseconds.
        public var peakNanoseconds: Int64?
    }

    /// The selected decoder and available acceleration evidence.
    public struct Decoder: Equatable, Sendable {
        /// The decoder session reported by mpv.
        public enum Session: Equatable, Sendable {
            /// The decoder session has not been reported.
            case unknown
            /// mpv reports a software decoder session.
            case software
            /// mpv reports the named hardware decoder session.
            case hardware(String)
        }

        /// The reported video codec, when available.
        public var codec: String?
        /// mpv's chosen decoder API, independent of actual VideoToolbox acceleration.
        public var selectedDecoder: String?
        /// Public VideoToolbox session-property readback; unknown on unsupported OS/builds.
        public var videoToolboxSessionUsesHardware: Bool?
        /// Codec-level VideoToolbox probe only; it does not validate profile, depth or resolution.
        public var videoToolboxSupportsCodec: Bool?
        /// Actual mpv decoder selection after opening this item.
        public var session: Session = .unknown
        /// The hardware decoder's renderer interop, when reported.
        public var interop: String?
        /// The decoder's output pixel format, when reported.
        public var decodedPixelFormat: String?
        /// Why the requested decoder path was not used, if known.
        public var fallbackReason: String?
        /// Creates decoder diagnostics with no observed session.
        public init() {}
    }

    /// Native sample-buffer output counters and build timings.
    public struct NativeOutputStatistics: Equatable, Sendable {
        /// Native output uploads/composites/geometry copies only. Excludes decoder,
        /// Core Image internals, GPU internals and compositor/presentation copies.
        public var pixelBufferCopies: Int64?
        /// The number of native video samples built since the last reset.
        public var sampleBuildCount: Int64?
        /// The most recent native sample build duration in nanoseconds.
        public var lastSampleBuildNanoseconds: Int64?
        /// Total native sample build time in nanoseconds since the last reset.
        public var totalSampleBuildNanoseconds: Int64?
    }

    /// Counters reset when the native VO resets/reconfigures.
    public var nativeOutputStatistics: NativeOutputStatistics?
    /// Frames dropped by the decoder, when reported.
    public var decoderDroppedFrames: Int64?
    /// Frames dropped by the video output, when reported.
    public var outputDroppedFrames: Int64?
    /// mpv's display-sync mistiming counter, not every missed physical refresh.
    public var mistimedFrames: Int64?
    /// Frames delayed by the video output, when reported.
    public var delayedFrames: Int64?
    /// The reported audio/video timing difference in seconds.
    public var audioVideoDriftSeconds: Double?
    /// Accumulated audio/video synchronization correction in seconds.
    public var totalAudioVideoCorrectionSeconds: Double?
    /// The frame rate reported by the media container.
    public var containerFramesPerSecond: Double?
    /// Timestamp-based estimate from filter output, including deinterlacing.
    public var estimatedFilterFramesPerSecond: Double?
    /// Only provided when no active filter changes cadence.
    public var estimatedDecodedFramesPerSecond: Double?
    /// The display's nominal refresh rate in frames per second.
    public var nominalDisplayFramesPerSecond: Double?
    /// Measured display-sync refresh estimate; unavailable on unsupported output routes.
    public var estimatedDisplayFramesPerSecond: Double?
    /// Pass timings for newly rendered frames, when available.
    public var freshRenderPasses: [RenderPass]?
    /// Pass timings for redrawing an existing frame, when available.
    public var redrawRenderPasses: [RenderPass]?
    /// Not exposed by the current native instrumentation.
    public var decodeNanoseconds: Int64?
    /// Frame copies, when exposed by decoder instrumentation.
    public var frameCopyCount: Int64?
    /// Monotonic elapsed time from requested load to the first playback-restart event.
    public var startLatencySeconds: Double?
    /// Monotonic elapsed time from seek event to playback-restart, not HDMI-visible latency.
    public var seekLatencySeconds: Double?
    /// The current decoder observations.
    public var decoder: Decoder = .init()
    /// The requested and accepted renderer quality settings.
    public var renderingQuality: MPVRenderingQualityStatus = .init()
    /// The current deinterlacing configuration and observations.
    public var deinterlace: MPVDeinterlaceStatus = .init()
    /// Reported reasons for using fallback playback paths.
    public var fallbackReasons: [String] = []
    /// Creates playback diagnostics with no measurements.
    public init() {}
}
