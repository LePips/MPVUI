/// A named chapter on a media timeline.
public struct MPVChapter: Identifiable, Equatable, Hashable, Sendable {
    /// The chapter's zero-based index.
    public let id: Int

    /// A display title embedded in the media, when present.
    public let title: String?

    /// The chapter's first timeline position.
    public let startTime: Duration

    /// The chapter's final timeline position, when known.
    public let endTime: Duration?

    init(
        id: Int,
        title: String? = nil,
        startTime: Duration,
        endTime: Duration? = nil
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
    }

    /// The nonnegative chapter duration, when an end time is available.
    public var duration: Duration? {
        guard let endTime else { return nil }
        return (endTime - startTime).clampPositiveOrZero
    }
}
