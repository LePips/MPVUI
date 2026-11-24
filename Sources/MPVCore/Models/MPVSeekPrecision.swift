/// How accurately a seek targets the requested timestamp.
public enum MPVSeekPrecision: String, CaseIterable, Equatable, Sendable {

    /// Decodes from the preceding keyframe to land on the exact timestamp.
    case exact
    /// Lands on the nearest keyframe for faster interactive skipping and scrubbing.
    case keyframes

    package var absoluteFlag: String {
        switch self {
        case .exact: "absolute+exact"
        case .keyframes: "absolute+keyframes"
        }
    }

    package var relativeFlag: String {
        switch self {
        case .exact: "relative+exact"
        case .keyframes: "relative+keyframes"
        }
    }
}
