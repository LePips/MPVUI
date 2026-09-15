final class MPVRenderTarget: @unchecked Sendable {
    let layerAddress: Int64
    let layerOwner: AnyObject
    let drawableWidth: Int
    let drawableHeight: Int
    let usesExtendedDynamicRange: Bool
    let displaySupportsExtendedDynamicRange: Bool
    let outputHeadroom: Double
    let displayCapabilities: MPVDisplayCapabilities
    let configuredDynamicRange: MPVPresentationStatus.DynamicRange
    let policyFallbackReason: MPVPresentationStatus.FallbackReason?
    let colorConfiguration: MPVRenderColorConfiguration?

    init(
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
        colorConfiguration: MPVRenderColorConfiguration? = nil
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

    func matches(_ other: MPVRenderTarget) -> Bool {
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

    func matchesSurfaceConfiguration(_ other: MPVRenderTarget) -> Bool {
        layerAddress == other.layerAddress
            && usesExtendedDynamicRange == other.usesExtendedDynamicRange
            && displaySupportsExtendedDynamicRange == other.displaySupportsExtendedDynamicRange
            && abs(outputHeadroom - other.outputHeadroom) < 0.01
            && displayCapabilities == other.displayCapabilities
            && configuredDynamicRange == other.configuredDynamicRange
            && policyFallbackReason == other.policyFallbackReason
            && colorConfiguration == other.colorConfiguration
    }

    func replacingDrawableSize(width: Int, height: Int) -> MPVRenderTarget {
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
