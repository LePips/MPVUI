import Foundation

/// A complete copied playback state. Its generation identifies the requested load.
public struct MPVSessionSnapshot: Equatable, Sendable {

    /// Identity of the source load that produced this state.
    public package(set) var generation: UInt64 = 0
    /// Current playback lifecycle.
    public package(set) var state: MPVPlaybackState = .idle
    /// Current position in the source timeline.
    public package(set) var position: Duration = .zero
    /// Duration, or zero when unknown.
    public package(set) var duration: Duration = .zero
    /// Whether seeking is available.
    public package(set) var isSeekable = false
    /// Whether playback is intended to remain paused, including while seeking or buffering.
    public package(set) var isPaused = true
    /// Whether playback has produced a frame for this load.
    public package(set) var hasPlaybackFrame = false
    /// The current chapter index, or `nil` when no chapter is active.
    public package(set) var currentChapterIndex: Int?
    /// The playback volume in mpv's `0...100` range.
    public package(set) var volume = 100.0
    /// Whether audio is muted.
    public package(set) var isMuted = false
    /// Playback speed multiplier.
    public package(set) var playbackRate = 1.0
    /// Source, track, chapter, and signal metadata.
    public package(set) var mediaInformation: MPVMediaInformation = .empty
    /// Demuxer cache and buffering state.
    public package(set) var buffer: MPVBufferStatus = .empty
    /// Copied decoder and renderer diagnostics.
    public package(set) var diagnostics = MPVPlaybackDiagnostics()
    /// Whether detailed diagnostics sampling is enabled.
    public package(set) var isDiagnosticsEnabled = false
    /// Configured color conversion and its evidence.
    public package(set) var color: MPVRenderColorStatus = .unknown
    /// Source Dolby Vision metadata and native validation evidence.
    public package(set) var dolbyVision: MPVDolbyVisionStatus = .unknown
    /// Complete semantic subtitle presentation, including clears.
    public package(set) var subtitles = TextSubtitleSnapshot()
    /// Whether text subtitle interception is enabled.
    public package(set) var interceptsTextSubtitles = false
    /// Most recent command or playback failure.
    public package(set) var error: MPVPlayerError?
    /// The native renderer reported for the current source, or `nil` before initialization.
    public package(set) var nativeVideoOutput: String?
    /// Whether the session has permanently closed.
    public package(set) var isClosed = false

    package var requestedVideoFeatures: Set<MPVVideoFeature>?

    /// The composition capabilities of the current renderer, independent of system picture-in-picture readiness.
    ///
    /// - Complexity: O(n), where n is the number of reported tracks.
    public var videoFeatureCapabilities: MPVVideoFeatureCapabilities {
        .init(
            backend: mediaInformation.hdr.presentation.backend,
            dolbyVision: dolbyVision,
            hasVideo: mediaInformation.tracks.contains { $0.type == .video },
            pictureInPictureRequiresNativeOutput: false,
            supportsPictureInPicture: true
        )
    }

    /// The current source's accumulated feature request, when one has been made.
    ///
    /// - Complexity: O(n), where n is the number of reported tracks.
    public var videoFeatureRequestResult: MPVVideoFeatureRequestResult? {
        requestedVideoFeatures.map { videoFeatureCapabilities.requestResult(for: $0) }
    }

    /// Whether this load has produced a frame with known video dimensions.
    public var hasVideoFrame: Bool {
        hasPlaybackFrame && mediaInformation.dimensions != nil
    }

    /// Creates the idle state of an uninitialized session.
    public init() {}

    package static func loading(
        source: URL,
        configuration: MPVSessionConfiguration,
        generation: UInt64,
        automaticallyPlays: Bool?,
        startTime: Duration?
    ) -> Self {
        var snapshot = Self()
        snapshot.generation = generation
        snapshot.state = .loading
        snapshot.isPaused = !(automaticallyPlays ?? configuration.automaticallyPlays)
        snapshot.position = (startTime ?? configuration.startTime ?? .zero).clampPositiveOrZero
        snapshot.mediaInformation = .init(sourceURL: source)
        snapshot.volume = configuration.volume
        snapshot.playbackRate = configuration.playbackRate
        snapshot.dolbyVision = .init(requestedPolicy: configuration.dolbyVisionPolicy)

        return snapshot
    }

    package mutating func apply(_ update: MPVEngineUpdate) {
        switch update {
        case let .state(value):
            state = value

            switch value {
            case .loading, .stopped, .idle, .failed:
                hasPlaybackFrame = false
                currentChapterIndex = nil

            default: break
            }

            if value == .stopped || value == .idle {
                nativeVideoOutput = nil
            }

            if let failure = value.error {
                error = failure
            }

        case let .paused(value): isPaused = value

        case let .timing(value, total, seekable):
            position = value
            duration = total
            isSeekable = seekable
            mediaInformation.duration = total > .zero ? total : nil

        case let .frameRate(value): mediaInformation.framesPerSecond = value

        case let .chapter(value): currentChapterIndex = value

        case let .videoFrame(value): hasPlaybackFrame = value

        case let .buffer(value): buffer = value

        case let .media(value):
            mediaInformation = value

            if let total = value.duration {
                duration = total
            }

        case let .diagnostics(value): diagnostics = value

        case let .dolbyVision(value): dolbyVision = value

        case let .color(value): color = value

        case let .audio(value, muted, rate):
            volume = value
            isMuted = muted
            playbackRate = rate

        case let .textSubtitles(value): subtitles = value

        case let .error(value, fatal):
            error = value

            if fatal {
                state = .failed(value)
                hasPlaybackFrame = false
                currentChapterIndex = nil
            }

        case .log: break
        }
    }
}

/// An ordered session update containing a complete playback state or a log message.
public enum MPVSessionEvent: Sendable {

    /// Complete state copied after an ordered native update.
    case snapshot(MPVSessionSnapshot)
    /// Diagnostic message copied before native event storage expires.
    case log(MPVLogMessage)
}

package extension MPVSession {

    func record(_ update: MPVEngineUpdate) {
        latestSnapshot.generation = currentGeneration
        latestSnapshot.isDiagnosticsEnabled = isDiagnosticsEnabled
        latestSnapshot.interceptsTextSubtitles = isTextSubtitleInterceptionEnabled
        latestSnapshot.isClosed = isClosed
        latestSnapshot.apply(update)

        let event: MPVSessionEvent = if case let .log(log) = update {
            .log(log)
        } else {
            .snapshot(latestSnapshot)
        }

        for observer in observers.values {
            observer.yield(event)
        }

        for observer in nativeObservers.values {
            observer(event)
        }
    }
}
