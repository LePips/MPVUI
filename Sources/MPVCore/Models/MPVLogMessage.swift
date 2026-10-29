/// A copied mpv diagnostic message.
public struct MPVLogMessage: Equatable, Sendable {

    /// The mpv component that emitted the message.
    public let prefix: String
    /// The message severity.
    public let level: MPVLogLevel
    /// The copied diagnostic text.
    public let message: String

    /// Creates a log message with its native component and severity.
    public init(prefix: String, level: MPVLogLevel, message: String) {
        self.prefix = prefix
        self.level = level
        self.message = message
    }
}
