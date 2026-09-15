import Dispatch
import Foundation

// Loads sources and applies playback controls, including deferred seeks.
extension MPVEngine {
    func load(
        _ url: URL,
        autoPlay: Bool?,
        startTime: Duration?,
        generation: UInt64
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let restartsRejectedNativeOutput = self.didRequestNativeOutputFallback && self.handle == nil
            self.cancelSubtitleQueries()
            self.didRequestNativeOutputFallback = false
            self.currentGeneration = generation
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
            self.shouldAutoPlay = autoPlay ?? self.configuration.autoPlay
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
            self.desiredProperties.removeValue(forKey: "audio-delay")
            self.desiredProperties.removeValue(forKey: "sub-delay")
            self.desiredProperties.removeValue(forKey: "secondary-sub-delay")
            self.publishState(.loading)
            self.startSecurityScopedAccessIfNeeded(for: url)
            if restartsRejectedNativeOutput {
                // A new typed load can supersede a fallback before the UI
                // receives it. Reuse the retained native target for that new
                // source; its older fallback emission is generation-filtered.
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

    func togglePlayback() {
        queue.async { [weak self] in
            guard let self else { return }
            self.setPlayingImmediately(self.isPaused || self.didReachEnd || !self.isFileLoaded)
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
                "pause", to: Self.pauseValue(playing: self.shouldAutoPlay, displaySwitching: switching)
            )
            if status < 0 {
                self.publishCommandError(status, context: "Suspend playback for display switch")
            }
        }
    }

    func stop(generation: UInt64? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelSubtitleQueries()
            self.completePiPSeek(false)
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
        let target = time.clampPositiveOrZero
        queue.async { [weak self] in
            guard let self else { return }
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
            guard let self else { return }
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
                .loadFailed(code: status, message: mpvErrorMessage(status))
            )
            return
        }

        requestedPlaylistEntryID = result?.mapValue?["playlist_entry_id"]?.integerValue
        // START_FILE is delivered asynchronously. Mark the submitted load now
        // so another immediate surface rebuild preserves and resubmits it.
        isLoading = true
        needsSourceLoad = false
        _ = setPropertyImmediately(
            "pause", to: Self.pauseValue(playing: shouldAutoPlay, displaySwitching: isDisplaySwitchInProgress)
        )
        pendingStartTime = nil
    }

    private func setPlayingImmediately(_ playing: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        shouldAutoPlay = playing
        isPaused = !playing

        if playing, !isFileLoaded, !isLoading, let sourceURL {
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
            loadPendingSourceIfPossible()
            return
        }

        guard handle != nil else { return }
        let status = setPropertyImmediately(
            "pause", to: Self.pauseValue(playing: playing, displaySwitching: isDisplaySwitchInProgress)
        )
        publish(.paused(isPaused))
        refreshState()
        if status < 0 {
            publishCommandError(status, context: playing ? "Play" : "Pause")
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

    static func pauseValue(playing: Bool, displaySwitching: Bool) -> String {
        playing && !displaySwitching ? "no" : "yes"
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
}
