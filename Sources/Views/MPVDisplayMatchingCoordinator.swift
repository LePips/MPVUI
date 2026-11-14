import Foundation
import MPVCore

/// Testable policy independent of HDMI hardware or notification timing.
struct MPVDisplayMatchingState {

    enum Action: Equatable {

        case keep
        case clear
        case apply(MPVDisplayMatchingContent)
    }

    private(set) var content: MPVDisplayMatchingContent?
    private(set) var mediaGeneration: UInt64?

    mutating func ownershipDidChange() {
        // Generations are player-local. A different player may have the same
        // numeric generation, including when its next item has no video.
        mediaGeneration = nil
    }

    mutating func update(
        candidate: MPVDisplayMatchingContent?,
        mediaGeneration: UInt64,
        playbackState: MPVPlaybackState,
        matchingEnabled: Bool,
        isActive: Bool,
        modeSwitchInProgress: Bool,
        hasUnsupportedCadence: Bool = false,
        isPreparing: Bool = false
    ) -> Action {
        guard isActive,
              matchingEnabled,
              playbackState != .idle,
              !playbackState.isTerminal
        else {
            return clear()
        }

        // The display can be blank for seconds. Do not restart a mode switch,
        // or momentarily restore the UI mode for seeks or next-item loading.
        guard !modeSwitchInProgress,
              isPreparing || playbackState != .loading,
              playbackState != .seeking,
              isPreparing || playbackState != .buffering
        else {
            return .keep
        }

        // A known cadence outside the platform hint range must release an old
        // preference. Missing same-item metadata can still retain it below.
        guard !hasUnsupportedCadence else {
            return clear()
        }
        guard let candidate else {
            // Retain a known format during same-item metadata refreshes; an
            // audio-only or unknown-format next item must release the old mode.
            return self.mediaGeneration == mediaGeneration ? .keep : clear()
        }

        self.mediaGeneration = mediaGeneration
        guard content != candidate else {
            return .keep
        }

        content = candidate

        return .apply(candidate)
    }

    private mutating func clear() -> Action {
        mediaGeneration = nil
        guard content != nil else { return .keep }

        content = nil

        return .clear
    }
}

/// A platform's display-mode matching endpoint. Content, ownership, and media
/// lifecycle stay shared. The endpoint translates requests and OS events.
@MainActor
protocol MPVDisplayMatchingTarget: AnyObject {

    /// Stable across wrappers for the same physical/window-owned endpoint.
    var identity: ObjectIdentifier { get }

    var isMatchingEnabled: Bool { get }

    var isModeSwitchInProgress: Bool { get }

    /// Returns `false` when the platform cannot represent a nonempty hint.
    /// A `nil` hint releases this player's preference.
    @discardableResult
    func apply(_ content: MPVDisplayMatchingContent?) -> Bool

    /// The returned closure cancels observation. The coordinator owns its lifetime.
    func observeChanges(_ onChange: @escaping @MainActor () -> Void) -> @MainActor () -> Void
}

/// One active surface owns each window's display criteria. An old surface can
/// neither clear nor reclaim a successor's criteria merely by being detached.
@MainActor
final class MPVDisplayMatchingCoordinator {

    private struct Input {

        let media: MPVMediaInformation
        let mediaGeneration: UInt64
        let playbackRate: Double
        let state: MPVPlaybackState
        let outputUsesHDR: Bool
        let videoOutput: MPVPlayerConfiguration.VideoOutput
        let dolbyVisionStatus: MPVDolbyVisionStatus
        let isPaused: Bool
    }

    private struct Owner {

        let id: UUID
        weak var value: MPVDisplayMatchingCoordinator?
    }

    private final class Preparation {

        let id: UUID
        let generation: UInt64
        let forAutoplay: Bool
        let continuation: CheckedContinuation<MPVDisplayMatchingPreparationResult, Never>
        var timeoutTask: Task<Void, Never>?
        var settlingTask: Task<Void, Never>?
        var settlingContent: MPVDisplayMatchingContent?
        var observedSwitch = false
        var deadlinePassed = false

        init(
            id: UUID,
            generation: UInt64,
            forAutoplay: Bool,
            continuation: CheckedContinuation<MPVDisplayMatchingPreparationResult, Never>
        ) {
            self.id = id
            self.generation = generation
            self.forAutoplay = forAutoplay
            self.continuation = continuation
        }
    }

    private static var owners: [ObjectIdentifier: Owner] = [:]
    private(set) var isDisplayModeSwitchInProgress = false
    var displayModeSwitchDidChange: (@MainActor (Bool) -> Void)?
    private let ownershipID = UUID()

    @MPVMainActorResource
    private var target: (any MPVDisplayMatchingTarget)?
    private var cancelObservation: (@MainActor () -> Void)?
    private var matchingState = MPVDisplayMatchingState()
    private var latestInput: Input?
    private var preparation: Preparation?
    private let settlingInterval: Duration

    var content: MPVDisplayMatchingContent? {
        matchingState.content
    }

    init(settlingInterval: Duration = .milliseconds(500)) {
        self.settlingInterval = settlingInterval
    }

    nonisolated deinit {
        performMainActorCleanup { [_target, ownershipID, cancelObservation, isDisplayModeSwitchInProgress, displayModeSwitchDidChange] in
            // Weak references are already nil during deinit. A stable ownership
            // token also prevents deferred cleanup from clearing a successor.
            if let target = _target.wrappedValue, Self.owners[target.identity]?.id == ownershipID {
                Self.owners.removeValue(forKey: target.identity)
                target.apply(nil)
            }
            cancelObservation?()
            if isDisplayModeSwitchInProgress {
                displayModeSwitchDidChange?(false)
            }
            _target.release()
        }
    }

    func update(
        target: (any MPVDisplayMatchingTarget)?,
        media: MPVMediaInformation,
        mediaGeneration: UInt64,
        playbackRate: Double,
        state: MPVPlaybackState,
        isActive: Bool,
        outputUsesHDR: Bool,
        videoOutput: MPVPlayerConfiguration.VideoOutput,
        dolbyVisionStatus: MPVDolbyVisionStatus,
        isPaused: Bool? = nil
    ) {
        guard isActive, let target else {
            detach()
            return
        }

        attach(to: target)

        latestInput = Input(
            media: media,
            mediaGeneration: mediaGeneration,
            playbackRate: playbackRate,
            state: state,
            outputUsesHDR: outputUsesHDR,
            videoOutput: videoOutput,
            dolbyVisionStatus: dolbyVisionStatus,
            isPaused: isPaused ?? (state == .paused)
        )

        refresh()
    }

    func detach() {
        finishPreparation(.cancelled)
        if let target, Self.owners[target.identity]?.value === self {
            Self.owners.removeValue(forKey: target.identity)
            target.apply(nil)
        }

        releaseObservations()
        target = nil
        matchingState = MPVDisplayMatchingState()
        latestInput = nil
        setModeSwitchInProgress(false)
    }

    /// Waits without changing playback intent. Loading metadata may supply the
    /// initial hint even while the normal lifecycle still reports buffering.
    func prepare(timeout: Duration, forAutoplay: Bool = false) async -> MPVDisplayMatchingPreparationResult {
        guard !Task.isCancelled else { return .cancelled }
        guard let target, let input = latestInput,
              input.state != .idle, !input.state.isTerminal
        else { return .unavailable }
        guard target.isMatchingEnabled else { return .disabled }
        guard forAutoplay || input.isPaused else { return .requiresPausedPlayback }
        guard timeout > .zero else { return .timedOut }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                finishPreparation(.cancelled)
                let pending = Preparation(id: id, generation: input.mediaGeneration, forAutoplay: forAutoplay, continuation: continuation)
                preparation = pending
                pending.timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let self, let pending = self.preparation, pending.id == id else { return }

                    // Missing metadata must not stall autoplay indefinitely.
                    // A reported HDMI switch still has to end and settle.
                    if pending.forAutoplay, self.isDisplayModeSwitchInProgress || pending.settlingTask != nil {
                        pending.deadlinePassed = true
                    } else {
                        self.finishPreparation(.timedOut)
                    }
                }
                refresh()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.preparation?.id == id else { return }

                self?.finishPreparation(.cancelled)
            }
        }
    }

    private func attach(to target: any MPVDisplayMatchingTarget) {
        guard self.target?.identity != target.identity
            || Self.owners[target.identity]?.value !== self
        else { return }

        detach()

        let key = target.identity

        // Relinquish the retiring owner's notifications without clearing the
        // active criteria. This prevents an unnecessary intermediate blackout.
        if let previous = Self.owners[key]?.value {
            previous.finishPreparation(.cancelled)
            previous.releaseObservations()
            previous.target = nil
            previous.latestInput = nil
            matchingState = previous.matchingState
            matchingState.ownershipDidChange()
            previous.matchingState = MPVDisplayMatchingState()
            previous.setModeSwitchInProgress(false)
        }

        self.target = target
        Self.owners[key] = Owner(id: ownershipID, value: self)

        cancelObservation = target.observeChanges { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        guard let target,
              let input = latestInput,
              Self.owners[target.identity]?.value === self
        else {
            return
        }

        setModeSwitchInProgress(target.isModeSwitchInProgress)

        if let preparation {
            if input.mediaGeneration != preparation.generation || input.state == .idle || input.state.isTerminal {
                finishPreparation(.cancelled)
            } else if !preparation.forAutoplay, !input.isPaused {
                finishPreparation(.requiresPausedPlayback)
            } else if !target.isMatchingEnabled {
                finishPreparation(.disabled)
            }
        }

        let candidate = MPVDisplayMatchingContent(
            media: input.media,
            playbackRate: input.playbackRate,
            outputUsesHDR: input.outputUsesHDR,
            videoOutput: input.videoOutput,
            dolbyVisionStatus: input.dolbyVisionStatus
        )
        let hasUnsupportedCadence = input.media.framesPerSecond != nil
            && MPVDisplayMatchingContent.refreshRate(
                for: input.media.framesPerSecond,
                playbackRate: input.playbackRate
            ) == nil

        let action = matchingState.update(
            candidate: candidate,
            mediaGeneration: input.mediaGeneration,
            playbackState: input.state,
            matchingEnabled: target.isMatchingEnabled,
            isActive: true,
            modeSwitchInProgress: isDisplayModeSwitchInProgress,
            hasUnsupportedCadence: hasUnsupportedCadence,
            isPreparing: preparation != nil
        )

        switch action {
        case .keep:
            break
        case .clear:
            target.apply(nil)
        case let .apply(content):
            guard target.apply(content) else {
                matchingState = MPVDisplayMatchingState()
                target.apply(nil)
                finishPreparation(.unavailable)
                return
            }
        }

        if hasUnsupportedCadence, !isDisplayModeSwitchInProgress {
            finishPreparation(.unavailable)
        }
        updatePreparation()
    }

    private func updatePreparation() {
        guard let preparation, let target else { return }

        // Read again after apply: setting criteria can start a switch synchronously.
        setModeSwitchInProgress(target.isModeSwitchInProgress)
        if isDisplayModeSwitchInProgress {
            preparation.observedSwitch = true
            preparation.settlingTask?.cancel()
            preparation.settlingTask = nil
            preparation.settlingContent = nil
            return
        }

        guard let content = matchingState.content,
              matchingState.mediaGeneration == preparation.generation,
              latestInput?.state != .seeking
        else {
            preparation.settlingTask?.cancel()
            preparation.settlingTask = nil
            preparation.settlingContent = nil
            if preparation.deadlinePassed {
                finishPreparation(.timedOut)
            }
            return
        }
        guard preparation.settlingContent != content else { return }

        preparation.settlingTask?.cancel()
        preparation.settlingContent = content
        let id = preparation.id
        preparation.settlingTask = Task { [weak self, settlingInterval] in
            do { try await Task.sleep(for: settlingInterval) } catch { return }
            guard let self, self.preparation?.id == id else { return }

            self.refresh()
            guard let current = self.preparation,
                  current.id == id,
                  current.settlingContent == content,
                  !self.isDisplayModeSwitchInProgress
            else { return }

            self.finishPreparation(current.observedSwitch ? .switchCompleted : .noSwitchObserved)
        }
    }

    private func finishPreparation(_ result: MPVDisplayMatchingPreparationResult) {
        guard let pending = preparation else { return }

        preparation = nil
        pending.timeoutTask?.cancel()
        pending.settlingTask?.cancel()
        pending.continuation.resume(returning: result)
    }

    private func setModeSwitchInProgress(_ value: Bool) {
        guard isDisplayModeSwitchInProgress != value else { return }

        isDisplayModeSwitchInProgress = value
        displayModeSwitchDidChange?(value)
    }

    private func releaseObservations() {
        cancelObservation?()
        cancelObservation = nil
    }
}
