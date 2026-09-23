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

    /// Retire rendering before the final player owner disappears. Enqueueing a
    /// weak asynchronous shutdown can leave VO work alive through app/test
    /// teardown, after native shader/compiler globals begin destruction.
    func shutdownSynchronously() {
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            destroyHandle(preservePlayback: false)
        } else {
            queue.sync { destroyHandle(preservePlayback: false) }
        }
    }

    func createHandle() {
        dispatchPrecondition(condition: .onQueue(queue))

        guard let renderTarget else { return }
        videoToolboxSessionUsesHardware = nil
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
            var windowID = renderTarget.layerAddress
            try check(
                mpv_set_option(newHandle, "wid", MPV_FORMAT_INT64, &windowID),
                context: "Set Metal render surface"
            )

            if videoOutput == .sampleBuffer {
                try setInitialOption("vo", value: "avfoundation")
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
                try setInitialOption("vo", value: "gpu-next")
                try setInitialOption("gpu-api", value: "vulkan")
                try setInitialOption("gpu-context", value: "moltenvk")
                try setInitialOption(
                    "external-surface-size",
                    value: "\(renderTarget.drawableWidth)x\(renderTarget.drawableHeight)"
                )
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
            try setInitialOption("ao", value: "avfoundation,")
            for (name, value) in configuration.audio.mpvOptions {
                try setInitialOption(name, value: value)
            }

            try setInitialOption("hwdec", value: configuration.hardwareDecoding.rawValue)
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
            if videoOutput == .metal {
                for (name, value) in Self.colorTargetOptions(for: renderTarget) {
                    try setInitialOption(name, value: value)
                }
            }

            for (name, value) in configuration.additionalOptions
                where !isManagedOption(name)
            {
                try setInitialOption(name, value: value)
            }

            try check(mpv_initialize(newHandle), context: "Initialize mpv")
        } catch {
            publishFatalError(error, globally: true)
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
        startDiagnosticsTimer()
        applyDesiredProperties()
        loadPendingSourceIfPossible()
    }

    func destroyHandle(preservePlayback: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        cancelSubtitleQueries()
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil
        completePiPSeek(false)
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
            if !isDisplaySwitchInProgress {
                shouldAutoPlay = !(getFlag("pause") ?? isPaused)
            }
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
}
