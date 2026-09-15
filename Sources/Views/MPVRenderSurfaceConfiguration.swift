import CoreGraphics

/// The display and color contract shared by every native player surface.
struct MPVRenderSurfaceConfiguration: Sendable {
    let usesExtendedDynamicRange: Bool
    let displaySupportsExtendedDynamicRange: Bool
    let drawableSize: CGSize
    let scale: CGFloat
    let outputHeadroom: Double
    let displayCapabilities: MPVDisplayCapabilities
    let configuredDynamicRange: MPVPresentationStatus.DynamicRange
    let policyFallbackReason: MPVPresentationStatus.FallbackReason?
    let colorConfiguration: MPVRenderColorConfiguration?

    init(
        usesExtendedDynamicRange: Bool,
        displaySupportsExtendedDynamicRange: Bool,
        drawableSize: CGSize,
        scale: CGFloat,
        outputHeadroom: Double,
        displayCapabilities: MPVDisplayCapabilities? = nil,
        configuredDynamicRange: MPVPresentationStatus.DynamicRange? = nil,
        policyFallbackReason: MPVPresentationStatus.FallbackReason? = nil,
        colorConfiguration: MPVRenderColorConfiguration? = nil
    ) {
        self.usesExtendedDynamicRange = usesExtendedDynamicRange
        self.displaySupportsExtendedDynamicRange =
            displaySupportsExtendedDynamicRange
        self.drawableSize = drawableSize
        self.scale = scale
        self.outputHeadroom = Self.quantizedOutputHeadroom(outputHeadroom)
        self.displayCapabilities = displayCapabilities ?? MPVDisplayCapabilities(
            hdrSupport: displaySupportsExtendedDynamicRange ? .supported : .unsupported,
            currentEDRHeadroom: outputHeadroom,
            potentialEDRHeadroom: outputHeadroom
        )
        self.configuredDynamicRange = configuredDynamicRange
            ?? (usesExtendedDynamicRange ? .hdr : .sdr)
        self.policyFallbackReason = policyFallbackReason
        self.colorConfiguration = colorConfiguration
    }

    static func drawableSize(for boundsSize: CGSize, scale: CGFloat) -> CGSize {
        CGSize(
            width: max(
                0,
                (boundsSize.width * scale).rounded(.toNearestOrEven)
            ),
            height: max(
                0,
                (boundsSize.height * scale).rounded(.toNearestOrEven)
            )
        )
    }

    func requiresRendererReconfiguration(
        comparedTo other: MPVRenderSurfaceConfiguration
    ) -> Bool {
        usesExtendedDynamicRange != other.usesExtendedDynamicRange
            || displaySupportsExtendedDynamicRange
            != other.displaySupportsExtendedDynamicRange
            || outputHeadroom != other.outputHeadroom
            || displayCapabilities != other.displayCapabilities
            || configuredDynamicRange != other.configuredDynamicRange
            || policyFallbackReason != other.policyFallbackReason
            || colorConfiguration != other.colorConfiguration
    }

    func requiresGeometryCommit(
        comparedTo other: MPVRenderSurfaceConfiguration
    ) -> Bool {
        drawableSize != other.drawableSize
            || abs(scale - other.scale) >= .ulpOfOne
    }

    private static func quantizedOutputHeadroom(_ outputHeadroom: Double) -> Double {
        guard outputHeadroom.isFinite else { return 1 }
        let clampedHeadroom = max(outputHeadroom, 1)
        let scaledHeadroom = clampedHeadroom * 100
        guard scaledHeadroom.isFinite else { return clampedHeadroom }
        return scaledHeadroom.rounded(.toNearestOrEven) / 100
    }
}
