/// A complete semantic text subtitle presentation, in presentation order.
///
/// Empty ``regions`` clears the presentation. Use ``text`` for a flattened string.
public struct TextSubtitleSnapshot: Sendable, Hashable {
    /// The text regions in presentation order.
    public let regions: [TextSubtitleRegion]

    init(regions: [TextSubtitleRegion] = []) {
        self.regions = regions
    }

    /// Region text joined with newlines in presentation order.
    public var text: String {
        regions.map(\.text).joined(separator: "\n")
    }

    /// Whether this snapshot represents a cleared subtitle presentation.
    public var isEmpty: Bool {
        regions.isEmpty
    }
}
