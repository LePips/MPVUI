package final class MPVRenderTarget: @unchecked Sendable {

    package let layerAddress: Int64
    package let layerOwner: AnyObject
    package let drawableWidth: Int
    package let drawableHeight: Int
    package let usesExtendedDynamicRange: Bool
    package let displaySupportsExtendedDynamicRange: Bool
    package let outputHeadroom: Double
    package let displayCapabilities: MPVDisplayCapabilities
    package let configuredDynamicRange: MPVPresentationStatus.DynamicRange
    package let policyFallbackReason: MPVPresentationStatus.FallbackReason?
    package let colorConfiguration: MPVSurfaceColorConfiguration?

    package init(
        layerAddress: Int64,
        layerOwner: AnyObject,
        drawableWidth: Int,
        drawableHeight: Int,
        usesExtendedDynamicRange: Bool,
        displaySupportsExtendedDynamicRange: Bool,
        outputHeadroom: Double,
        displayCapabilities: MPVDisplayCapabilities? = nil,
        configuredDynamicRange: MPVPresentationStatus.DynamicRange? = nil,
        policyFallbackReason: MPVPresentationStatus.FallbackReason? = nil,
        colorConfiguration: MPVSurfaceColorConfiguration? = nil
    ) {
        self.layerAddress = layerAddress
        self.layerOwner = layerOwner
        self.drawableWidth = max(0, drawableWidth)
        self.drawableHeight = max(0, drawableHeight)
        self.usesExtendedDynamicRange = usesExtendedDynamicRange
        self.displaySupportsExtendedDynamicRange = displaySupportsExtendedDynamicRange
        self.outputHeadroom = outputHeadroom.isFinite ? max(1, outputHeadroom) : 1
        self.displayCapabilities = displayCapabilities ?? MPVDisplayCapabilities(
            hdrSupport: displaySupportsExtendedDynamicRange ? .supported : .unsupported,
            currentEDRHeadroom: self.outputHeadroom
        )
        self.configuredDynamicRange = configuredDynamicRange
            ?? (usesExtendedDynamicRange ? .hdr : .sdr)
        self.policyFallbackReason = policyFallbackReason
        self.colorConfiguration = colorConfiguration
    }

    package func matches(_ other: MPVRenderTarget) -> Bool {
        layerAddress == other.layerAddress
            && drawableWidth == other.drawableWidth
            && drawableHeight == other.drawableHeight
            && usesExtendedDynamicRange == other.usesExtendedDynamicRange
            && displaySupportsExtendedDynamicRange == other.displaySupportsExtendedDynamicRange
            && abs(outputHeadroom - other.outputHeadroom) < 0.01
            && displayCapabilities == other.displayCapabilities
            && configuredDynamicRange == other.configuredDynamicRange
            && policyFallbackReason == other.policyFallbackReason
            && colorConfiguration == other.colorConfiguration
    }

    package func matchesSurfaceConfiguration(_ other: MPVRenderTarget) -> Bool {
        layerAddress == other.layerAddress
            && usesExtendedDynamicRange == other.usesExtendedDynamicRange
            && displaySupportsExtendedDynamicRange == other.displaySupportsExtendedDynamicRange
            && abs(outputHeadroom - other.outputHeadroom) < 0.01
            && displayCapabilities == other.displayCapabilities
            && configuredDynamicRange == other.configuredDynamicRange
            && policyFallbackReason == other.policyFallbackReason
            && colorConfiguration == other.colorConfiguration
    }

    package func replacingDrawableSize(width: Int, height: Int) -> MPVRenderTarget {
        MPVRenderTarget(
            layerAddress: layerAddress,
            layerOwner: layerOwner,
            drawableWidth: width,
            drawableHeight: height,
            usesExtendedDynamicRange: usesExtendedDynamicRange,
            displaySupportsExtendedDynamicRange: displaySupportsExtendedDynamicRange,
            outputHeadroom: outputHeadroom,
            displayCapabilities: displayCapabilities,
            configuredDynamicRange: configuredDynamicRange,
            policyFallbackReason: policyFallbackReason,
            colorConfiguration: colorConfiguration
        )
    }
}
