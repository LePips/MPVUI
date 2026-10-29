import MPVCore

/// The work needed to prepare a source and its selected tracks for AirPlay.
///
/// A plan describes processing on this device. It does not guarantee receiver compatibility,
/// local network access, or sufficient encoding performance for uninterrupted playback.
public struct MPVExternalPlaybackPlan: Equatable, Sendable {

    /// The processing required before and during playback.
    public enum Method: Equatable, Sendable {

        /// The system player reads the source without constructing HLS on this device.
        case directPlayback
        /// Selected compressed tracks are copied into local HLS without encoding.
        case remuxing
        /// Video is copied, if present, and audio is encoded as AAC in local HLS.
        case audioTranscoding
        /// Audio is copied, if present, and video is encoded as H.264 SDR in local HLS.
        case videoTranscoding
        /// Video and audio are encoded as H.264 SDR and AAC in local HLS.
        case audioAndVideoTranscoding
        /// mpv renders selected tracks as H.264 SDR video and stereo AAC to preserve subtitles or playback options.
        case rendering
    }

    /// An input or playback requirement that needs mpv's rendering pipeline.
    public enum RenderingReason: Hashable, Sendable {

        /// Visible subtitles must be included in the video.
        case subtitles
        /// A nonzero audio delay must be applied.
        case audioDelay
        /// Input options require mpv's source handling.
        case inputOptions
        /// A selected track has no native stream index and must be resolved by mpv.
        case trackSelection
    }

    static let direct = Self(method: .directPlayback, requiresForeground: false, renderingReasons: [])

    /// The processing required for the captured source and track selection.
    public let method: Method
    /// Whether HDR-to-SDR processing must pause while an iOS app is inactive.
    public let requiresForeground: Bool
    /// The reasons mpv rendering is required, or an empty set for other methods.
    public let renderingReasons: Set<RenderingReason>

    /// Whether this device constructs HLS segments and serves them over the local network.
    public var requiresLocalHLS: Bool {
        method != .directPlayback
    }

    /// Whether selected tracks must be decoded and encoded on this device.
    public var isTranscoding: Bool {
        method != .directPlayback && method != .remuxing
    }

    init(hasVideo: Bool, hasAudio: Bool, copiesVideo: Bool, copiesAudio: Bool, requiresForeground: Bool) {
        switch (hasVideo && !copiesVideo, hasAudio && !copiesAudio) {
        case (false, false): method = .remuxing
        case (false, true): method = .audioTranscoding
        case (true, false): method = .videoTranscoding
        case (true, true): method = .audioAndVideoTranscoding
        }

        self.requiresForeground = requiresForeground
        renderingReasons = []
    }

    init(rendering options: MPVMediaPackagingOptions, toneMapsHDR: Bool) {
        method = .rendering
        requiresForeground = toneMapsHDR && options.videoIndex != -2

        renderingReasons = Set(options.renderingReasons.map {
            switch $0 {
            case .subtitles: RenderingReason.subtitles
            case .audioDelay: RenderingReason.audioDelay
            case .inputOptions: RenderingReason.inputOptions
            case .trackSelection: RenderingReason.trackSelection
            }
        })
    }

    private init(method: Method, requiresForeground: Bool, renderingReasons: Set<RenderingReason>) {
        self.method = method
        self.requiresForeground = requiresForeground
        self.renderingReasons = renderingReasons
    }
}
