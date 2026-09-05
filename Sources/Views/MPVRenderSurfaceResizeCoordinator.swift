import CoreGraphics
import Dispatch
import QuartzCore

/// The geometry lifecycle that produced a render-surface size request.
enum MPVGeometryChangeKind: String, Sendable {
    case continuousInteractive
    case animatedTransition
    case discrete
    case final
}

/// Serializes and coalesces CAMetalLayer-backed mpv resize requests.
///
/// The coordinator deliberately treats the layer's observed `drawableSize` as
/// presentation state, not as acknowledgement from mpv. A size becomes
/// committed only after `commit` returns `true` for the matching surface
/// generation and layer identity.
@MainActor
final class MPVRenderSurfaceResizeCoordinator {
    struct Timing: Sendable {
        var continuousCadenceNanoseconds: UInt64
        var continuousTrailingDelayNanoseconds: UInt64
        var animatedTransitionFallbackDelayNanoseconds: UInt64
        var discreteCoalescingDelayNanoseconds: UInt64

        init(
            continuousCadenceNanoseconds: UInt64 = 33_333_333,
            continuousTrailingDelayNanoseconds: UInt64 = 120_000_000,
            animatedTransitionFallbackDelayNanoseconds: UInt64 = 600_000_000,
            discreteCoalescingDelayNanoseconds: UInt64 = 16_000_000
        ) {
            self.continuousCadenceNanoseconds = continuousCadenceNanoseconds
            self.continuousTrailingDelayNanoseconds =
                continuousTrailingDelayNanoseconds
            self.animatedTransitionFallbackDelayNanoseconds =
                animatedTransitionFallbackDelayNanoseconds
            self.discreteCoalescingDelayNanoseconds =
                discreteCoalescingDelayNanoseconds
        }
    }

    struct CommitRequest: Equatable, Sendable {
        let identifier: UInt64
        let drawableSize: CGSize
        let contentsScale: CGFloat
        let layerAddress: Int64
        let surfaceGeneration: UInt64
        let geometryChangeKind: MPVGeometryChangeKind
        let requestedAtUptimeNanoseconds: UInt64
    }

    enum DiagnosticEvent: String, Sendable {
        case activated
        case deactivated
        case rendererConfigurationChanged
        case surfaceSuperseded
        case continuousInteractionBegan
        case continuousInteractionEnded
        case requested
        case invalidRequest
        case inactiveRequest
        case pendingCancelled
        case scheduled
        case animatedFallbackScheduled
        case continuousFinalScheduled
        case authoritativeFinalPreserved
        case submitted
        case committed
        case failed
        case staleCompletion
        case rolledBack
        case alreadySynchronized
        case snapshot
    }

    struct InFlightDiagnostic: Sendable {
        let identifier: UInt64
        let drawableSize: CGSize
        let contentsScale: CGFloat
        let geometryChangeKind: MPVGeometryChangeKind
    }

    struct DiagnosticSnapshot: Sendable {
        let event: DiagnosticEvent
        let latestRequestedDrawableSize: CGSize?
        let pendingDrawableSize: CGSize?
        let committedDrawableSize: CGSize?
        let failedDrawableSize: CGSize?
        let inFlight: InFlightDiagnostic?
        let activeLayerAddress: Int64?
        let surfaceGeneration: UInt64
        let geometryChangeKind: MPVGeometryChangeKind?
        let contentsScale: CGFloat?
        let committedContentsScale: CGFloat?
        let finalCommitRequired: Bool
        let isContinuousInteraction: Bool
        let hasScheduledCommit: Bool
        let hasAnimatedFallback: Bool
        let hasContinuousFinalFallback: Bool
        let observedDrawableSize: CGSize?
        let resizeLatencyNanoseconds: UInt64?
    }

    typealias Commit = @MainActor (CommitRequest) async -> Bool
    typealias EmitDiagnostic = @MainActor (DiagnosticSnapshot) -> Void

    fileprivate struct Geometry: Equatable {
        let drawableSize: CGSize
        let contentsScale: CGFloat
    }

    fileprivate struct PendingRequest {
        let sequence: UInt64
        let geometry: Geometry
        let kind: MPVGeometryChangeKind
        let surfaceGeneration: UInt64
        let requestedAtUptimeNanoseconds: UInt64
    }

    fileprivate struct InFlightRequest: Equatable {
        let sequence: UInt64
        let commit: CommitRequest
        let geometry: Geometry
        let layerIdentifier: ObjectIdentifier
    }

    private let timing: Timing
    private let commit: Commit
    private let emitDiagnostic: EmitDiagnostic?

    private weak var activeLayer: CAMetalLayer?
    private var activeLayerAddress: Int64?
    private var activeContentsScale: CGFloat?

    private var latestRequest: PendingRequest?
    private var pendingRequest: PendingRequest?
    private var committedGeometry: Geometry?
    private var failedGeometry: Geometry?
    private var inFlightRequest: InFlightRequest?
    private var lastAuthoritativeFinalGeometry: Geometry?

    private var surfaceGeneration: UInt64 = 0
    private var requestSequence: UInt64 = 0
    private var commitIdentifier: UInt64 = 0
    private var finalCommitRequired = false
    private var isContinuousInteraction = false
    private var lastContinuousSubmissionUptimeNanoseconds: UInt64?
    private var lastResizeLatencyNanoseconds: UInt64?

    private var schedulingTask: Task<Void, Never>?
    private var animatedFallbackTask: Task<Void, Never>?
    private var continuousFinalTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?

    init(
        timing: Timing = .init(),
        commit: @escaping Commit,
        emitDiagnostic: EmitDiagnostic? = nil
    ) {
        self.timing = timing
        self.commit = commit
        self.emitDiagnostic = emitDiagnostic
    }

    isolated deinit {
        schedulingTask?.cancel()
        animatedFallbackTask?.cancel()
        continuousFinalTask?.cancel()
        commitTask?.cancel()
    }

    /// The current state, intended for logging and integration-test probes.
    var diagnosticSnapshot: DiagnosticSnapshot {
        makeDiagnosticSnapshot(event: .snapshot)
    }

    /// Converts a layer identity to the address format consumed by MPVPlayer.
    static func layerAddress(of layer: CAMetalLayer) -> Int64 {
        let pointer = Unmanaged.passUnretained(layer).toOpaque()
        return Int64(bitPattern: UInt64(UInt(bitPattern: pointer)))
    }

    /// Starts a new surface generation and records the size already accepted
    /// when the renderer was attached.
    func activate(
        layer: CAMetalLayer,
        layerAddress: Int64,
        contentsScale: CGFloat,
        committedSize: CGSize?
    ) {
        resetActiveSurface(event: nil)

        let normalizedScale = Self.normalizedContentsScale(contentsScale)
        activeLayer = layer
        activeLayerAddress = layerAddress
        activeContentsScale = normalizedScale

        if let committedSize, Self.isValid(drawableSize: committedSize) {
            let geometry = Geometry(
                drawableSize: committedSize,
                contentsScale: normalizedScale
            )
            committedGeometry = geometry
            apply(geometry, to: layer)
        }

        emit(.activated)
        schedulePendingRequestIfPossible()
    }

    /// Detaches the active surface without allowing a late acknowledgement to
    /// mutate the next surface generation.
    func deactivate() {
        resetActiveSurface(event: .deactivated)
    }

    /// Invalidates work when another view becomes the player's active surface.
    func surfaceWasSuperseded() {
        resetActiveSurface(event: .surfaceSuperseded)
    }

    /// Invalidates work before pixel-format, color-space, or renderer contract
    /// changes. Call `activate` again after the replacement target is attached.
    func rendererConfigurationDidChange() {
        resetActiveSurface(event: .rendererConfigurationChanged)
    }

    /// Marks the start of an interactive burst. Calling this is optional;
    /// receiving a `.continuousInteractive` request starts the burst as well.
    func beginContinuousInteraction() {
        guard activeLayer != nil, activeLayerAddress != nil else { return }
        beginContinuousInteractionIfNeeded()
    }

    /// Abandons an interactive burst without disturbing the active surface,
    /// committed geometry, or any resize operation already in flight.
    func abortContinuousInteraction() {
        isContinuousInteraction = false
        activeContentsScale = activeLayer?.contentsScale
        cancelPendingResize(emitEvent: true)
    }

    /// Ends an interactive burst with an authoritative final geometry.
    @discardableResult
    func endContinuousInteraction(
        finalSize: CGSize,
        contentsScale: CGFloat
    ) -> Bool {
        if authoritativeFinalAlreadyCommitted(
            finalSize,
            contentsScale: contentsScale
        ) {
            emit(.alreadySynchronized)
            return false
        }
        let requestedAt = requestTimeForAuthoritativeGeometry(
            finalSize,
            contentsScale: contentsScale
        )
        isContinuousInteraction = false
        lastContinuousSubmissionUptimeNanoseconds = nil
        continuousFinalTask?.cancel()
        continuousFinalTask = nil
        emit(.continuousInteractionEnded)
        return enqueueResize(
            to: finalSize,
            contentsScale: contentsScale,
            kind: .final,
            requestedAtUptimeNanoseconds: requestedAt
        )
    }

    /// Commits the final geometry supplied by a platform transition
    /// coordinator. This cancels the missing-completion fallback.
    @discardableResult
    func completeAnimatedTransition(
        finalSize: CGSize,
        contentsScale: CGFloat
    ) -> Bool {
        if authoritativeFinalAlreadyCommitted(
            finalSize,
            contentsScale: contentsScale
        ) {
            animatedFallbackTask?.cancel()
            animatedFallbackTask = nil
            emit(.alreadySynchronized)
            return false
        }
        let requestedAt = requestTimeForAuthoritativeGeometry(
            finalSize,
            contentsScale: contentsScale
        )
        animatedFallbackTask?.cancel()
        animatedFallbackTask = nil
        return enqueueResize(
            to: finalSize,
            contentsScale: contentsScale,
            kind: .final,
            requestedAtUptimeNanoseconds: requestedAt
        )
    }

    /// Requests a resize. Invalid transient geometry cancels only pending
    /// scheduling; the active surface, committed drawable, and in-flight
    /// acknowledgement remain intact.
    @discardableResult
    func requestResize(
        to drawableSize: CGSize,
        contentsScale: CGFloat,
        kind: MPVGeometryChangeKind
    ) -> Bool {
        enqueueResize(
            to: drawableSize,
            contentsScale: contentsScale,
            kind: kind,
            requestedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    @discardableResult
    private func enqueueResize(
        to drawableSize: CGSize,
        contentsScale: CGFloat,
        kind: MPVGeometryChangeKind,
        requestedAtUptimeNanoseconds: UInt64
    ) -> Bool {
        let hasQueuedAuthoritativeFinal =
            kind != .final
                && inFlightRequest != nil
                && pendingRequest?.kind == .final

        guard Self.isValid(drawableSize: drawableSize),
              contentsScale.isFinite,
              contentsScale > 0
        else {
            if hasQueuedAuthoritativeFinal {
                emit(.invalidRequest)
                return false
            }
            cancelPendingResize(emitEvent: false)
            emit(.invalidRequest)
            return false
        }

        guard activeLayer != nil, activeLayerAddress != nil else {
            emit(.inactiveRequest)
            return false
        }

        let geometry = Geometry(
            drawableSize: drawableSize,
            contentsScale: Self.normalizedContentsScale(contentsScale)
        )

        // A lifecycle-authoritative final queued behind an older in-flight
        // commit must not be downgraded or discarded by a later layout pass.
        // Ignore duplicate geometry. Promote a newer discrete geometry so the
        // latest one remains authoritative; a newer continuous or animated
        // lifecycle supplies its own trailing-final obligation.
        var effectiveKind = kind
        if hasQueuedAuthoritativeFinal {
            if pendingRequest?.geometry == geometry {
                emit(.authoritativeFinalPreserved)
                return false
            }
            if kind == .discrete {
                effectiveKind = .final
            }
        }

        // UIKit can issue unchanged layout callbacks outside a real resize
        // burst. Do not turn those into a synthetic continuous interaction
        // whose trailing final would recreate an already-current swapchain.
        if effectiveKind != .final,
           committedGeometry == geometry,
           pendingRequest == nil,
           inFlightRequest == nil,
           !isContinuousInteraction
        {
            activeContentsScale = geometry.contentsScale
            emit(.alreadySynchronized)
            return false
        }

        if failedGeometry == geometry {
            guard effectiveKind == .final else {
                emit(.requested)
                return false
            }
            // An explicit or lifecycle-authoritative final is allowed to retry
            // a geometry that previously failed. Automatic loops are not.
            failedGeometry = nil
        } else if failedGeometry != nil {
            failedGeometry = nil
        }

        requestSequence &+= 1
        let request = PendingRequest(
            sequence: requestSequence,
            geometry: geometry,
            kind: effectiveKind,
            surfaceGeneration: surfaceGeneration,
            requestedAtUptimeNanoseconds: requestedAtUptimeNanoseconds
        )
        latestRequest = request
        pendingRequest = request

        schedulingTask?.cancel()
        schedulingTask = nil

        switch effectiveKind {
        case .continuousInteractive:
            beginContinuousInteractionIfNeeded()
            finalCommitRequired = true
            lastAuthoritativeFinalGeometry = nil
            animatedFallbackTask?.cancel()
            animatedFallbackTask = nil
            armContinuousFinalFallback(for: request)
        case .animatedTransition:
            isContinuousInteraction = false
            lastContinuousSubmissionUptimeNanoseconds = nil
            continuousFinalTask?.cancel()
            continuousFinalTask = nil
            finalCommitRequired = true
            lastAuthoritativeFinalGeometry = nil
            armAnimatedFallback(for: request)
        case .discrete:
            isContinuousInteraction = false
            lastContinuousSubmissionUptimeNanoseconds = nil
            continuousFinalTask?.cancel()
            continuousFinalTask = nil
            animatedFallbackTask?.cancel()
            animatedFallbackTask = nil
            finalCommitRequired = false
        case .final:
            isContinuousInteraction = false
            lastContinuousSubmissionUptimeNanoseconds = nil
            continuousFinalTask?.cancel()
            continuousFinalTask = nil
            animatedFallbackTask?.cancel()
            animatedFallbackTask = nil
            finalCommitRequired = true
        }

        activeContentsScale = geometry.contentsScale
        lastResizeLatencyNanoseconds = nil
        emit(.requested)
        schedulePendingRequestIfPossible()
        return true
    }
}

private extension MPVRenderSurfaceResizeCoordinator {
    static func isValid(drawableSize: CGSize) -> Bool {
        MPVMetalLayer.isValidDrawableSize(drawableSize)
    }

    static func normalizedContentsScale(_ contentsScale: CGFloat) -> CGFloat {
        guard contentsScale.isFinite, contentsScale > 0 else { return 1 }
        return max(contentsScale, 1)
    }

    func beginContinuousInteractionIfNeeded() {
        guard !isContinuousInteraction else { return }
        isContinuousInteraction = true
        finalCommitRequired = true
        lastContinuousSubmissionUptimeNanoseconds = nil
        lastAuthoritativeFinalGeometry = nil
        emit(.continuousInteractionBegan)
    }

    func resetActiveSurface(event: DiagnosticEvent?) {
        surfaceGeneration &+= 1
        schedulingTask?.cancel()
        schedulingTask = nil
        animatedFallbackTask?.cancel()
        animatedFallbackTask = nil
        continuousFinalTask?.cancel()
        continuousFinalTask = nil

        // Cancellation is advisory. Keep the in-flight record until the
        // closure actually returns so a replacement surface cannot start a
        // second native resize concurrently.
        commitTask?.cancel()
        if inFlightRequest == nil {
            commitTask = nil
        }

        activeLayer = nil
        activeLayerAddress = nil
        activeContentsScale = nil
        latestRequest = nil
        pendingRequest = nil
        committedGeometry = nil
        failedGeometry = nil
        lastAuthoritativeFinalGeometry = nil
        finalCommitRequired = false
        isContinuousInteraction = false
        lastContinuousSubmissionUptimeNanoseconds = nil
        lastResizeLatencyNanoseconds = nil

        if let event {
            emit(event)
        }
    }

    func cancelPendingResize(emitEvent: Bool) {
        let hadPendingWork =
            pendingRequest != nil
                || schedulingTask != nil
                || animatedFallbackTask != nil
                || continuousFinalTask != nil

        schedulingTask?.cancel()
        schedulingTask = nil
        animatedFallbackTask?.cancel()
        animatedFallbackTask = nil
        continuousFinalTask?.cancel()
        continuousFinalTask = nil
        latestRequest = nil
        pendingRequest = nil
        finalCommitRequired = false
        lastContinuousSubmissionUptimeNanoseconds = nil

        if emitEvent, hadPendingWork {
            emit(.pendingCancelled)
        }
    }

    func schedulePendingRequestIfPossible() {
        guard inFlightRequest == nil,
              let request = pendingRequest,
              request.surfaceGeneration == surfaceGeneration,
              activeLayer != nil,
              activeLayerAddress != nil
        else { return }

        switch request.kind {
        case .continuousInteractive:
            let delay = continuousCadenceDelay()
            if delay == 0 {
                submitPendingRequest()
            } else {
                schedule(request, afterNanoseconds: delay)
            }
        case .animatedTransition:
            // Retain the old drawable until transition completion or fallback.
            break
        case .discrete:
            schedule(
                request,
                afterNanoseconds: timing.discreteCoalescingDelayNanoseconds
            )
        case .final:
            submitPendingRequest()
        }
    }

    func schedule(_ request: PendingRequest, afterNanoseconds delay: UInt64) {
        schedulingTask?.cancel()
        schedulingTask = nil

        guard delay > 0 else {
            submitPendingRequest()
            return
        }

        let generation = surfaceGeneration
        schedulingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,
                  let self,
                  self.surfaceGeneration == generation,
                  self.pendingRequest?.sequence == request.sequence
            else { return }

            self.schedulingTask = nil
            self.submitPendingRequest()
        }
        emit(.scheduled)
    }

    func continuousCadenceDelay() -> UInt64 {
        guard timing.continuousCadenceNanoseconds > 0,
              let lastSubmission = lastContinuousSubmissionUptimeNanoseconds
        else { return 0 }

        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= lastSubmission else {
            return timing.continuousCadenceNanoseconds
        }
        let elapsed = now - lastSubmission
        guard elapsed < timing.continuousCadenceNanoseconds else { return 0 }
        return timing.continuousCadenceNanoseconds - elapsed
    }

    func requestTimeForAuthoritativeGeometry(
        _ drawableSize: CGSize,
        contentsScale: CGFloat
    ) -> UInt64 {
        let geometry = Geometry(
            drawableSize: drawableSize,
            contentsScale: Self.normalizedContentsScale(contentsScale)
        )
        if latestRequest?.geometry == geometry,
           let requestedAt = latestRequest?.requestedAtUptimeNanoseconds
        {
            return requestedAt
        }
        return DispatchTime.now().uptimeNanoseconds
    }

    func authoritativeFinalAlreadyCommitted(
        _ drawableSize: CGSize,
        contentsScale: CGFloat
    ) -> Bool {
        guard Self.isValid(drawableSize: drawableSize),
              contentsScale.isFinite,
              contentsScale > 0,
              !finalCommitRequired,
              pendingRequest == nil,
              inFlightRequest == nil
        else { return false }

        let geometry = Geometry(
            drawableSize: drawableSize,
            contentsScale: Self.normalizedContentsScale(contentsScale)
        )
        return lastAuthoritativeFinalGeometry == geometry
            && committedGeometry == geometry
    }

    func armContinuousFinalFallback(for request: PendingRequest) {
        continuousFinalTask?.cancel()
        continuousFinalTask = nil

        let delay = timing.continuousTrailingDelayNanoseconds
        let generation = surfaceGeneration
        continuousFinalTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled,
                  let self,
                  self.surfaceGeneration == generation,
                  self.latestRequest?.sequence == request.sequence,
                  self.latestRequest?.kind == .continuousInteractive,
                  let latest = self.latestRequest
            else { return }

            self.continuousFinalTask = nil
            self.isContinuousInteraction = false
            self.emit(.continuousFinalScheduled)
            self.enqueueResize(
                to: latest.geometry.drawableSize,
                contentsScale: latest.geometry.contentsScale,
                kind: .final,
                requestedAtUptimeNanoseconds:
                latest.requestedAtUptimeNanoseconds
            )
        }
    }

    func armAnimatedFallback(for request: PendingRequest) {
        animatedFallbackTask?.cancel()
        animatedFallbackTask = nil

        let delay = timing.animatedTransitionFallbackDelayNanoseconds
        let generation = surfaceGeneration
        animatedFallbackTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled,
                  let self,
                  self.surfaceGeneration == generation,
                  self.latestRequest?.sequence == request.sequence,
                  self.latestRequest?.kind == .animatedTransition,
                  let latest = self.latestRequest
            else { return }

            self.animatedFallbackTask = nil
            self.enqueueResize(
                to: latest.geometry.drawableSize,
                contentsScale: latest.geometry.contentsScale,
                kind: .final,
                requestedAtUptimeNanoseconds:
                latest.requestedAtUptimeNanoseconds
            )
        }
        emit(.animatedFallbackScheduled)
    }

    func submitPendingRequest() {
        guard inFlightRequest == nil,
              let request = pendingRequest,
              request.surfaceGeneration == surfaceGeneration,
              let layer = activeLayer,
              let layerAddress = activeLayerAddress
        else { return }

        schedulingTask?.cancel()
        schedulingTask = nil

        // Ordinary duplicate geometry needs no work. An authoritative final
        // deliberately bypasses this shortcut so the native boundary receives
        // one exact trailing acknowledgement even when the leading/intermediate
        // commit already reached the same geometry.
        if request.kind != .final, committedGeometry == request.geometry {
            pendingRequest = nil
            apply(request.geometry, to: layer, includeDrawableSize: false)
            emit(.alreadySynchronized)
            return
        }

        pendingRequest = nil
        commitIdentifier &+= 1
        let commitRequest = CommitRequest(
            identifier: commitIdentifier,
            drawableSize: request.geometry.drawableSize,
            contentsScale: request.geometry.contentsScale,
            layerAddress: layerAddress,
            surfaceGeneration: request.surfaceGeneration,
            geometryChangeKind: request.kind,
            requestedAtUptimeNanoseconds:
            request.requestedAtUptimeNanoseconds
        )
        let inFlight = InFlightRequest(
            sequence: request.sequence,
            commit: commitRequest,
            geometry: request.geometry,
            layerIdentifier: ObjectIdentifier(layer)
        )
        inFlightRequest = inFlight

        if request.kind == .continuousInteractive {
            lastContinuousSubmissionUptimeNanoseconds =
                DispatchTime.now().uptimeNanoseconds
        }

        // Keep these mutations in the same disabled-actions transaction and
        // immediately before the native resize submission.
        apply(
            request.geometry,
            to: layer,
            includeDrawableSize: false
        )
        emit(.submitted)

        let commit = self.commit
        commitTask = Task { @MainActor [weak self] in
            let didCommit = await commit(commitRequest)
            self?.complete(inFlight, didCommit: didCommit)
        }
    }

    func complete(_ completed: InFlightRequest, didCommit: Bool) {
        lastResizeLatencyNanoseconds = Self.elapsedNanoseconds(
            since: completed.commit.requestedAtUptimeNanoseconds,
            until: DispatchTime.now().uptimeNanoseconds
        )

        guard inFlightRequest == completed else {
            emit(.staleCompletion)
            return
        }

        inFlightRequest = nil
        commitTask = nil

        let completionMatchesActiveSurface =
            completed.commit.surfaceGeneration == surfaceGeneration
                && completed.commit.layerAddress == activeLayerAddress
                && activeLayer.map(ObjectIdentifier.init)
                == completed.layerIdentifier

        guard completionMatchesActiveSurface else {
            emit(.staleCompletion)
            schedulePendingRequestIfPossible()
            return
        }

        if didCommit {
            committedGeometry = completed.geometry
            failedGeometry = nil

            if completed.commit.geometryChangeKind == .final {
                completeAuthoritativeFinal(completed)
            }

            if let pending = pendingRequest,
               pending.geometry == completed.geometry
            {
                if pending.kind != .final
                    || completed.commit.geometryChangeKind == .final
                {
                    pendingRequest = nil
                }
            }

            emit(.committed)
        } else {
            failedGeometry = completed.geometry
            if let committedGeometry, let layer = activeLayer {
                apply(
                    committedGeometry,
                    to: layer,
                    includeDrawableSize: false
                )
                emit(.rolledBack)
            }

            if let pending = pendingRequest,
               pending.geometry == completed.geometry,
               pending.kind != .final
            {
                pendingRequest = nil
            }
            emit(.failed)
        }

        schedulePendingRequestIfPossible()
    }

    func completeAuthoritativeFinal(_ completed: InFlightRequest) {
        lastAuthoritativeFinalGeometry = completed.geometry

        // A final acknowledgement can finish after a newer interaction has
        // already supplied different geometry. It authoritatively commits its
        // own size, but must not clear the newer request's trailing-final
        // obligation or cancel the fallback task that is its only completion
        // path. Same-geometry work remains deduplicated because this native
        // acknowledgement completed after that newer request was received.
        if let pending = pendingRequest,
           pending.sequence > completed.sequence,
           pending.geometry != completed.geometry,
           pending.kind != .discrete
        {
            return
        }

        finalCommitRequired = false
        isContinuousInteraction = false
        continuousFinalTask?.cancel()
        continuousFinalTask = nil
        animatedFallbackTask?.cancel()
        animatedFallbackTask = nil
    }

    func apply(
        _ geometry: Geometry,
        to layer: CAMetalLayer,
        includeDrawableSize: Bool = true
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = geometry.contentsScale
        if includeDrawableSize {
            layer.drawableSize = geometry.drawableSize
        }
        CATransaction.commit()
        activeContentsScale = geometry.contentsScale
    }

    func emit(_ event: DiagnosticEvent) {
        emitDiagnostic?(makeDiagnosticSnapshot(event: event))
    }

    func makeDiagnosticSnapshot(event: DiagnosticEvent) -> DiagnosticSnapshot {
        let inFlight = inFlightRequest.map {
            InFlightDiagnostic(
                identifier: $0.commit.identifier,
                drawableSize: $0.commit.drawableSize,
                contentsScale: $0.commit.contentsScale,
                geometryChangeKind: $0.commit.geometryChangeKind
            )
        }

        return DiagnosticSnapshot(
            event: event,
            latestRequestedDrawableSize: latestRequest?.geometry.drawableSize,
            pendingDrawableSize: pendingRequest?.geometry.drawableSize,
            committedDrawableSize: committedGeometry?.drawableSize,
            failedDrawableSize: failedGeometry?.drawableSize,
            inFlight: inFlight,
            activeLayerAddress: activeLayerAddress,
            surfaceGeneration: surfaceGeneration,
            geometryChangeKind: latestRequest?.kind,
            contentsScale: activeContentsScale,
            committedContentsScale: committedGeometry?.contentsScale,
            finalCommitRequired: finalCommitRequired,
            isContinuousInteraction: isContinuousInteraction,
            hasScheduledCommit: schedulingTask != nil,
            hasAnimatedFallback: animatedFallbackTask != nil,
            hasContinuousFinalFallback: continuousFinalTask != nil,
            observedDrawableSize: activeLayer?.drawableSize,
            resizeLatencyNanoseconds: lastResizeLatencyNanoseconds
        )
    }

    static func elapsedNanoseconds(since start: UInt64, until end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}
