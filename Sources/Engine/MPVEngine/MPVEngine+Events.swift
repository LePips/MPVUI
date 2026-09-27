import Dispatch
import Foundation
import Libmpv

// Observes properties and drains libmpv events on the engine queue.
extension MPVEngine {
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
            "video-dec-params",
            "video-target-params",
            "audio-params",
            "video-codec",
            "video-format",
            "audio-codec-name",
            "hwdec-current",
            "file-format",
            "file-size",
            "estimated-vf-fps",
            "container-fps",
            "volume",
            "mute",
            "speed",
        ]

        for (index, property) in properties.enumerated() {
            let format: mpv_format = switch property {
            case "hwdec-current":
                MPV_FORMAT_STRING
            case "time-pos", "duration", "estimated-vf-fps", "container-fps":
                // Scalar observations suppress notifications for unchanged
                // values. Position events also carry the value into Swift.
                MPV_FORMAT_DOUBLE
            case "video-params", "video-dec-params", "video-out-params", "video-target-params":
                // mpv invalidates these maps on every playback tick. Typed
                // observations compare every field and suppress unchanged
                // values, avoiding repeated full media-information snapshots
                // while retaining color metadata and availability changes.
                MPV_FORMAT_NODE
            default:
                MPV_FORMAT_NONE
            }
            let status = mpv_observe_property(
                handle,
                UInt64(index + 1),
                property,
                format
            )
            if status < 0 {
                publishCommandError(status, context: "Observe \(property)")
            }
        }

        if isTextSubtitleInterceptionEnabled {
            observeTextSubtitleSnapshot()
        }
    }

    func scheduleEventDrain() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lifecycleDiagnostics.engineActivity.nativeWakeups &+= 1
            self.drainEvents()
        }
    }

    func drainEvents() {
        dispatchPrecondition(condition: .onQueue(queue))
        lifecycleDiagnostics.engineActivity.eventDrainPasses &+= 1

        while let handle {
            guard let eventPointer = mpv_wait_event(handle, 0) else { return }
            let event = eventPointer.pointee
            if event.event_id == MPV_EVENT_NONE {
                return
            }
            handleEvent(event)
        }
    }

    // Consume one borrowed native event on the engine queue. Keeping this
    // boundary separate from polling also lets tests deliver rare/stale events.
    func handleEvent(_ event: mpv_event) {
        dispatchPrecondition(condition: .onQueue(queue))
        if event.event_id != MPV_EVENT_NONE {
            lifecycleDiagnostics.engineActivity.nativeEvents &+= 1
        }
        switch event.event_id {
        case MPV_EVENT_COMMAND_REPLY:
            guard let query = subtitleQueries.removeValue(forKey: event.reply_userdata) else { return }
            if query.cancellation.isCancelled {
                query.continuation.resume(throwing: CancellationError())
            } else if event.error < 0 {
                query.continuation.resume(throwing: subtitleQueryError(event.error))
            } else if let data = event.data,
                      let snapshots = MPVTextSubtitleTimeline.snapshots(from: MPVNodeValue(
                          copying: data.assumingMemoryBound(to: mpv_event_command.self).pointee.result
                      ))
            {
                query.continuation.resume(returning: snapshots)
            } else {
                query.continuation.resume(throwing: subtitleQueryError(MPV_ERROR_GENERIC.rawValue))
            }

        case MPV_EVENT_START_FILE:
            lifecycleDiagnostics.startFileEvents &+= 1
            guard playbackRequestIsActive else { return }
            guard let data = event.data else { return }
            let startEvent = data.assumingMemoryBound(to: mpv_event_start_file.self).pointee
            let entryID = startEvent.playlist_entry_id
            if let requestedPlaylistEntryID, entryID != requestedPlaylistEntryID {
                return
            }
            cancelSubtitleQueries()
            resetMediaObservations()
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
            clearTextSubtitleSnapshot()
            pendingPiPSeek?.sawSeek = true
            seekUptime = DispatchTime.now().uptimeNanoseconds
            isSeeking = true
            publishState(.seeking)

        case MPV_EVENT_PLAYBACK_RESTART:
            guard isRequestedPlaylistEntryActive else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if let requestedLoadUptime {
                playbackDiagnostics.startLatencySeconds = Double(now - requestedLoadUptime) / 1_000_000_000
                self.requestedLoadUptime = nil
            }
            if let seekUptime {
                playbackDiagnostics.seekLatencySeconds = Double(now - seekUptime) / 1_000_000_000
                self.seekUptime = nil
            }
            isLoading = false
            isSeeking = false
            isIdle = false
            hasPlaybackStarted = true
            refreshPlaybackDiagnostics()
            refreshTiming()
            refreshBuffer()
            refreshTextSubtitleSnapshot()
            refreshState()
            // FILE_LOADED can publish .paused before a frame exists. A restart
            // also occurs for paused playback after its first frame is ready.
            performPendingRendererCommands()

            if let request = pendingPiPSeek, request.sawSeek,
               abs((lastPosition - request.target).seconds) < 1
            {
                completePiPSeek(true)
            }

        case MPV_EVENT_VIDEO_RECONFIG, MPV_EVENT_AUDIO_RECONFIG:
            guard isRequestedPlaylistEntryActive else { return }
            refreshMediaInformation()

        case MPV_EVENT_PROPERTY_CHANGE:
            guard isRequestedPlaylistEntryActive else { return }
            guard let data = event.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let name = property.name else { return }
            let propertyName = String(cString: name)
            lifecycleDiagnostics.engineActivity.propertyChangeEvents[propertyName, default: 0] &+= 1
            // Target parameters can contain an unknown pixel aspect ratio
            // represented as NaN. Native node equality considers NaN unequal
            // to itself, so compare the target signal we actually publish.
            let needsValue = propertyName == "time-pos" || propertyName == "sub-text-snapshot"
                || propertyName == "video-target-params" || propertyName == "hwdec-current"
            let copiedNode = needsValue ? MPVNodeValue(copying: property) : nil
            handlePropertyChange(propertyName, copiedNode: copiedNode)

        case MPV_EVENT_END_FILE:
            handleEndFile(event)

        case MPV_EVENT_LOG_MESSAGE:
            handleLogMessage(event)

        case MPV_EVENT_QUEUE_OVERFLOW:
            cancelSubtitleQueries()
            publish(
                .error(
                    .eventQueueOverflow,
                    fatal: false
                )
            )
            if playbackRequestIsActive {
                refreshAll()
            }

        case MPV_EVENT_SHUTDOWN:
            cancelSubtitleQueries()
            completePiPSeek(false)
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
        return Self.nativeDiagnosticMatchesCurrentEntry(requested: requestedPlaylistEntryID, active: activePlaylistEntryID)
    }

    func resetMediaObservations() {
        videoToolboxSessionUsesHardware = nil
        lastContainerFramesPerSecond = nil
        lastVideoTargetObservation = nil
    }

    private func handlePropertyChange(_ name: String, copiedNode: MPVNodeValue? = nil) {
        switch name {
        case "pause":
            isPaused = isDisplaySwitchInProgress ? !shouldAutoPlay : (getFlag(name) ?? isPaused)
            publish(.paused(isPaused))
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

        case "time-pos":
            lastPosition = (copiedNode?.doubleValue.flatMap(Duration.init(mpvSeconds:)) ?? lastPosition)
                .clampPositiveOrZero
            publishTiming()

        case "seekable":
            refreshTiming()

        case "duration":
            refreshTiming()
            refreshMediaInformation()

        case "cache-buffering-state", "demuxer-cache-duration", "demuxer-cache-state":
            refreshBuffer()

        case "volume", "mute", "speed":
            refreshAudioState()

        case "estimated-vf-fps":
            // The media snapshot prefers container FPS. An estimator update
            // cannot change it while that authoritative value is available;
            // playback diagnostics still sample the estimator independently.
            if lastContainerFramesPerSecond == nil {
                refreshMediaInformation()
            }

        case "video-target-params":
            let observation = copiedNode.map {
                VideoTargetObservation.available(MPVVideoSignalParser.parse($0))
            } ?? .unavailable
            guard observation != lastVideoTargetObservation else { return }
            lastVideoTargetObservation = observation
            refreshMediaInformation()

        case "hwdec-current":
            let selectedDecoder = copiedNode?.stringValue
            if selectedDecoder != playbackDiagnostics.decoder.selectedDecoder {
                // A previous decoder session cannot establish a new selection.
                // A log delivered first already published this same selection.
                videoToolboxSessionUsesHardware = nil
            }
            refreshDecoderDiagnostics(hardwareDecoder: selectedDecoder)
            refreshMediaInformation()

        case "track-list", "current-tracks/audio/id", "current-tracks/video/id",
             "current-tracks/sub/id", "media-title", "metadata", "chapter-list",
             "video-out-params", "video-params", "video-dec-params",
             "audio-params", "video-codec", "video-format",
             "audio-codec-name", "file-format", "file-size",
             "container-fps":
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

    private func handleEndFile(_ event: mpv_event) {
        guard playbackRequestIsActive else { return }
        guard let data = event.data else {
            completePiPSeek(false)
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
            completePiPSeek(false)
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

        pendingRendererCommands.removeAll()

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
            // An exact seek to the endpoint can retire the VO without a
            // playback-restart event. The terminal timeline is authoritative.
            let reachedRequestedEnd = pendingPiPSeek.map {
                lastDuration > .zero && $0.target >= lastDuration - .milliseconds(1)
            } ?? false
            completePiPSeek(reachedRequestedEnd)

        case MPV_END_FILE_REASON_STOP, MPV_END_FILE_REASON_QUIT:
            completePiPSeek(false)
            publishState(.stopped)

        case MPV_END_FILE_REASON_ERROR:
            completePiPSeek(false)
            let code = endEvent.error
            publishFatalError(
                .playbackFailed(code: code, message: mpvErrorMessage(code))
            )

        default:
            break
        }
    }

    static func nativeDiagnosticMatchesCurrentEntry(requested: Int64?, active: Int64?) -> Bool {
        requested == nil || active == requested
    }
}
