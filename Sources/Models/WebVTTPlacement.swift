/// WebVTT cue placement in normalized video coordinates.
///
/// Positions may extend outside `0...1`. Maximum dimensions constrain the cue box;
/// they do not measure it. Snap-to-line positions are approximate; exact placement
/// depends on the client's font and collision layout.
public struct WebVTTPlacement: Sendable, Hashable {
    /// The point on the cue box selected along the horizontal axis.
    public enum HorizontalAnchor: Sendable, Hashable {
        /// The horizontal center of the cue box.
        case center
        /// The left edge of the cue box.
        case left
        /// The right edge of the cue box.
        case right
    }

    /// The point on the cue box selected along the vertical axis.
    public enum VerticalAnchor: Sendable, Hashable {
        /// The vertical center of the cue box.
        case center
        /// The top edge of the cue box.
        case top
        /// The bottom edge of the cue box.
        case bottom
    }

    /// The physical alignment of text inside the cue box.
    public enum TextAlignment: Sendable, Hashable {
        /// Centers text within the cue box.
        case center
        /// Aligns text to the left edge.
        case left
        /// Aligns text to the right edge.
        case right
    }

    /// The direction in which lines are laid out.
    public enum WritingDirection: Sendable, Hashable {
        /// Horizontal text lines.
        case horizontal
        /// Vertical text with successive lines placed to the left.
        case verticalGrowingLeft
        /// Vertical text with successive lines placed to the right.
        case verticalGrowingRight
    }

    /// The normalized horizontal viewport position.
    public let horizontalPosition: Float

    /// The normalized vertical viewport position.
    public let verticalPosition: Float

    /// The cue-box anchor placed at ``horizontalPosition``.
    public let horizontalAnchor: HorizontalAnchor

    /// The cue-box anchor placed at ``verticalPosition``.
    public let verticalAnchor: VerticalAnchor

    /// The optional maximum cue-box width, normalized to viewport width.
    public let maximumWidth: Float?

    /// The optional maximum cue-box height, normalized to viewport height.
    public let maximumHeight: Float?

    /// The physical text alignment inside the cue box.
    public let textAlignment: TextAlignment

    /// The cue's resolved writing direction.
    public let writingDirection: WritingDirection

    init(
        horizontalPosition: Float,
        verticalPosition: Float,
        horizontalAnchor: HorizontalAnchor = .center,
        verticalAnchor: VerticalAnchor = .bottom,
        maximumWidth: Float? = nil,
        maximumHeight: Float? = nil,
        textAlignment: TextAlignment = .center,
        writingDirection: WritingDirection = .horizontal
    ) {
        self.horizontalPosition = horizontalPosition
        self.verticalPosition = verticalPosition
        self.horizontalAnchor = horizontalAnchor
        self.verticalAnchor = verticalAnchor
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.textAlignment = textAlignment
        self.writingDirection = writingDirection
    }
}
