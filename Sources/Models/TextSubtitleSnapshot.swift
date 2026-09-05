/// A complete, ordered snapshot of the semantic text subtitles currently
/// presented by the player.
///
/// An empty `regions` array represents a cleared subtitle presentation. Use
/// ``text`` when only a flattened subtitle string is needed.
public struct TextSubtitleSnapshot: Sendable, Hashable {
    /// The text regions in presentation order.
    public let regions: [TextSubtitleRegion]

    /// Creates a subtitle snapshot.
    public init(regions: [TextSubtitleRegion] = []) {
        self.regions = regions
    }

    /// The region texts flattened in presentation order.
    public var text: String {
        regions.map(\.text).joined(separator: "\n")
    }

    /// Whether this snapshot represents a cleared subtitle presentation.
    public var isEmpty: Bool {
        regions.isEmpty
    }
}
