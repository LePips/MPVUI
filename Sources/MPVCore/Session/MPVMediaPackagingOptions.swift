import Foundation

/// Captures track selection and input options for native packaging or mpv rendering.
package struct MPVMediaPackagingOptions: Equatable, Sendable {

    package enum RenderingReason: Sendable {

        case subtitles
        case audioDelay
        case inputOptions
        case trackSelection
    }

    package static let sourceOptionNames: Set<String> = [
        "http-header-fields",
        "user-agent",
        "referrer",
        "cookies",
        "cookies-file",
        "tls-verify",
        "tls-ca-file",
        "network-timeout",
        "demuxer-lavf-o"
    ]

    package var mpv: [String: String]
    package var input: [String: String] = [:]
    package var videoIndex: Int32 = -1
    package var audioIndex: Int32 = -1
    package var hasSelectedExternalTracks = false
    package var renderingReasons: Set<RenderingReason> = []

    package var requiresRenderer: Bool {
        !renderingReasons.isEmpty
    }

    package init(mpv: [String: String] = [:], httpHeaders: [String]? = nil) {
        self.mpv = mpv
        videoIndex = mpv["vid"] == "no" ? -2 : -1
        audioIndex = mpv["aid"] == "no" ? -2 : -1

        // Use mpv's encoder when subtitles, timing, or input options require its renderer or input handling.
        if ["sid", "secondary-sid"].contains(where: {
            let visibility = $0 == "sid" ? "sub-visibility" : "secondary-sub-visibility"
            return mpv[$0] != nil && mpv[$0] != "no" && mpv[visibility] != "no"
        }) {
            renderingReasons.insert(.subtitles)
        }

        if (Double(mpv["audio-delay"] ?? "0") ?? 0) != 0 {
            renderingReasons.insert(.audioDelay)
        }

        if ["cookies", "cookies-file", "demuxer-lavf-o"].contains(where: { mpv[$0] != nil })
            || (mpv["http-header-fields"] != nil && httpHeaders == nil)
        {
            renderingReasons.insert(.inputOptions)
        }

        for (source, target) in [("user-agent", "user_agent"), ("referrer", "referer"), ("tls-ca-file", "ca_file")] {
            input[target] = mpv[source]
        }

        if let httpHeaders, !httpHeaders.isEmpty {
            input["headers"] = httpHeaders.joined(separator: "\r\n") + "\r\n"
        }

        input["tls_verify"] = mpv["tls-verify"] == "no" ? "0" : "1"

        let timeout = Double(mpv["network-timeout"] ?? "60") ?? 60
        input["rw_timeout"] = String(Int64(max(1, min(timeout, 3600)) * 1_000_000))
    }
}
