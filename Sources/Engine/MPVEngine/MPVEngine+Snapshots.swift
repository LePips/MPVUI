import Foundation

// Builds playback and media snapshots and publishes generation-tagged updates.
extension MPVEngine {
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
        publish(.paused(isPaused))
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
        lastPosition = (getDouble("time-pos").flatMap(Duration.init(mpvSeconds:)) ?? lastPosition).clampPositiveOrZero
        lastDuration = (getDouble("duration").flatMap(Duration.init(mpvSeconds:)) ?? lastDuration).clampPositiveOrZero
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

    func refreshMediaInformation() {
        let tracks = Self.parseTracks(getNode("track-list"))
        let chapters = Self.parseChapters(getNode("chapter-list"))
        let metadata = Self.parseMetadata(getNode("metadata"))

        // Never merge stages: a filter can tone-map PQ to SDR, while native
        // display conversion and physical presentation may remain unobservable.
        let track = getNode("current-tracks/video")
        let source = MPVVideoSignalParser.parse(getNode("video-dec-params"), track: track)
        let videoParameters = getNode("video-params")
        let videoOutputParameters = getNode("video-out-params")
        let decoded = MPVVideoSignalParser.parse(videoParameters)
        let videoOutputInput = MPVVideoSignalParser.parse(videoOutputParameters)
        let output = MPVVideoSignalParser.parse(getNode("video-target-params"))
        // Dimensions and rotation are part of these nodes. Reuse the same
        // snapshots instead of making another libmpv call for each field.
        let parameters = videoParameters?.mapValue
        let outputParameters = videoOutputParameters?.mapValue
        let width = parameters?["w"]?.integerValue ?? outputParameters?["w"]?.integerValue ?? 0
        let height = parameters?["h"]?.integerValue ?? outputParameters?["h"]?.integerValue ?? 0
        let display = renderTarget?.displayCapabilities ?? .unknown
        let configured: MPVPresentationStatus.DynamicRange = liveConfigurationFailure == nil
            ? renderTarget?.configuredDynamicRange ?? .unknown : .unknown
        let fallback = Self.resolvedPresentationFallback(
            backend: presentationFallbackReason,
            policy: renderTarget?.policyFallbackReason,
            liveFailure: liveConfigurationFailure
        )
            ?? Self.hdrFallbackReason(
                source: source,
                display: display,
                configuredDynamicRange: configured,
                requestedPolicy: configuration.hdrPolicy
            )
        let hdr = MPVHDRStatus(
            source: source,
            decoded: decoded,
            videoOutputInput: videoOutputInput,
            output: output,
            displayCapabilities: display,
            presentation: MPVPresentationStatus(
                requestedPolicy: configuration.hdrPolicy,
                backend: videoOutput,
                configuredDynamicRange: configured,
                actualDynamicRange: .unknown,
                fallbackReason: fallback
            )
        )

        let dimensions: MPVVideoDimensions? =
            width > 0 && height > 0
                ? MPVVideoDimensions(
                    width: Int(width),
                    height: Int(height),
                    displayWidth: (parameters?["dw"]?.integerValue
                        ?? outputParameters?["dw"]?.integerValue).map(Int.init),
                    displayHeight: (parameters?["dh"]?.integerValue
                        ?? outputParameters?["dh"]?.integerValue).map(Int.init)
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
                    videoCodec: getString("video-format"),
                    audioCodec: getString("audio-codec-name"),
                    hardwareDecoder: getString("hwdec-current"),
                    dimensions: dimensions,
                    framesPerSecond: getDouble("container-fps") ?? getDouble("estimated-vf-fps"),
                    rotation: Int(
                        parameters?["rotate"]?.integerValue
                            ?? outputParameters?["rotate"]?.integerValue
                            ?? 0
                    ),
                    metadata: metadata,
                    chapters: chapters,
                    tracks: tracks,
                    hdr: hdr
                )
            )
        )
        publish(.dolbyVision(dolbyVisionResolver.status(source: source, backend: videoOutput)))
        if let color = renderTarget?.colorConfiguration?.status {
            publish(.color(color))
        }
    }

    static func resolvedPresentationFallback(
        backend: MPVPresentationStatus.FallbackReason?,
        policy: MPVPresentationStatus.FallbackReason?,
        liveFailure: String?
    ) -> MPVPresentationStatus.FallbackReason? {
        if let liveFailure {
            return .liveConfigurationFailed(liveFailure)
        }
        // A missing optional native option must not hide a policy the operating
        // system cannot enforce. Backend replacement reasons preserve the original cause.
        if backend == .unsupportedSubtitleLuminance {
            return policy ?? backend
        }
        return backend ?? policy
    }

    static func hdrFallbackReason(
        source: MPVVideoSignal,
        display: MPVDisplayCapabilities,
        configuredDynamicRange: MPVPresentationStatus.DynamicRange,
        requestedPolicy: MPVPlayerConfiguration.HDRPolicy
    ) -> MPVPresentationStatus.FallbackReason? {
        guard requestedPolicy != .disabled,
              source.isHDR || requestedPolicy == .always || requestedPolicy == .constrained
        else { return nil }
        if display.hdrSupport == .unsupported {
            return .displayDoesNotSupportHDR
        }
        if let currentHeadroom = display.currentEDRHeadroom, currentHeadroom <= 1 {
            return .insufficientCurrentHeadroom
        }
        return nil
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

            let subtitleRole: MPVSubtitleRole? = switch track["main-selection"]?.integerValue {
            case 0: .primary
            case 1: .secondary
            default: nil
            }
            return MPVMediaTrack(
                id: Int(id),
                type: type,
                title: track["title"]?.stringValue,
                language: track["lang"]?.stringValue,
                codec: track["codec"]?.stringValue,
                isSelected: track["selected"]?.boolValue ?? false,
                subtitleRole: subtitleRole,
                isDefault: track["default"]?.boolValue ?? false,
                isForced: track["forced"]?.boolValue ?? false,
                isExternal: track["external"]?.boolValue ?? false
            )
        } ?? []
    }

    static func parseChapters(_ node: MPVNodeValue?) -> [MPVChapter] {
        guard let values = node?.arrayValue else { return [] }

        var chapters: [MPVChapter] = []
        chapters.reserveCapacity(values.count)
        var nextStart: Duration?
        // A reverse scan finds the next valid boundary once per chapter,
        // including when malformed entries must be skipped.
        for (index, value) in values.enumerated().reversed() {
            guard let chapter = value.mapValue else { continue }
            let start = chapter["time"]?.doubleValue.flatMap(Duration.init(mpvSeconds:))
            chapters.append(MPVChapter(
                id: index,
                title: chapter["title"]?.stringValue,
                startTime: start ?? .zero,
                endTime: nextStart
            ))
            if let start {
                nextStart = start
            }
        }
        chapters.reverse()
        return chapters
    }

    static func parseMetadata(_ node: MPVNodeValue?) -> [String: String] {
        guard let values = node?.mapValue else { return [:] }
        return values.reduce(into: [:]) { result, pair in
            if let string = pair.value.stringValue {
                result[pair.key] = string
            }
        }
    }

    func publish(_ update: MPVEngineUpdate) {
        updateContinuation.yield(
            MPVEngineEmission(
                generation: currentGeneration,
                update: update
            )
        )
    }

    private func publishGlobally(_ update: MPVEngineUpdate) {
        updateContinuation.yield(
            MPVEngineEmission(
                generation: nil,
                update: update
            )
        )
    }

    func publishFatalError(_ error: MPVPlayerError, globally: Bool = false) {
        completePiPSeek(false)
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
                .commandFailed(context: context, code: code, message: mpvErrorMessage(code)),
                fatal: false
            )
        )
    }
}
