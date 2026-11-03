import Foundation

/// Describes one selectable video, audio, or subtitle track.
public struct MPVMediaTrack: Hashable, Sendable {

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

    /// Whether mpv has selected this track.
    public let isSelected: Bool

    /// The selected subtitle slot, or `nil` for unselected and non-subtitle tracks.
    /// Both subtitle slots can have a selected track at the same time.
    public let subtitleRole: MPVSubtitleRole?

    /// Whether the container marks this as a default track.
    public let isDefault: Bool

    /// Whether the container marks this as a forced track.
    public let isForced: Bool

    /// Whether the track comes from outside the primary media source.
    public let isExternal: Bool

    /// The resource containing an external track, when reported by mpv.
    public let externalURL: URL?

    /// The identity supplied when the client loaded this external resource.
    public let clientID: String?

    /// The demuxer's stream index (`ff-index`), when available.
    /// Matches FFmpeg's stream index for libavformat inputs. Other demuxers may use
    /// different numbering. Compare only against metadata for the same source representation.
    /// For external tracks this indexes the external resource, not the primary media.
    public let sourceStreamIndex: Int?

    /// The container-specific stream identifier (`src-id`), when available.
    /// Its meaning depends on the demuxer. It is distinct from the selectable ``mpvID``.
    public let sourceID: Int?

    /// Whether the source marks this track as intended for hearing-impaired audiences.
    public let isHearingImpaired: Bool
    /// Whether the source marks this track as intended for visually impaired audiences.
    public let isVisualImpaired: Bool
    /// Whether the source marks this track as commentary.
    public let isCommentary: Bool

    /// Text extraction capabilities of this subtitle format, or `nil` for other track types.
    /// Native composition availability is reported separately by the player's video capabilities.
    public var subtitleCapabilities: MPVSubtitleCapabilities? {
        type == .subtitle ? MPVSubtitleCapabilities(codec: codec) : nil
    }

    /// Whether this subtitle format requires composition in the native renderer.
    public var requiresSubtitleRenderer: Bool {
        subtitleCapabilities?.requiresNativeComposition == true
    }

    /// Creates a track with mpv's integer `id`, stored as ``mpvID``.
    package init(
        id: Int,
        type: MPVTrackType,
        title: String? = nil,
        language: String? = nil,
        codec: String? = nil,
        isSelected: Bool = false,
        subtitleRole: MPVSubtitleRole? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isExternal: Bool = false,
        externalURL: URL? = nil,
        clientID: String? = nil,
        sourceStreamIndex: Int? = nil,
        sourceID: Int? = nil,
        isHearingImpaired: Bool = false,
        isVisualImpaired: Bool = false,
        isCommentary: Bool = false
    ) {
        mpvID = id
        self.type = type
        self.title = title
        self.language = language
        self.codec = codec
        self.isSelected = isSelected
        self.subtitleRole = type == .subtitle && isSelected ? subtitleRole : nil
        self.isDefault = isDefault
        self.isForced = isForced
        self.isExternal = isExternal
        self.externalURL = externalURL
        self.clientID = clientID
        self.sourceStreamIndex = sourceStreamIndex.flatMap { $0 >= 0 ? $0 : nil }
        self.sourceID = sourceID.flatMap { $0 >= 0 ? $0 : nil }
        self.isHearingImpaired = isHearingImpaired
        self.isVisualImpaired = isVisualImpaired
        self.isCommentary = isCommentary
    }
}

extension MPVMediaTrack: Identifiable {

    /// An identity unique across all track categories.
    public var id: MPVMediaTrackIdentifier {
        MPVMediaTrackIdentifier(type: type, mpvID: mpvID)
    }
}
