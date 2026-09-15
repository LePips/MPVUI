import Foundation

/// Structured native diagnostics come from the VO or the decoder's registered
/// owner log. Arbitrary quoted error text must not be interpreted as a sentinel.
enum MPVNativeDiagnosticParser {
    static func payload(
        _ log: MPVLogMessage,
        sentinel: String,
        allowsDecoder: Bool = false
    ) -> String? {
        var text = log.message.trimmingCharacters(in: .whitespacesAndNewlines)
        switch log.prefix {
        case "vo/avfoundation":
            break
        case "ffmpeg/video" where allowsDecoder:
            // common/av_log.c optionally prepends AVCodecContext.item_name.
            // Decoder diagnostics are routed by their registered opaque owner,
            // not through FFmpeg's process-global first-player log.
            if !text.hasPrefix(sentinel), let separator = text.range(of: ": ") {
                let codec = String(text[..<separator.lowerBound])
                guard ["hevc", "h264", "av1", "vp9", "mpeg2video", "mpeg4", "h263", "vc1", "prores"].contains(codec) else {
                    return nil
                }
                text = String(text[separator.upperBound...])
            }
        default:
            return nil
        }
        guard text.hasPrefix(sentinel) else { return nil }
        return String(text.dropFirst(sentinel.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
