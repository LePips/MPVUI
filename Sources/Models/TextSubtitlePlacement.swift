/// Placement information for a semantic text subtitle region.
public enum TextSubtitlePlacement: Sendable, Hashable {
    /// Client-defined placement for SubRip, TTML, `mov_text`, and other non-WebVTT text.
    case automatic

    /// Placement derived from a WebVTT cue's positioning settings.
    case webVTT(WebVTTPlacement)
}
