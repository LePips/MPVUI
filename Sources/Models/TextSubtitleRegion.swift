/// One semantic text region in a subtitle snapshot.
public struct TextSubtitleRegion: Sendable, Hashable {
    /// The region's decoded text.
    public let text: String

    /// The placement supplied by the subtitle decoder.
    public let placement: TextSubtitlePlacement

    /// The source track in the current media item, when supplied by the native reader.
    public let trackID: MPVMediaTrackIdentifier?

    /// The live selection that produced this region. Independent timeline queries
    /// have no role because they do not select a track.
    public let role: MPVSubtitleRole?

    init(
        text: String,
        placement: TextSubtitlePlacement = .automatic,
        trackID: MPVMediaTrackIdentifier? = nil,
        role: MPVSubtitleRole? = nil
    ) {
        self.text = text
        self.placement = placement
        self.trackID = trackID
        self.role = role
    }
}
