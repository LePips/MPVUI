import Foundation
import MPVUI

enum ExampleDisplayFormat {
    static func duration(_ duration: Duration?) -> String {
        guard let duration, duration >= .zero else { return "—" }

        let wholeSeconds = Duration.seconds(duration.components.seconds)
        let pattern: Duration.TimeFormatStyle.Pattern =
            wholeSeconds >= .seconds(3600) ? .hourMinuteSecond : .minuteSecond
        return wholeSeconds.formatted(.time(pattern: pattern))
    }

    static func dimensions(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "—" }
        return "\(width)×\(height)"
    }

    static func frameRate(_ framesPerSecond: Double?) -> String {
        guard let framesPerSecond, framesPerSecond.isFinite, framesPerSecond > 0 else {
            return "—"
        }

        if framesPerSecond.rounded() == framesPerSecond {
            return "\(Int(framesPerSecond)) fps"
        }
        return "\(number(framesPerSecond, fractionDigits: 2)) fps"
    }

    static func dataRate(_ bytesPerSecond: Int64) -> String {
        let nonnegativeRate = max(0, bytesPerSecond)
        if nonnegativeRate >= 1_000_000 {
            return "\(number(Double(nonnegativeRate) / 1_000_000, fractionDigits: 1)) MB/s"
        }
        if nonnegativeRate >= 1000 {
            return "\(number(Double(nonnegativeRate) / 1000, fractionDigits: 1)) KB/s"
        }
        return "\(nonnegativeRate) B/s"
    }

    static func bytes(_ byteCount: Int64?) -> String {
        guard let byteCount, byteCount >= 0 else { return "—" }
        if byteCount >= 1_000_000_000 {
            return "\(number(Double(byteCount) / 1_000_000_000, fractionDigits: 2)) GB"
        }
        if byteCount >= 1_000_000 {
            return "\(number(Double(byteCount) / 1_000_000, fractionDigits: 1)) MB"
        }
        if byteCount >= 1000 {
            return "\(number(Double(byteCount) / 1000, fractionDigits: 1)) KB"
        }
        return "\(byteCount) B"
    }

    static func percentage(_ value: Double) -> String {
        let finiteValue = value.isFinite ? value : 0
        return "\(Int((clamp(finiteValue, to: 0 ... 1) * 100).rounded()))%"
    }

    static func decimal(_ value: Double?, suffix: String = "") -> String {
        guard let value, value.isFinite else { return "—" }
        let rendered: String = if value.rounded() == value {
            "\(Int(value))"
        } else {
            number(value, fractionDigits: 2)
        }
        return suffix.isEmpty ? rendered : "\(rendered) \(suffix)"
    }

    static func decimal(_ duration: Duration?, suffix: String = "") -> String {
        decimal(duration?.seconds, suffix: suffix)
    }

    static func playbackState(_ state: MPVPlaybackState) -> String {
        switch state {
        case .idle: "Idle"
        case .loading: "Loading"
        case .ready: "Ready"
        case .playing: "Playing"
        case .paused: "Paused"
        case .buffering: "Buffering"
        case .seeking: "Seeking"
        case .ended: "Ended"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    static func transferFunction(_ transferFunction: MPVTransferFunction) -> String {
        switch transferFunction {
        case .unknown: "Unknown"
        case .bt709: "BT.709"
        case .bt1886: "BT.1886"
        case .sRGB: "sRGB"
        case .linear: "Linear"
        case .gamma18: "Gamma 1.8"
        case .gamma20: "Gamma 2.0"
        case .gamma22: "Gamma 2.2"
        case .gamma24: "Gamma 2.4"
        case .gamma26: "Gamma 2.6"
        case .gamma28: "Gamma 2.8"
        case .pq: "PQ (ST 2084)"
        case .hlg: "HLG"
        case let .other(value): value
        }
    }

    static func track(_ track: MPVMediaTrack) -> String {
        let values: [String?] = [track.title, track.language, track.codec]
        var parts: [String] =
            values
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
        if track.isDefault {
            parts.append("Default")
        }
        if track.isForced {
            parts.append("Forced")
        }
        if track.isExternal {
            parts.append("External")
        }
        return parts.isEmpty ? "Track \(track.mpvID)" : parts.joined(separator: " · ")
    }

    private static func number(_ value: Double, fractionDigits: Int) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .grouping(.never)
        )
    }
}
