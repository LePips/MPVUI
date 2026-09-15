#if os(iOS) && !targetEnvironment(macCatalyst)
import AVKit
import CoreMedia
import Foundation

/// AVKit transport and presentation coordinator for the application-owned
/// layer fed directly by mpv's AVFoundation VO. No frames are captured here.
@MainActor
final class MPVSampleBufferPictureInPictureController: NSObject {
    struct Snapshot: Equatable {
        var isSupported = false
        var isPossible = false
        var isActive = false
        var isStarting = false
        var isStopping = false
        var isSuspended = false
        var renderSize = CGSize.zero
        var lastError: MPVPlayerError?
    }

    private(set) var snapshot = Snapshot()

    var allowsAutomaticStartFromInline = false {
        didSet {
            platformController?.canStartPictureInPictureAutomaticallyFromInline =
                allowsAutomaticStartFromInline
        }
    }

    private weak var player: MPVPlayer?
    private let displayLayer: AVSampleBufferDisplayLayer
    private let onStateChange: @MainActor (Snapshot) -> Void
    private let restoreUserInterface: @MainActor () async -> Bool
    private let onRenderingModeChange: @MainActor (Bool) -> Void
    private var platformController: AVPictureInPictureController?
    private var observations: [NSKeyValueObservation] = []
    private var isInvalidated = false
    private var isRenderingInPictureInPicture = false
    private var stopRequested = false
    private var startupTask: Task<Void, Never>?
    private var requestTasks: [UUID: Task<Void, Never>] = [:]
    private var requestTimeouts: [UUID: Task<Void, Never>] = [:]
    private var pendingSkips: [UUID: () -> Void] = [:]
    private var latestSkipID: UUID?
    private var pendingSkipTarget: Duration?
    private var pendingRestorations: [UUID: (Bool) -> Void] = [:]
    private var lastPlaybackState: PlaybackSnapshot?
    private var lastPublishedSnapshot: Snapshot?

    private struct PlaybackSnapshot: Equatable {
        let state: MPVPlaybackState
        let duration: Duration
        let isSeekable: Bool
        let isPaused: Bool
        let sourceURL: URL?
    }

    init(
        player: MPVPlayer,
        displayLayer: AVSampleBufferDisplayLayer,
        onStateChange: @escaping @MainActor (Snapshot) -> Void,
        restoreUserInterface: @escaping @MainActor () async -> Bool,
        onRenderingModeChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.player = player
        self.displayLayer = displayLayer
        self.onStateChange = onStateChange
        self.restoreUserInterface = restoreUserInterface
        self.onRenderingModeChange = onRenderingModeChange
        super.init()

        // Do not infer support on Catalyst/macOS/tvOS from API availability.
        // The native frame path also removes the old simulator readback ban.
        snapshot.isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        guard snapshot.isSupported else {
            publish()
            return
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        platformController = controller
        controller.delegate = self
        observations = [
            controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
                [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshPlatformState() }
            },
            controller.observe(\.isPictureInPictureSuspended, options: [.initial, .new]) {
                [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshPlatformState() }
            },
            displayLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) {
                [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshPlatformState() }
            },
        ]
        refreshPlaybackState()
    }

    isolated deinit {
        startupTask?.cancel()
        requestTasks.values.forEach { $0.cancel() }
        requestTimeouts.values.forEach { $0.cancel() }
        pendingSkips.values.forEach { $0() }
        pendingRestorations.values.forEach { $0(false) }
        platformController?.delegate = nil
        platformController?.stopPictureInPicture()
        platformController?.contentSource = nil
        observations.removeAll()
    }

    /// Called from the player's state emissions. Position updates alone do not
    /// invalidate AVKit playback state on every video frame.
    func refreshPlaybackState() {
        guard !isInvalidated, let player else { return }
        let value = PlaybackSnapshot(
            state: player.state,
            duration: player.duration,
            isSeekable: player.isSeekable,
            isPaused: player.isPlaybackPausedForPictureInPicture,
            sourceURL: player.mediaInformation.sourceURL
        )
        if value != lastPlaybackState {
            lastPlaybackState = value
            platformController?.requiresLinearPlayback = !value.isSeekable
            platformController?.invalidatePlaybackState()
        }
        refreshPlatformState()
        switch player.state {
        case .idle, .stopped, .failed:
            stop()
        case .loading, .ready, .playing, .paused, .buffering, .seeking, .ended:
            break
        }
    }

    func start() {
        guard !isInvalidated else { return }
        guard let controller = platformController else {
            fail(.pictureInPictureUnsupported)
            return
        }
        guard !snapshot.isActive, !snapshot.isStarting, !snapshot.isStopping else { return }
        refreshPlatformState()
        guard snapshot.isPossible else {
            fail(.pictureInPictureNotReady)
            return
        }
        prepareToStartPictureInPicture()
        controller.startPictureInPicture()
    }

    func stop() {
        guard !isInvalidated, snapshot.isActive || snapshot.isStarting else { return }
        stopRequested = true
        snapshot.isStopping = true
        publish()
        platformController?.stopPictureInPicture()
    }

    func clearLastError() {
        snapshot.lastError = nil
        publish()
    }

    /// The facade must invalidate before retiring the native output target.
    /// AVKit callbacks are always completed, including in-flight skip/restore.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        startupTask?.cancel()
        startupTask = nil
        requestTasks.values.forEach { $0.cancel() }
        requestTasks.removeAll()
        requestTimeouts.values.forEach { $0.cancel() }
        requestTimeouts.removeAll()
        let skips = pendingSkips.values
        pendingSkips.removeAll()
        latestSkipID = nil
        pendingSkipTarget = nil
        skips.forEach { $0() }
        let restorations = pendingRestorations.values
        pendingRestorations.removeAll()
        restorations.forEach { $0(false) }
        observations.removeAll()
        platformController?.delegate = nil
        platformController?.stopPictureInPicture()
        platformController?.contentSource = nil
        platformController = nil
        setRenderingMode(false)
        snapshot.isPossible = false
        snapshot.isActive = false
        snapshot.isStarting = false
        snapshot.isStopping = false
        snapshot.isSuspended = false
        publish()
    }

    private func playbackTimeRange() -> CMTimeRange {
        guard let player, !isInvalidated else { return .invalid }
        let currentTime = displayLayer.controlTimebase.map(CMTimebaseGetTime) ?? .invalid
        return MPVPictureInPicturePlaybackPolicy.playbackTimeRange(
            hasMedia: player.mediaInformation.sourceURL != nil,
            state: player.state,
            duration: player.duration,
            displayTime: currentTime
        )
    }

    private func refreshPlatformState() {
        guard !isInvalidated, let controller = platformController else { return }
        snapshot.isPossible = controller.isPictureInPicturePossible
            && displayLayer.isReadyForDisplay
            && playbackTimeRange().isValid
        snapshot.isSuspended = controller.isPictureInPictureSuspended
        publish()
    }

    func prepareToStartPictureInPicture() {
        guard !snapshot.isStarting else { return }
        stopRequested = false
        snapshot.lastError = nil
        snapshot.isStarting = true
        setRenderingMode(true)
        publish()
        startupTask?.cancel()
        startupTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.snapshot.isStarting, !self.isInvalidated else { return }
            self.stopRequested = true
            self.platformController?.stopPictureInPicture()
            self.snapshot.isStarting = false
            self.snapshot.isStopping = false
            self.setRenderingMode(false)
            self.fail(.pictureInPictureTimedOut(operation: .start))
        }
    }

    private func setRenderingMode(_ enabled: Bool) {
        guard isRenderingInPictureInPicture != enabled else { return }
        isRenderingInPictureInPicture = enabled
        onRenderingModeChange(enabled)
    }

    private func fail(_ error: MPVPlayerError) {
        snapshot.lastError = error
        publish()
    }

    private func publish() {
        guard lastPublishedSnapshot != snapshot else { return }
        lastPublishedSnapshot = snapshot
        onStateChange(snapshot)
    }

    private func finishSkip(_ id: UUID) {
        if latestSkipID == id {
            latestSkipID = nil
            pendingSkipTarget = nil
        }
        requestTasks.removeValue(forKey: id)?.cancel()
        requestTimeouts.removeValue(forKey: id)?.cancel()
        pendingSkips.removeValue(forKey: id)?()
    }

    private func finishRestoration(_ id: UUID, restored: Bool) {
        requestTasks.removeValue(forKey: id)?.cancel()
        requestTimeouts.removeValue(forKey: id)?.cancel()
        pendingRestorations.removeValue(forKey: id)?(restored)
    }

    func didFailToStartPictureInPicture(error: any Error) {
        guard !isInvalidated else { return }
        startupTask?.cancel()
        startupTask = nil
        snapshot.isStarting = false
        snapshot.isStopping = false
        stopRequested = false
        setRenderingMode(false)
        fail(.pictureInPictureFailed(operation: .start, message: error.localizedDescription))
    }

    func requestInterfaceRestoration(completion: @escaping (Bool) -> Void) {
        guard !isInvalidated else {
            completion(false)
            return
        }
        let id = UUID()
        pendingRestorations[id] = completion
        let restore = restoreUserInterface
        requestTasks[id] = Task { @MainActor [weak self] in
            let restored = await restore()
            self?.finishRestoration(id, restored: restored)
        }
        requestTimeouts[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.finishRestoration(id, restored: false)
        }
    }

    private func waitForDisplayTimeline(player: MPVPlayer, target: Duration) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        // playback-restart precedes AVFoundation's presentation in some VO
        // schedules. Do not complete AVKit's skip until its own clock agrees.
        while !Task.isCancelled, !isInvalidated, start.duration(to: clock.now) < .seconds(2) {
            // An exact endpoint seek can retire the VO at EOF without a new
            // frame or playback-restart. The engine's attributed EOF completes
            // that seek; there is no remaining display clock to converge.
            if player.state == .ended, player.duration > .zero,
               target >= player.duration - .milliseconds(1)
            {
                return true
            }
            if let timebase = displayLayer.controlTimebase {
                let time = CMTimebaseGetTime(timebase)
                let rate = CMTimebaseGetRate(timebase)
                let elapsed = start.duration(to: clock.now).seconds
                let expectedRate = player.isPlaybackPausedForPictureInPicture ? 0 : player.playbackRate
                let tolerance = max(0.25, 2 / max(player.mediaInformation.framesPerSecond ?? 24, 1))
                let positionMatches = time.isNumeric
                    && time.seconds >= target.seconds - tolerance
                    && time.seconds <= target.seconds + elapsed * expectedRate + tolerance
                if positionMatches, abs(rate - expectedRate) < 0.01, displayLayer.isReadyForDisplay {
                    return true
                }
            }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return false
    }
}

extension MPVSampleBufferPictureInPictureController: @MainActor AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard !isInvalidated else { return }
        if stopRequested {
            controller.stopPictureInPicture()
            return
        }
        prepareToStartPictureInPicture()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard !isInvalidated else { return }
        startupTask?.cancel()
        startupTask = nil
        snapshot.isStarting = false
        snapshot.isActive = true
        setRenderingMode(true)
        publish()
        if stopRequested {
            controller.stopPictureInPicture()
        }
    }

    func pictureInPictureControllerWillStopPictureInPicture(_: AVPictureInPictureController) {
        guard !isInvalidated else { return }
        snapshot.isStopping = true
        publish()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
        guard !isInvalidated else { return }
        startupTask?.cancel()
        startupTask = nil
        snapshot.isStarting = false
        snapshot.isActive = false
        snapshot.isStopping = false
        snapshot.isSuspended = false
        stopRequested = false
        setRenderingMode(false)
        refreshPlaybackState()
        publish()
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        didFailToStartPictureInPicture(error: error)
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        requestInterfaceRestoration(completion: completionHandler)
    }
}

extension MPVSampleBufferPictureInPictureController: @MainActor AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_: AVPictureInPictureController, setPlaying playing: Bool) {
        guard !isInvalidated, let player else { return }
        playing ? player.play() : player.pause()
        refreshPlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_: AVPictureInPictureController) -> CMTimeRange {
        playbackTimeRange()
    }

    func pictureInPictureControllerIsPlaybackPaused(_: AVPictureInPictureController) -> Bool {
        player?.isPlaybackPausedForPictureInPicture ?? true
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        didTransitionToRenderSize size: CMVideoDimensions
    ) {
        guard !isInvalidated else { return }
        snapshot.renderSize = CGSize(width: max(0, Int(size.width)), height: max(0, Int(size.height)))
        publish()
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        skipByInterval interval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        requestSkip(by: interval, completion: completionHandler)
    }

    func requestSkip(by interval: CMTime, completion completionHandler: @escaping () -> Void) {
        guard !isInvalidated, let player,
              let target = MPVPictureInPicturePlaybackPolicy.seekTarget(
                  position: pendingSkipTarget ?? player.position,
                  interval: interval,
                  duration: player.duration,
                  isSeekable: player.isSeekable
              )
        else {
            completionHandler()
            return
        }
        let id = UUID()
        latestSkipID = id
        pendingSkipTarget = target
        pendingSkips[id] = completionHandler
        requestTasks[id] = Task { @MainActor [weak self, weak player] in
            if let player {
                var succeeded = await player.seekForPictureInPicture(to: target)
                if succeeded, let self, !Task.isCancelled {
                    succeeded = await self.waitForDisplayTimeline(player: player, target: target)
                }
                if !succeeded, !Task.isCancelled, self?.latestSkipID == id {
                    self?.fail(.pictureInPictureFailed(
                        operation: .seek, message: "The Picture in Picture seek could not be completed."
                    ))
                }
            }
            self?.platformController?.invalidatePlaybackState()
            self?.finishSkip(id)
        }
        requestTimeouts[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, !self.isInvalidated, self.pendingSkips[id] != nil else { return }
            self.fail(.pictureInPictureTimedOut(operation: .seek))
            self.finishSkip(id)
        }
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_: AVPictureInPictureController) -> Bool {
        false
    }
}
#endif
