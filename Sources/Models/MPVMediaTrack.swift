/// Describes one selectable video, audio, or subtitle track.
public struct MPVMediaTrack: Identifiable, Hashable, Sendable {
    /// An identity unique across all track categories.
    public var id: MPVMediaTrackIdentifier {
        MPVMediaTrackIdentifier(type: type, mpvID: mpvID)
    }

    /// The integer identifier assigned by mpv within this track category.
    public let mpvID: Int

    /// The category of the track.
    public let type: MPVTrackType

    /// A display title embedded in the media, when present.
    public let title: String?

    /// A language tag or language name embedded in the media, when present.
    public let language: String?

    /// The codec name reported by mpv, when present.
    public let codec: String?

    /// Whether mpv currently selected this track.
    public let isSelected: Bool

    /// Whether the container marks this as a default track.
    public let isDefault: Bool

    /// Whether the container marks this as a forced track.
    public let isForced: Bool

    /// Whether the track was loaded from outside the primary media source.
    public let isExternal: Bool

    /// Creates a media track description.
    ///
    /// - Parameters:
    ///   - id: The integer identifier assigned by mpv.
    ///   - type: The track category.
    ///   - title: An optional display title.
    ///   - language: An optional language tag or name.
    ///   - codec: An optional codec name.
    ///   - isSelected: Whether the track is currently selected.
    ///   - isDefault: Whether the track is marked as the default.
    ///   - isForced: Whether the track is marked as forced.
    ///   - isExternal: Whether the track came from an external source.
    public init(
        id: Int,
        type: MPVTrackType,
        title: String? = nil,
        language: String? = nil,
        codec: String? = nil,
        isSelected: Bool = false,
        isDefault: Bool = false,
        isForced: Bool = false,
        isExternal: Bool = false
    ) {
        mpvID = id
        self.type = type
        self.title = title
        self.language = language
        self.codec = codec
        self.isSelected = isSelected
        self.isDefault = isDefault
        self.isForced = isForced
        self.isExternal = isExternal
    }
}
