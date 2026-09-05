import CoreGraphics
import Foundation
import Metal
import QuartzCore

/// A shared Metal layer that preserves MPVUI's host contract while MoltenVK
/// retires or replaces a swapchain.
final class MPVMetalLayer: CAMetalLayer {
    /// Native libmpv and MoltenVK surface extents use a signed C `int`.
    static let maximumDrawableDimension = CGFloat(Int32.max)

    #if os(iOS)
    private var hostExtendedDynamicRangeContent: Bool?
    #endif

    private let drawableStateLock = NSLock()
    private var storedLastValidDrawableSize: CGSize?
    private var nativeResizeTransactionCount = 0

    override var colorspace: CGColorSpace? {
        get { super.colorspace }
        set {
            guard !Self.matchesColorSpace(super.colorspace, newValue) else { return }
            super.colorspace = newValue
        }
    }

    override var pixelFormat: MTLPixelFormat {
        get { super.pixelFormat }
        set {
            guard super.pixelFormat != newValue else { return }
            super.pixelFormat = newValue
        }
    }

    override var isOpaque: Bool {
        get { true }
        set {
            guard !super.isOpaque else { return }
            super.isOpaque = true
        }
    }

    override var contentsGravity: CALayerContentsGravity {
        get { .resizeAspectFill }
        set {
            guard super.contentsGravity != .resizeAspectFill else { return }
            super.contentsGravity = .resizeAspectFill
        }
    }

    #if canImport(UIKit)
    /// MoltenVK configures both filters while creating a swapchain on its
    /// render thread. UIKit requires mutations of a view-owned layer to occur
    /// on main, so preserve the request without blocking the renderer.
    override var minificationFilter: CALayerContentsFilter {
        get { super.minificationFilter }
        set {
            if Thread.isMainThread {
                applyMinificationFilter(newValue)
            } else {
                DispatchQueue.main.async(
                    execute: DispatchWorkItem { [weak self] in
                        self?.applyMinificationFilter(newValue)
                    }
                )
            }
        }
    }

    override var magnificationFilter: CALayerContentsFilter {
        get { super.magnificationFilter }
        set {
            if Thread.isMainThread {
                applyMagnificationFilter(newValue)
            } else {
                DispatchQueue.main.async(
                    execute: DispatchWorkItem { [weak self] in
                        self?.applyMagnificationFilter(newValue)
                    }
                )
            }
        }
    }
    #endif

    override var drawableSize: CGSize {
        get {
            drawableStateLock.lock()
            defer { drawableStateLock.unlock() }
            return super.drawableSize
        }
        set {
            guard newValue.width.isFinite, newValue.height.isFinite else { return }

            drawableStateLock.lock()
            defer { drawableStateLock.unlock() }

            if Self.isMoltenVKRetirementSentinel(newValue) {
                guard !Thread.isMainThread,
                      storedLastValidDrawableSize != nil,
                      nativeResizeTransactionCount > 0
                else { return }
                super.drawableSize = newValue
                return
            }

            guard Self.isValidDrawableSize(newValue) else { return }

            // Unlike colorspace and pixelFormat, an equal drawable-size write
            // is not redundant. MoltenVK uses it while installing a replacement
            // swapchain to invalidate CAMetalLayer's cached drawable pool.
            super.drawableSize = newValue
            storedLastValidDrawableSize = newValue
        }
    }

    static func isValidDrawableSize(_ size: CGSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width > 1
            && size.height > 1
            && size.width <= maximumDrawableDimension
            && size.height <= maximumDrawableDimension
    }

    /// Limits MoltenVK's retirement sentinel exception to a host-authorized
    /// synchronous swapchain replacement. Other background writers remain
    /// subject to the normal 1x1 rejection policy.
    func beginNativeResizeTransaction() {
        drawableStateLock.lock()
        nativeResizeTransactionCount &+= 1
        drawableStateLock.unlock()
    }

    func endNativeResizeTransaction() {
        drawableStateLock.lock()
        nativeResizeTransactionCount = max(nativeResizeTransactionCount - 1, 0)

        // A successful replacement normally installs its final extent before
        // returning. If MoltenVK exits abnormally after writing only its 1x1
        // retirement sentinel, never expose that transient as durable layer
        // geometry once the outermost native transaction has ended.
        if nativeResizeTransactionCount == 0,
           Self.isMoltenVKRetirementSentinel(super.drawableSize),
           let storedLastValidDrawableSize
        {
            super.drawableSize = storedLastValidDrawableSize
        }
        drawableStateLock.unlock()
    }

    private static func isMoltenVKRetirementSentinel(_ size: CGSize) -> Bool {
        size.width == 1 && size.height == 1
    }

    #if os(iOS)
    /// Records the host's EDR policy on main before native rendering starts.
    func configureExtendedDynamicRangeContent(_ newValue: Bool) {
        precondition(Thread.isMainThread)
        hostExtendedDynamicRangeContent = newValue
        if #available(iOS 26.0, *) {
            return
        }
        setExtendedDynamicRangeContent(newValue)
    }

    /// MoltenVK can write this property from its render queue. Redundant native
    /// writes are ignored and valid writes are marshalled without blocking it.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                applyExtendedDynamicRangeRequest(newValue)
            } else {
                DispatchQueue.main.async(
                    execute: DispatchWorkItem { [weak self] in
                        self?.applyExtendedDynamicRangeRequest(newValue)
                    }
                )
            }
        }
    }

    private func applyExtendedDynamicRangeRequest(_ newValue: Bool) {
        precondition(Thread.isMainThread)
        guard hostExtendedDynamicRangeContent == newValue else { return }
        if #available(iOS 26.0, *) {
            return
        }
        setExtendedDynamicRangeContent(newValue)
    }

    private func setExtendedDynamicRangeContent(_ newValue: Bool) {
        guard super.wantsExtendedDynamicRangeContent != newValue else { return }
        super.wantsExtendedDynamicRangeContent = newValue
    }
    #endif

    #if canImport(UIKit)
    private func applyMinificationFilter(_ newValue: CALayerContentsFilter) {
        precondition(Thread.isMainThread)
        guard super.minificationFilter != newValue else { return }
        super.minificationFilter = newValue
    }

    private func applyMagnificationFilter(_ newValue: CALayerContentsFilter) {
        precondition(Thread.isMainThread)
        guard super.magnificationFilter != newValue else { return }
        super.magnificationFilter = newValue
    }
    #endif

    private static func matchesColorSpace(
        _ lhs: CGColorSpace?,
        _ rhs: CGColorSpace?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            if lhs === rhs {
                return true
            }
            guard let lhsName = lhs.name, let rhsName = rhs.name else { return false }
            return lhsName == rhsName
        default:
            return false
        }
    }
}
