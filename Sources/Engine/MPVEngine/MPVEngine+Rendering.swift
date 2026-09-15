import Dispatch
import Foundation

// Attaches render surfaces and applies live size, color, and backend changes.
extension MPVEngine {
    func attach(to target: MPVRenderTarget) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.didRequestNativeOutputFallback else { return }

            if let currentTarget = self.renderTarget, currentTarget.layerAddress == target.layerAddress {
                if self.handle != nil {
                    self.updateRenderTargetImmediately(target, previous: currentTarget)
                    return
                }
                // A failed initialization remains stable until the surface is
                // explicitly detached/re-activated or its configuration
                // changes. SwiftUI updates must not spin retrying the same
                // failing libmpv context.
                if self.fatalPlaybackError != nil, currentTarget.matchesSurfaceConfiguration(target) {
                    return
                }
            }

            if self.handle != nil {
                self.destroyHandle(preservePlayback: true)
            }

            self.renderTarget = target
            self.outputHeadroom = max(1, target.outputHeadroom)
            self.createHandle()
        }
    }

    func resizeRenderTargetAndWait(
        width: Int,
        height: Int,
        forLayerAddress layerAddress: Int64,
        force: Bool = false
    ) async -> Bool {
        guard Self.isValidDrawableExtent(width: width, height: height) else { return false }
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(
                    returning: self.resizeRenderTargetImmediately(
                        width: width,
                        height: height,
                        forLayerAddress: layerAddress,
                        force: force
                    )
                )
            }
        }
    }

    /// The native fence stops submissions and drains GPU work before main changes
    /// the layer. Native rendering never synchronously dispatches to main.
    func beginColorUpdate(forLayerAddress address: Int64) -> Bool {
        queue.sync {
            guard colorUpdateLayerAddress == nil, renderTarget?.layerAddress == address else { return false }
            colorUpdateHasNativeFence = false
            // An initialized handle without any current or pending item has no
            // VO/GPU submissions to drain. Preserve its future output contract
            // now; a loading item must acquire the real native fence instead.
            guard handle != nil, !isRendererIdleWithoutSource else {
                colorUpdateLayerAddress = address
                return true
            }
            guard videoOutput == .metal,
                  setPropertyImmediately("external-surface-update", to: "yes") >= 0 else { return false }
            colorUpdateLayerAddress = address
            colorUpdateHasNativeFence = true
            return true
        }
    }

    func finishColorUpdate(target: MPVRenderTarget) {
        queue.sync {
            guard colorUpdateLayerAddress == target.layerAddress else { return }
            defer {
                colorUpdateLayerAddress = nil
                let hadNativeFence = colorUpdateHasNativeFence
                colorUpdateHasNativeFence = false
                if hadNativeFence, handle != nil {
                    let status = setPropertyImmediately("external-surface-update", to: "no")
                    if status < 0 {
                        liveConfigurationFailure = "external-surface-update"
                        publishCommandError(status, context: "Resume color-managed surface")
                    }
                }
            }
            guard let previous = renderTarget, previous.layerAddress == target.layerAddress else { return }
            updateRenderTargetImmediately(target, previous: previous)
        }
    }

    private var isRendererIdleWithoutSource: Bool {
        sourceURL == nil && !needsSourceLoad && !isLoading && !playbackRequestIsActive
    }

    func renderOutputSize() async -> MPVRenderOutputSize? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }

                guard let values = self.getNode("osd-dimensions")?.mapValue,
                      let widthValue = values["w"]?.integerValue,
                      let heightValue = values["h"]?.integerValue,
                      let width = Int(exactly: widthValue),
                      let height = Int(exactly: heightValue),
                      width > 0,
                      height > 0
                else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(
                    returning: MPVRenderOutputSize(
                        width: width,
                        height: height
                    )
                )
            }
        }
    }

    func detach(fromLayerAddress layerAddress: Int64) {
        queue.async { [weak self] in
            self?.detachImmediately(fromLayerAddress: layerAddress)
        }
    }

    func detachSynchronously(fromLayerAddress layerAddress: Int64) {
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            detachImmediately(fromLayerAddress: layerAddress)
        } else {
            queue.sync {
                detachImmediately(fromLayerAddress: layerAddress)
            }
        }
    }

    /// Retires whichever render target is still owned by the engine before a
    /// different surface token is allowed to touch its host layer.
    func detachCurrentRenderTargetSynchronously() {
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            detachCurrentRenderTargetImmediately()
        } else {
            queue.sync {
                detachCurrentRenderTargetImmediately()
            }
        }
    }

    /// Switch only after the old VO has retired; each backend requires a
    /// different layer type. The current view supplies the new target next.
    func switchVideoOutputSynchronously(
        to videoOutput: MPVPlayerConfiguration.VideoOutput,
        preservePlayback: Bool,
        fallbackReason: MPVPresentationStatus.FallbackReason? = nil
    ) {
        let change = {
            self.destroyHandle(preservePlayback: preservePlayback)
            self.renderTarget = nil
            self.videoOutput = videoOutput
            self.presentationFallbackReason = fallbackReason
            self.liveConfigurationFailure = nil
            self.didRequestNativeOutputFallback = false
            self.fatalPlaybackError = nil
            if !preservePlayback {
                // destroyHandle may have no handle left after a rejected VO.
                // Never reload the previous URL while attaching the new layer.
                self.sourceURL = nil
                self.pendingStartTime = nil
                self.pendingSeekAfterLoad = nil
                self.needsSourceLoad = false
                self.playbackRequestIsActive = false
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            change()
        } else {
            queue.sync(execute: change)
        }
    }

    private func updateRenderTargetImmediately(_ target: MPVRenderTarget, previous: MPVRenderTarget) {
        guard !previous.matches(target) else { return }
        let changedColor = !previous.matchesSurfaceConfiguration(target)
        renderTarget = target
        outputHeadroom = target.outputHeadroom
        if videoOutput == .metal {
            if changedColor {
                liveConfigurationFailure = nil
                let options = Self.colorTargetOptions(for: target)
                for (name, value) in options {
                    let status = setPropertyImmediately(name, to: value)
                    if status < 0 {
                        liveConfigurationFailure = name
                        publishCommandError(status, context: "Update render color target \(name)")
                    }
                }
                lifecycleDiagnostics.liveColorUpdates &+= 1
            }
            if previous.drawableWidth != target.drawableWidth
                || previous.drawableHeight != target.drawableHeight
                || previous.usesExtendedDynamicRange != target.usesExtendedDynamicRange
                || previous.colorConfiguration?.pixelFormat != target.colorConfiguration?.pixelFormat
            {
                // The embedding option has force_update=true and synchronously
                // reaches VOCTRL_EXTERNAL_RESIZE, including equal extents when
                // a color-space change needs a fresh swapchain description.
                let resized = resizeRenderTargetImmediately(
                    width: target.drawableWidth, height: target.drawableHeight,
                    forLayerAddress: target.layerAddress, force: true
                )
                if !resized {
                    liveConfigurationFailure = "external-surface-size"
                }
            }
        }
        refreshMediaInformation()
    }

    @discardableResult
    private func resizeRenderTargetImmediately(
        width: Int,
        height: Int,
        forLayerAddress layerAddress: Int64,
        force: Bool = false
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard Self.isValidDrawableExtent(width: width, height: height),
              let currentTarget = renderTarget,
              currentTarget.layerAddress == layerAddress
        else { return false }
        if !force,
           currentTarget.drawableWidth == width,
           currentTarget.drawableHeight == height
        {
            return true
        }

        guard handle != nil else {
            // Keep the latest geometry so a subsequently created handle starts
            // with the current drawable dimensions.
            renderTarget = currentTarget.replacingDrawableSize(width: width, height: height)
            return true
        }

        let layer = currentTarget.layerOwner as? MPVMetalLayer
        let status: Int32 = {
            layer?.beginNativeResizeTransaction()
            defer { layer?.endNativeResizeTransaction() }
            return setPropertyImmediately(
                "external-surface-size",
                to: "\(width)x\(height)"
            )
        }()
        if status >= 0 {
            renderTarget = currentTarget.replacingDrawableSize(width: width, height: height)
            lifecycleDiagnostics.surfaceResizeCommands &+= 1
            publishRenderSurfaceDiagnostic(
                "mpv resize trigger accepted=\(width)x\(height) "
                    + "lifecycle=\(lifecycleDiagnostics)"
            )
            return true
        }

        publishCommandError(status, context: "Resize Metal render surface")
        return false
    }

    private static func isValidDrawableExtent(width: Int, height: Int) -> Bool {
        width > 1
            && height > 1
            && width <= Int(Int32.max)
            && height <= Int(Int32.max)
    }

    private func detachImmediately(fromLayerAddress layerAddress: Int64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard renderTarget?.layerAddress == layerAddress else { return }

        destroyHandle(preservePlayback: true)
        renderTarget = nil
    }

    private func detachCurrentRenderTargetImmediately() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard renderTarget != nil else { return }

        destroyHandle(preservePlayback: true)
        renderTarget = nil
    }

    static func colorTargetOptions(for target: MPVRenderTarget) -> [(String, String)] {
        target.colorConfiguration?.options ?? colorTargetOptions(
            usesExtendedDynamicRange: target.usesExtendedDynamicRange,
            outputHeadroom: target.outputHeadroom
        )
    }

    static func colorTargetOptions(
        usesExtendedDynamicRange: Bool,
        outputHeadroom: Double
    ) -> [(String, String)] {
        usesExtendedDynamicRange ? [
            ("target-prim", "display-p3"),
            ("target-trc", "linear"),
            ("target-peak", formatTargetPeak(targetPeakNits(forOutputHeadroom: outputHeadroom))),
        ] : [
            ("target-prim", "bt.709"), ("target-trc", "srgb"), ("target-peak", "auto"),
        ]
    }

    static func targetPeakNits(forOutputHeadroom headroom: Double) -> Double {
        sdrReferenceWhiteNits * (headroom.isFinite ? max(1, headroom) : 1)
    }

    private static let sdrReferenceWhiteNits = 203.0

    private static func formatTargetPeak(_ nits: Double) -> String {
        guard nits.isFinite else { return String(Int(sdrReferenceWhiteNits)) }
        let boundedNits = clamp(nits, to: sdrReferenceWhiteNits ... 10000)
        return String(Int(boundedNits.rounded()))
    }
}
