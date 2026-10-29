import Foundation
import Observation

/// Observable playback state and controls for an existing ``MPVSession``.
///
/// Unchanged fields do not invalidate their observers. Releasing the controller
/// stops observation without closing its session.
@MainActor
@Observable
public final class MPVSessionController {

    /// The single session shared with platform surfaces and services.
    public let session: MPVSession
    /// Normalized settings used to create the session.
    public let configuration: MPVSessionConfiguration
    /// Current playback lifecycle.
    public private(set) var state: MPVPlaybackState = .idle
    /// Current source position.
    public private(set) var position: Duration = .zero
    /// Source duration, or zero when unknown.
    public private(set) var duration: Duration = .zero
    /// Whether playback is intended to remain paused, including while seeking or buffering.
    public private(set) var isPaused = true
    /// Whether the current source supports seeking.
    public private(set) var isSeekable = false
    /// Whether the current source has produced a video frame.
    public private(set) var hasVideoFrame = false
    /// The playback volume in mpv's `0...100` range.
    public private(set) var volume = 100.0
    /// Whether audio output is muted.
    public private(set) var isMuted = false
    /// Current playback speed multiplier.
    public private(set) var playbackRate = 1.0
    /// Current source, track, chapter, and signal metadata.
    public private(set) var mediaInformation: MPVMediaInformation = .empty
    /// Current cache state.
    public private(set) var bufferStatus: MPVBufferStatus = .empty
    /// Latest copied decoder and rendering observations.
    public private(set) var playbackDiagnostics = MPVPlaybackDiagnostics()
    /// Latest configured color conversion evidence.
    public private(set) var renderColorStatus: MPVRenderColorStatus = .unknown
    /// Latest Dolby Vision validation and conversion evidence.
    public private(set) var dolbyVisionStatus: MPVDolbyVisionStatus = .unknown
    /// Latest semantic text subtitle presentation, including explicit clears.
    public private(set) var textSubtitles = TextSubtitleSnapshot()
    /// Latest command or playback failure.
    public private(set) var lastError: MPVPlayerError?
    /// Result of the shared session's accumulated renderer-feature requests.
    public private(set) var videoFeatureRequestResult: MPVVideoFeatureRequestResult?
    /// Current chapter index, when one is active.
    public private(set) var currentChapterIndex: Int?

    @ObservationIgnored
    private var delivery: Task<Void, Never>?
    @ObservationIgnored
    private var generation: UInt64 = 0

    /// Current resolved rendering backend.
    public var videoOutput: MPVVideoOutput {
        mediaInformation.hdr.presentation.backend
    }

    /// Renderer capabilities evaluated from the shared source and output evidence.
    ///
    /// - Complexity: O(n), where n is the number of reported tracks.
    public var videoFeatureCapabilities: MPVVideoFeatureCapabilities {
        MPVVideoFeatureCapabilities(
            backend: videoOutput,
            dolbyVision: dolbyVisionStatus,
            hasVideo: mediaInformation.tracks.contains { $0.type == .video },
            pictureInPictureRequiresNativeOutput: false,
            supportsPictureInPicture: true
        )
    }

    /// Creates a controller that observes an existing session.
    public init(session: MPVSession) {
        self.session = session
        configuration = session.configuration
        apply(session.snapshot)

        let events = session.makeEventStream()

        delivery = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }

                if case let .snapshot(snapshot) = event {
                    self?.apply(snapshot)
                }
            }
        }
    }

    deinit { delivery?.cancel() }

    /// Submits a typed command and reports submission failures through ``lastError``.
    public func send(_ command: MPVSessionCommand) {
        do { generation = try session.send(command).generation }
        catch { lastError = error as? MPVPlayerError ?? .clientUnavailable }
    }

    /// Replaces the source with optional per-load playback settings.
    public func load(_ url: URL, playAutomatically: Bool? = nil, startTime: Duration? = nil) {
        send(.load(
            url,
            playAutomatically: playAutomatically,
            startTime: startTime
        ))
    }

    /// Resumes playback.
    public func play() {
        send(.play)
    }

    /// Pauses playback.
    public func pause() {
        send(.pause)
    }

    /// Toggles playback intention.
    public func togglePlayback() {
        send(.togglePlayback)
    }

    /// Stops and releases native playback resources.
    public func stop() {
        send(.stop)
    }

    /// Seeks to an absolute source timestamp.
    public func seek(to time: Duration) {
        send(.seek(to: time))
    }

    /// Seeks relative to the current or pending position.
    public func seek(by offset: Duration) {
        send(.seekByOffset(offset))
    }

    /// Selects a track from the current source.
    public func selectTrack(_ id: MPVMediaTrackIdentifier) {
        send(.selectTrack(id))
    }

    /// Selects or disables one subtitle role.
    public func selectSubtitle(_ id: MPVMediaTrackIdentifier?, for role: MPVSubtitleRole = .primary) {
        send(.selectSubtitle(id, for: role))
    }

    /// Enables or disables detailed diagnostics sampling.
    public func setDiagnosticsEnabled(_ enabled: Bool) {
        send(.setDiagnosticsEnabled(enabled))
    }

    /// Enables or disables text subtitle interception and delivery.
    public func setTextSubtitleInterceptionEnabled(_ enabled: Bool) {
        send(.setTextSubtitleInterceptionEnabled(enabled))
    }

    /// Clears a recoverable failure.
    public func clearLastError() {
        send(.clearLastError)
    }

    private func apply(_ value: MPVSessionSnapshot) {
        guard value.generation >= generation else { return }

        generation = value.generation

        if state != value.state {
            state = value.state
        }

        if position != value.position {
            position = value.position
        }

        if duration != value.duration {
            duration = value.duration
        }

        if isPaused != value.isPaused {
            isPaused = value.isPaused
        }

        if isSeekable != value.isSeekable {
            isSeekable = value.isSeekable
        }

        if hasVideoFrame != value.hasVideoFrame {
            hasVideoFrame = value.hasVideoFrame
        }

        if volume != value.volume {
            volume = value.volume
        }

        if isMuted != value.isMuted {
            isMuted = value.isMuted
        }

        if playbackRate != value.playbackRate {
            playbackRate = value.playbackRate
        }

        if mediaInformation != value.mediaInformation {
            mediaInformation = value.mediaInformation
        }

        if bufferStatus != value.buffer {
            bufferStatus = value.buffer
        }

        if playbackDiagnostics != value.diagnostics {
            playbackDiagnostics = value.diagnostics
        }

        if renderColorStatus != value.color {
            renderColorStatus = value.color
        }

        if dolbyVisionStatus != value.dolbyVision {
            dolbyVisionStatus = value.dolbyVision
        }

        if textSubtitles != value.subtitles {
            textSubtitles = value.subtitles
        }

        if lastError != value.error {
            lastError = value.error
        }

        if videoFeatureRequestResult != value.videoFeatureRequestResult {
            videoFeatureRequestResult = value.videoFeatureRequestResult
        }

        if currentChapterIndex != value.currentChapterIndex {
            currentChapterIndex = value.currentChapterIndex
        }
    }
}
