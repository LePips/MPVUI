/// A copied mpv diagnostic message.
public struct MPVLogMessage: Equatable, Sendable {
    public let prefix: String
    public let level: String
    public let message: String

    public init(prefix: String, level: String, message: String) {
        self.prefix = prefix
        self.level = level
        self.message = message
    }
}
