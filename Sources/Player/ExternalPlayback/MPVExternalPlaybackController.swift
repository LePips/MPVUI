import AVFoundation
import Foundation
import MPVCore
import Observation

/// Manages AirPlay playback through ``MPVPlayer/externalPlayback``.
///
/// Add ``MPVRoutePicker`` to your custom controls to prepare media after a destination is selected.
/// Keep ``MPVVideoPlayer`` attached for system video output. Use ``MPVPlayer`` to control
/// play, pause, seek, volume, mute, and playback rate. Call ``stop()`` to return to mpv
/// at the current position.
///
/// Compatible sources play directly. Other sources are packaged into HLS on this device
/// as playback advances. Compatible H.264, HEVC, AAC, AC-3, and E-AC-3 tracks are copied,
/// preserving HDR and surround sound when supported by the receiver. Each incompatible
/// track is converted independently to H.264 SDR video up to 1080p30 or AAC audio with up
/// to eight channels. Visible subtitles and mpv-specific input or timing options require
/// rendering through mpv, which produces H.264 video and stereo AAC audio.
///
/// Packaging requires native HLS support, a local network, `NSLocalNetworkUsageDescription`,
/// and an App Transport Security allowance for local networking. Background playback requires
/// the host app's audio background mode. HDR-to-SDR conversion uses the GPU and pauses while
/// iOS is inactive. Copying HDR tracks can continue in the background.
///
/// Select embedded tracks before starting external playback. External track files are unsupported.
/// Direct playback uses AVKit's track selection. Return to local playback to change mpv tracks.
/// Use ``makePreparationPlan(using:)`` to inspect the required work before starting playback.
/// ``preparationPlan`` reports the processing selected by the current preparation.
///
/// - Important: Experimental.
@MainActor
@Observable
public final class MPVExternalPlaybackController {

    /// Whether media is being prepared for system playback.
    public private(set) var isPreparing = false
    /// Whether the system player is ready to play, even if no AirPlay destination is selected.
    public private(set) var isPrepared = false
    /// Whether AVFoundation reports active external video playback.
    public private(set) var isActive = false
    /// The current preparation's processing plan, or `nil` before it is resolved or after stopping.
    public private(set) var preparationPlan: MPVExternalPlaybackPlan?
    /// The most recent external playback error, cleared when a new session starts.
    public private(set) var lastError: MPVPlayerError?

    @ObservationIgnored
    let systemPlayer = AVPlayer()
    @ObservationIgnored
    private weak var player: MPVPlayer?
    @ObservationIgnored
    private var stream: MPVHLSStream?
    @ObservationIgnored
    private var preparation: Task<Void, Error>?
    @ObservationIgnored
    private var monitoring: Task<Void, Never>?
    @ObservationIgnored
    private var requestID = UUID()
    @ObservationIgnored
    private var desiredPaused = true
    @ObservationIgnored
    private var timelineOrigin = 0.0
    @ObservationIgnored
    private var sourceDuration: Duration = .zero
    @ObservationIgnored
    private var sourceIsSeekable = false
    @ObservationIgnored
    private var overrideURL: URL?
    @ObservationIgnored
    private var securityScopedURL: URL?
    @ObservationIgnored
    private var isSeeking = false
    @ObservationIgnored
    private var seekID = UUID()
    @ObservationIgnored
    private var routePreparation: Task<Void, Never>?
    @ObservationIgnored
    private var routeRequestID = UUID()
    @ObservationIgnored
    private var airPlayRouteSelected = false
    @ObservationIgnored
    private var routeObserver: NSObjectProtocol?

    /// Whether the resolved preparation plan encodes tracks on this device.
    /// This is false while the plan is unknown and for direct playback or remuxing.
    public var isTranscoding: Bool {
        preparationPlan?.isTranscoding ?? false
    }

    var controlsPlayback: Bool {
        isPreparing || isPrepared
    }

    init(player: MPVPlayer) {
        self.player = player
        systemPlayer.allowsExternalPlayback = true
        systemPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    }

    isolated deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }

        routePreparation?.cancel()
        invalidate(restore: false)
    }

    /// Clears the most recent media preparation or external playback error.
    public func clearLastError() {
        lastError = nil
    }

    /// Inspects the current source and selected tracks without changing playback or constructing HLS.
    ///
    /// Native inspection may read media and decode a keyframe, but does not open encoders or start a server.
    /// The optional URL supplies an alternate compatible rendition with the same timeline.
    /// Reevaluate after changing the source, track selection, or playback options.
    ///
    /// - Throws: ``MPVPlayerError`` if media is unavailable, selected external tracks are unsupported,
    ///   or inspection fails. Cancellation or changed source options throw `CancellationError`.
    public func makePreparationPlan(using url: URL? = nil) async throws -> MPVExternalPlaybackPlan {
        try Task.checkCancellation()

        let player = try loadedPlayer()
        let generation = player.mediaGeneration
        guard let source = url ?? player.mediaInformation.sourceURL else { throw CancellationError() }

        let position = player.state == .ended || player.state == .stopped ? .zero : player.position
        let options = await player.externalPlaybackOptions()

        try Task.checkCancellation()
        guard player.mediaGeneration == generation else { throw CancellationError() }

        let toneMapsHDR = player.mediaInformation.hdr.isHDRContent || player.dolbyVisionStatus.sourceProfile != nil
        let scoped = source.isFileURL && source.startAccessingSecurityScopedResource()

        defer {
            if scoped {
                source.stopAccessingSecurityScopedResource()
            }
        }

        do {
            if url == nil {
                try validateEmbeddedTracks(options)
            }

            let plan: MPVExternalPlaybackPlan = if try await canPlayDirectly(
                AVURLAsset(url: source),
                options: options,
                isAlternate: url != nil
            ) {
                .direct
            } else if options.requiresRenderer {
                .init(rendering: options, toneMapsHDR: toneMapsHDR)
            } else {
                try await MPVMediaPackager().inspect(source: source, startTime: position, options: options)
            }

            let currentOptions = await player.externalPlaybackOptions()

            try Task.checkCancellation()
            guard player.mediaGeneration == generation, currentOptions == options else { throw CancellationError() }

            return plan
        } catch {
            try Task.checkCancellation()
            guard player.mediaGeneration == generation else { throw CancellationError() }

            throw error
        }
    }

    /// Prepares system playback at the current position, remuxing or converting media as needed.
    ///
    /// The optional URL provides compatible media with the same timeline, such as HLS from a server.
    /// mpv's HTTP options apply to on-device packaging and are not forwarded to the receiver.
    /// For authenticated media, provide a URL the receiver can access directly.
    /// Cancellation or failure restores local playback. The user selects the playback destination.
    public func start(using url: URL? = nil) async throws {
        let player = try loadedPlayer()

        if isPrepared, url == overrideURL {
            return
        }

        invalidate(restore: true)
        overrideURL = url
        sourceDuration = player.duration
        sourceIsSeekable = player.isSeekable
        desiredPaused = player.isPlaybackPausedForPictureInPicture
        lastError = nil
        isPreparing = true

        let id = requestID
        let position = player.state == .ended || player.state == .stopped ? .zero : player.position
        let task = Task { try await self.prepare(at: position, request: id) }
        preparation = task

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }

            if requestID == id {
                preparation = nil
            }
        } catch {
            guard requestID == id else { throw CancellationError() }

            let description = (error as? MPVHTTPMediaServer.ServerError)?.message ?? error.localizedDescription
            let failure = (error as? MPVPlayerError) ?? .externalPlaybackFailed(description)

            if !(error is CancellationError) {
                lastError = failure
            }

            invalidate(restore: true)

            if error is CancellationError {
                throw error
            }

            throw failure
        }
    }

    /// Returns playback to mpv at the current position, preserving whether playback is paused.
    public func stop() {
        routeRequestID = UUID()
        routePreparation?.cancel()
        routePreparation = nil
        refresh()
        invalidate(restore: true)
    }

    #if os(iOS)
    func observeAirPlayRoutes() {
        guard routeObserver == nil else { return }

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?
                    .updateAirPlayRoute(isSelected: AVAudioSession.sharedInstance()
                        .currentRoute
                        .outputs
                        .contains { $0.portType == .airPlay })
            }
        }
    }

    func prepareForRouteSelection() {
        observeAirPlayRoutes()
        guard player?.configuration.audio.audioSession == .automatic else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            try session.setActive(true)
        } catch {
            lastError = .externalPlaybackFailed(error.localizedDescription)
        }
    }
    #endif

    // Both route changes and picker dismissal can report the same selection.
    // Handle them together so each selection starts at most one preparation task.
    func updateAirPlayRoute(isSelected: Bool, retry: Bool = false) {
        let changed = airPlayRouteSelected != isSelected

        airPlayRouteSelected = isSelected

        guard isSelected else {
            if changed {
                stop()
            }

            return
        }
        guard changed || retry, !controlsPlayback, routePreparation == nil,
              let source = player?.mediaInformation.sourceURL, player?.mediaInformation.tracks.isEmpty == false else { return }

        let id = UUID()
        routeRequestID = id

        routePreparation = Task { [weak self] in
            guard let self else { return }

            defer {
                if self.routeRequestID == id {
                    self.routePreparation = nil
                }
            }

            guard !Task.isCancelled, self.routeRequestID == id,
                  self.player?.mediaInformation.sourceURL == source else { return }

            do { try await self.start() } catch {
                // start() already records the error and restores local playback.
            }
        }
    }

    func invalidate(restore: Bool) {
        let wasControlling = controlsPlayback

        requestID = UUID()
        seekID = UUID()
        preparation?.cancel()
        preparation = nil
        monitoring?.cancel()
        monitoring = nil
        systemPlayer.pause()
        systemPlayer.replaceCurrentItem(with: nil)

        if let stream {
            Task { await stream.stop() }
        }

        stream = nil
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        isPreparing = false
        isPrepared = false
        isActive = false
        preparationPlan = nil
        isSeeking = false

        if wasControlling, restore {
            player?.resumeAfterExternalPlayback(paused: desiredPaused)
        }
    }

    func setPlaying(_ playing: Bool) {
        desiredPaused = !playing

        if let player, isPreparing {
            player.updateExternalPlayback(
                position: player.position,
                duration: sourceDuration,
                seekable: sourceIsSeekable,
                paused: desiredPaused,
                state: player.state
            )
        }

        guard isPrepared, !isSeeking else { return }

        if playing {
            systemPlayer.playImmediately(atRate: Float(player?.playbackRate ?? 1))
        } else {
            systemPlayer.pause()
        }

        refresh()
    }

    func updateAudio() {
        guard let player else { return }

        systemPlayer.volume = Float(player.volume / 100)
        systemPlayer.isMuted = player.isMuted

        if isPrepared, !desiredPaused, !isSeeking {
            systemPlayer.rate = Float(player.playbackRate)
        }
    }

    func seek(to position: Duration) {
        guard let player, sourceIsSeekable else { return }

        let target = sourceDuration > .zero ? clamped(position, to: .zero ... sourceDuration) : position.clampPositiveOrZero
        let seconds = target.seconds - (stream?.startTime.seconds ?? 0) + timelineOrigin

        let inWindow = systemPlayer.currentItem?.seekableTimeRanges.contains {
            CMTimeRangeContainsTime($0.timeRangeValue, time: CMTime(seconds: seconds, preferredTimescale: 600))
        } ?? false

        if isPreparing || (stream != nil && !inWindow) {
            restart(at: target)
            return
        }

        isSeeking = true

        let id = UUID()
        seekID = id

        player.updateExternalPlayback(
            position: target,
            duration: sourceDuration,
            seekable: sourceIsSeekable,
            paused: desiredPaused,
            state: .seeking
        )

        systemPlayer
            .seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] finished in
                Task { @MainActor in
                    guard let self, self.seekID == id, self.isPrepared else { return }

                    self.isSeeking = false

                    if !finished {
                        self.lastError = .externalPlaybackFailed("The system player could not complete the seek.")
                    }

                    self.setPlaying(!self.desiredPaused)
                }
            }
    }

    private func restart(at position: Duration) {
        let paused = desiredPaused

        invalidate(restore: false)
        desiredPaused = paused
        isPreparing = true

        let id = requestID

        player?.updateExternalPlayback(
            position: position,
            duration: sourceDuration,
            seekable: sourceIsSeekable,
            paused: paused,
            state: .seeking
        )

        preparation = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.prepare(at: position, request: id)

                if self.requestID == id {
                    self.preparation = nil
                }
            } catch {
                guard self.requestID == id else { return }

                let description = (error as? MPVHTTPMediaServer.ServerError)?.message ?? error.localizedDescription
                self.lastError = (error as? MPVPlayerError) ?? .externalPlaybackFailed(description)
                self.invalidate(restore: true)
            }
        }
    }

    private func prepare(at position: Duration, request id: UUID) async throws {
        guard let player, let originalURL = player.mediaInformation.sourceURL else { throw CancellationError() }

        await player.pauseForExternalPlayback()
        try validate(id)
        #if os(iOS) || os(tvOS)
        if player.configuration.audio.audioSession == .automatic {
            let session = AVAudioSession.sharedInstance()
            #if os(iOS)
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            #else
            try session.setCategory(.playback, mode: .moviePlayback)
            #endif
            try session.setActive(true)
        }
        #endif
        player.updateExternalPlayback(
            position: position,
            duration: sourceDuration,
            seekable: sourceIsSeekable,
            paused: desiredPaused,
            state: .loading
        )

        let candidate = overrideURL ?? originalURL

        if candidate.isFileURL, candidate.startAccessingSecurityScopedResource() {
            securityScopedURL = candidate
        }

        let options = await player.externalPlaybackOptions()

        try validate(id)

        if overrideURL == nil {
            try validateEmbeddedTracks(options)
        }

        let asset = AVURLAsset(url: candidate)
        let direct = try await canPlayDirectly(asset, options: options, isAlternate: overrideURL != nil)

        try validate(id)

        let item: AVPlayerItem

        if direct {
            preparationPlan = .direct
            item = AVPlayerItem(asset: asset)
            timelineOrigin = 0
        } else {
            let stream = try MPVHLSStream(startTime: position)
            self.stream = stream

            let url = try await stream.start(
                source: originalURL,
                packaging: options,
                toneMapHDR: player.mediaInformation.hdr.isHDRContent || player.dolbyVisionStatus.sourceProfile != nil,
                onPreparation: { [weak self] plan in
                    guard let self, self.requestID == id else { return }

                    self.preparationPlan = plan
                }
            )

            try validate(id)
            item = AVPlayerItem(url: url)
        }

        item.preferredForwardBufferDuration = 6
        systemPlayer.replaceCurrentItem(with: item)
        updateAudio()

        let deadline = ContinuousClock.now + .seconds(60)

        while item.status == .unknown {
            try validate(id)

            guard ContinuousClock.now < deadline
            else { throw MPVPlayerError.externalPlaybackFailed("System playback preparation timed out.") }

            try await Task.sleep(for: .milliseconds(50))
        }

        try validate(id)

        guard item.status == .readyToPlay else {
            throw MPVPlayerError.externalPlaybackFailed(item.error?.localizedDescription ?? "The system player cannot open this media.")
        }

        if stream != nil {
            // The player can become ready before the HLS timeline is available.
            // Wait for its start time because MPEG-TS timestamps may not begin at zero.
            while item.seekableTimeRanges.isEmpty {
                try validate(id)

                guard item.status != .failed, ContinuousClock.now < deadline else {
                    throw MPVPlayerError.externalPlaybackFailed(item.error?.localizedDescription ?? "The HLS timeline is unavailable.")
                }

                try await Task.sleep(for: .milliseconds(50))
            }

            timelineOrigin = item.seekableTimeRanges[0].timeRangeValue.start.seconds
        }

        let target = stream.map { timelineOrigin + max(0, position.seconds - $0.startTime.seconds) } ?? position.seconds

        if target > 0 || stream != nil {
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                item.cancelPendingSeeks()
            }
            defer { timeout.cancel() }

            let finished = await withTaskCancellationHandler {
                await systemPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            } onCancel: {
                item.cancelPendingSeeks()
            }

            try validate(id)
            guard finished else { throw MPVPlayerError.externalPlaybackFailed("The system player could not reach the requested position.") }
        }

        try validate(id)
        isPreparing = false
        isPrepared = true
        setPlaying(!desiredPaused)

        monitoring = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()

                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    private func refresh() {
        guard isPrepared, !isSeeking, let player, let item = systemPlayer.currentItem else { return }

        if item.status == .failed || stream?.failure != nil {
            lastError = .externalPlaybackFailed(stream?.failure ?? item.error?.localizedDescription ?? "External playback failed.")
            invalidate(restore: true)
            return
        }

        isActive = systemPlayer.isExternalPlaybackActive

        let rawPosition = systemPlayer.currentTime().seconds - timelineOrigin + (stream?.startTime.seconds ?? 0)
        let position = Duration(mpvSeconds: max(rawPosition, 0)) ?? player.position
        stream?.updatePlaybackPosition(position)

        if stream == nil, let value = Duration(mpvSeconds: item.duration.seconds), value > .zero {
            sourceDuration = value
            sourceIsSeekable = !item.seekableTimeRanges.isEmpty
        }

        let ended = sourceDuration > .zero && position >= sourceDuration - .milliseconds(100)
        let state: MPVPlaybackState

        switch systemPlayer.timeControlStatus {
        case .paused:
            desiredPaused = true
            state = ended ? .ended : .paused

        case .waitingToPlayAtSpecifiedRate:
            state = .buffering

        case .playing:
            desiredPaused = false
            state = .playing

        @unknown default:
            state = .buffering
        }

        player.updateExternalPlayback(
            position: position,
            duration: sourceDuration,
            seekable: sourceIsSeekable,
            paused: desiredPaused,
            state: state
        )
    }

    private func validate(_ id: UUID) throws {
        try Task.checkCancellation()
        guard requestID == id else { throw CancellationError() }
    }

    private func loadedPlayer() throws -> MPVPlayer {
        guard let player, player.mediaInformation.sourceURL != nil, !player.mediaInformation.tracks.isEmpty else {
            throw MPVPlayerError.externalPlaybackFailed("Wait for media to load before preparing external playback.")
        }

        return player
    }

    private func validateEmbeddedTracks(_ options: MPVMediaPackagingOptions) throws {
        guard !options.hasSelectedExternalTracks else {
            throw MPVPlayerError
                .externalPlaybackFailed("Select embedded tracks before preparing AirPlay. External track files are not supported.")
        }
    }

    private func canPlayDirectly(_ asset: AVURLAsset, options: MPVMediaPackagingOptions, isAlternate: Bool) async throws -> Bool {
        if !isAlternate,
           options.requiresRenderer || options.mpv.keys.contains(where: { MPVMediaPackagingOptions.sourceOptionNames.contains($0) })
        {
            try Task.checkCancellation()
            return false
        }

        let timeout = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            asset.cancelLoading()
        }
        defer { timeout.cancel() }

        let compatibility = try? await withTaskCancellationHandler {
            try await asset.load(.isPlayable, .isCompatibleWithAirPlayVideo)
        } onCancel: {
            asset.cancelLoading()
        }

        try Task.checkCancellation()

        let direct = compatibility?.0 == true && compatibility?.1 == true

        if isAlternate, !direct {
            throw MPVPlayerError.externalPlaybackFailed("The alternate URL must provide media compatible with AirPlay.")
        }

        return direct
    }
}
