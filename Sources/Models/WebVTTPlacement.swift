/// WebVTT cue placement in normalized video coordinates.
///
/// Positions can fall outside `0 ... 1` when a cue intentionally extends
/// beyond the viewport. Maximum dimensions constrain the cue box when
/// present; they are not its measured size. Snap-to-line coordinates can be
/// approximate because their exact position depends on the client's font and
/// collision layout.
public struct WebVTTPlacement: Sendable, Hashable {
    /// The point on the cue box selected along the horizontal axis.
    public enum HorizontalAnchor: Sendable, Hashable {
        case center
        case left
        case right
    }

    /// The point on the cue box selected along the vertical axis.
    public enum VerticalAnchor: Sendable, Hashable {
        case center
        case top
        case bottom
    }

    /// The physical alignment of text inside the cue box.
    public enum TextAlignment: Sendable, Hashable {
        case center
        case left
        case right
    }

    /// The direction in which lines are laid out.
    public enum WritingDirection: Sendable, Hashable {
        case horizontal
        case verticalGrowingLeft
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

    /// Creates resolved WebVTT placement information.
    public init(
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
