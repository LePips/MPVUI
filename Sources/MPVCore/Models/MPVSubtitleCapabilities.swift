/// Semantic text support for a reported subtitle format.
/// These describe extraction support, not source readiness or renderer availability.
public struct MPVSubtitleCapabilities: Hashable, Sendable {

    // Matches the sub-text-cues guard in the bundled native query patch.
    private static let queryCodecs: Set<String> = ["subrip", "srt", "webvtt", "webvtt-webm", "ttml", "mov_text", "text"]
    // The native ASS converter exposes plain text for these legacy formats,
    // but the full-source query command intentionally supports a smaller set.
    private static let additionalLiveCodecs: Set<String> = [
        "microdvd",
        "subviewer",
        "subviewer1",
        "sami",
        "realtext",
        "jacosub",
        "mpl2",
        "vplayer",
        "pjs",
        "stl",
        "scc",
        "eia_608"
    ]
    /// Whether the format can provide live semantic cues when text interception is enabled
    /// and the track is selected and visible. ASS/SSA styling and bitmap formats stay native.
    public let supportsLiveText: Bool

    /// Whether the format supports full timeline queries, including while unselected.
    /// Queries also require a loaded, finite, fully seekable source. Reads can fail or be
    /// canceled. Partial live timelines and ordered-chapter virtual timelines are unsupported.
    public let supportsTimelineQueries: Bool

    /// Whether this format requires native composition instead of a semantic text overlay.
    /// Unknown formats conservatively require native composition.
    public var requiresNativeComposition: Bool {
        !supportsLiveText
    }

    package init(codec: String?) {
        let codec = codec?.lowercased() ?? ""
        supportsTimelineQueries = Self.queryCodecs.contains(codec)
        supportsLiveText = supportsTimelineQueries || Self.additionalLiveCodecs.contains(codec)
    }
}
