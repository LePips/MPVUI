/// The encoded and display dimensions of a video stream.
public struct MPVVideoDimensions: Equatable, Hashable, Sendable {
    /// Encoded width in pixels.
    public let width: Int

    /// Encoded height in pixels.
    public let height: Int

    /// Display width after applying pixel-aspect correction, when reported.
    public let displayWidth: Int?

    /// Display height after applying pixel-aspect correction, when reported.
    public let displayHeight: Int?

    /// Creates a video-dimensions value.
    ///
    /// Negative dimensions are normalized to zero. Negative optional display
    /// dimensions are discarded.
    ///
    /// - Parameters:
    ///   - width: Encoded width in pixels.
    ///   - height: Encoded height in pixels.
    ///   - displayWidth: Pixel-aspect-corrected display width, when known.
    ///   - displayHeight: Pixel-aspect-corrected display height, when known.
    public init(
        width: Int,
        height: Int,
        displayWidth: Int? = nil,
        displayHeight: Int? = nil
    ) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.displayWidth = displayWidth.flatMap { $0 >= 0 ? $0 : nil }
        self.displayHeight = displayHeight.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// Width used for presentation, falling back to the encoded width.
    public var effectiveWidth: Int {
        displayWidth ?? width
    }

    /// Height used for presentation, falling back to the encoded height.
    public var effectiveHeight: Int {
        displayHeight ?? height
    }

    /// The presentation aspect ratio, or `nil` when it cannot be determined.
    public var aspectRatio: Double? {
        guard effectiveWidth > 0, effectiveHeight > 0 else { return nil }
        return Double(effectiveWidth) / Double(effectiveHeight)
    }

    /// Whether either encoded dimension is unavailable.
    public var isEmpty: Bool {
        width == 0 || height == 0
    }

    /// Video dimensions with no reported size.
    public static let empty = Self(width: 0, height: 0)
}
