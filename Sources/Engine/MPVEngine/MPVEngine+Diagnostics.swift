import Dispatch
import Foundation
import Libmpv

// Collects lifecycle and playback diagnostics and processes native output logs.
extension MPVEngine {
    func lifecycleSnapshot() async -> MPVEngineLifecycleDiagnostics {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.lifecycleDiagnostics ?? .init())
            }
        }
    }

    /// One-shot rendered-pixel inspection for integration validation. PiP uses
    /// native frame delivery and never calls this diagnostic.
    func renderedScreenshotForTesting() async -> MPVNodeValue? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let (status, value) = self.runCommandReturningValue(["screenshot-raw", "window", "bgr0"])
                continuation.resume(returning: status >= 0 ? value : nil)
            }
        }
    }

    func recordAcceptedCommand(_ arguments: [String], status: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard status >= 0, let command = arguments.first?.lowercased() else { return }
        recordPersistentCommandMutation(arguments)
        switch command {
        case "loadfile":
            lifecycleDiagnostics.loadCommands &+= 1
        case "seek":
            lifecycleDiagnostics.seekCommands &+= 1
        default:
            break
        }
    }

    func handleLogMessage(_ event: mpv_event) {
        guard let data = event.data else { return }
        let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
        // Copy before retiring a rejected native handle invalidates event data.
        let log = MPVLogMessage(
            prefix: message.prefix.map { String(cString: $0) } ?? "mpv",
            level: message.level.flatMap {
                MPVPlayerConfiguration.LogLevel(rawValue: String(cString: $0))
            } ?? .info,
            message: message.text.map { String(cString: $0) } ?? ""
        )
        if isRequestedPlaylistEntryActive, let hardware = MPVPlaybackDiagnosticsParser.videoToolboxSession(log) {
            updateVideoToolboxSession(hardware, hardwareDecoder: getString("hwdec-current"))
        }
        if videoOutput == .sampleBuffer,
           isRequestedPlaylistEntryActive,
           dolbyVisionResolver.consume(log: log)
        {
            refreshMediaInformation()
        }
        if videoOutput == .sampleBuffer, !didRequestNativeOutputFallback,
           let reason = Self.nativeOutputRejectionReason(log),
           Self.nativeDiagnosticMatchesCurrentEntry(requested: requestedPlaylistEntryID, active: activePlaylistEntryID),
           sourceURL != nil
        {
            // A replacement load can overtake a queued rejection log. Apply
            // fallback only to the matching entry, including after its
            // END_FILE has cleared both IDs, never to a newer pending load.
            didRequestNativeOutputFallback = true
            // Reconfiguration can fail before FILE_LOADED. Preserve the
            // requested position/intention even if END_FILE already arrived.
            if !isFileLoaded, !isLoading {
                pendingStartTime = lastPosition
                shouldAutoPlay = !isPaused
                pendingExternalTracks = externalTracks
            }
            let requestedVideoTrack = desiredProperties["vid"]
            destroyHandle(preservePlayback: true)
            // A failed VO reconfiguration can make mpv disable its video
            // track. That is an output failure, not the user's track choice;
            // do not carry an automatic vid=no into the replacement renderer.
            desiredProperties["vid"] = requestedVideoTrack
            needsSourceLoad = true
            playbackRequestIsActive = true
            didReachEnd = false
            fatalPlaybackError = nil
            publish(.nativeVideoOutputUnavailable(reason))
        }
        let orderedLevels: [MPVPlayerConfiguration.LogLevel] = [.none, .fatal, .error, .warning, .info, .status, .verbose, .debug, .trace]
        let threshold = orderedLevels.firstIndex(of: configuration.logLevel) ?? 0
        let severity = orderedLevels.firstIndex(of: log.level) ?? 0
        if threshold > 0, severity > 0, severity <= threshold {
            publish(.log(log))
        }
    }

    func startDiagnosticsTimer() {
        diagnosticsTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.isRequestedPlaylistEntryActive, self.isFileLoaded else { return }
            self.refreshPlaybackDiagnostics()
        }
        diagnosticsTimer = timer
        timer.resume()
    }

    func refreshPlaybackDiagnostics() {
        guard handle != nil else { return }
        lifecycleDiagnostics.engineActivity.diagnosticsSnapshots &+= 1
        var result = playbackDiagnostics
        result.audio = MPVAudioStatusParser.parse(
            output: getString("current-ao"), codec: getString("audio-codec-name"),
            sourceChannels: getString("current-tracks/audio/demux-channels"),
            outputChannels: getString("audio-out-params/channels"),
            outputFormat: getString("audio-out-params/format"),
            native: getNode("avfoundation-audio-spatialization")
        )
        result.decoderDroppedFrames = MPVPlaybackDiagnosticsParser.nonnegative(getInt64("decoder-frame-drop-count"))
        result.outputDroppedFrames = MPVPlaybackDiagnosticsParser.nonnegative(getInt64("frame-drop-count"))
        result.mistimedFrames = MPVPlaybackDiagnosticsParser.nonnegative(getInt64("mistimed-frame-count"))
        result.delayedFrames = MPVPlaybackDiagnosticsParser.nonnegative(getInt64("vo-delayed-frame-count"))
        result.audioVideoDriftSeconds = MPVPlaybackDiagnosticsParser.finite(getDouble("avsync"))
        result.totalAudioVideoCorrectionSeconds = MPVPlaybackDiagnosticsParser.finite(getDouble("total-avsync-change"))
        result.containerFramesPerSecond = MPVPlaybackDiagnosticsParser.finite(getDouble("container-fps"))
        result.estimatedFilterFramesPerSecond = MPVPlaybackDiagnosticsParser.finite(getDouble("estimated-vf-fps"))
        result.nominalDisplayFramesPerSecond = MPVPlaybackDiagnosticsParser.finite(getDouble("display-fps"))
        result.estimatedDisplayFramesPerSecond = MPVPlaybackDiagnosticsParser.finite(getDouble("estimated-display-fps"))
        let passes = videoOutput == .metal ? getNode("vo-passes")?.mapValue : nil
        result.freshRenderPasses = MPVPlaybackDiagnosticsParser.renderPasses(passes?["fresh"])
        result.redrawRenderPasses = MPVPlaybackDiagnosticsParser.renderPasses(passes?["redraw"])
        result.nativeOutputStatistics = videoOutput == .sampleBuffer
            ? MPVPlaybackDiagnosticsParser.nativeStatistics(getNode("avfoundation-video-statistics")) : nil
        let hardwareDecoder = getString("hwdec-current")
        result.decoder = decoderDiagnostics(hardwareDecoder: hardwareDecoder)
        result.deinterlace = MPVRenderingOptions.deinterlaceStatus(
            policy: configuration.deinterlace,
            interlaced: getFlag("video-frame-info/interlaced"), hardwareDecoder: hardwareDecoder,
            automaticFilterIsActive: getFlag("deinterlace-active")
        )
        // Filter-output cadence is a decoded cadence estimate only if the filter
        // chain has no configured processing capable of changing timestamps.
        let filters = getNode("vf")?.arrayValue
        result.estimatedDecodedFramesPerSecond = configuration.deinterlace.mode == .disabled && filters?.isEmpty == true
            ? result.estimatedFilterFramesPerSecond : nil
        if let resolution = renderingResolution {
            var effective: [String: String] = [:]
            for name in resolution.options.keys {
                if let value = getString(name) {
                    effective[name] = value
                }
            }
            if !resolution.shaderPaths.isEmpty {
                effective["glsl-shaders"] = getString("glsl-shaders")
            }
            result.renderingQuality = MPVRenderingQualityStatus(
                requested: configuration.renderingQuality, resolvedPreset: resolution.preset,
                backend: videoOutput, effectiveOptions: effective,
                unsupportedFeatures: resolution.unsupportedFeatures
            )
        }
        result.fallbackReasons = diagnosticFallbackReasons(result)
        result.engineActivity = lifecycleDiagnostics.engineActivity
        playbackDiagnostics = result
        publish(.diagnostics(result))
    }

    func decoderDiagnostics(hardwareDecoder: String?) -> MPVPlaybackDiagnostics.Decoder {
        MPVPlaybackDiagnosticsParser.decoder(
            codec: getString("video-format"), hardwareDecoder: hardwareDecoder,
            interop: getString("hwdec-interop"), pixelFormat: getString("video-dec-params/pixelformat"),
            requested: configuration.hardwareDecoding,
            sessionUsesHardware: videoToolboxSessionUsesHardware
        )
    }

    // Session logs and copied selected-decoder events can expose a fallback that
    // starts and ends between periodic snapshots. Publish each delivered change.
    func updateVideoToolboxSession(
        _ session: MPVPlaybackDiagnosticsParser.VideoToolboxSessionResult,
        hardwareDecoder: String?
    ) {
        videoToolboxSessionUsesHardware = switch session {
        case .hardware: true
        case .software: false
        case .unknown: nil
        }
        refreshDecoderDiagnostics(hardwareDecoder: hardwareDecoder)
    }

    func refreshDecoderDiagnostics(hardwareDecoder: String?) {
        guard handle != nil else { return }
        var result = playbackDiagnostics
        result.decoder = decoderDiagnostics(hardwareDecoder: hardwareDecoder)
        result.fallbackReasons = diagnosticFallbackReasons(result)
        guard result != playbackDiagnostics else { return }
        // This updates decoder fields only; diagnosticsSnapshots is the
        // revision of full timer/native snapshots used by timing collectors.
        result.engineActivity = lifecycleDiagnostics.engineActivity
        playbackDiagnostics = result
        publish(.diagnostics(result))
    }

    private func diagnosticFallbackReasons(_ result: MPVPlaybackDiagnostics) -> [String] {
        var reasons = [result.decoder.fallbackReason, result.deinterlace.reason, liveConfigurationFailure]
            .compactMap(\.self)
        if case let .nativeOutputUnavailable(reason) = presentationFallbackReason {
            reasons.append(reason)
        }
        return reasons
    }

    static func nativeOutputRejectionReason(_ log: MPVLogMessage) -> String? {
        let reason = MPVNativeDiagnosticParser.payload(
            log, sentinel: "MPVUI_NATIVE_DOLBY_VISION_UNSUPPORTED:", allowsDecoder: true
        ) ?? MPVNativeDiagnosticParser.payload(log, sentinel: "MPVUI_NATIVE_VIDEO_UNSUPPORTED:")
        return reason.flatMap { $0.isEmpty ? nil : $0 }
    }

    func publishRenderSurfaceDiagnostic(_ message: String) {
        switch configuration.logLevel {
        case .verbose, .debug, .trace:
            publish(
                .log(
                    MPVLogMessage(
                        prefix: "mpvui/render-surface",
                        level: .debug,
                        message: message
                    )
                )
            )
        case .none, .fatal, .error, .warning, .info, .status:
            break
        }
    }
}
