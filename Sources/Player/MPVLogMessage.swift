/// A copied mpv diagnostic message.
public struct MPVLogMessage: Equatable, Sendable {
    /// The mpv component that emitted the message.
    public let prefix: String
    /// The message severity.
    public let level: MPVPlayerConfiguration.LogLevel
    /// The copied diagnostic text.
    public let message: String
}
