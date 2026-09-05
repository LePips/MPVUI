final class MPVRenderTarget: @unchecked Sendable {
    let layerAddress: Int64
    let layerOwner: AnyObject
    let drawableWidth: Int
    let drawableHeight: Int
    let usesExtendedDynamicRange: Bool
    let displaySupportsExtendedDynamicRange: Bool
    let outputHeadroom: Double

    init(
        layerAddress: Int64,
        layerOwner: AnyObject,
        drawableWidth: Int,
        drawableHeight: Int,
        usesExtendedDynamicRange: Bool,
        displaySupportsExtendedDynamicRange: Bool,
        outputHeadroom: Double
    ) {
        self.layerAddress = layerAddress
        self.layerOwner = layerOwner
        self.drawableWidth = max(0, drawableWidth)
        self.drawableHeight = max(0, drawableHeight)
        self.usesExtendedDynamicRange = usesExtendedDynamicRange
        self.displaySupportsExtendedDynamicRange = displaySupportsExtendedDynamicRange
        self.outputHeadroom = outputHeadroom
    }

    func matches(_ other: MPVRenderTarget) -> Bool {
        layerAddress == other.layerAddress
            && drawableWidth == other.drawableWidth
            && drawableHeight == other.drawableHeight
            && usesExtendedDynamicRange == other.usesExtendedDynamicRange
            && displaySupportsExtendedDynamicRange == other.displaySupportsExtendedDynamicRange
            && abs(outputHeadroom - other.outputHeadroom) < 0.01
    }

    func matchesSurfaceConfiguration(_ other: MPVRenderTarget) -> Bool {
        layerAddress == other.layerAddress
            && usesExtendedDynamicRange == other.usesExtendedDynamicRange
            && displaySupportsExtendedDynamicRange == other.displaySupportsExtendedDynamicRange
            && abs(outputHeadroom - other.outputHeadroom) < 0.01
    }

    func replacingDrawableSize(width: Int, height: Int) -> MPVRenderTarget {
        MPVRenderTarget(
            layerAddress: layerAddress,
            layerOwner: layerOwner,
            drawableWidth: width,
            drawableHeight: height,
            usesExtendedDynamicRange: usesExtendedDynamicRange,
            displaySupportsExtendedDynamicRange: displaySupportsExtendedDynamicRange,
            outputHeadroom: outputHeadroom
        )
    }
}
