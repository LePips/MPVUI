/// Placement information for a semantic text subtitle region.
public enum TextSubtitlePlacement: Sendable, Hashable {
    /// Placement is intentionally left to the client.
    ///
    /// SubRip, TTML, `mov_text`, and other non-WebVTT semantic text formats
    /// use automatic placement.
    case automatic

    /// Placement derived from a WebVTT cue's positioning settings.
    case webVTT(WebVTTPlacement)
}
