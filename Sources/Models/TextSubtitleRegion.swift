/// One semantic text region in a subtitle snapshot.
public struct TextSubtitleRegion: Sendable, Hashable {
    /// The region's decoded text.
    public let text: String

    /// The placement supplied by the subtitle decoder.
    public let placement: TextSubtitlePlacement

    /// Creates a text subtitle region.
    public init(
        text: String,
        placement: TextSubtitlePlacement = .automatic
    ) {
        self.text = text
        self.placement = placement
    }
}
