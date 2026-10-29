import CMPV
import Dispatch
import Foundation

// Loads sources and applies playback controls, including deferred seeks.
package extension MPVSession {

    var requestedVideoSelection: String {
        desiredProperties["vid"]
            ?? configuration.additionalOptions["vid"]
            ?? configuration.additionalOptions["video"]
            ?? "auto"
    }

    static func pauseValue(playing: Bool, displaySwitching: Bool) -> String {
        playing && !displaySwitching ? "no" : "yes"
    }

    /// Track discovery is authoritative only at on_preloaded. An empty track
    /// list before that point does not establish that a source is audio-only.
    static func requiresVideoSurface(tracks: MPVNodeValue?, selection: String) -> Bool {
        guard selection != "no", selection != "-2" else { return false }

        return (tracks?.arrayValue ?? []).contains { node in
            guard let track = node.mapValue, track["type"]?.stringValue == "video" else { return false }

            if let id = Int64(selection), id >= 0 {
                return track["id"]?.integerValue == id
            }

            // Embedded cover art must not prevent an audio file from playing.
            return track["albumart"]?.boolValue != true
        }
    }

    func load(
        _ url: URL,
        playAutomatically: Bool?,
        startTime: Duration?,
        generation: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }

            self.cancelSubtitleQueries()

            if self.usesAndroidOutput {
                self.didFallbackFromAndroidNative = false
                self.androidNativeFallbackReason = nil
                self.desiredProperties.removeValue(forKey: "hwdec")

                let display = self.renderTarget?.displayCapabilities ?? .unknown
                let output = MPVAndroidOutputPolicy.output(self.configuration, display: display)

                if output != self.videoOutput {
                    self.destroyHandle(preservePlayback: false)
                    self.videoOutput = output
                }
            }

            self.isStoppedForResourceRelease = false
            self.resetMediaObservations()
            self.didRejectNativeOutput = false
            self.currentGeneration = generation

            let previousSnapshot = self.latestSnapshot

            self.latestSnapshot = .loading(
                source: url,
                configuration: self.configuration,
                generation: generation,
                automaticallyPlays: playAutomatically,
                startTime: startTime
            )

            self.latestSnapshot.volume = previousSnapshot.volume
            self.latestSnapshot.isMuted = previousSnapshot.isMuted
            self.latestSnapshot.playbackRate = previousSnapshot.playbackRate
            self.playbackDiagnostics = MPVPlaybackDiagnostics()
            self.requestedLoadUptime = DispatchTime.now().uptimeNanoseconds
            self.seekUptime = nil
            self.dolbyVisionResolver.reset()
            self.videoToolboxSessionUsesHardware = nil
            self.completePiPSeek(false)
            self.clearTextSubtitleSnapshot()
            self.stopSecurityScopedAccess()
            self.stopExternalSecurityScopedAccess()
            self.externalTracks.removeAll()
            self.pendingExternalTracks.removeAll()
            self.sourceURL = url

            self.pendingStartTime =
                startTime?.clampPositiveOrZero
                    ?? self.configuration.startTime

            self.pendingSeekAfterLoad = nil
            self.needsSourceLoad = true
            self.shouldAutoPlay = playAutomatically ?? self.configuration.automaticallyPlays
            self.isPaused = !self.shouldAutoPlay
            self.didReachEnd = false
            self.hasPlaybackStarted = false
            self.playbackRequestIsActive = true
            self.fatalPlaybackError = nil
            self.isLoading = true
            self.isFileLoaded = false
            self.lastPosition = self.pendingStartTime?.clampPositiveOrZero ?? .zero
            self.lastDuration = .zero
            self.lastSeekable = false
            self.desiredProperties.removeValue(forKey: "vid")
            self.desiredProperties.removeValue(forKey: "aid")
            self.desiredProperties.removeValue(forKey: "sid")
            self.desiredProperties.removeValue(forKey: "secondary-sid")

            // Clear per-item timing on the retained client as well as in its
            // recreation state. The configured VO stays attached across loads.
            for property in ["audio-delay", "sub-delay", "secondary-sub-delay"] {
                if self.desiredProperties.removeValue(forKey: property) != nil, self.handle != nil {
                    let value = self.configuration.additionalOptions[property] ?? "0"
                    let status = self.setPropertyImmediately(property, to: value)

                    if status < 0 {
                        self.publishCommandError(status, context: "Reset \(property)")
                    }
                }
            }

            self.publishState(.loading)
            self.startSecurityScopedAccessIfNeeded(for: url)

            if self.handle == nil {
                // Discover tracks before deciding whether playback needs a view.
                self.createHandle()
            } else {
                self.loadPendingSourceIfPossible()
            }
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

    /// Waits for mpv to pause before another player takes over audio playback.
    func pauseAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.setPlayingImmediately(false)
                continuation.resume()
            }
        }
    }

    /// Discards events from the previous session, then restores the local position and pause state.
    func resumeAfterHandoff(at position: Duration, paused: Bool, generation: UInt64) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }

            self.drainEvents()
            self.currentGeneration = generation

            if self.handle != nil, self.isFileLoaded {
                let result = self.runCommand(["seek", Self.format(position), "absolute+exact"])

                if result < 0 {
                    self.publishCommandError(result, context: "Restore playback after external playback")
                }
            } else {
                self.pendingStartTime = position
            }

            self.lastPosition = position
            self.setPlayingImmediately(!paused)
            self.publishTiming()
        }
    }

    func togglePlayback() {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }

            self.setPlayingImmediately(self.isPaused || self.didReachEnd || (!self.isFileLoaded && !self.isLoading))
        }
    }

    /// HDMI mode changes temporarily suspend the media clock. Keep this
    /// mechanical pause separate from the user's play/pause intention.
    func setDisplaySwitchInProgress(_ switching: Bool) {
        queue.async { [weak self] in
            guard let self, self.isDisplaySwitchInProgress != switching else { return }

            self.isDisplaySwitchInProgress = switching
            guard self.handle != nil else { return }

            let status = self.setPropertyImmediately(
                "pause",
                to: Self.pauseValue(playing: self.shouldAutoPlay, displaySwitching: switching)
            )

            if status < 0 {
                self.publishCommandError(status, context: "Suspend playback for display switch")
            }
        }
    }

    func stop(generation: UInt64? = nil) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }

            self.latestSnapshot.requestedVideoFeatures = nil
            self.cancelSubtitleQueries()
            self.completePiPSeek(false)

            // Snapshot before stop unloads the file and track selections.
            self.snapshotRuntimeProperties()

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
            self.isStoppedForResourceRelease = true
            self.requestedPlaylistEntryID = nil
            self.activePlaylistEntryID = nil
            self.isLoading = false
            self.isFileLoaded = false
            self.isSeeking = false
            self.isPausedForCache = false
            self.isIdle = true
            self.isPaused = true
            self.didReachEnd = false
            self.hasPlaybackStarted = false

            // Avoid destroyHandle's active-playback position snapshot: stop
            // means replay from zero, while preserving the source and settings.
            self.destroyHandle(preservePlayback: true)
            self.pendingStartTime = nil
            self.pendingSeekAfterLoad = nil
            self.lastPosition = .zero
            self.stopSecurityScopedAccess()
            self.stopExternalSecurityScopedAccess()
            self.publish(.paused(true))
            self.publish(.buffer(.empty))
            self.publishTiming()
            self.publishState(.stopped)
        }
    }

    func seek(to time: Duration) {
        let target = time.clampPositiveOrZero

        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }

            self.completePiPSeek(false)

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
            guard let self, !self.isClosed else { return }

            self.completePiPSeek(false)

            if self.handle == nil || !self.isFileLoaded {
                let pendingPosition =
                    self.pendingSeekAfterLoad
                        ?? self.pendingStartTime
                        ?? self.lastPosition

                let unclampedTarget = (pendingPosition + offset).clampPositiveOrZero

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
        setProperty("volume", to: Self.format(clamped(volume, to: 0 ... 100)))
    }

    func setMuted(_ muted: Bool) {
        setProperty("mute", to: muted ? "yes" : "no")
    }

    func toggleMute() {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }

            let muted =
                self.getFlag("mute")
                ?? (self.desiredProperties["mute"] == "yes")
            self.setPropertyImmediatelyOrDefer("mute", to: muted ? "no" : "yes")
        }
    }

    func setPlaybackRate(_ rate: Double) {
        guard rate > 0 else { return }

        setProperty("speed", to: Self.format(clamped(rate, to: 0.01 ... 100)))
    }

    func loadPendingSourceIfPossible() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard needsSourceLoad, handle != nil, let sourceURL else { return }

        var arguments = ["loadfile", platform.mediaPath(sourceURL), "replace"]

        if let start = pendingStartTime, start > .zero {
            // mpv expects the playlist index before per-file options.
            // -1 keeps replacement semantics while allowing the start option.
            arguments.append("-1")
            arguments.append("start=\(Self.format(start))")
        }

        // Apply the transport state before mpv can start the new file, including
        // replacements on a client that was previously playing.
        let pauseStatus = setPropertyImmediately(
            "pause",
            to: Self.pauseValue(playing: shouldAutoPlay, displaySwitching: isDisplaySwitchInProgress)
        )

        guard pauseStatus >= 0 else {
            isLoading = false
            needsSourceLoad = false
            playbackRequestIsActive = false

            publishFatalError(
                .loadFailed(code: pauseStatus, message: mpvErrorMessage(pauseStatus))
            )

            return
        }

        requestedPlaylistEntryID = nil

        let (status, result) = runCommandReturningValue(arguments)

        guard status >= 0 else {
            isLoading = false
            needsSourceLoad = false
            playbackRequestIsActive = false

            publishFatalError(
                .loadFailed(code: status, message: mpvErrorMessage(status))
            )

            return
        }

        requestedPlaylistEntryID = result?.mapValue?["playlist_entry_id"]?.integerValue

        // The replacement command aborts the old item before its held hook is
        // released, so it cannot briefly start audio during source changes.
        releasePendingPreload()

        // START_FILE is delivered asynchronously. Mark the submitted load now
        // so another immediate surface rebuild preserves and resubmits it.
        isLoading = true
        needsSourceLoad = false
        pendingStartTime = nil
    }

    func continuePreloadIfPossible() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard pendingPreloadHookID != nil, handle != nil else { return }

        let selection = requestedVideoSelection
        guard renderTarget != nil || !Self.requiresVideoSurface(tracks: getNode("track-list"), selection: selection) else { return }

        // A seek received during discovery can become the initial position,
        // without starting and then resetting the audio/video clocks.
        if let position = pendingSeekAfterLoad {
            let status = setPropertyImmediately("file-local-options/start", to: Self.format(position))

            if status >= 0 {
                pendingSeekAfterLoad = nil
            } else {
                publishCommandError(status, context: "Set startup position")
            }
        }

        // Apply the current item's selection before mpv creates either decoder.
        // Without a surface, video stays disabled even for embedded cover art.
        let status = setPropertyImmediately("vid", to: selection)

        guard status >= 0 else {
            _ = runCommand(["stop"])
            releasePendingPreload()
            isLoading = false
            playbackRequestIsActive = false
            publishFatalError(.loadFailed(code: status, message: mpvErrorMessage(status)))

            return
        }

        releasePendingPreload()
    }

    func releasePendingPreload() {
        guard let hook = pendingPreloadHookID, let handle else { return }

        pendingPreloadHookID = nil
        continuePreload(hook, on: handle)
    }

    func continuePreload(_ hook: UInt64, on handle: OpaquePointer) {
        let status = mpv_hook_continue(handle, hook)

        if status < 0 {
            publishCommandError(status, context: "Continue media loading")
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

    func startSecurityScopedAccessIfNeeded(for url: URL) {
        guard securityScopedURL == nil else { return }
        guard platform.beginSourceAccess(url) else { return }

        securityScopedURL = url
    }

    func stopSecurityScopedAccess() {
        if let securityScopedURL {
            platform.endSourceAccess(securityScopedURL)
        }

        securityScopedURL = nil
    }

    private func setPlayingImmediately(_ playing: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }

        shouldAutoPlay = playing
        isPaused = !playing

        if playing, !isFileLoaded, !isLoading, let sourceURL {
            isStoppedForResourceRelease = false

            let restartPosition = pendingStartTime?.clampPositiveOrZero ?? .zero
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

            if handle == nil {
                createHandle()
            } else {
                loadPendingSourceIfPossible()
            }

            return
        }

        publish(.paused(isPaused))
        guard handle != nil else { return }

        let status = setPropertyImmediately(
            "pause",
            to: Self.pauseValue(playing: playing, displaySwitching: isDisplaySwitchInProgress)
        )

        publish(.paused(isPaused))
        refreshState()

        if status < 0 {
            publishCommandError(status, context: playing ? "Play" : "Pause")
        }
    }
}
