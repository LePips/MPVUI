/// The resolved destination of a completed seek within one source load.
public struct MPVSeekResult: Equatable, Sendable {

    /// The source-load generation that completed the operation.
    public let generation: UInt64
    /// The requested position after clamping to the known timeline.
    public let target: Duration
    /// The native position when playback restarted or reached the endpoint.
    public let position: Duration

    package init(generation: UInt64, target: Duration, position: Duration) {
        self.generation = generation
        self.target = target
        self.position = position
    }
}
