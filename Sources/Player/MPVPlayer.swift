import Foundation
import Observation

/// A Swift-facing controller for one mpv playback session.
///
/// `MPVPlayer` owns transport and observable playback state. A rendering view
/// attaches its platform surface separately, keeping the public controller and
/// media models independent of each platform renderer.
@MainActor
@Observable
public final class MPVPlayer {
    /// The configuration used to create the underlying mpv client.
    public let configuration: MPVPlayerConfiguration

    /// The playback lifecycle state.
    public private(set) var state: MPVPlaybackState = .idle

    /// Current playback position.
    public private(set) var position: Duration = .zero

    /// Current media duration, or zero when it is unknown.
    public private(set) var duration: Duration = .zero

    /// Whether the current source supports seeking.
    public private(set) var isSeekable = false

    /// Current demuxer/network buffer state.
    public private(set) var bufferStatus: MPVBufferStatus = .empty

    /// Metadata, tracks, codecs, dimensions, and HDR information.
    public private(set) var mediaInformation: MPVMediaInformation = .empty

    /// Playback volume in mpv's `0...100` range.
    public private(set) var volume: Double

    /// Whether audio output is muted.
    public private(set) var isMuted = false

    /// Current playback-rate multiplier.
    public private(set) var playbackRate: Double

    /// The most recent playback error.
    public private(set) var lastError: MPVPlayerError?

    @ObservationIgnored
    public var logHandler: (@MainActor @Sendable (MPVLogMessage) -> Void)?

    @ObservationIgnored
    private var engine: MPVEngine?
    @ObservationIgnored
    private var activeRenderSurfaceToken: UUID?
    @ObservationIgnored
    private var playbackGeneration: UInt64 = 0

    @ObservationIgnored

    private var isTextSubtitleInterceptionEnabled = false
    private let textSubtitleSnapshots = TextSubtitleSnapshotBroadcaster()

    /// Creates an empty player with the supplied configuration.
    public init(configuration: MPVPlayerConfiguration = .init()) {
        self.configuration = configuration
        volume = configuration.volume
        playbackRate = configuration.playbackRate

        engine = MPVEngine(configuration: configuration) { [weak self] emission in
            self?.apply(emission)
        }
    }

    /// Creates a player and queues a media URL for loading when a render
    /// surface is attached.
    public convenience init(
        url: URL,
        configuration: MPVPlayerConfiguration = .init()
    ) {
        self.init(configuration: configuration)
        load(url)
    }

    deinit {
        textSubtitleSnapshots.terminate()
        engine?.shutdown()
    }

    /// Loads new media, replacing any current playlist entry.
    ///
    /// Loading can be requested before a view is attached. The URL is retained
    /// and opened as soon as the Metal render surface is ready. A negative
    /// per-load start time is clamped to zero.
    public func load(
        _ url: URL,
        autoPlay: Bool? = nil,
        startTime: Duration? = nil
    ) {
        let normalizedStartTime = startTime.map { max(.zero, $0) }
        let effectiveStartTime = normalizedStartTime ?? configuration.startTime ?? .zero
        playbackGeneration &+= 1
        if isTextSubtitleInterceptionEnabled {
            textSubtitleSnapshots.clear()
        }
        state = .loading
        lastError = nil
        position = effectiveStartTime
        duration = .zero
        isSeekable = false
        bufferStatus = .empty
        mediaInformation = MPVMediaInformation(sourceURL: url)
        engine?.load(
            url,
            autoPlay: autoPlay,
            startTime: normalizedStartTime,
            generation: playbackGeneration
        )
    }

    /// Starts or resumes playback.
    public func play() {
        engine?.play()
    }

    /// Pauses playback.
    public func pause() {
        engine?.pause()
    }

    /// Toggles between playing and paused.
    public func togglePlayback() {
        engine?.togglePlayback()
    }

    /// Stops the current playback item.
    public func stop() {
        playbackGeneration &+= 1
        if isTextSubtitleInterceptionEnabled {
            textSubtitleSnapshots.clear()
        }
        engine?.stop(generation: playbackGeneration)
    }

    /// Seeks to an absolute timeline position.
    public func seek(to time: Duration) {
        let target =
            duration > .zero
                ? clamp(time, to: .zero ... duration)
                : max(.zero, time)
        engine?.seek(to: target)
    }

    /// Seeks by a relative duration.
    public func seek(by offset: Duration) {
        engine?.seek(by: offset)
    }

    /// Advances one decoded frame and pauses playback.
    public func stepForward() {
        engine?.frameStep(backward: false)
    }

    /// Moves backward by one decoded frame and pauses playback.
    public func stepBackward() {
        engine?.frameStep(backward: true)
    }

    /// Sets playback volume in mpv's `0...100` range.
    public func setVolume(_ newVolume: Double) {
        guard !newVolume.isNaN else { return }
        let normalized = clamp(newVolume, to: 0 ... 100)
        volume = normalized
        engine?.setVolume(normalized)
    }

    /// Sets whether audio is muted.
    public func setMuted(_ muted: Bool) {
        isMuted = muted
        engine?.setMuted(muted)
    }

    /// Toggles audio muting.
    public func toggleMute() {
        isMuted.toggle()
        engine?.toggleMute()
    }

    /// Sets a positive playback-rate multiplier.
    public func setPlaybackRate(_ rate: Double) {
        guard rate.isFinite, rate > 0 else { return }
        let normalized = clamp(
            rate,
            to: MPVPlayerConfiguration
                .minimumPlaybackRate ... MPVPlayerConfiguration.maximumPlaybackRate
        )
        playbackRate = normalized
        engine?.setPlaybackRate(normalized)
    }

    /// Selects a video, audio, or subtitle track by its mpv identifier.
    public func selectTrack(_ track: MPVMediaTrack) {
        engine?.selectTrack(track)
    }

    /// Disables the selected track of the given type.
    public func disableTrack(_ type: MPVTrackType) {
        engine?.disableTrack(type)
    }

    /// Loads an external video, audio, or subtitle file.
    public func loadExternalTrack(
        _ url: URL,
        type: MPVTrackType,
        select: Bool = true
    ) {
        engine?.loadExternalTrack(url, type: type, select: select)
    }

    /// Sets audio delay. Negative values make audio play earlier.
    public func setAudioDelay(_ delay: Duration) {
        engine?.setAudioDelay(delay)
    }

    /// Sets subtitle delay. Negative values show subtitles earlier.
    public func setSubtitleDelay(_ delay: Duration) {
        engine?.setSubtitleDelay(delay)
    }

    /// Creates a stream of semantic text subtitles for custom presentation.
    ///
    /// The first call opts this player into text interception for its remaining
    /// lifetime. mpv stops drawing supported semantic text formats such as
    /// SubRip, WebVTT, TTML, and `mov_text`, while ASS/SSA and image subtitles
    /// continue through mpv's native renderer. Call this before loading media
    /// when even a transient natively rendered text cue would be undesirable.
    ///
    /// Every call returns an independent stream that immediately yields the
    /// latest complete snapshot (initially empty). Identical snapshots are
    /// deduplicated and each subscriber buffers only the newest pending value.
    /// Empty snapshots clear the client's subtitle presentation.
    public func textSubtitleStream() -> AsyncStream<TextSubtitleSnapshot> {
        if !isTextSubtitleInterceptionEnabled {
            isTextSubtitleInterceptionEnabled = true
            engine?.enableTextSubtitleInterception()
        }
        return textSubtitleSnapshots.subscribe()
    }

    /// Moves to the next chapter when one exists.
    public func nextChapter() {
        command("add", arguments: ["chapter", "1"])
    }

    /// Moves to the previous chapter when one exists.
    public func previousChapter() {
        command("add", arguments: ["chapter", "-1"])
    }

    /// Sets a lower-level mpv property not covered by the typed player API.
    ///
    /// The value is retained if no rendering surface is attached and restored
    /// if the renderer must be recreated. Prefer a typed player method when one
    /// is available so MPVUI can normalize the value and update observable state
    /// immediately. Properties owned by MPVUI's renderer or typed playback state
    /// are rejected and reported through ``lastError``.
    ///
    /// Set an mpv property.
    public func setProperty(_ name: String, to value: String) {
        engine?.performPropertySet(name, value: value)
    }

    /// Runs an mpv command
    public func command(_ name: String, arguments: [String] = []) {
        engine?.performCommand(name, arguments: arguments)
    }

    /// Clears the last non-fatal command error.
    public func clearLastError() {
        if case .failed = state {
            return
        }
        lastError = nil
    }

    /// All currently reported video tracks.
    public var videoTracks: [MPVMediaTrack] {
        mediaInformation.tracks.filter { $0.type == .video }
    }

    /// All currently reported audio tracks.
    public var audioTracks: [MPVMediaTrack] {
        mediaInformation.tracks.filter { $0.type == .audio }
    }

    /// All currently reported subtitle tracks.
    public var subtitleTracks: [MPVMediaTrack] {
        mediaInformation.tracks.filter { $0.type == .subtitle }
    }
}

// MARK: - Rendering bridge

extension MPVPlayer {
    var hasActiveRenderSurface: Bool {
        activeRenderSurfaceToken != nil
    }

    func activateRenderSurface(token: UUID) {
        guard activeRenderSurfaceToken != token else { return }

        // Ownership can move to a surface whose geometry is not attachable yet.
        // Retire the previous native target synchronously so neither that new
        // surface nor a subsequently restored one can host-write a layer that
        // still backs a live swapchain.
        engine?.detachCurrentRenderTargetSynchronously()
        activeRenderSurfaceToken = token
    }

    func isRenderSurfaceActive(token: UUID) -> Bool {
        activeRenderSurfaceToken == token
    }

    func attachRenderTarget(
        token: UUID,
        layerAddress: Int64,
        layerOwner: AnyObject,
        drawableWidth: Int,
        drawableHeight: Int,
        usesExtendedDynamicRange: Bool,
        displaySupportsExtendedDynamicRange: Bool,
        outputHeadroom: Double
    ) {
        guard activeRenderSurfaceToken == token else { return }
        engine?.attach(
            to: MPVRenderTarget(
                layerAddress: layerAddress,
                layerOwner: layerOwner,
                drawableWidth: drawableWidth,
                drawableHeight: drawableHeight,
                usesExtendedDynamicRange: usesExtendedDynamicRange,
                displaySupportsExtendedDynamicRange: displaySupportsExtendedDynamicRange,
                outputHeadroom: outputHeadroom
            )
        )
    }

    func renderOutputSize() async -> MPVRenderOutputSize? {
        await engine?.renderOutputSize()
    }

    func resizeRenderTargetAndWait(
        token: UUID,
        layerAddress: Int64,
        drawableWidth: Int,
        drawableHeight: Int,
        force: Bool = false
    ) async -> Bool {
        guard activeRenderSurfaceToken == token else { return false }
        return await engine?.resizeRenderTargetAndWait(
            width: drawableWidth,
            height: drawableHeight,
            forLayerAddress: layerAddress,
            force: force
        ) ?? false
    }

    func lifecycleDiagnostics() async -> MPVEngineLifecycleDiagnostics {
        await engine?.lifecycleSnapshot() ?? .init()
    }

    func emitRenderSurfaceDiagnostic(_ message: @autoclosure () -> String) {
        guard logHandler != nil else { return }
        switch configuration.logLevel {
        case .verbose, .debug, .trace:
            logHandler?(
                MPVLogMessage(
                    prefix: "mpvui/render-surface",
                    level: "debug",
                    message: message()
                )
            )
        case .none, .fatal, .error, .warning, .info, .status:
            break
        }
    }

    func detachRenderTarget(token: UUID, layerAddress: Int64?) {
        if activeRenderSurfaceToken == token {
            activeRenderSurfaceToken = nil
        }
        if let layerAddress {
            // The engine validates the address against its current target.
            // Detaching an inactive surface is still necessary when a newer,
            // zero-sized surface claimed ownership but never attached.
            engine?.detach(fromLayerAddress: layerAddress)
        }
    }

    func detachRenderTargetSynchronously(token: UUID, layerAddress: Int64) {
        guard activeRenderSurfaceToken == token else { return }
        engine?.detachSynchronously(fromLayerAddress: layerAddress)
    }
}

// MARK: - Engine updates

private extension MPVPlayer {
    func apply(_ emission: MPVEngineEmission) {
        guard emission.generation == nil || emission.generation == playbackGeneration else {
            return
        }

        let update = emission.update
        switch update {
        case let .state(newState):
            state = newState
            if case let .failed(error) = newState {
                lastError = error
            }

        case let .timing(newPosition, newDuration, seekable):
            position = newPosition
            duration = newDuration
            isSeekable = seekable

        case let .buffer(status):
            bufferStatus = status

        case let .media(information):
            mediaInformation = information
            if let mediaDuration = information.duration {
                duration = mediaDuration
            }

        case let .audio(newVolume, muted, rate):
            volume = newVolume
            isMuted = muted
            playbackRate = rate

        case let .textSubtitles(snapshot):
            guard isTextSubtitleInterceptionEnabled else { return }
            textSubtitleSnapshots.publish(snapshot)

        case let .error(error, fatal):
            lastError = error
            if fatal {
                state = .failed(error)
            }

        case let .log(log):
            logHandler?(
                MPVLogMessage(
                    prefix: log.prefix,
                    level: log.level,
                    message: log.message
                )
            )
        }
    }
}
