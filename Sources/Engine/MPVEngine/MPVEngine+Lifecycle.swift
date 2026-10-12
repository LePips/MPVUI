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

// Creates, configures, and retires the libmpv handle on the engine queue.
extension MPVEngine {
    private static let wakeupCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
        context in
        guard let context else { return }
        let engine = Unmanaged<WeakBox<MPVEngine>>.fromOpaque(context).takeUnretainedValue()
        engine.value?.scheduleEventDrain()
    }

    func shutdown() {
        queue.async { [weak self] in
            self?.destroyHandle(preservePlayback: false)
        }
    }

    /// Retire rendering before the final player owner disappears. Enqueuing a
    /// weak asynchronous shutdown can leave VO work alive through app/test
    /// teardown, after native shader/compiler globals begin destruction.
    func shutdownSynchronously() {
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            destroyHandle(preservePlayback: false)
        } else {
            queue.sync { destroyHandle(preservePlayback: false) }
        }
    }

    func createHandle(allowStopped: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))

        guard handle == nil, !didRejectNativeOutput, allowStopped || !isStoppedForResourceRelease else { return }
        resetMediaObservations()
        liveConfigurationFailure = nil
        fatalPlaybackError = nil
        guard let newHandle = mpv_create() else {
            publishFatalError(
                .clientCreationFailed,
                globally: true
            )
            return
        }

        handle = newHandle
        let contextPointer = Unmanaged.passUnretained(wakeupContext).toOpaque()
        mpv_set_wakeup_callback(newHandle, Self.wakeupCallback, contextPointer)
        // Request diagnostics before initialization so Vulkan/libplacebo's
        // one-time surface enumeration and selected format are observable.
        // Native capability rejection is an internal output contract, even
        // when the host disables public diagnostics. Preserve that preference
        // when forwarding messages below.
        let requestedLogLevel: String =
            if [.none, .fatal, .error, .warning].contains(configuration.logLevel) {
                "info"
            } else {
                configuration.logLevel.rawValue
            }
        _ = mpv_request_log_messages(newHandle, requestedLogLevel)

        do {
            if let renderTarget {
                var windowID = renderTarget.layerAddress
                try check(
                    mpv_set_option(newHandle, "wid", MPV_FORMAT_INT64, &windowID),
                    context: "Set render surface"
                )
            }

            if videoOutput == .sampleBuffer {
                try setInitialOption("vo", value: renderTarget == nil ? "null" : "avfoundation")
                try setInitialOption("avfoundation-presentation", value: "media")
                try setInitialOption(
                    "avfoundation-native-dovi-profile7",
                    value: configuration.dolbyVisionPolicy.nativeMPVValue
                )
                try setInitialOption("avfoundation-pip-composite-osd", value: "yes")
                let subtitleStatus = mpv_set_option_string(
                    newHandle, "avfoundation-subtitle-luminance",
                    Self.format(configuration.subtitleLuminance)
                )
                if subtitleStatus == MPV_ERROR_OPTION_NOT_FOUND.rawValue {
                    presentationFallbackReason = .unsupportedSubtitleLuminance
                } else {
                    try check(subtitleStatus, context: "Set native subtitle luminance")
                }
            } else {
                try setInitialOption("vo", value: renderTarget == nil ? "null" : "gpu-next")
                try setInitialOption("gpu-api", value: "vulkan")
                try setInitialOption("gpu-context", value: "moltenvk")
                if let renderTarget {
                    try setInitialOption(
                        "external-surface-size",
                        value: "\(renderTarget.drawableWidth)x\(renderTarget.drawableHeight)"
                    )
                }
                try setInitialOption("target-colorspace-hint", value: "no")
            }
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
            // With a passthrough sink, the spatial output takes TrueHD and DTS-HD for it and
            // refuses everything else, which goes on to AVFoundation.
            try setInitialOption("ao", value: passthroughSinkBridge == nil ? "avfoundation," : "spatial,avfoundation,")
            for (name, value) in configuration.audio.mpvOptions {
                try setInitialOption(name, value: value)
            }
            if let passthroughSinkBridge {
                try setInitialOption("ao-spatial-sink", value: passthroughSinkBridge.address)
                try setInitialOption("audio-spdif", value: spdifCodecs)
            }

            for (name, value) in MPVRenderingOptions.hardwareDecodingOptions(configuration.hardwareDecoding, backend: videoOutput) {
                try setInitialOption(name, value: value)
            }
            renderingResolution = MPVRenderingOptions.resolve(
                configuration.renderingQuality, backend: videoOutput,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
            for (name, value) in renderingResolution?.options ?? [:] {
                try setInitialOption(name, value: value)
            }
            for path in renderingResolution?.shaderPaths ?? [] {
                // The append operation disables string-list splitting, preserving
                // literal colons and backslashes in local shader paths.
                try setInitialOption("glsl-shaders-append", value: path)
            }
            for (name, value) in MPVRenderingOptions.deinterlaceOptions(configuration.deinterlace) {
                try setInitialOption(name, value: value)
            }

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
            if videoOutput == .metal, let renderTarget {
                for (name, value) in Self.colorTargetOptions(for: renderTarget) {
                    try setInitialOption(name, value: value)
                }
            }

            for (name, value) in configuration.additionalOptions
                where !isManagedOption(name)
            {
                try setInitialOption(name, value: value)
            }

            // Play audio without creating a video window or decoder.
            try setInitialOption("force-window", value: "no")
            if renderTarget == nil {
                try setInitialOption("vid", value: "no")
            }

            try check(mpv_initialize(newHandle), context: "Initialize mpv")
            try check(mpv_hook_add(newHandle, 0, "on_preloaded", 0), context: "Observe available tracks")
        } catch {
            publishFatalError(error, globally: true)
            mpv_destroy(newHandle)
            handle = nil
            return
        }

        lifecycleDiagnostics.handlesCreated &+= 1
        if let renderTarget {
            publishRenderSurfaceDiagnostic(
                "mpv renderer attached output=\(renderTarget.drawableWidth)x"
                    + "\(renderTarget.drawableHeight) lifecycle=\(lifecycleDiagnostics)"
            )
        }

        observeProperties()
        startDiagnosticsTimer()
        applyDesiredProperties()
        loadPendingSourceIfPossible()
    }

    /// MoltenVK retires outstanding presentations by briefly assigning 1x1 to
    /// its layer during swapchain destruction. Authorize that native write only
    /// on the retained Metal target while teardown joins the rendering threads.
    @discardableResult
    func withNativeSurfaceRetirement(_ body: () -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        let layer = videoOutput == .metal ? renderTarget?.layerOwner as? MPVMetalLayer : nil
        layer?.beginNativeResizeTransaction()
        defer { layer?.endNativeResizeTransaction() }
        body()
        return layer?.invalidateDrawablePoolAfterNativeTeardown() ?? false
    }

    func destroyHandle(preservePlayback: Bool, alreadyShuttingDown: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        cancelSubtitleQueries()
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil
        completePiPSeek(false)
        // A deferred load has no native session to retire. Preserve its
        // pending state across surface changes, but fully clear it on shutdown.
        if handle == nil, preservePlayback {
            return
        }
        if handle != nil, preservePlayback, isFileLoaded || isLoading {
            lastPosition =
                pendingSeekAfterLoad
                    ?? getDouble("time-pos").flatMap(Duration.init(mpvSeconds:))
                    ?? lastPosition
            pendingStartTime = lastPosition
            pendingSeekAfterLoad = nil
            if !isDisplaySwitchInProgress {
                shouldAutoPlay = !(getFlag("pause") ?? isPaused)
            }
            needsSourceLoad = sourceURL != nil
            snapshotRuntimeProperties()
            pendingExternalTracks = externalTracks
        }

        if let oldHandle = handle {
            handle = nil
            mpv_set_wakeup_callback(oldHandle, nil, nil)
            mpv_wakeup(oldHandle)
            withNativeSurfaceRetirement {
                if alreadyShuttingDown {
                    mpv_destroy(oldHandle)
                } else {
                    mpv_terminate_destroy(oldHandle)
                }
            }
            lifecycleDiagnostics.handlesDestroyed &+= 1
        }
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
            isStoppedForResourceRelease = true
            isPaused = true
            shouldAutoPlay = false
            didReachEnd = false
            sourceURL = nil
            pendingStartTime = nil
            pendingSeekAfterLoad = nil
            needsSourceLoad = false
            lastPosition = .zero
            lastDuration = .zero
            lastSeekable = false
            requestedLoadUptime = nil
            seekUptime = nil
            stopSecurityScopedAccess()
            stopExternalSecurityScopedAccess()
            externalTracks.removeAll()
            pendingExternalTracks.removeAll()
            publishState(.stopped)
        }
    }
}
