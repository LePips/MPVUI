import Foundation

/// Typed playback operations shared by platform players.
public enum MPVSessionCommand: Sendable {

    /// Replaces the source; omitted options use the session defaults.
    case load(URL, autoPlay: Bool? = nil, startTime: Duration? = nil)
    /// Starts or resumes playback, including replay after stop.
    case play
    /// Pauses without discarding the user's source.
    case pause
    /// Toggles the current playback intention.
    case togglePlayback
    /// Stops playback and releases native decode and rendering resources.
    case stop
    /// Seeks to an absolute position.
    case seek(Duration)
    /// Seeks relative to the current or pending position.
    case seekRelative(Duration)
    /// Advances one video frame, optionally backwards.
    case frameStep(backward: Bool)
    /// Changes volume, clamped to the supported range.
    case volume(Double)
    /// Changes the mute setting.
    case mute(Bool)
    /// Toggles mute against the latest serialized session state.
    case toggleMute
    /// Changes the playback speed.
    case playbackRate(Double)
    /// Selects a video, audio, or primary subtitle track.
    case selectTrack(MPVMediaTrackIdentifier)
    /// Selects or disables the specified subtitle role.
    case selectSubtitle(MPVMediaTrackIdentifier?, role: MPVSubtitleRole)
    /// Disables one track type.
    case disableTrack(MPVTrackType)
    /// Enables semantic text subtitle delivery.
    case interceptTextSubtitles(Bool)
    /// Enables detailed diagnostic sampling.
    case diagnostics(Bool)
    /// Sets a caller-owned native property.
    case property(String, String)
    /// Executes a validated native command.
    case native([String])
    /// Adds an external track, optionally selecting it in a subtitle role.
    case externalTrack(URL, type: MPVTrackType, select: Bool, role: MPVSubtitleRole?)
    /// Clears the last recoverable error without changing a failed lifecycle.
    case clearError
}

/// Identifies one accepted operation and the load generation it addresses.
public struct MPVSessionOperation: Equatable, Sendable {

    /// Monotonically increasing operation identity within this session.
    public let id: UInt64
    /// The load identity after this operation is submitted.
    public let generation: UInt64
}

public extension MPVSession {

    /// Returns the most recent copied state after pending native operations finish.
    var snapshot: MPVSessionSnapshot {
        queue.sync { latestSnapshot }
    }

    package func closeImmediately() {
        guard !isClosed else { return }
        isClosed = true
        latestSnapshot.requestedVideoFeatures = nil
        eventDrainSource.cancel()
        destroyHandle(preservePlayback: false)
        if !latestSnapshot.isClosed {
            record(.state(.stopped))
        }
        renderTarget = nil
        for observer in observers.values {
            observer.finish()
        }
        observers.removeAll()
        updateContinuation.finish()
    }

    /// Enqueues a command and returns its stable identity. Native work remains
    /// serialized independently of the caller's UI executor.
    @discardableResult
    func send(_ command: MPVSessionCommand) throws -> MPVSessionOperation {
        try queue.sync {
            guard !isClosed else { throw MPVPlayerError.clientUnavailable }
            let id = nextOperationID
            nextOperationID &+= 1
            var generation = currentGeneration
            switch command {
            case let .load(url, autoPlay, startTime):
                generation &+= 1
                load(url, autoPlay: autoPlay, startTime: startTime, generation: generation)
            case .play: play()
            case .pause: pause()
            case .togglePlayback: togglePlayback()
            case .stop:
                generation &+= 1
                stop(generation: generation)
            case let .seek(time): seek(to: time)
            case let .seekRelative(time): seek(by: time)
            case let .frameStep(backward): frameStep(backward: backward)
            case let .volume(value): setVolume(value)
            case let .mute(value): setMuted(value)
            case .toggleMute: toggleMute()
            case let .playbackRate(value): setPlaybackRate(value)
            case let .selectTrack(value): selectTrack(value)
            case let .selectSubtitle(value, role): selectSubtitle(value, for: role)
            case let .disableTrack(value): disableTrack(value)
            case let .interceptTextSubtitles(value): setTextSubtitleInterceptionEnabled(value)
            case let .diagnostics(value): setDiagnosticsEnabled(value)
            case let .property(name, value): performPropertySet(name, value: value)
            case let .native(arguments):
                if let name = arguments.first {
                    performCommand(name, arguments: Array(arguments.dropFirst()))
                }
            case let .externalTrack(url, type, select, role):
                loadExternalTrack(url, type: type, select: select, subtitleRole: role ?? .primary)
            case .clearError:
                queue.async { [weak self] in
                    guard let self, self.latestSnapshot.state.error == nil else { return }
                    self.latestSnapshot.error = nil
                    self.record(.state(self.latestSnapshot.state))
                }
            }
            return MPVSessionOperation(id: id, generation: generation)
        }
    }

    /// Accumulates renderer requests for the current source without changing its output.
    func requestVideoFeatures(_ features: Set<MPVVideoFeature>) -> MPVVideoFeatureRequestResult {
        queue.sync {
            guard !isClosed else { return latestSnapshot.videoFeatureCapabilities.resolve(features) }
            latestSnapshot.requestedVideoFeatures = (latestSnapshot.requestedVideoFeatures ?? []).union(features)
            record(.state(latestSnapshot.state))
            return latestSnapshot.videoFeatureCapabilities.resolve(latestSnapshot.requestedVideoFeatures ?? features)
        }
    }

    /// Subscribes to complete ordered states and logs, starting with the current state.
    /// Cancelling iteration removes the observer; closing finishes every stream.
    func events() -> AsyncStream<MPVSessionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MPVSessionEvent>.makeStream()
        continuation.onTermination = { [weak self] _ in
            self?.queue.async { [weak self] in self?.observers.removeValue(forKey: id) }
        }
        queue.sync {
            continuation.yield(.snapshot(latestSnapshot))
            if isClosed {
                continuation.finish()
            } else {
                observers[id] = continuation
            }
        }
        return stream
    }

    /// Permanently closes the session after detaching native notification sources.
    /// Repeated calls are harmless, and further commands are rejected.
    func close() {
        shutdownSynchronously()
    }
}
