import Foundation

/// An external media source and the identity and metadata supplied by its client.
public struct MPVExternalTrack: Hashable, Sendable {

    /// The selection to apply after loading, unless a newer selection supersedes it.
    public enum Selection: Hashable, Sendable {

        /// Preserve the current selections.
        case unselected
        /// Select the first added track, using the primary slot for subtitles.
        case selected
        /// Select the first added subtitle in the secondary slot.
        case secondarySubtitle
    }

    /// The local file or remote resource to open.
    public let url: URL
    /// The category of tracks to import from the resource.
    public let type: MPVTrackType
    /// An optional client identity, unique within this media load and track category.
    /// It is independent of the display title and native track IDs.
    public let clientID: String?
    /// A display title to use instead of the resource's title.
    public let title: String?
    /// A language tag to use instead of the resource's language.
    public let language: String?
    /// The selection requested when this resource finishes loading.
    public let selection: Selection

    /// Describes an external file. Secondary selection is valid only for subtitles.
    public init(
        url: URL,
        type: MPVTrackType,
        clientID: String? = nil,
        title: String? = nil,
        language: String? = nil,
        selection: Selection = .selected
    ) {
        self.url = url
        self.type = type
        self.clientID = clientID
        self.title = title
        self.language = language
        self.selection = selection
    }
}

/// Tracks imported by one external-resource request, scoped to its source load.
public struct MPVExternalTrackLoadResult: Equatable, Sendable {

    /// The descriptor submitted by the caller.
    public let source: MPVExternalTrack
    /// The source-load generation that owns these tracks.
    public let generation: UInt64
    /// Imported tracks in native order, including their client identity.
    public let tracks: [MPVMediaTrack]
}
