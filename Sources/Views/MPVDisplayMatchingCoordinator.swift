import Foundation

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
        modeSwitchInProgress: Bool
    ) -> Action {
        guard isActive, matchingEnabled,
              playbackState != .idle, !playbackState.isTerminal
        else {
            return clear()
        }

        // The display can be blank for seconds. Do not restart a mode switch,
        // or momentarily restore the UI mode for seeks or next-item loading.
        guard !modeSwitchInProgress,
              playbackState != .loading,
              playbackState != .seeking,
              playbackState != .buffering
        else { return .keep }

        guard let candidate else {
            // Retain a known format during same-item metadata refreshes; an
            // audio-only or unknown-format next item must release the old mode.
            return self.mediaGeneration == mediaGeneration ? .keep : clear()
        }
        self.mediaGeneration = mediaGeneration
        guard content != candidate else { return .keep }
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
/// lifecycle stay shared; the endpoint translates requests and OS events.
@MainActor
protocol MPVDisplayMatchingTarget: AnyObject {
    /// Stable across wrappers for the same physical/window-owned endpoint.
    var identity: ObjectIdentifier { get }
    var isMatchingEnabled: Bool { get }
    var isModeSwitchInProgress: Bool { get }
    /// Returns false when a non-nil hint cannot be represented by the platform.
    /// A nil hint releases this player's preference.
    @discardableResult
    func apply(_ content: MPVDisplayMatchingContent?) -> Bool
    /// The returned closure cancels observation. The coordinator owns its lifetime.
    func observeChanges(_ onChange: @escaping @MainActor () -> Void) -> @MainActor () -> Void
}

/// One active surface owns each window's display criteria. An old surface can
/// neither clear nor reclaim a successor's criteria merely by being detached.
@MainActor
final class MPVDisplayMatchingCoordinator {
    private static var owners: [ObjectIdentifier: WeakBox<MPVDisplayMatchingCoordinator>] = [:]

    private var target: (any MPVDisplayMatchingTarget)?
    private var cancelObservation: (@MainActor () -> Void)?
    private var matchingState = MPVDisplayMatchingState()
    var content: MPVDisplayMatchingContent? {
        matchingState.content
    }

    private var latestInput: Input?
    private(set) var isDisplayModeSwitchInProgress = false
    var displayModeSwitchDidChange: ((Bool) -> Void)?

    private struct Input {
        let media: MPVMediaInformation
        let mediaGeneration: UInt64
        let state: MPVPlaybackState
        let outputUsesHDR: Bool
        let videoOutput: MPVPlayerConfiguration.VideoOutput
        let dolbyVisionStatus: MPVDolbyVisionStatus
    }

    func update(
        target: (any MPVDisplayMatchingTarget)?,
        media: MPVMediaInformation,
        mediaGeneration: UInt64,
        state: MPVPlaybackState,
        isActive: Bool,
        outputUsesHDR: Bool,
        videoOutput: MPVPlayerConfiguration.VideoOutput,
        dolbyVisionStatus: MPVDolbyVisionStatus
    ) {
        guard isActive, let target else {
            detach()
            return
        }
        attach(to: target)
        latestInput = Input(
            media: media, mediaGeneration: mediaGeneration,
            state: state, outputUsesHDR: outputUsesHDR,
            videoOutput: videoOutput, dolbyVisionStatus: dolbyVisionStatus
        )
        refresh()
    }

    func detach() {
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

    isolated deinit {
        detach()
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
            previous.releaseObservations()
            previous.target = nil
            previous.latestInput = nil
            matchingState = previous.matchingState
            matchingState.ownershipDidChange()
            previous.matchingState = MPVDisplayMatchingState()
            previous.setModeSwitchInProgress(false)
        }
        self.target = target
        Self.owners[key] = WeakBox(self)
        cancelObservation = target.observeChanges { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        guard let target, let input = latestInput,
              Self.owners[target.identity]?.value === self
        else { return }
        setModeSwitchInProgress(target.isModeSwitchInProgress)
        let candidate = MPVDisplayMatchingContent(
            media: input.media, outputUsesHDR: input.outputUsesHDR,
            videoOutput: input.videoOutput, dolbyVisionStatus: input.dolbyVisionStatus
        )
        let action = matchingState.update(
            candidate: candidate,
            mediaGeneration: input.mediaGeneration,
            playbackState: input.state,
            matchingEnabled: target.isMatchingEnabled,
            isActive: true,
            modeSwitchInProgress: isDisplayModeSwitchInProgress
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
                return
            }
        }
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
