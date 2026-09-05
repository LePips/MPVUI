/// A media track category understood by mpv.
public enum MPVTrackType: String, CaseIterable, Hashable, Sendable {
    /// A video track.
    case video

    /// An audio track.
    case audio

    /// A subtitle track.
    case subtitle
}
