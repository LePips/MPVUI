/// A track identity that remains unique across video, audio, and subtitles.
public struct MPVMediaTrackIdentifier: Hashable, Sendable {
    /// The track category.
    public let type: MPVTrackType

    /// The integer identifier assigned by mpv within that category.
    public let mpvID: Int

    public init(type: MPVTrackType, mpvID: Int) {
        self.type = type
        self.mpvID = mpvID
    }
}
