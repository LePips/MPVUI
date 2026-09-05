/// A playback error surfaced by an ``MPVPlayer``.
public struct MPVPlayerError: Error, Equatable, Sendable {
    /// The localized description of the failure.
    public let localizedDescription: String

    /// Creates a playback error with a localized description.
    public init(localizedDescription: String) {
        self.localizedDescription = localizedDescription
    }
}
