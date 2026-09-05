import Dispatch
import Foundation
import Libmpv

// Autolink mpv’s iOS/tvOS OpenGL ES backend only where the SDK provides it.
// Catalyst shares SwiftPM’s iOS platform condition but has no OpenGLES framework.
#if canImport(OpenGLES)
import OpenGLES
#endif

#if targetEnvironment(macCatalyst)
// MoltenVK uses macOS GPU discovery when running under Catalyst.
import IOKit
#endif

#if canImport(Darwin)
import Darwin
#endif

/// Owns the libmpv handle and confines all client API access to one queue.
///
/// The wakeup callback only schedules a drain, as required by libmpv. Event
/// values are copied into Swift models before the next call to
/// `mpv_wait_event` invalidates them.
final class MPVEngine: @unchecked Sendable {
    typealias Sink = @MainActor @Sendable (MPVEngineEmission) -> Void

    /// Properties already managed
    private static let reservedProperties: Set<String> = [
        "external-surface-size",
        "gpu-api",
        "gpu-context",
        "mute",
        "pause",
        "speed",
        "sub-text-intercept",
        "sub-text-snapshot",
        "target-colorspace-hint",
        "target-peak",
        "target-prim",
        "target-trc",
        "vo",
        "volume",
        "wid",
    ]
    private static let textSubtitleObservationID = UInt64.max - 1
    private static let textSubtitleSnapshotRefreshProperties: Set<String> = [
        "secondary-sub-visibility",
        "sub-visibility",
    ]

    private struct ExternalTrack {
        let url: URL
        let type: MPVTrackType
        let select: Bool
    }

    private static let wakeupCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
        context in
        guard let context else { return }
        let engine = Unmanaged<WeakBox<MPVEngine>>.fromOpaque(context).takeUnretainedValue()
        engine.value?.scheduleEventDrain()
    }

    private let queue = DispatchQueue(label: "com.lepips.MPVUI.engine", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueValue: UInt8 = 1
    private let configuration: MPVPlayerConfiguration
    private let updateContinuation: AsyncStream<MPVEngineEmission>.Continuation
    private let updateDeliveryTask: Task<Void, Never>

    private lazy var wakeupContext = WeakBox(self)

    // All properties below are isolated to `queue`.
    private var handle: OpaquePointer?
    private var currentGeneration: UInt64 = 0
    private var renderTarget: MPVRenderTarget?
    private var outputHeadroom: Double = 1
    private var sourceURL: URL?
    private var pendingStartTime: Duration?
    private var pendingSeekAfterLoad: Duration?
    private var needsSourceLoad = false
    private var shouldAutoPlay: Bool
    private var securityScopedURL: URL?
    private var externalTracks: [ExternalTrack] = []
    private var pendingExternalTracks: [ExternalTrack] = []
    private var externalSecurityScopedURLs: Set<URL> = []
    private var desiredProperties: [String: String]

    private var isLoading = false
    private var isFileLoaded = false
    private var isPaused = false
    private var isSeeking = false
    private var isPausedForCache = false
    private var isIdle = true
    private var didReachEnd = false
    private var hasPlaybackStarted = false
    private var playbackRequestIsActive = false
    private var requestedPlaylistEntryID: Int64?
    private var activePlaylistEntryID: Int64?
    private var fatalPlaybackError: MPVPlayerError?

    private var lastPosition: Duration = .zero
    private var lastDuration: Duration = .zero
    private var lastSeekable = false
    private var lastState: MPVPlaybackState = .idle
    private var lastTextSubtitleSnapshot = TextSubtitleSnapshot()
    private var isTextSubtitleInterceptionEnabled = false
    private var lifecycleDiagnostics = MPVEngineLifecycleDiagnostics()

    init(configuration: MPVPlayerConfiguration, sink: @escaping Sink) {
        self.configuration = configuration
        // This unified stream carries state and errors as well as diagnostics;
        // it must remain lossless. If logging needs backpressure in the future,
        // move logs to a separately bounded channel with explicit drop reporting.
        let (updates, continuation) = AsyncStream<MPVEngineEmission>.makeStream()
        updateContinuation = continuation
        updateDeliveryTask = Task { @MainActor in
            for await update in updates {
                sink(update)
            }
        }
        shouldAutoPlay = configuration.autoPlay
        pendingStartTime = configuration.startTime
        desiredProperties = [
            "volume": Self.format(configuration.volume),
            "mute": "no",
            "speed": Self.format(configuration.playbackRate),
        ]
        queue.setSpecific(key: queueKey, value: queueValue)
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            destroyHandle(preservePlayback: false)
        } else {
            queue.sync {
                destroyHandle(preservePlayback: false)
            }
        }
        updateContinuation.finish()
        updateDeliveryTask.cancel()
    }

    func attach(to target: MPVRenderTarget) {
        queue.async { [weak self] in
            guard let self else { return }

            if let currentTarget = self.renderTarget,
               currentTarget.matchesSurfaceConfiguration(target)
            {
                if self.handle != nil {
                    if !currentTarget.matches(target) {
                        self.resizeRenderTargetImmediately(
                            width: target.drawableWidth,
                            height: target.drawableHeight,
                            forLayerAddress: target.layerAddress
                        )
                    }
                    return
                }
                // A failed initialization remains stable until the surface is
                // explicitly detached/re-activated or its configuration
                // changes. SwiftUI updates must not spin retrying the same
                // failing libmpv context.
                if self.fatalPlaybackError != nil {
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

    func lifecycleSnapshot() async -> MPVEngineLifecycleDiagnostics {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.lifecycleDiagnostics ?? .init())
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

    func shutdown() {
        queue.async { [weak self] in
            self?.destroyHandle(preservePlayback: false)
        }
    }

    func enableTextSubtitleInterception() {
        queue.async { [weak self] in
            guard let self, !self.isTextSubtitleInterceptionEnabled else { return }
            self.isTextSubtitleInterceptionEnabled = true
            self.lastTextSubtitleSnapshot = TextSubtitleSnapshot()
            guard self.handle != nil else { return }

            let status = self.setPropertyImmediately("sub-text-intercept", to: "yes")
            guard status >= 0 else {
                self.publishCommandError(status, context: "Enable text subtitle interception")
                return
            }
            self.observeTextSubtitleSnapshot()
            self.refreshTextSubtitleSnapshot()
        }
    }

    func load(
        _ url: URL,
        autoPlay: Bool?,
        startTime: Duration?,
        generation: UInt64
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.currentGeneration = generation
            self.clearTextSubtitleSnapshot()
            self.stopSecurityScopedAccess()
            self.stopExternalSecurityScopedAccess()
            self.externalTracks.removeAll()
            self.pendingExternalTracks.removeAll()
            self.sourceURL = url
            self.pendingStartTime =
                startTime.map { max(.zero, $0) }
                    ?? self.configuration.startTime
            self.pendingSeekAfterLoad = nil
            self.needsSourceLoad = true
            self.shouldAutoPlay = autoPlay ?? self.configuration.autoPlay
            self.isPaused = !self.shouldAutoPlay
            self.didReachEnd = false
            self.hasPlaybackStarted = false
            self.playbackRequestIsActive = true
            self.fatalPlaybackError = nil
            self.isLoading = true
            self.isFileLoaded = false
            self.lastPosition = max(.zero, self.pendingStartTime ?? .zero)
            self.lastDuration = .zero
            self.lastSeekable = false
            self.desiredProperties.removeValue(forKey: "vid")
            self.desiredProperties.removeValue(forKey: "aid")
            self.desiredProperties.removeValue(forKey: "sid")
            self.desiredProperties.removeValue(forKey: "audio-delay")
            self.desiredProperties.removeValue(forKey: "sub-delay")
            self.publishState(.loading)
            self.startSecurityScopedAccessIfNeeded(for: url)
            self.loadPendingSourceIfPossible()
        }
    }

    func play() {
        queue.async { [weak self] in
            self?.setPlayingImmediately(true)
        }
    }

    func pause() {
        queue.async { [weak self] in
            self?.setPlayingImmediately(false)
        }
    }

    func togglePlayback() {
        queue.async { [weak self] in
            guard let self else { return }
            self.setPlayingImmediately(self.isPaused || self.didReachEnd || !self.isFileLoaded)
        }
    }

    func stop(generation: UInt64? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            if let generation {
                self.currentGeneration = generation
            }
            self.clearTextSubtitleSnapshot()
            self.shouldAutoPlay = false
            self.needsSourceLoad = false
            self.pendingStartTime = nil
            self.pendingSeekAfterLoad = nil
            self.fatalPlaybackError = nil
            self.pendingExternalTracks = self.externalTracks

            if self.handle != nil, self.isFileLoaded || self.isLoading {
                let status = self.runCommand(["stop"])
                if status < 0 {
                    self.publishCommandError(status, context: "Stop")
                    return
                }
            }

            // A rapid replacement can be removed before mpv emits either a
            // START_FILE or END_FILE event for it. Once `stop` succeeds, the
            // user's requested state is authoritative; delayed events stay
            // ignored until a later load or play request clears this latch.
            self.playbackRequestIsActive = false
            self.requestedPlaylistEntryID = nil
            self.activePlaylistEntryID = nil
            self.isLoading = false
            self.isFileLoaded = false
            self.isSeeking = false
            self.isPausedForCache = false
            self.isIdle = true
            self.didReachEnd = false
            self.hasPlaybackStarted = false
            self.publishState(.stopped)
        }
    }

    func seek(to time: Duration) {
        let target = max(.zero, time)
        queue.async { [weak self] in
            guard let self else { return }
            if self.handle == nil || !self.isFileLoaded {
                if self.handle != nil, self.isLoading, !self.needsSourceLoad {
                    self.pendingSeekAfterLoad = target
                } else {
                    self.pendingStartTime = target
                }
                self.lastPosition = target
                self.publishTiming()
            } else {
                let status = self.runCommand(["seek", Self.format(target), "absolute+exact"])
                if status < 0 {
                    self.publishCommandError(status, context: "Seek")
                }
            }
        }
    }

    func seek(by offset: Duration) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.handle == nil || !self.isFileLoaded {
                let pendingPosition =
                    self.pendingSeekAfterLoad
                        ?? self.pendingStartTime
                        ?? self.lastPosition
                let unclampedTarget = max(.zero, pendingPosition + offset)
                let target =
                    self.lastDuration > .zero
                        ? min(unclampedTarget, self.lastDuration)
                        : unclampedTarget
                if self.handle != nil, self.isLoading, !self.needsSourceLoad {
                    self.pendingSeekAfterLoad = target
                } else {
                    self.pendingStartTime = target
                }
                self.lastPosition = target
                self.publishTiming()
            } else {
                let status = self.runCommand(["seek", Self.format(offset), "relative+exact"])
                if status < 0 {
                    self.publishCommandError(status, context: "Seek")
                }
            }
        }
    }

    func frameStep(backward: Bool) {
        command([backward ? "frame-back-step" : "frame-step"])
    }

    func setVolume(_ volume: Double) {
        setProperty("volume", to: Self.format(clamp(volume, to: 0 ... 100)))
    }

    func setMuted(_ muted: Bool) {
        setProperty("mute", to: muted ? "yes" : "no")
    }

    func toggleMute() {
        queue.async { [weak self] in
            guard let self else { return }
            let muted =
                self.getFlag("mute")
                ?? (self.desiredProperties["mute"] == "yes")
            self.setPropertyImmediatelyOrDefer("mute", to: muted ? "no" : "yes")
        }
    }

    func setPlaybackRate(_ rate: Double) {
        guard rate > 0 else { return }
        setProperty("speed", to: Self.format(clamp(rate, to: 0.01 ... 100)))
    }

    func selectTrack(_ track: MPVMediaTrack) {
        setProperty(Self.selectionProperty(for: track.type), to: String(track.mpvID))
    }

    func disableTrack(_ type: MPVTrackType) {
        setProperty(Self.selectionProperty(for: type), to: "no")
    }

    func loadExternalTrack(_ url: URL, type: MPVTrackType, select: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let track = ExternalTrack(url: url, type: type, select: select)
            self.startExternalSecurityScopedAccessIfNeeded(for: url)
            self.externalTracks.append(track)

            guard self.isFileLoaded, self.handle != nil else {
                self.pendingExternalTracks.append(track)
                return
            }

            self.loadExternalTrackImmediately(track)
        }
    }

    func setAudioDelay(_ delay: Duration) {
        setProperty("audio-delay", to: Self.format(delay))
    }

    func setSubtitleDelay(_ delay: Duration) {
        setProperty("sub-delay", to: Self.format(delay))
    }

    func performPropertySet(_ name: String, value: String) {
        let propertyName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !propertyName.isEmpty else { return }
        guard !Self.reservedProperties.contains(propertyName.lowercased()) else {
            queue.async { [weak self] in
                self?.publish(
                    .error(
                        MPVPlayerError(
                            localizedDescription:
                            "The mpv property '\(propertyName)' is managed by MPVUI."
                        ),
                        fatal: false
                    )
                )
            }
            return
        }
        setProperty(propertyName, to: value)
    }

    func performCommand(_ name: String, arguments: [String]) {
        guard !name.isEmpty else { return }
        if name.caseInsensitiveCompare("stop") == .orderedSame, arguments.isEmpty {
            stop()
            return
        }
        command([name] + arguments)
    }
}

// MARK: - Handle lifecycle

private extension MPVEngine {
    @discardableResult
    func resizeRenderTargetImmediately(
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

    static func isValidDrawableExtent(width: Int, height: Int) -> Bool {
        width > 1
            && height > 1
            && width <= Int(Int32.max)
            && height <= Int(Int32.max)
    }

    func detachImmediately(fromLayerAddress layerAddress: Int64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard renderTarget?.layerAddress == layerAddress else { return }

        destroyHandle(preservePlayback: true)
        renderTarget = nil
    }

    func detachCurrentRenderTargetImmediately() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard renderTarget != nil else { return }

        destroyHandle(preservePlayback: true)
        renderTarget = nil
    }

    func createHandle() {
        dispatchPrecondition(condition: .onQueue(queue))

        guard let renderTarget else { return }
        fatalPlaybackError = nil
        guard let newHandle = mpv_create() else {
            publishFatalError(
                "Unable to create the mpv client.",
                globally: true
            )
            return
        }

        handle = newHandle
        let contextPointer = Unmanaged.passUnretained(wakeupContext).toOpaque()
        mpv_set_wakeup_callback(newHandle, Self.wakeupCallback, contextPointer)
        // Request diagnostics before initialization so Vulkan/libplacebo's
        // one-time surface enumeration and selected format are observable.
        _ = mpv_request_log_messages(newHandle, configuration.logLevel.rawValue)

        do {
            var windowID = renderTarget.layerAddress
            try check(
                mpv_set_option(newHandle, "wid", MPV_FORMAT_INT64, &windowID),
                context: "Set Metal render surface"
            )

            try setInitialOption("vo", value: "gpu-next")
            try setInitialOption("gpu-api", value: "vulkan")
            try setInitialOption("gpu-context", value: "moltenvk")
            try setInitialOption(
                "external-surface-size",
                value: "\(renderTarget.drawableWidth)x\(renderTarget.drawableHeight)"
            )
            try setInitialOption("target-colorspace-hint", value: "yes")
            try setInitialOption("input-default-bindings", value: "no")
            try setInitialOption("subs-match-os-language", value: "yes")
            try setInitialOption("subs-fallback", value: "yes")
            if isTextSubtitleInterceptionEnabled {
                try setInitialOption("sub-text-intercept", value: "yes")
            }

            // AVSampleBufferAudioRenderer preserves the decoded channel layout,
            // allowing Apple's system spatializer to render compatible surround
            // content. The trailing comma retains mpv's normal audio-output
            // autoprobing as a fallback if AVFoundation cannot open the route.
            try setInitialOption("ao", value: "avfoundation,")

            try setInitialOption("hwdec", value: configuration.hardwareDecoding.rawValue)

            try setInitialOption("cache", value: "auto")
            try setInitialOption(
                "cache-secs", value: Self.format(configuration.networkCacheSeconds)
            )
            try setInitialOption("cache-pause", value: "yes")
            try setInitialOption(
                "cache-pause-initial",
                value: configuration.initialBufferSeconds > .zero ? "yes" : "no"
            )
            try setInitialOption(
                "cache-pause-wait",
                value: Self.format(configuration.initialBufferSeconds)
            )
            try setInitialOption("loop-file", value: configuration.loop ? "inf" : "no")
            try setInitialOption("volume", value: Self.format(configuration.volume))
            try setInitialOption("speed", value: Self.format(configuration.playbackRate))

            // The Core Animation layer and mpv output descriptions must agree.
            // Extended linear P3 retains EDR values; the sRGB target deliberately
            // makes mpv tone-map HDR on displays where EDR is unavailable.
            if renderTarget.usesExtendedDynamicRange {
                try setInitialOption("target-prim", value: "display-p3")
                try setInitialOption("target-trc", value: "linear")
                try setInitialOption(
                    "target-peak",
                    value: Self.formatTargetPeak(
                        Self.targetPeakNits(forOutputHeadroom: outputHeadroom)
                    )
                )
            } else {
                try setInitialOption("target-prim", value: "bt.709")
                try setInitialOption("target-trc", value: "srgb")
                try setInitialOption("target-peak", value: "auto")
            }

            for (name, value) in configuration.additionalOptions
                where !Self.reservedProperties.contains(name.lowercased())
            {
                try setInitialOption(name, value: value)
            }

            try check(mpv_initialize(newHandle), context: "Initialize mpv")
        } catch let error as MPVPlayerError {
            publishFatalError(error.localizedDescription, globally: true)
            mpv_destroy(newHandle)
            handle = nil
            return
        } catch {
            publishFatalError(
                error.localizedDescription,
                globally: true
            )
            mpv_destroy(newHandle)
            handle = nil
            return
        }

        lifecycleDiagnostics.handlesCreated &+= 1
        publishRenderSurfaceDiagnostic(
            "mpv renderer attached output=\(renderTarget.drawableWidth)x"
                + "\(renderTarget.drawableHeight) lifecycle=\(lifecycleDiagnostics)"
        )

        observeProperties()
        applyDesiredProperties()
        loadPendingSourceIfPossible()
    }

    func destroyHandle(preservePlayback: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let oldHandle = handle else {
            if !preservePlayback {
                stopSecurityScopedAccess()
                stopExternalSecurityScopedAccess()
            }
            return
        }

        if preservePlayback, isFileLoaded || isLoading {
            lastPosition =
                pendingSeekAfterLoad
                    ?? getDouble("time-pos").flatMap(Duration.init(mpvSeconds:))
                    ?? lastPosition
            pendingStartTime = lastPosition
            pendingSeekAfterLoad = nil
            shouldAutoPlay = !(getFlag("pause") ?? isPaused)
            needsSourceLoad = sourceURL != nil
            snapshotRuntimeProperties()
            pendingExternalTracks = externalTracks
        }

        handle = nil
        mpv_set_wakeup_callback(oldHandle, nil, nil)
        mpv_wakeup(oldHandle)
        mpv_terminate_destroy(oldHandle)
        lifecycleDiagnostics.handlesDestroyed &+= 1
        clearTextSubtitleSnapshot()

        isLoading = false
        isFileLoaded = false
        isSeeking = false
        isPausedForCache = false
        isIdle = true
        hasPlaybackStarted = false
        requestedPlaylistEntryID = nil
        activePlaylistEntryID = nil

        if preservePlayback, needsSourceLoad {
            publishState(.loading)
        }

        if !preservePlayback {
            playbackRequestIsActive = false
            sourceURL = nil
            pendingStartTime = nil
            pendingSeekAfterLoad = nil
            needsSourceLoad = false
            lastPosition = .zero
            lastDuration = .zero
            lastSeekable = false
            stopSecurityScopedAccess()
            stopExternalSecurityScopedAccess()
            externalTracks.removeAll()
            pendingExternalTracks.removeAll()
            publishState(.stopped)
        }
    }

    func loadPendingSourceIfPossible() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard needsSourceLoad, handle != nil, let sourceURL else { return }

        var arguments = ["loadfile", Self.mpvPath(for: sourceURL), "replace"]
        if let start = pendingStartTime, start > .zero {
            // mpv expects the playlist index before per-file options.
            // -1 keeps replacement semantics while allowing the start option.
            arguments.append("-1")
            arguments.append("start=\(Self.format(start))")
        }

        requestedPlaylistEntryID = nil
        let (status, result) = runCommandReturningValue(arguments)
        guard status >= 0 else {
            isLoading = false
            needsSourceLoad = false
            playbackRequestIsActive = false
            publishFatalError(
                localizedDescription(status, context: "Load media")
            )
            return
        }

        requestedPlaylistEntryID = result?.mapValue?["playlist_entry_id"]?.integerValue
        // START_FILE is delivered asynchronously. Mark the submitted load now
        // so another immediate surface rebuild preserves and resubmits it.
        isLoading = true
        needsSourceLoad = false
        _ = setPropertyImmediately("pause", to: shouldAutoPlay ? "no" : "yes")
        pendingStartTime = nil
    }

    func setPlayingImmediately(_ playing: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        shouldAutoPlay = playing
        isPaused = !playing

        if playing, !isFileLoaded, !isLoading, let sourceURL {
            let restartPosition = max(.zero, pendingStartTime ?? .zero)
            pendingStartTime = restartPosition
            pendingSeekAfterLoad = nil
            lastPosition = restartPosition
            didReachEnd = false
            playbackRequestIsActive = true
            fatalPlaybackError = nil
            needsSourceLoad = true
            isLoading = true
            pendingExternalTracks = externalTracks
            startSecurityScopedAccessIfNeeded(for: sourceURL)
            publishState(.loading)
            loadPendingSourceIfPossible()
            return
        }

        guard handle != nil else { return }
        let status = setPropertyImmediately("pause", to: playing ? "no" : "yes")
        if status < 0 {
            publishCommandError(status, context: playing ? "Play" : "Pause")
        }
    }

    func snapshotRuntimeProperties() {
        dispatchPrecondition(condition: .onQueue(queue))
        let names = [
            "volume", "mute", "speed", "vid", "aid", "sid", "audio-delay", "sub-delay",
        ]
        for name in names {
            if let value = getString(name) {
                desiredProperties[name] = value
            }
        }
    }

    func applyDesiredProperties() {
        dispatchPrecondition(condition: .onQueue(queue))
        for (name, value) in desiredProperties {
            let status = setPropertyImmediately(name, to: value)
            if status < 0 {
                publishCommandError(status, context: "Restore \(name)")
            }
        }
    }

    func loadPendingExternalTracks() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isFileLoaded else { return }

        let tracks = pendingExternalTracks
        pendingExternalTracks.removeAll()
        for track in tracks {
            loadExternalTrackImmediately(track)
        }

        // Re-adding an external track with its original `select` flag can
        // temporarily change the active track. A renderer rebuild must honor
        // the user's latest embedded/external/off selection captured above.
        for name in ["vid", "aid", "sid"] {
            guard let value = desiredProperties[name] else { continue }
            let status = setPropertyImmediately(name, to: value)
            if status < 0 {
                publishCommandError(status, context: "Restore \(name)")
            }
        }
    }

    func applyPendingSeekAfterLoad() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let target = pendingSeekAfterLoad else { return }
        pendingSeekAfterLoad = nil

        let status = runCommand(["seek", Self.format(target), "absolute+exact"])
        if status < 0 {
            publishCommandError(status, context: "Seek")
            return
        }

        lastPosition = target
        publishTiming()
    }

    private func loadExternalTrackImmediately(_ track: ExternalTrack) {
        dispatchPrecondition(condition: .onQueue(queue))
        let commandName: String =
            switch track.type {
            case .video: "video-add"
            case .audio: "audio-add"
            case .subtitle: "sub-add"
            }

        let status = runCommand([
            commandName,
            Self.mpvPath(for: track.url),
            track.select ? "select" : "auto",
        ])
        if status < 0 {
            publishCommandError(status, context: "Load external \(track.type.rawValue) track")
        }
    }

    func setInitialOption(_ name: String, value: String) throws {
        guard let handle else {
            throw MPVPlayerError(localizedDescription: "mpv is not available.")
        }
        try check(mpv_set_option_string(handle, name, value), context: "Set option \(name)")
    }

    func observeProperties() {
        guard let handle else { return }

        let properties = [
            "pause",
            "core-idle",
            "idle-active",
            "seeking",
            "paused-for-cache",
            "eof-reached",
            "seekable",
            "duration",
            "time-pos",
            "cache-buffering-state",
            "demuxer-cache-duration",
            "demuxer-cache-state",
            "track-list",
            "current-tracks/audio/id",
            "current-tracks/video/id",
            "current-tracks/sub/id",
            "media-title",
            "metadata",
            "chapter-list",
            "video-out-params",
            "video-params",
            "audio-params",
            "video-codec",
            "audio-codec-name",
            "hwdec-current",
            "file-format",
            "file-size",
            "estimated-vf-fps",
            "volume",
            "mute",
            "speed",
        ]

        for (index, property) in properties.enumerated() {
            let status = mpv_observe_property(
                handle,
                UInt64(index + 1),
                property,
                MPV_FORMAT_NONE
            )
            if status < 0 {
                publishCommandError(status, context: "Observe \(property)")
            }
        }

        if isTextSubtitleInterceptionEnabled {
            observeTextSubtitleSnapshot()
        }
    }

    func observeTextSubtitleSnapshot() {
        guard let handle else { return }
        let status = mpv_observe_property(
            handle,
            Self.textSubtitleObservationID,
            "sub-text-snapshot",
            MPV_FORMAT_NODE
        )
        if status < 0 {
            publishCommandError(status, context: "Observe sub-text-snapshot")
        }
    }
}

// MARK: - Commands and properties

private extension MPVEngine {
    func command(_ arguments: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            let status = self.runCommand(arguments)
            if status < 0 {
                self.publishCommandError(status, context: arguments.first ?? "Command")
            }
        }
    }

    func runCommand(_ arguments: [String]) -> Int32 {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }

        var cArguments: [UnsafePointer<CChar>?] = arguments.map { argument in
            guard let duplicate = strdup(argument) else { return nil }
            return UnsafePointer(duplicate)
        }
        cArguments.append(nil)

        defer {
            for case let pointer? in cArguments {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }

        let status = mpv_command(handle, &cArguments)
        recordAcceptedCommand(arguments, status: status)
        return status
    }

    func runCommandReturningValue(_ arguments: [String]) -> (Int32, MPVNodeValue?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let handle else { return (MPV_ERROR_UNINITIALIZED.rawValue, nil) }

        var cArguments: [UnsafePointer<CChar>?] = arguments.map { argument in
            guard let duplicate = strdup(argument) else { return nil }
            return UnsafePointer(duplicate)
        }
        cArguments.append(nil)

        defer {
            for case let pointer? in cArguments {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }

        var result = mpv_node()
        let status = mpv_command_ret(handle, &cArguments, &result)
        recordAcceptedCommand(arguments, status: status)
        guard status >= 0 else { return (status, nil) }
        defer { mpv_free_node_contents(&result) }
        return (status, MPVNodeValue(copying: result))
    }

    func recordAcceptedCommand(_ arguments: [String], status: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard status >= 0, let command = arguments.first?.lowercased() else { return }
        switch command {
        case "loadfile":
            lifecycleDiagnostics.loadCommands &+= 1
        case "seek":
            lifecycleDiagnostics.seekCommands &+= 1
        default:
            break
        }
    }

    func setProperty(_ name: String, to value: String) {
        queue.async { [weak self] in
            self?.setPropertyImmediatelyOrDefer(name, to: value)
        }
    }

    func setPropertyImmediatelyOrDefer(_ name: String, to value: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        desiredProperties[name] = value
        guard handle != nil else { return }

        let status = setPropertyImmediately(name, to: value)
        if status < 0 {
            publishCommandError(status, context: "Set \(name)")
        } else if Self.textSubtitleSnapshotRefreshProperties.contains(
            name.lowercased()
        ) {
            // `sub-text-snapshot` is a computed property. mpv updates the
            // value synchronously when visibility changes, but does not emit
            // a property-change notification for that dependency, so refresh
            // it explicitly for semantic-subtitle stream consumers.
            refreshTextSubtitleSnapshot()
        }
    }

    func setPropertyImmediately(_ name: String, to value: String) -> Int32 {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        return mpv_set_property_string(handle, name, value)
    }

    func getFlag(_ name: String) -> Bool? {
        guard let handle else { return nil }
        var value: Int32 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else { return nil }
        return value != 0
    }

    func getInt64(_ name: String) -> Int64? {
        guard let handle else { return nil }
        var value: Int64 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return value
    }

    func getDouble(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value: Double = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return nil }
        return value.isFinite ? value : nil
    }

    func getString(_ name: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(validatingCString: value)
    }

    func getNode(_ name: String) -> MPVNodeValue? {
        guard let handle else { return nil }
        var node = mpv_node()
        guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &node) >= 0 else { return nil }
        defer { mpv_free_node_contents(&node) }
        return MPVNodeValue(copying: node)
    }
}

// MARK: - Event processing

private extension MPVEngine {
    func scheduleEventDrain() {
        queue.async { [weak self] in
            self?.drainEvents()
        }
    }

    func drainEvents() {
        dispatchPrecondition(condition: .onQueue(queue))

        while let handle {
            guard let eventPointer = mpv_wait_event(handle, 0) else { return }
            let event = eventPointer.pointee
            if event.event_id == MPV_EVENT_NONE {
                return
            }
            handleEvent(event)
        }
    }

    func handleEvent(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_START_FILE:
            lifecycleDiagnostics.startFileEvents &+= 1
            guard playbackRequestIsActive else { return }
            guard let data = event.data else { return }
            let startEvent = data.assumingMemoryBound(to: mpv_event_start_file.self).pointee
            let entryID = startEvent.playlist_entry_id
            if let requestedPlaylistEntryID, entryID != requestedPlaylistEntryID {
                return
            }
            requestedPlaylistEntryID = entryID
            activePlaylistEntryID = entryID
            isLoading = true
            isFileLoaded = false
            isSeeking = false
            isPausedForCache = false
            isIdle = false
            didReachEnd = false
            hasPlaybackStarted = false
            fatalPlaybackError = nil
            clearTextSubtitleSnapshot()
            publishState(.loading)

        case MPV_EVENT_FILE_LOADED:
            guard isRequestedPlaylistEntryActive else { return }
            isLoading = false
            isFileLoaded = true
            isIdle = false
            refreshTiming()
            applyPendingSeekAfterLoad()
            refreshBuffer()
            refreshAudioState()
            refreshMediaInformation()
            loadPendingExternalTracks()
            refreshTextSubtitleSnapshot()
            publishState(isPaused ? .paused : .ready)

        case MPV_EVENT_SEEK:
            guard isRequestedPlaylistEntryActive else { return }
            isSeeking = true
            publishState(.seeking)

        case MPV_EVENT_PLAYBACK_RESTART:
            guard isRequestedPlaylistEntryActive else { return }
            isLoading = false
            isSeeking = false
            isIdle = false
            hasPlaybackStarted = true
            refreshTiming()
            refreshBuffer()
            refreshTextSubtitleSnapshot()
            refreshState()

        case MPV_EVENT_VIDEO_RECONFIG, MPV_EVENT_AUDIO_RECONFIG:
            guard isRequestedPlaylistEntryActive else { return }
            refreshMediaInformation()

        case MPV_EVENT_PROPERTY_CHANGE:
            guard isRequestedPlaylistEntryActive else { return }
            guard let data = event.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let name = property.name else { return }
            let copiedNode: MPVNodeValue? =
                if property.format == MPV_FORMAT_NODE, let value = property.data {
                    MPVNodeValue(
                        copying: value.assumingMemoryBound(to: mpv_node.self).pointee
                    )
                } else {
                    nil
                }
            handlePropertyChange(String(cString: name), copiedNode: copiedNode)

        case MPV_EVENT_END_FILE:
            handleEndFile(event)

        case MPV_EVENT_LOG_MESSAGE:
            handleLogMessage(event)

        case MPV_EVENT_QUEUE_OVERFLOW:
            publish(
                .error(
                    MPVPlayerError(
                        localizedDescription:
                        "The mpv event queue overflowed; player state was refreshed."
                    ),
                    fatal: false
                )
            )
            if playbackRequestIsActive {
                refreshAll()
            }

        case MPV_EVENT_SHUTDOWN:
            guard let oldHandle = handle else { return }
            handle = nil
            playbackRequestIsActive = false
            clearTextSubtitleSnapshot()
            mpv_set_wakeup_callback(oldHandle, nil, nil)
            mpv_destroy(oldHandle)
            lifecycleDiagnostics.handlesDestroyed &+= 1
            publishState(.stopped)

        default:
            break
        }
    }

    var isRequestedPlaylistEntryActive: Bool {
        guard playbackRequestIsActive else { return false }
        guard let requestedPlaylistEntryID else { return true }
        return activePlaylistEntryID == requestedPlaylistEntryID
    }

    func handlePropertyChange(_ name: String, copiedNode: MPVNodeValue? = nil) {
        switch name {
        case "pause":
            isPaused = getFlag(name) ?? isPaused
            refreshState()

        case "core-idle", "idle-active":
            isIdle = (getFlag("idle-active") ?? getFlag("core-idle")) ?? isIdle
            refreshState()

        case "seeking":
            isSeeking = getFlag(name) ?? isSeeking
            refreshState()

        case "paused-for-cache":
            isPausedForCache = getFlag(name) ?? isPausedForCache
            refreshBuffer()
            refreshState()

        case "eof-reached":
            didReachEnd = getFlag(name) ?? didReachEnd
            refreshState()

        case "time-pos", "seekable":
            refreshTiming()

        case "duration":
            refreshTiming()
            refreshMediaInformation()

        case "cache-buffering-state", "demuxer-cache-duration", "demuxer-cache-state":
            refreshBuffer()

        case "volume", "mute", "speed":
            refreshAudioState()

        case "track-list", "current-tracks/audio/id", "current-tracks/video/id",
             "current-tracks/sub/id", "media-title", "metadata", "chapter-list",
             "video-out-params", "video-params", "audio-params", "video-codec",
             "audio-codec-name", "hwdec-current", "file-format", "file-size",
             "estimated-vf-fps":
            refreshMediaInformation()
            if name == "track-list" || name == "current-tracks/sub/id" {
                refreshTextSubtitleSnapshot()
            }

        case "sub-text-snapshot":
            updateTextSubtitleSnapshot(from: copiedNode)

        default:
            break
        }
    }

    func handleEndFile(_ event: mpv_event) {
        guard playbackRequestIsActive else { return }
        guard let data = event.data else {
            playbackRequestIsActive = false
            publishState(.ended)
            return
        }

        let endEvent = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
        let entryID = endEvent.playlist_entry_id

        // Commands can outrun callback delivery. Ignore lifecycle events for
        // an entry displaced by a newer typed load instead of publishing a
        // terminal state for the replacement request.
        if let requestedPlaylistEntryID, entryID != requestedPlaylistEntryID {
            if activePlaylistEntryID == entryID {
                activePlaylistEntryID = nil
            }
            return
        }

        if endEvent.reason == MPV_END_FILE_REASON_REDIRECT {
            // A playlist-like source replaces itself with new entries. The
            // next START_FILE identifies the actual selected item.
            clearTextSubtitleSnapshot()
            requestedPlaylistEntryID = nil
            activePlaylistEntryID = nil
            isLoading = true
            isFileLoaded = false
            isSeeking = false
            isPausedForCache = false
            isIdle = false
            publishState(.loading)
            return
        }

        // Typed stop requests publish synchronously after mpv accepts the
        // command, so any STOP that reaches this active-request path belongs
        // to an internal or advanced raw command and must not override state.
        if endEvent.reason == MPV_END_FILE_REASON_STOP {
            return
        }

        playbackRequestIsActive = false
        clearTextSubtitleSnapshot()
        requestedPlaylistEntryID = nil
        activePlaylistEntryID = nil
        isLoading = false
        isFileLoaded = false
        isSeeking = false
        isPausedForCache = false
        isIdle = true
        hasPlaybackStarted = false

        switch endEvent.reason {
        case MPV_END_FILE_REASON_EOF:
            didReachEnd = true
            lastPosition = lastDuration
            publishTiming()
            publishState(.ended)

        case MPV_END_FILE_REASON_STOP, MPV_END_FILE_REASON_QUIT:
            publishState(.stopped)

        case MPV_END_FILE_REASON_ERROR:
            let code = endEvent.error
            publishFatalError(
                localizedDescription(code, context: "Playback failed")
            )

        default:
            break
        }
    }

    func handleLogMessage(_ event: mpv_event) {
        guard let data = event.data else { return }
        let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
        publish(
            .log(
                MPVEngineLog(
                    prefix: message.prefix.map { String(cString: $0) } ?? "mpv",
                    level: message.level.map { String(cString: $0) } ?? "info",
                    message: message.text.map { String(cString: $0) } ?? ""
                )
            )
        )
    }
}

// MARK: - State snapshots

private extension MPVEngine {
    func refreshAll() {
        refreshTiming()
        refreshBuffer()
        refreshAudioState()
        refreshMediaInformation()
        refreshTextSubtitleSnapshot()
        refreshState()
    }

    func refreshState() {
        let state: MPVPlaybackState =
            if let fatalPlaybackError {
                .failed(fatalPlaybackError)
            } else if didReachEnd {
                .ended
            } else if isLoading {
                .loading
            } else if isSeeking {
                .seeking
            } else if isPausedForCache {
                .buffering
            } else if isIdle, !isFileLoaded {
                sourceURL == nil ? .idle : .stopped
            } else if isPaused {
                .paused
            } else if isFileLoaded, hasPlaybackStarted {
                .playing
            } else if isFileLoaded {
                .ready
            } else {
                .idle
            }

        publishState(state)
    }

    func publishState(_ state: MPVPlaybackState) {
        guard state != lastState else { return }
        lastState = state
        switch state {
        case .loading:
            lifecycleDiagnostics.loadingStateTransitions &+= 1
        case .buffering:
            lifecycleDiagnostics.bufferingStateTransitions &+= 1
        case .seeking:
            lifecycleDiagnostics.seekingStateTransitions &+= 1
        default:
            break
        }
        publish(.state(state))
    }

    func refreshTiming() {
        lastPosition = max(
            .zero,
            getDouble("time-pos").flatMap(Duration.init(mpvSeconds:)) ?? lastPosition
        )
        lastDuration = max(
            .zero,
            getDouble("duration").flatMap(Duration.init(mpvSeconds:)) ?? lastDuration
        )
        lastSeekable = getFlag("seekable") ?? lastSeekable
        publishTiming()
    }

    func publishTiming() {
        publish(
            .timing(
                position: lastPosition,
                duration: lastDuration,
                isSeekable: lastSeekable
            )
        )
    }

    func refreshBuffer() {
        let cache = getNode("demuxer-cache-state")?.mapValue ?? [:]
        let ranges = Self.parseSeekableRanges(cache["seekable-ranges"])

        let resumeProgress = Double(getInt64("cache-buffering-state") ?? 0) / 100
        publish(
            .buffer(
                MPVBufferStatus(
                    isBuffering: isPausedForCache,
                    progress: resumeProgress,
                    secondsBufferedAhead: (cache["cache-duration"]?.doubleValue
                        ?? getDouble("demuxer-cache-duration")).flatMap(Duration.init(mpvSeconds:))
                        ?? .zero,
                    bufferedEnd: cache["cache-end"]?.doubleValue.flatMap(
                        Duration.init(mpvSeconds:)
                    ),
                    bytesAhead: cache["fw-bytes"]?.integerValue ?? 0,
                    inputRate: cache["raw-input-rate"]?.integerValue ?? 0,
                    seekableRanges: ranges
                )
            )
        )
    }

    func refreshAudioState() {
        let volume = clamp(getDouble("volume") ?? configuration.volume, to: 0 ... 100)
        let isMuted = getFlag("mute") ?? false
        let playbackRate = getDouble("speed") ?? configuration.playbackRate
        desiredProperties["volume"] = Self.format(volume)
        desiredProperties["mute"] = isMuted ? "yes" : "no"
        desiredProperties["speed"] = Self.format(playbackRate)
        publish(.audio(volume: volume, isMuted: isMuted, playbackRate: playbackRate))
    }

    func refreshTextSubtitleSnapshot() {
        guard isTextSubtitleInterceptionEnabled else { return }
        updateTextSubtitleSnapshot(from: getNode("sub-text-snapshot"))
    }

    func updateTextSubtitleSnapshot(from node: MPVNodeValue?) {
        guard isTextSubtitleInterceptionEnabled else { return }
        let snapshot = MPVTextSubtitleParser.snapshot(from: node)
        guard snapshot != lastTextSubtitleSnapshot else { return }
        lastTextSubtitleSnapshot = snapshot
        publish(.textSubtitles(snapshot))
    }

    func clearTextSubtitleSnapshot() {
        guard isTextSubtitleInterceptionEnabled, !lastTextSubtitleSnapshot.isEmpty else {
            return
        }
        lastTextSubtitleSnapshot = TextSubtitleSnapshot()
        publish(.textSubtitles(TextSubtitleSnapshot()))
    }

    func refreshMediaInformation() {
        let tracks = Self.parseTracks(getNode("track-list"))
        let chapters = Self.parseChapters(getNode("chapter-list"))
        let metadata = Self.parseMetadata(getNode("metadata"))

        let width = getInt64("video-params/w") ?? getInt64("video-out-params/w") ?? 0
        let height = getInt64("video-params/h") ?? getInt64("video-out-params/h") ?? 0
        // `video-params` describes the decoded source. Prefer it over
        // `video-out-params`, which can reflect filters applied later in the
        // pipeline and must not make HDR source detection depend on output.
        let primaries =
            getString("video-params/primaries")
            ?? getString("video-out-params/primaries")
        let gamma =
            getString("video-params/gamma")
            ?? getString("video-out-params/gamma")
        let transferFunction = MPVTransferFunction(mpvValue: gamma)
        let contentIsHDR = transferFunction == .pq || transferFunction == .hlg
        let displayCapable = renderTarget?.displaySupportsExtendedDynamicRange ?? false
        let active =
            contentIsHDR
                && (renderTarget?.usesExtendedDynamicRange ?? false)
                && displayCapable
                && outputHeadroom > 1

        let hdr = MPVHDRStatus(
            primaries: primaries,
            transferFunction: transferFunction,
            minimumLuminance: getDouble("video-params/min-luma")
                ?? getDouble("video-out-params/min-luma"),
            maximumLuminance: getDouble("video-params/max-luma")
                ?? getDouble("video-out-params/max-luma"),
            maxContentLightLevel: getDouble("video-params/max-cll")
                ?? getDouble("video-out-params/max-cll"),
            maxFrameAverageLightLevel: getDouble("video-params/max-fall")
                ?? getDouble("video-out-params/max-fall"),
            signalPeak: getDouble("video-params/sig-peak")
                ?? getDouble("video-out-params/sig-peak"),
            isDisplayHDRCapable: displayCapable,
            isHDRActive: active
        )

        let dimensions: MPVVideoDimensions? =
            width > 0 && height > 0
                ? MPVVideoDimensions(
                    width: Int(width),
                    height: Int(height),
                    displayWidth: (getInt64("video-params/dw")
                        ?? getInt64("video-out-params/dw")).map(Int.init),
                    displayHeight: (getInt64("video-params/dh")
                        ?? getInt64("video-out-params/dh")).map(Int.init)
                )
                : nil
        let reportedDuration: Duration? =
            if let duration = getDouble("duration").flatMap(Duration.init(mpvSeconds:)) {
                duration
            } else {
                lastDuration > .zero ? lastDuration : nil
            }

        publish(
            .media(
                MPVMediaInformation(
                    sourceURL: sourceURL,
                    title: getString("media-title"),
                    duration: reportedDuration,
                    container: getString("file-format"),
                    fileSize: getInt64("file-size"),
                    videoCodec: getString("video-codec"),
                    audioCodec: getString("audio-codec-name"),
                    hardwareDecoder: getString("hwdec-current"),
                    dimensions: dimensions,
                    framesPerSecond: getDouble("estimated-vf-fps"),
                    rotation: Int(
                        getInt64("video-params/rotate")
                            ?? getInt64("video-out-params/rotate")
                            ?? 0
                    ),
                    metadata: metadata,
                    chapters: chapters,
                    tracks: tracks,
                    hdr: hdr
                )
            )
        )
    }
}

extension MPVEngine {
    static func targetPeakNits(forOutputHeadroom headroom: Double) -> Double {
        sdrReferenceWhiteNits * max(1, headroom)
    }

    static func parseSeekableRanges(_ node: MPVNodeValue?) -> [ClosedRange<Duration>] {
        node?.arrayValue?.compactMap { value in
            guard let range = value.mapValue,
                  let start = range["start"]?.doubleValue.flatMap(Duration.init(mpvSeconds:)),
                  let end = range["end"]?.doubleValue.flatMap(Duration.init(mpvSeconds:)),
                  start <= end
            else { return nil }

            return start ... end
        } ?? []
    }

    static func parseTracks(_ node: MPVNodeValue?) -> [MPVMediaTrack] {
        node?.arrayValue?.compactMap { value in
            guard let track = value.mapValue,
                  let id = track["id"]?.integerValue,
                  let rawType = track["type"]?.stringValue
            else { return nil }

            let type: MPVTrackType
            switch rawType {
            case "video": type = .video
            case "audio": type = .audio
            case "sub": type = .subtitle
            default: return nil
            }

            return MPVMediaTrack(
                id: Int(id),
                type: type,
                title: track["title"]?.stringValue,
                language: track["lang"]?.stringValue,
                codec: track["codec"]?.stringValue,
                isSelected: track["selected"]?.boolValue ?? false,
                isDefault: track["default"]?.boolValue ?? false,
                isForced: track["forced"]?.boolValue ?? false,
                isExternal: track["external"]?.boolValue ?? false
            )
        } ?? []
    }

    static func parseChapters(_ node: MPVNodeValue?) -> [MPVChapter] {
        guard let values = node?.arrayValue else { return [] }

        return values.enumerated().compactMap { index, value in
            guard let chapter = value.mapValue else { return nil }
            let nextStart = values.dropFirst(index + 1).compactMap {
                $0.mapValue?["time"]?.doubleValue.flatMap(Duration.init(mpvSeconds:))
            }.first

            return MPVChapter(
                id: index,
                title: chapter["title"]?.stringValue,
                startTime: chapter["time"]?.doubleValue
                    .flatMap(Duration.init(mpvSeconds:)) ?? .zero,
                endTime: nextStart
            )
        }
    }

    static func parseMetadata(_ node: MPVNodeValue?) -> [String: String] {
        guard let values = node?.mapValue else { return [:] }
        return values.reduce(into: [:]) { result, pair in
            if let string = pair.value.stringValue {
                result[pair.key] = string
            }
        }
    }
}

// MARK: - Utilities

private extension MPVEngine {
    static let sdrReferenceWhiteNits = 203.0

    func publish(_ update: MPVEngineUpdate) {
        updateContinuation.yield(
            MPVEngineEmission(
                generation: currentGeneration,
                update: update
            )
        )
    }

    func publishRenderSurfaceDiagnostic(_ message: String) {
        switch configuration.logLevel {
        case .verbose, .debug, .trace:
            publish(
                .log(
                    MPVEngineLog(
                        prefix: "mpvui/render-surface",
                        level: "debug",
                        message: message
                    )
                )
            )
        case .none, .fatal, .error, .warning, .info, .status:
            break
        }
    }

    func publishGlobally(_ update: MPVEngineUpdate) {
        updateContinuation.yield(
            MPVEngineEmission(
                generation: nil,
                update: update
            )
        )
    }

    func publishFatalError(_ localizedDescription: String, globally: Bool = false) {
        let error = MPVPlayerError(localizedDescription: localizedDescription)
        fatalPlaybackError = error
        lastState = .failed(error)
        let update = MPVEngineUpdate.error(error, fatal: true)
        if globally {
            publishGlobally(update)
        } else {
            publish(update)
        }
    }

    func publishCommandError(_ code: Int32, context: String) {
        publish(
            .error(
                MPVPlayerError(
                    localizedDescription: localizedDescription(code, context: context)
                ),
                fatal: false
            )
        )
    }

    func check(_ status: Int32, context: String) throws {
        guard status < 0 else { return }
        throw MPVPlayerError(
            localizedDescription: localizedDescription(status, context: context)
        )
    }

    func localizedDescription(_ code: Int32, context: String) -> String {
        let detail = mpv_error_string(code).map { String(cString: $0) } ?? "Unknown mpv error"
        return "\(context): \(detail)"
    }

    func startSecurityScopedAccessIfNeeded(for url: URL) {
        guard securityScopedURL == nil else { return }
        guard url.isFileURL, url.startAccessingSecurityScopedResource() else { return }
        securityScopedURL = url
    }

    func stopSecurityScopedAccess() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    func startExternalSecurityScopedAccessIfNeeded(for url: URL) {
        guard url.isFileURL, !externalSecurityScopedURLs.contains(url) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        externalSecurityScopedURLs.insert(url)
    }

    func stopExternalSecurityScopedAccess() {
        for url in externalSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        externalSecurityScopedURLs.removeAll()
    }

    static func selectionProperty(for type: MPVTrackType) -> String {
        switch type {
        case .video: "vid"
        case .audio: "aid"
        case .subtitle: "sid"
        }
    }

    static func mpvPath(for url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }

    static func format(_ number: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), number)
    }

    static func format(_ duration: Duration) -> String {
        format(duration.seconds)
    }

    static func formatTargetPeak(_ nits: Double) -> String {
        guard nits.isFinite else { return String(Int(sdrReferenceWhiteNits)) }
        let boundedNits = clamp(nits, to: sdrReferenceWhiteNits ... 10000)
        return String(Int(boundedNits.rounded()))
    }
}
