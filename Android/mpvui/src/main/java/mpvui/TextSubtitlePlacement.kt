package mpvui

/** Placement of a semantic subtitle region within the video viewport. */
sealed class TextSubtitlePlacement {
    /** Client-defined placement for non-WebVTT text. */
    data object Automatic : TextSubtitlePlacement()
    /** Placement resolved from authored WebVTT cue settings. */
    data class WebVTT(val placement: WebVTTPlacement) : TextSubtitlePlacement()
}

/** WebVTT placement in normalized video coordinates, matching the Swift model.
 * Positions can extend beyond 0...1. Dimensions limit the cue box rather than measure it.
 * Snap-to-line positions are estimates; exact layout depends on the host's font and collision handling.
 */
data class WebVTTPlacement(
    val horizontalPosition: Float,
    val verticalPosition: Float,
    val horizontalAnchor: HorizontalAnchor = HorizontalAnchor.CENTER,
    val verticalAnchor: VerticalAnchor = VerticalAnchor.BOTTOM,
    val maximumWidth: Float? = null,
    val maximumHeight: Float? = null,
    val textAlignment: TextAlignment = TextAlignment.CENTER,
    val writingDirection: WritingDirection = WritingDirection.HORIZONTAL,
) {
    /** The cue-box edge or center attached to the horizontal position. */
    enum class HorizontalAnchor { CENTER, LEFT, RIGHT }
    /** The cue-box edge or center attached to the vertical position. */
    enum class VerticalAnchor { CENTER, TOP, BOTTOM }
    /** Physical alignment inside the cue box, after resolving text direction. */
    enum class TextAlignment { CENTER, LEFT, RIGHT }
    /** Direction of text lines and progression of successive vertical lines. */
    enum class WritingDirection { HORIZONTAL, VERTICAL_GROWING_LEFT, VERTICAL_GROWING_RIGHT }
}
