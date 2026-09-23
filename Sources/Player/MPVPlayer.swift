import AVFoundation
import Foundation
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

    /// The video output currently in use. Unsupported native formats fall back
    /// to Metal for the current source; the next load retries the configured output.
    public private(set) var videoOutput: MPVPlayerConfiguration.VideoOutput

    /// Why the current source switched from native sample buffers to Metal.
    public private(set) var videoOutputFallbackReason: String?

    /// A machine-readable reason for a backend fallback, when one occurred.
    public private(set) var presentationFallbackReason: MPVPresentationStatus.FallbackReason?

    /// The playback lifecycle state.
    public private(set) var state: MPVPlaybackState = .idle

    /// Current playback position.
    public private(set) var position: Duration = .zero

    /// Current media duration, or zero when it is unknown.
    public private(set) var duration: Duration = .zero

    /// Whether the current source supports seeking.
    public private(set) var isSeekable = false

    /// Playback intention, including while seeking or waiting for data.
    public private(set) var isPaused = true

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

    /// Current demuxer/network buffer state.
    public private(set) var bufferStatus: MPVBufferStatus = .empty

    /// Metadata, tracks, codecs, dimensions, and HDR information.
    public private(set) var mediaInformation: MPVMediaInformation = .empty

    /// Decoder and rendering counters reported by the active engine.
    public private(set) var playbackDiagnostics = MPVPlaybackDiagnostics()

    /// Configured color target and its evidence, separate from screen luminance.
    public private(set) var renderColorStatus: MPVRenderColorStatus = .unknown

    /// This item's source profile, validated native output and lossy conversion.
    public private(set) var dolbyVisionStatus: MPVDolbyVisionStatus = .unknown

    /// Capabilities of the current item and backend. Inline SwiftUI content is
    /// distinguished from graphics that must be baked into native video samples.
    public var videoFeatureCapabilities: MPVVideoFeatureCapabilities {
        MPVVideoFeatureCapabilities(
            backend: videoOutput,
            dolbyVision: dolbyVisionStatus,
            hasVideo: mediaInformation.videoCodec != nil || dolbyVisionStatus.sourceProfile != nil,
            pictureInPictureRequiresNativeOutput: Self.pictureInPictureRequiresNativeOutput,
            supportsPictureInPicture: Self.platformSupportsPictureInPicture
        )
    }

    /// The latest feature request, including any reload or iOS PiP tradeoff.
    public private(set) var videoFeatureRequestResult: MPVVideoFeatureRequestResult?

    @ObservationIgnored
    private var requestedVideoFeatures: Set<MPVVideoFeature> = []
    @ObservationIgnored
    private var requestedVideoFeaturePolicy: MPVNativeVideoFeaturePolicy?

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
        videoOutput = configuration.videoOutput
        dolbyVisionStatus = MPVDolbyVisionStatus(requestedPolicy: configuration.dolbyVisionPolicy)
        volume = configuration.volume
        playbackRate = configuration.playbackRate

        engine = MPVEngine(configuration: configuration) { [weak self] emission in
            self?.apply(emission)
        }
    }

    /// Creates a player and loads the URL once a render surface is ready.
    public convenience init(
        url: URL,
        configuration: MPVPlayerConfiguration = .init()
    ) {
        self.init(configuration: configuration)
        load(url)
    }

    isolated deinit {
        storedPictureInPicture?.invalidate()
        textSubtitleSnapshots.terminate()
        engine?.shutdownSynchronously()
    }

    /// Replaces the current media once a render surface is ready.
    ///
    /// May be called before attaching a view. Omitted options use the configuration;
    /// negative start times are clamped to zero.
    public func load(
        _ url: URL,
        autoPlay: Bool? = nil,
        startTime: Duration? = nil
    ) {
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
        bufferStatus = .empty
        mediaInformation = MPVMediaInformation(sourceURL: url)
        playbackDiagnostics = MPVPlaybackDiagnostics()
        renderColorStatus = .unknown
        dolbyVisionStatus = MPVDolbyVisionStatus(requestedPolicy: configuration.dolbyVisionPolicy)
        requestedVideoFeatures = []
        requestedVideoFeaturePolicy = nil
        videoFeatureRequestResult = nil
        let restoresConfiguredOutput = videoOutput != configuration.videoOutput
        if restoresConfiguredOutput {
            changeVideoOutput(to: configuration.videoOutput, preservePlayback: false)
        }
        videoOutputFallbackReason = nil
        presentationFallbackReason = nil
        engine?.load(
            url,
            autoPlay: autoPlay,
            startTime: normalizedStartTime,
            generation: playbackGeneration
        )
        if restoresConfiguredOutput {
            reattachVideoOutput()
        }
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

    /// Selects a video, audio, or subtitle track using its ``MPVMediaTrack/id``.
    /// Subtitle tracks are selected as primary. Use ``selectSubtitle(_:for:)``
    /// to choose a secondary track.
    public func selectTrack(_ id: MPVMediaTrackIdentifier) {
        if id.type == .subtitle {
            selectSubtitle(id)
        } else {
            engine?.selectTrack(id)
        }
    }

    /// Disables the selected track of the given type.
    /// For subtitles, disables the primary selection only.
    public func disableTrack(_ type: MPVTrackType) {
        engine?.disableTrack(type)
    }

    /// Selects a subtitle track for one role, or turns that role off with nil.
    /// Identifiers must come from ``subtitleTracks`` for the current item.
    /// Selecting a track already used by the other role moves it to this role.
    /// Selection is asynchronous; observe ``selectedSubtitle(for:)`` for the result.
    /// Invalid identifiers report ``MPVPlayerError/invalidSubtitleTrack(_:)`` via ``lastError``.
    public func selectSubtitle(
        _ id: MPVMediaTrackIdentifier?,
        for role: MPVSubtitleRole = .primary
    ) {
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

    /// The track currently selected in a subtitle role, including when hidden.
    public func selectedSubtitle(for role: MPVSubtitleRole = .primary) -> MPVMediaTrack? {
        subtitleTracks.first { $0.subtitleRole == role }
    }

    /// Loads an external video, audio, or subtitle file.
    public func loadExternalTrack(
        _ url: URL,
        type: MPVTrackType,
        select: Bool = true
    ) {
        engine?.loadExternalTrack(url, type: type, select: select)
    }

    /// Loads an external subtitle file and selects its first track in the given
    /// role. Pass nil to add the file without selecting it. Can be queued after
    /// ``load(_:)`` before the media or render surface is ready.
    public func loadExternalSubtitle(_ url: URL, selecting role: MPVSubtitleRole? = .primary) {
        engine?.loadExternalTrack(
            url, type: .subtitle, select: role != nil, subtitleRole: role ?? .primary
        )
    }

    /// Sets audio delay. Negative values make audio play earlier.
    public func setAudioDelay(_ delay: Duration) {
        engine?.setAudioDelay(delay)
    }

    /// Sets subtitle delay. Negative values show subtitles earlier.
    public func setSubtitleDelay(_ delay: Duration, for role: MPVSubtitleRole = .primary) {
        engine?.setSubtitleDelay(delay, for: role)
    }

    /// Hides or shows one subtitle role without changing its selected track.
    public func setSubtitlesVisible(_ visible: Bool, for role: MPVSubtitleRole = .primary) {
        engine?.setSubtitlesVisible(visible, for: role)
    }

    /// Streams semantic text subtitles for custom presentation.
    ///
    /// The first call enables interception for the player's lifetime. mpv stops
    /// drawing SubRip, WebVTT, TTML, and `mov_text`; ASS/SSA and image subtitles
    /// still use mpv's renderer. Call before loading to avoid a native text flash.
    ///
    /// Each stream immediately yields the latest complete snapshot (initially empty),
    /// skips duplicates, and buffers only the newest pending value. Empty snapshots
    /// clear the client's subtitle presentation.
    public func textSubtitleStream() -> AsyncStream<TextSubtitleSnapshot> {
        if !isTextSubtitleInterceptionEnabled {
            isTextSubtitleInterceptionEnabled = true
            engine?.enableTextSubtitleInterception()
        }
        return textSubtitleSnapshots.subscribe()
    }

    /// Reads every nonempty text presentation for a loaded subtitle track.
    ///
    /// Works for selected or disabled SubRip, WebVTT, TTML, and `mov_text`
    /// tracks, including external files. Does not enable interception or change
    /// selection, visibility, pause state, or playback position. Results are
    /// ordered, nonoverlapping intervals containing all overlapping cue regions.
    /// Gaps are omitted. Times exclude subtitle delay and speed adjustments.
    ///
    /// This scans the subtitle source asynchronously, potentially reading the
    /// whole container or downloading it again. Retain the result for repeated
    /// lookups. Requires a finite, seekable source; unsupported tracks and read
    /// failures throw. Cancelling the task, replacing the source, or stopping
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

    /// Requests capabilities before selecting native subtitles or configuring
    /// zoom/overlays. A request made before metadata arrives is reevaluated when
    /// the item is identified. Requests apply only to the current item.
    ///
    /// Pass `.preferFeatures` to explicitly allow a Metal reload. On iOS that
    /// reload removes PiP support; the returned result reports this tradeoff.
    /// Native DV frames are never modified to satisfy an incompatible request.
    @discardableResult
    public func requestVideoFeatures(
        _ features: Set<MPVVideoFeature>,
        policy: MPVNativeVideoFeaturePolicy? = nil
    ) -> MPVVideoFeatureRequestResult {
        requestedVideoFeatures.formUnion(features)
        requestedVideoFeaturePolicy = policy ?? requestedVideoFeaturePolicy ?? configuration.nativeVideoFeaturePolicy
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
    /// Values persist before surface attachment and across renderer recreation.
    /// Use typed methods for normalization and immediate state updates. Properties
    /// managed by MPVUI's renderer or playback state are rejected through ``lastError``.
    public func setProperty(_ name: String, to value: String) {
        if ["video-zoom", "video-pan-x", "video-pan-y"].contains(name),
           let amount = Double(value), amount.isFinite, amount != 0
        {
            requestVideoFeatures([.zoomAndPan])
        } else if ["video-scale-x", "video-scale-y"].contains(name),
                  let amount = Double(value), amount.isFinite, amount != 1
        {
            requestVideoFeatures([.zoomAndPan])
        }
        engine?.performPropertySet(name, value: value)
    }

    /// Runs an mpv command.
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

    func updateDolbyVisionStatus(_ status: MPVDolbyVisionStatus) {
        dolbyVisionStatus = status
        if configuration.nativeVideoFeaturePolicy == .preferFeatures,
           mediaInformation.tracks.contains(where: {
               $0.type == .subtitle && $0.isSelected && subtitleUsesNativeComposition(codec: $0.codec)
           })
        {
            requestedVideoFeatures.insert(.nativeSubtitles)
            requestedVideoFeaturePolicy = requestedVideoFeaturePolicy ?? configuration.nativeVideoFeaturePolicy
        }
        if !requestedVideoFeatures.isEmpty, videoFeatureRequestResult?.outcome != .switchedToMetal {
            _ = resolveRequestedVideoFeatures()
        }
    }

    private func subtitleUsesNativeComposition(codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        let intercepted = ["subrip", "srt", "webvtt", "webvtt-webm", "ttml", "mov_text", "text"].contains(codec)
        return !isTextSubtitleInterceptionEnabled || !intercepted
    }

    private func resolveRequestedVideoFeatures() -> MPVVideoFeatureRequestResult {
        let capabilities = videoFeatureCapabilities
        let unavailable = Set(requestedVideoFeatures.filter { capabilities[$0].availability == .unavailable })
        let unknown = requestedVideoFeatures.contains { capabilities[$0].availability == .unknown }
        let needsFallback = unavailable.contains {
            capabilities[$0].restriction == .nativeDolbyVisionPreservesRPU
                && ($0 != .pictureInPictureSubtitles || !Self.pictureInPictureRequiresNativeOutput)
        }
        let losesPiP = Self.pictureInPictureRequiresNativeOutput && videoOutput == .sampleBuffer && needsFallback
        let canSwitch = needsFallback && requestedVideoFeaturePolicy == .preferFeatures
        let outcome: MPVVideoFeatureRequestResult.Outcome
        let reason: String?
        if needsFallback {
            outcome = canSwitch ? .switchedToMetal : .requiresMetalFallback
            reason = losesPiP
                ? "Native Dolby Vision preserves unmodified RPU frames. Metal enables compositing and geometry, but iOS picture in picture becomes unavailable."
                : "Native Dolby Vision preserves unmodified RPU frames. Metal enables compositing and geometry."
        } else if !unavailable.isEmpty {
            outcome = .unavailable
            reason = unavailable.contains { capabilities[$0].restriction == .nativeDolbyVisionPreservesRPU }
                ? "Native Dolby Vision cannot bake subtitles into RPU frames, and switching to Metal would remove iOS picture in picture."
                : "The requested picture-in-picture feature is unavailable on this platform or backend."
        } else if unknown {
            outcome = .awaitingVideoMetadata
            reason = "Video metadata is not yet available."
        } else {
            outcome = .available
            reason = nil
        }
        if canSwitch {
            handleNativeVideoOutputUnavailable(reason ?? "Requested video features require Metal.")
        }
        let finalUnavailable = canSwitch
            ? Set(requestedVideoFeatures.filter { videoFeatureCapabilities[$0].availability == .unavailable })
            : unavailable
        let result = MPVVideoFeatureRequestResult(
            outcome: outcome,
            requestedFeatures: requestedVideoFeatures,
            unavailableFeatures: finalUnavailable,
            requiresReload: needsFallback,
            losesPictureInPicture: losesPiP,
            reason: reason
        )
        videoFeatureRequestResult = result
        return result
    }

    /// Changes for every load, including consecutive loads of the same URL.
    var mediaGeneration: UInt64 {
        playbackGeneration
    }

    func setDisplaySwitchInProgress(_ switching: Bool) {
        engine?.setDisplaySwitchInProgress(switching)
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
        if configuration.hdrPolicy == .disabled, policyFallbackReason == .unsupportedPolicy {
            handleNativeVideoOutputUnavailable(
                "The native layer cannot enforce SDR on this OS; using Metal tone mapping.",
                fallbackReason: .unsupportedPolicy
            )
            return
        }
        let displayLayer = sampleBufferDisplayLayer
        let target = MPVRenderTarget(
            layerAddress: Int64(Int(bitPattern: Unmanaged.passUnretained(displayLayer).toOpaque())),
            layerOwner: displayLayer,
            drawableWidth: 2, drawableHeight: 2,
            usesExtendedDynamicRange: configuredDynamicRange == .hdr
                || configuredDynamicRange == .constrainedHDR,
            displaySupportsExtendedDynamicRange: displayCapabilities.hdrSupport == .supported,
            outputHeadroom: displayCapabilities.currentEDRHeadroom ?? 1,
            displayCapabilities: displayCapabilities,
            configuredDynamicRange: configuredDynamicRange,
            policyFallbackReason: policyFallbackReason,
            colorConfiguration: colorConfiguration
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

    var hasActiveRenderSurface: Bool {
        activeRenderSurfaceToken != nil
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
            colorConfiguration: colorConfiguration
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
                    level: .debug,
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

    /// Called only after native output has rejected a frame before display.
    func handleNativeVideoOutputUnavailable(
        _ reason: String,
        fallbackReason: MPVPresentationStatus.FallbackReason? = nil
    ) {
        guard videoOutput == .sampleBuffer else { return }
        videoOutputFallbackReason = reason
        presentationFallbackReason = fallbackReason ?? .nativeOutputUnavailable(reason)
        lastError = nil
        state = .loading
        changeVideoOutput(to: .metal, preservePlayback: true, fallbackReason: presentationFallbackReason)
        reattachVideoOutput()
    }

    private func changeVideoOutput(
        to output: MPVPlayerConfiguration.VideoOutput,
        preservePlayback: Bool,
        fallbackReason: MPVPresentationStatus.FallbackReason? = nil
    ) {
        storedPictureInPicture?.videoOutputWillChange()
        // The native renderer must release its target before we remove or
        // configure layers on the main actor.
        engine?.switchVideoOutputSynchronously(
            to: output, preservePlayback: preservePlayback, fallbackReason: fallbackReason
        )
        hasAttachedSampleBufferOutput = false
        sampleBufferRenderTarget = nil
        storedSampleBufferDisplayLayer?.removeFromSuperlayer()
        videoOutput = output
        storedPictureInPicture?.videoOutputDidChange()
    }

    private func reattachVideoOutput() {
        // A replacement inline view may have registered while macOS PiP still
        // owns the original surface. Keep rendering inside that PiP window.
        (renderingPlatformSurface ?? activePlatformSurface)?.videoOutputDidChange()
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
        switch update {
        case let .nativeVideoOutputUnavailable(reason):
            handleNativeVideoOutputUnavailable(reason)

        case let .paused(paused):
            isPaused = paused

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

        case let .diagnostics(diagnostics):
            playbackDiagnostics = diagnostics

        case let .color(status):
            renderColorStatus = status

        case let .dolbyVision(status):
            updateDolbyVisionStatus(status)

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
            logHandler?(log)
        }
        storedPictureInPicture?.refreshPlaybackState()
    }
}
