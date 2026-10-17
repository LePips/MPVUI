import AVFoundation
import Foundation
import MPVCore
import Observation

/// Playback control and observable state for one mpv session.
///
/// Keep the player alive across view updates and attach an ``MPVVideoPlayer``
/// for rendering. Configure and load media on the main actor:
///
/// ```swift
/// let player = MPVPlayer(configuration: .init(autoPlay: false))
/// player.load(URL(filePath: "/path/to/movie.mp4"), startTime: .seconds(30))
/// ```
@MainActor
@Observable
public final class MPVPlayer {

    /// Immutable settings used to create the underlying mpv client.
    /// Runtime controls update the player's state, leaving these defaults unchanged.
    public let configuration: MPVPlayerConfiguration

    /// The playback lifecycle state.
    public private(set) var state: MPVPlaybackState = .idle

    /// Current playback position.
    public private(set) var position: Duration = .zero

    /// Current media duration, or zero when unknown.
    public private(set) var duration: Duration = .zero

    /// Whether the current source supports seeking.
    public private(set) var isSeekable = false

    /// Playback intention, including while seeking or waiting for data.
    public private(set) var isPaused = true

    /// Current chapter index, or `nil` when no chapter is active.
    public private(set) var currentChapterIndex: Int?

    /// Whether detailed playback counters are sampled. Disabled by default.
    public private(set) var isDiagnosticsEnabled = false

    /// Current demuxer and network buffer state.
    public private(set) var bufferStatus: MPVBufferStatus = .empty

    /// Metadata, tracks, codecs, dimensions, and HDR information.
    public private(set) var mediaInformation: MPVMediaInformation = .empty

    /// Decoder and rendering counters reported by the active engine.
    public private(set) var playbackDiagnostics = MPVPlaybackDiagnostics()

    /// Configured color target and its evidence, separate from screen luminance.
    public private(set) var renderColorStatus: MPVRenderColorStatus = .unknown

    /// The current item's source profile, validated native output, and lossy conversion status.
    public private(set) var dolbyVisionStatus: MPVDolbyVisionStatus = .unknown

    /// The most recent feature request evaluated against the configured renderer.
    public private(set) var videoFeatureRequestResult: MPVVideoFeatureRequestResult?

    /// Playback volume in mpv's `0...100` range.
    public private(set) var volume: Double
    /// Whether audio output is muted.
    public private(set) var isMuted = false

    /// Current playback-rate multiplier.
    public private(set) var playbackRate: Double

    /// The most recent playback error.
    public private(set) var lastError: MPVPlayerError?

    /// Receives mpv log messages on the main actor at the configured log level.
    @ObservationIgnored
    public var logHandler: (@MainActor @Sendable (MPVLogMessage) -> Void)?

    /// Whether plain text subtitles are intercepted for app presentation.
    public private(set) var isTextSubtitleInterceptionEnabled = false
    private var hasPlaybackFrame = false

    @ObservationIgnored
    private var storedExternalPlayback: MPVExternalPlaybackController?

    @ObservationIgnored
    private var storedPictureInPicture: MPVPictureInPictureController?
    @ObservationIgnored
    private var storedSampleBufferDisplayLayer: AVSampleBufferDisplayLayer?
    @ObservationIgnored
    private var pictureInPictureSurfaceToken: UUID?
    @ObservationIgnored
    private var hasAttachedSampleBufferOutput = false
    @ObservationIgnored
    private var sampleBufferRenderTarget: MPVRenderTarget?
    @ObservationIgnored
    private weak var activePlatformSurface: MPVPlatformVideoPlayer?
    @ObservationIgnored
    private weak var renderingPlatformSurface: MPVPlatformVideoPlayer?

    @ObservationIgnored
    private var requestedVideoFeatures: Set<MPVVideoFeature> = []

    @ObservationIgnored
    private var engine: MPVSession?
    @ObservationIgnored
    private var activeRenderSurfaceToken: UUID?
    @ObservationIgnored
    private var playbackGeneration: UInt64 = 0

    private let textSubtitleSnapshots = TextSubtitleSnapshotBroadcaster()

    /// Whether the current item has produced a video frame.
    public var hasVideoFrame: Bool {
        hasPlaybackFrame && mediaInformation.dimensions != nil
    }

    /// The configured video output. It remains unchanged for this player's lifetime.
    public var videoOutput: MPVPlayerConfiguration.VideoOutput {
        configuration.videoOutput
    }

    /// AirPlay playback with on-device remuxing and conversion when needed.
    ///
    /// - Important: Experimental.
    public var externalPlayback: MPVExternalPlaybackController {
        if let storedExternalPlayback {
            return storedExternalPlayback
        }
        let controller = MPVExternalPlaybackController(player: self)
        storedExternalPlayback = controller
        return controller
    }

    /// System picture-in-picture controls for this playback session.
    public var pictureInPicture: MPVPictureInPictureController {
        if let storedPictureInPicture {
            return storedPictureInPicture
        }
        let controller = MPVPictureInPictureController(player: self)
        storedPictureInPicture = controller
        if let activePlatformSurface {
            controller.attach(to: activePlatformSurface)
        }
        return controller
    }

    /// Features supported by the current item and backend. Distinguishes inline
    /// SwiftUI content from graphics composited into native video samples.
    public var videoFeatureCapabilities: MPVVideoFeatureCapabilities {
        MPVVideoFeatureCapabilities(
            backend: videoOutput.coreValue,
            dolbyVision: dolbyVisionStatus,
            hasVideo: mediaInformation.videoCodec != nil || dolbyVisionStatus.sourceProfile != nil,
            pictureInPictureRequiresNativeOutput: Self.pictureInPictureRequiresNativeOutput,
            supportsPictureInPicture: Self.platformSupportsPictureInPicture
        )
    }

    /// All reported video tracks.
    public var videoTracks: [MPVMediaTrack] {
        mediaInformation.tracks.filter { $0.type == .video }
    }

    /// All reported audio tracks.
    public var audioTracks: [MPVMediaTrack] {
        mediaInformation.tracks.filter { $0.type == .audio }
    }

    /// All reported subtitle tracks.
    public var subtitleTracks: [MPVMediaTrack] {
        mediaInformation.tracks.filter { $0.type == .subtitle }
    }

    var isUsingExternalPlayback: Bool {
        storedExternalPlayback?.controlsPlayback == true
    }

    /// Creates an empty player with the supplied configuration.
    public init(configuration: MPVPlayerConfiguration = .init()) {
        self.configuration = configuration
        dolbyVisionStatus = MPVDolbyVisionStatus(requestedPolicy: configuration.dolbyVisionPolicy)
        volume = configuration.volume
        playbackRate = configuration.playbackRate

        engine = MPVSession(configuration: configuration) { [weak self] emission in
            self?.apply(emission)
        }
    }

    /// Creates a player and loads the URL. No video view is required.
    public convenience init(
        url: URL,
        configuration: MPVPlayerConfiguration = .init()
    ) {
        self.init(configuration: configuration)
        load(url)
    }

    isolated deinit {
        storedExternalPlayback?.invalidate(restore: false)
        storedPictureInPicture?.invalidate()
        textSubtitleSnapshots.terminate()
        engine?.shutdownSynchronously()
    }

    /// Loads new media. Audio plays without a video view.
    ///
    /// Omitted options use the configuration. Negative start times become zero.
    /// Media without audio waits for a video view.
    public func load(
        _ url: URL,
        autoPlay: Bool? = nil,
        startTime: Duration? = nil
    ) {
        storedExternalPlayback?.invalidate(restore: false)
        let normalizedStartTime = startTime?.clampPositiveOrZero
        isPaused = !(autoPlay ?? configuration.autoPlay)
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
        currentChapterIndex = nil
        hasPlaybackFrame = false
        bufferStatus = .empty
        mediaInformation = MPVMediaInformation(sourceURL: url)
        playbackDiagnostics = MPVPlaybackDiagnostics()
        renderColorStatus = .unknown
        dolbyVisionStatus = MPVDolbyVisionStatus(requestedPolicy: configuration.dolbyVisionPolicy)
        requestedVideoFeatures = []
        videoFeatureRequestResult = nil
        engine?.load(
            url,
            autoPlay: autoPlay,
            startTime: normalizedStartTime,
            generation: playbackGeneration
        )
    }

    /// Enables detailed diagnostics sampling; decoder and fallback changes remain event-driven.
    public func setDiagnosticsEnabled(_ enabled: Bool) {
        isDiagnosticsEnabled = enabled
        engine?.setDiagnosticsEnabled(enabled)
    }

    /// Starts or resumes playback.
    public func play() {
        if isUsingExternalPlayback {
            storedExternalPlayback?.setPlaying(true)
            return
        }
        engine?.play()
    }

    /// Pauses playback.
    public func pause() {
        if isUsingExternalPlayback {
            storedExternalPlayback?.setPlaying(false)
            return
        }
        engine?.pause()
    }

    /// Toggles between playing and paused.
    public func togglePlayback() {
        if isUsingExternalPlayback {
            storedExternalPlayback?.setPlaying(isPaused)
            return
        }
        engine?.togglePlayback()
    }

    /// Stops the current item and retires its native playback session.
    /// The source and runtime settings remain available for replay with ``play()``.
    public func stop() {
        storedExternalPlayback?.invalidate(restore: false)
        storedPictureInPicture?.stop()
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
                : time.clampPositiveOrZero
        if isUsingExternalPlayback {
            storedExternalPlayback?.seek(to: target)
            return
        }
        engine?.seek(to: target)
    }

    /// Seeks by a relative duration.
    public func seek(by offset: Duration) {
        if isUsingExternalPlayback {
            seek(to: position + offset)
            return
        }
        engine?.seek(by: offset)
    }

    /// Advances one decoded frame and pauses playback.
    public func stepForward() {
        guard allowLocalPlaybackOperation("Frame stepping") else { return }
        engine?.frameStep(backward: false)
    }

    /// Moves backward by one decoded frame and pauses playback.
    public func stepBackward() {
        guard allowLocalPlaybackOperation("Frame stepping") else { return }
        engine?.frameStep(backward: true)
    }

    /// Sets playback volume in mpv's `0...100` range.
    public func setVolume(_ newVolume: Double) {
        guard !newVolume.isNaN else { return }
        let normalized = clamp(newVolume, to: 0 ... 100)
        volume = normalized
        storedExternalPlayback?.updateAudio()
        engine?.setVolume(normalized)
    }

    /// Sets whether audio is muted.
    public func setMuted(_ muted: Bool) {
        isMuted = muted
        storedExternalPlayback?.updateAudio()
        engine?.setMuted(muted)
    }

    /// Toggles audio muting.
    public func toggleMute() {
        setMuted(!isMuted)
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
        storedExternalPlayback?.updateAudio()
        engine?.setPlaybackRate(normalized)
    }

    /// Selects a video, audio, or subtitle track using its ``MPVMediaTrack/id``.
    /// Selects subtitle tracks as primary. Use ``selectSubtitle(_:for:)``
    /// to choose a secondary track.
    public func selectTrack(_ id: MPVMediaTrackIdentifier) {
        guard allowLocalPlaybackOperation("Track selection") else { return }
        if id.type == .subtitle {
            selectSubtitle(id)
        } else {
            engine?.selectTrack(id)
        }
    }

    /// Disables the selected track of the given type.
    /// For subtitles, disables the primary selection only.
    public func disableTrack(_ type: MPVTrackType) {
        guard allowLocalPlaybackOperation("Track selection") else { return }
        engine?.disableTrack(type)
    }

    /// Selects a subtitle track for one role, or turns that role off with `nil`.
    /// Identifiers must come from ``subtitleTracks`` for the current item.
    /// Selecting a track already used by the other role moves it to this role.
    /// Selection is asynchronous. Observe ``selectedSubtitle(for:)`` for the result.
    /// Invalid identifiers report ``MPVPlayerError/invalidSubtitleTrack(_:)`` via ``lastError``.
    public func selectSubtitle(
        _ id: MPVMediaTrackIdentifier?,
        for role: MPVSubtitleRole = .primary
    ) {
        guard allowLocalPlaybackOperation("Subtitle selection") else { return }
        if let id {
            guard id.type == .subtitle,
                  let track = subtitleTracks.first(where: { $0.id == id })
            else {
                lastError = .invalidSubtitleTrack(id)
                return
            }
            if subtitleUsesNativeComposition(codec: track.codec) {
                requestVideoFeatures([.nativeSubtitles])
            }
        }
        engine?.selectSubtitle(id, for: role)
    }

    /// Returns the selected track for a subtitle role, including when hidden.
    public func selectedSubtitle(for role: MPVSubtitleRole = .primary) -> MPVMediaTrack? {
        subtitleTracks.first { $0.subtitleRole == role }
    }

    /// Loads an external video, audio, or subtitle file.
    public func loadExternalTrack(
        _ url: URL,
        type: MPVTrackType,
        select: Bool = true
    ) {
        guard allowLocalPlaybackOperation("External tracks") else { return }
        engine?.loadExternalTrack(url, type: type, select: select)
    }

    /// Loads an external subtitle file and selects its first track in the given
    /// role. Pass `nil` to add the file without selecting it. You can queue this
    /// after ``load(_:autoPlay:startTime:)``, before the media or render surface is ready.
    public func loadExternalSubtitle(_ url: URL, selecting role: MPVSubtitleRole? = .primary) {
        guard allowLocalPlaybackOperation("External subtitles") else { return }
        engine?.loadExternalTrack(
            url,
            type: .subtitle,
            select: role != nil,
            subtitleRole: role ?? .primary
        )
    }

    /// Sets audio delay. Negative values make audio play earlier.
    public func setAudioDelay(_ delay: Duration) {
        guard allowLocalPlaybackOperation("Audio delay") else { return }
        engine?.setAudioDelay(delay)
    }

    /// Sets subtitle delay. Negative values show subtitles earlier.
    public func setSubtitleDelay(_ delay: Duration, for role: MPVSubtitleRole = .primary) {
        guard allowLocalPlaybackOperation("Subtitle delay") else { return }
        engine?.setSubtitleDelay(delay, for: role)
    }

    /// Hides or shows one subtitle role without changing its selected track.
    public func setSubtitlesVisible(_ visible: Bool, for role: MPVSubtitleRole = .primary) {
        guard allowLocalPlaybackOperation("Subtitle visibility") else { return }
        engine?.setSubtitlesVisible(visible, for: role)
    }

    /// Enables or disables plain text interception. ASS and bitmap subtitles still use mpv.
    /// Enable before loading to avoid a native text flash; disabling clears all streams.
    public func setTextSubtitleInterceptionEnabled(_ enabled: Bool) {
        guard enabled != isTextSubtitleInterceptionEnabled else { return }
        isTextSubtitleInterceptionEnabled = enabled
        textSubtitleSnapshots.clear()
        engine?.setTextSubtitleInterceptionEnabled(enabled)
    }

    /// Streams complete semantic subtitle snapshots while interception is enabled.
    /// Subscription does not enable interception. Each stream immediately yields the
    /// latest snapshot, skips duplicates, and buffers only the newest pending value.
    public func textSubtitleStream() -> AsyncStream<TextSubtitleSnapshot> {
        textSubtitleSnapshots.subscribe()
    }

    /// Reads every nonempty text presentation for a loaded subtitle track.
    ///
    /// Works for selected or disabled SubRip, WebVTT, TTML, and `mov_text`
    /// tracks, including external files. Does not enable interception or change
    /// selection, visibility, pause state, or playback position. Returns ordered,
    /// nonoverlapping intervals containing all overlapping cue regions. The result
    /// omits gaps. Times exclude subtitle delay and speed adjustments.
    ///
    /// This scans the subtitle source asynchronously, potentially reading the
    /// whole container or downloading it again. Retain the result for repeated
    /// lookups. Requires a finite, seekable source. Unsupported tracks and read
    /// failures throw. Canceling the task, replacing the source, or stopping
    /// playback cancels an outstanding query.
    public func textSubtitleSnapshots(
        for track: MPVMediaTrackIdentifier
    ) async throws -> [TimedTextSubtitleSnapshot] {
        guard let engine else { throw MPVPlayerError.clientUnavailable }
        let generation = playbackGeneration
        let snapshots = try await engine.textSubtitleSnapshots(for: track)
        try Task.checkCancellation()
        guard generation == playbackGeneration else { throw CancellationError() }
        return snapshots
    }

    /// Reads all text cues containing a source timestamp (`start <= time < end`).
    ///
    /// Returns an empty snapshot in a gap. Has the same source requirements and
    /// scan cost as ``textSubtitleSnapshots(for:)``. For repeated queries, read
    /// all snapshots once and use ``TimedTextSubtitleSnapshot/contains(_:)``.
    public func textSubtitleSnapshot(
        for track: MPVMediaTrackIdentifier,
        at timestamp: Duration
    ) async throws -> TextSubtitleSnapshot {
        let snapshots = try await textSubtitleSnapshots(for: track)
        return snapshots.first { $0.contains(timestamp) }?.snapshot ?? TextSubtitleSnapshot()
    }

    /// Requests features before selecting native subtitles or configuring zoom and
    /// overlays. The player reevaluates requests made before metadata arrives
    /// once it identifies the item. Requests apply only to the current item.
    ///
    /// - Note: Native Dolby Vision does not support baked subtitles, overlays, or geometry changes.
    /// Unavailable features never switch the renderer or reload the item.
    @discardableResult
    public func requestVideoFeatures(_ features: Set<MPVVideoFeature>) -> MPVVideoFeatureRequestResult {
        requestedVideoFeatures.formUnion(features)
        return resolveRequestedVideoFeatures()
    }

    /// Moves to the next chapter when one exists.
    public func nextChapter() {
        command("add", arguments: ["chapter", "1"])
    }

    /// Moves to the previous chapter when one exists.
    public func previousChapter() {
        command("add", arguments: ["chapter", "-1"])
    }

    /// Sets an mpv property not covered by the typed API.
    ///
    /// Values persist before surface attachment and across native client recreation.
    /// Use typed methods for normalization and immediate state updates. MPVUI rejects
    /// properties it manages for rendering or playback and reports them through ``lastError``.
    /// - Note: Renderer-specific properties have no effect on outputs that do not support them.
    public func setProperty(_ name: String, to value: String) {
        guard allowLocalPlaybackOperation("mpv properties") else { return }
        let property = MPVOptionOwnership.normalizedProperty(name)
        if ["video-zoom", "video-pan-x", "video-pan-y"].contains(property),
           let amount = Double(value), amount.isFinite, amount != 0
        {
            requestVideoFeatures([.zoomAndPan])
        } else if ["video-scale-x", "video-scale-y"].contains(property),
                  let amount = Double(value), amount.isFinite, amount != 1
        {
            requestVideoFeatures([.zoomAndPan])
        }
        engine?.performPropertySet(name, value: value)
    }

    /// Runs an mpv command on the configured renderer. Commands require an attached
    /// surface. ``setProperty(_:to:)`` supports deferred settings.
    /// Commands cannot override the configured video output or its surface wiring.
    /// A command sent after stop creates an idle native client without reopening
    /// the source. Another ``stop()`` releases that client.
    public func command(_ name: String, arguments: [String] = []) {
        guard allowLocalPlaybackOperation("mpv commands") else { return }
        engine?.performCommand(name, arguments: arguments)
    }

    /// Clears the last nonfatal command error.
    public func clearLastError() {
        if case .failed = state {
            return
        }
        lastError = nil
    }
}

// MARK: - Rendering bridge

extension MPVPlayer {

    private static var pictureInPictureRequiresNativeOutput: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    private static var platformSupportsPictureInPicture: Bool {
        #if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
        true
        #else
        false
        #endif
    }

    /// Changes for every load, including consecutive loads of the same URL.
    var mediaGeneration: UInt64 {
        playbackGeneration
    }

    var isPlaybackPausedForPictureInPicture: Bool {
        switch state {
        case .idle, .stopped, .ended, .failed: true
        default: isPaused
        }
    }

    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        if let storedSampleBufferDisplayLayer {
            return storedSampleBufferDisplayLayer
        }
        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        storedSampleBufferDisplayLayer = displayLayer
        return displayLayer
    }

    var hasActiveRenderSurface: Bool {
        activeRenderSurfaceToken != nil
    }

    func updateDolbyVisionStatus(_ status: MPVDolbyVisionStatus) {
        dolbyVisionStatus = status
        if mediaInformation.tracks.contains(where: {
            $0.type == .subtitle && $0.isSelected && subtitleUsesNativeComposition(codec: $0.codec)
        }) {
            requestedVideoFeatures.insert(.nativeSubtitles)
        }
        if !requestedVideoFeatures.isEmpty {
            _ = resolveRequestedVideoFeatures()
        }
    }

    func setDisplaySwitchInProgress(_ switching: Bool) {
        engine?.setDisplaySwitchInProgress(switching)
    }

    func pauseForExternalPlayback() async {
        storedPictureInPicture?.stop()
        storedPictureInPicture?.refreshPlaybackState()
        textSubtitleSnapshots.clear()
        await engine?.pauseAndWait()
    }

    func externalPlaybackOptions() async -> MPVMediaPackagingOptions {
        await engine?.externalPlaybackOptions() ?? MPVMediaPackagingOptions()
    }

    func resumeAfterExternalPlayback(paused: Bool) {
        playbackGeneration &+= 1
        isPaused = paused
        state = paused ? .paused : .loading
        engine?.resumeAfterHandoff(at: position, paused: paused, generation: playbackGeneration)
        storedPictureInPicture?.refreshPlaybackState()
    }

    func updateExternalPlayback(position: Duration, duration: Duration, seekable: Bool, paused: Bool, state: MPVPlaybackState) {
        guard isUsingExternalPlayback else { return }
        self.position = position
        self.duration = duration
        isSeekable = seekable
        isPaused = paused
        self.state = state
        bufferStatus = .empty
    }

    func attachSampleBufferOutput() {
        guard videoOutput == .sampleBuffer, !hasAttachedSampleBufferOutput else { return }
        hasAttachedSampleBufferOutput = true
        if sampleBufferRenderTarget == nil {
            updateSampleBufferOutput(displayCapabilities: .unknown, configuredDynamicRange: .automatic)
        }
        if let sampleBufferRenderTarget {
            engine?.attach(to: sampleBufferRenderTarget)
        }
    }

    func updateSampleBufferOutput(
        displayCapabilities: MPVDisplayCapabilities,
        configuredDynamicRange: MPVPresentationStatus.DynamicRange,
        policyFallbackReason: MPVPresentationStatus.FallbackReason? = nil,
        colorConfiguration: MPVRenderColorConfiguration? = nil
    ) {
        guard videoOutput == .sampleBuffer else { return }
        let displayLayer = sampleBufferDisplayLayer
        let target = MPVRenderTarget(
            layerAddress: Int64(Int(bitPattern: Unmanaged.passUnretained(displayLayer).toOpaque())),
            layerOwner: displayLayer,
            drawableWidth: 2,
            drawableHeight: 2,
            usesExtendedDynamicRange: configuredDynamicRange == .hdr
                || configuredDynamicRange == .constrainedHDR,
            displaySupportsExtendedDynamicRange: displayCapabilities.hdrSupport == .supported,
            outputHeadroom: displayCapabilities.currentEDRHeadroom ?? 1,
            displayCapabilities: displayCapabilities,
            configuredDynamicRange: configuredDynamicRange,
            policyFallbackReason: policyFallbackReason,
            colorConfiguration: colorConfiguration?.sessionConfiguration
        )
        if let previous = sampleBufferRenderTarget, previous.matches(target) {
            return
        }
        sampleBufferRenderTarget = target
        if hasAttachedSampleBufferOutput {
            engine?.attach(to: target)
        }
    }

    func seekForPictureInPicture(to time: Duration) async -> Bool {
        await engine?.seekForPictureInPicture(to: time) ?? false
    }

    func renderedScreenshotForTesting() async -> MPVNodeValue? {
        await engine?.renderedScreenshotForTesting()
    }

    func pictureInPictureOverlayDidChange(_ surface: MPVPlatformVideoPlayer) {
        storedPictureInPicture?.overlayDidChange(on: surface)
    }

    func setPictureInPictureOverlay(_ bitmap: MPVVideoOverlayBitmap?) async -> Bool {
        await engine?.setPictureInPictureOverlay(bitmap) ?? false
    }

    func clearPictureInPictureOverlay() {
        engine?.clearPictureInPictureOverlay()
    }

    func textSubtitleInterceptionForTesting() async -> Bool? {
        await engine?.textSubtitleInterceptionForTesting()
    }

    func pictureInPictureSurfaceDidAttach(_ surface: MPVPlatformVideoPlayer) {
        activePlatformSurface = surface
        if surface.isActiveRenderingSurface {
            renderingPlatformSurface = surface
        }
        storedPictureInPicture?.attach(to: surface)
    }

    func pictureInPictureSurfaceDidDetach(_ surface: MPVPlatformVideoPlayer) {
        if activePlatformSurface === surface {
            activePlatformSurface = nil
        }
        if renderingPlatformSurface === surface {
            renderingPlatformSurface = nil
        }
        storedPictureInPicture?.detach(from: surface)
    }

    func retainRenderSurfaceForPictureInPicture(token: UUID) {
        guard activeRenderSurfaceToken == token else { return }
        pictureInPictureSurfaceToken = token
    }

    func releaseRenderSurfaceFromPictureInPicture(token: UUID) {
        guard pictureInPictureSurfaceToken == token else { return }
        pictureInPictureSurfaceToken = nil
    }

    func activateRenderSurface(token: UUID) {
        guard pictureInPictureSurfaceToken == nil || pictureInPictureSurfaceToken == token else { return }
        guard activeRenderSurfaceToken != token else { return }

        // Ownership can move to a surface whose geometry is not attachable yet.
        // Retire the previous native target synchronously so neither that new
        // surface nor a subsequently restored one can host-write a layer that
        // still backs a live swapchain.
        if videoOutput == .metal {
            engine?.detachCurrentRenderTargetSynchronously()
        }
        activeRenderSurfaceToken = token
    }

    func isRenderSurfaceActive(token: UUID) -> Bool {
        activeRenderSurfaceToken == token
    }

    /// Fences frame presentation while the owner changes its layer color
    /// contract. Finish synchronously through `attachRenderTarget` below.
    func beginRenderColorUpdate(token: UUID, layerAddress: Int64) -> Bool {
        guard activeRenderSurfaceToken == token else { return false }
        return engine?.beginColorUpdate(forLayerAddress: layerAddress) ?? false
    }

    func attachRenderTarget(
        token: UUID,
        layerAddress: Int64,
        layerOwner: AnyObject,
        drawableWidth: Int,
        drawableHeight: Int,
        usesExtendedDynamicRange: Bool,
        displaySupportsExtendedDynamicRange: Bool,
        outputHeadroom: Double,
        displayCapabilities: MPVDisplayCapabilities? = nil,
        configuredDynamicRange: MPVPresentationStatus.DynamicRange? = nil,
        policyFallbackReason: MPVPresentationStatus.FallbackReason? = nil,
        colorConfiguration: MPVRenderColorConfiguration? = nil,
        synchronousColorUpdate: Bool = false
    ) {
        guard activeRenderSurfaceToken == token else { return }
        let target = MPVRenderTarget(
            layerAddress: layerAddress,
            layerOwner: layerOwner,
            drawableWidth: drawableWidth,
            drawableHeight: drawableHeight,
            usesExtendedDynamicRange: usesExtendedDynamicRange,
            displaySupportsExtendedDynamicRange: displaySupportsExtendedDynamicRange,
            outputHeadroom: outputHeadroom,
            displayCapabilities: displayCapabilities,
            configuredDynamicRange: configuredDynamicRange,
            policyFallbackReason: policyFallbackReason,
            colorConfiguration: colorConfiguration?.sessionConfiguration
        )
        if synchronousColorUpdate {
            engine?.finishColorUpdate(target: target)
        } else {
            engine?.attach(to: target)
        }
    }

    func renderOutputSize() async -> MPVRenderOutputSize? {
        await engine?.renderOutputSize()
    }

    func resizeRenderTargetAndWait(
        token: UUID,
        layerAddress: Int64,
        drawableWidth: Int,
        drawableHeight: Int,
        force: Bool = false,
        live: Bool = false
    ) async -> Bool {
        guard activeRenderSurfaceToken == token else { return false }
        return await engine?.resizeRenderTargetAndWait(
            width: drawableWidth,
            height: drawableHeight,
            forLayerAddress: layerAddress,
            force: force,
            live: live
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
                    level: .debug,
                    message: message()
                )
            )
        case .none, .fatal, .error, .warning, .info, .status:
            break
        }
    }

    func detachRenderTarget(token: UUID, layerAddress: Int64?) {
        let wasActive = activeRenderSurfaceToken == token
        if wasActive {
            activeRenderSurfaceToken = nil
        }
        if wasActive, videoOutput == .sampleBuffer, hasAttachedSampleBufferOutput {
            hasAttachedSampleBufferOutput = false
            if let target = sampleBufferRenderTarget {
                engine?.detach(fromLayerAddress: target.layerAddress)
            }
        }
        if let layerAddress, videoOutput == .metal {
            // The engine validates the address against its current target.
            // Detaching an inactive surface is still necessary when a newer,
            // zero-sized surface claimed ownership but never attached.
            // Join the renderer before retiring its surface. A queued detach
            // can otherwise outlive its owner and race graphics-library cleanup.
            // Native output never synchronously waits on the main actor.
            engine?.detachSynchronously(fromLayerAddress: layerAddress)
        }
    }

    func detachRenderTargetSynchronously(token: UUID, layerAddress: Int64) {
        guard activeRenderSurfaceToken == token else { return }
        engine?.detachSynchronously(fromLayerAddress: layerAddress)
    }

    private func subtitleUsesNativeComposition(codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        let intercepted = ["subrip", "srt", "webvtt", "webvtt-webm", "ttml", "mov_text", "text"].contains(codec)
        return !isTextSubtitleInterceptionEnabled || !intercepted
    }

    private func resolveRequestedVideoFeatures() -> MPVVideoFeatureRequestResult {
        let result = videoFeatureCapabilities.resolve(requestedVideoFeatures)
        videoFeatureRequestResult = result
        return result
    }

    private func allowLocalPlaybackOperation(_ name: String) -> Bool {
        guard isUsingExternalPlayback else { return true }
        lastError = .externalPlaybackFailed("\(name) can be changed after returning to local playback.")
        return false
    }
}

// MARK: - Engine updates

extension MPVPlayer {

    /// Apply one generation-tagged engine update on the main actor.
    func apply(_ emission: MPVEngineEmission) {
        guard emission.generation == nil || emission.generation == playbackGeneration else {
            return
        }

        let update = emission.update
        let snapshot = emission.snapshot
        if isUsingExternalPlayback {
            if case let .log(log) = update {
                logHandler?(log)
            }
            return
        }
        var refreshPictureInPicture = false
        switch update {
        case let .paused(paused):
            refreshPictureInPicture = isPaused != paused
            isPaused = paused

        case let .state(newState):
            refreshPictureInPicture = state != newState
            state = newState
            hasPlaybackFrame = snapshot.hasPlaybackFrame
            currentChapterIndex = snapshot.currentChapterIndex
            if let error = snapshot.error {
                lastError = error
            }

        case let .timing(newPosition, newDuration, seekable):
            refreshPictureInPicture = duration != newDuration || isSeekable != seekable
            position = newPosition
            duration = newDuration
            isSeekable = seekable
            let reportedDuration = snapshot.mediaInformation.duration
            if mediaInformation.duration != reportedDuration {
                mediaInformation.duration = reportedDuration
            }

        case let .frameRate(rate):
            if mediaInformation.framesPerSecond != rate {
                mediaInformation.framesPerSecond = rate
            }

        case let .chapter(index):
            currentChapterIndex = index

        case let .videoFrame(available):
            refreshPictureInPicture = hasPlaybackFrame != available
            hasPlaybackFrame = available

        case let .buffer(status):
            bufferStatus = status

        case let .media(information):
            refreshPictureInPicture = mediaInformation != information
            mediaInformation = information
            duration = snapshot.duration

        case let .diagnostics(diagnostics):
            playbackDiagnostics = diagnostics

        case let .color(status):
            renderColorStatus = status

        case let .dolbyVision(status):
            updateDolbyVisionStatus(status)

        case let .audio(newVolume, muted, rate):
            refreshPictureInPicture = playbackRate != rate
            volume = newVolume
            isMuted = muted
            playbackRate = rate

        case let .textSubtitles(snapshot):
            guard isTextSubtitleInterceptionEnabled else { return }
            textSubtitleSnapshots.publish(snapshot)

        case let .error(error, fatal):
            lastError = error
            if fatal {
                state = snapshot.state
                hasPlaybackFrame = snapshot.hasPlaybackFrame
                currentChapterIndex = snapshot.currentChapterIndex
                refreshPictureInPicture = true
            }

        case let .log(log):
            logHandler?(log)
        }
        if refreshPictureInPicture {
            storedPictureInPicture?.refreshPlaybackState()
        }
    }
}
