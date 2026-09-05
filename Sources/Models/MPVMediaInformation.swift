import Foundation

/// Media properties and track metadata reported by mpv.
public struct MPVMediaInformation: Equatable, Sendable {
    /// The local or remote media source.
    public let sourceURL: URL?

    /// The media title, when reported.
    public let title: String?

    /// The media duration, when known.
    public let duration: Duration?

    /// The container or demuxer format name, when reported.
    public let container: String?

    /// The source size in bytes, when known.
    public let fileSize: Int64?

    /// The active video codec name, when reported.
    public let videoCodec: String?

    /// The active audio codec name, when reported.
    public let audioCodec: String?

    /// The active hardware decoder name, when hardware decoding is in use.
    public let hardwareDecoder: String?

    /// The active video's encoded and display dimensions.
    public let dimensions: MPVVideoDimensions?

    /// The active video's frame rate, when known.
    public let framesPerSecond: Double?

    /// Clockwise video rotation in degrees.
    public let rotation: Int

    /// Container-level metadata reported by mpv.
    public let metadata: [String: String]

    /// Chapters in timeline order.
    public let chapters: [MPVChapter]

    /// Video, audio, and subtitle tracks in mpv order.
    public let tracks: [MPVMediaTrack]

    /// HDR source and output status.
    public let hdr: MPVHDRStatus

    /// Creates a media-information snapshot.
    ///
    /// Negative durations, invalid frame rates, and negative file sizes are
    /// discarded.
    ///
    /// - Parameters:
    ///   - sourceURL: The local or remote media source.
    ///   - title: The media title, when reported.
    ///   - duration: The duration, when known.
    ///   - container: The container or demuxer format name.
    ///   - fileSize: The source size in bytes, when known.
    ///   - videoCodec: The active video codec name.
    ///   - audioCodec: The active audio codec name.
    ///   - hardwareDecoder: The active hardware decoder name.
    ///   - dimensions: The active video dimensions.
    ///   - framesPerSecond: The active video frame rate.
    ///   - rotation: Clockwise video rotation in degrees.
    ///   - metadata: Container-level metadata.
    ///   - chapters: Timeline chapters.
    ///   - tracks: Selectable media tracks.
    ///   - hdr: HDR source and output status.
    public init(
        sourceURL: URL? = nil,
        title: String? = nil,
        duration: Duration? = nil,
        container: String? = nil,
        fileSize: Int64? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        hardwareDecoder: String? = nil,
        dimensions: MPVVideoDimensions? = nil,
        framesPerSecond: Double? = nil,
        rotation: Int = 0,
        metadata: [String: String] = [:],
        chapters: [MPVChapter] = [],
        tracks: [MPVMediaTrack] = [],
        hdr: MPVHDRStatus = .sdr
    ) {
        self.sourceURL = sourceURL
        self.title = title
        self.duration = duration.flatMap { $0 >= .zero ? $0 : nil }
        self.container = container
        self.fileSize = fileSize.flatMap { $0 >= 0 ? $0 : nil }
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.hardwareDecoder = hardwareDecoder
        self.dimensions = dimensions
        self.framesPerSecond = Self.normalizedPositiveOrZero(framesPerSecond)
        self.rotation = rotation
        self.metadata = metadata
        self.chapters = chapters
        self.tracks = tracks
        self.hdr = hdr
    }

    /// A media-information value containing no source or reported properties.
    public static let empty = Self()

    private static func normalizedPositiveOrZero(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
