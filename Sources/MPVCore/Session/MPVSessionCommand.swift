import Foundation

/// Typed playback operations shared by platform players.
public enum MPVSessionCommand: Sendable {

    /// Replaces the source. Omitted options use the session defaults.
    /// Audio-only media starts without a surface. Enabled video waits for one.
    case load(URL, playAutomatically: Bool? = nil, startTime: Duration? = nil)
    /// Starts or resumes playback, including replay after stop.
    case play
    /// Pauses without discarding the user's source.
    case pause
    /// Toggles the current playback intention.
    case togglePlayback
    /// Stops playback and releases native decode and rendering resources.
    case stop
    /// Seeks to an absolute position.
    case seek(to: Duration)
    /// Seeks relative to the current or pending position.
    case seekByOffset(Duration)
    /// Steps one video frame forward and pauses playback.
    case stepForward
    /// Steps one video frame backward and pauses playback.
    case stepBackward
    /// Changes volume, clamped to the supported range.
    case setVolume(Double)
    /// Changes the mute setting.
    case setMuted(Bool)
    /// Toggles mute against the latest serialized session state.
    case toggleMute
    /// Changes the playback speed.
    case setPlaybackRate(Double)
    /// Selects a video, audio, or primary subtitle track.
    case selectTrack(MPVMediaTrackIdentifier)
    /// Selects or disables the specified subtitle role.
    case selectSubtitle(MPVMediaTrackIdentifier?, for: MPVSubtitleRole = .primary)
    /// Disables one track type.
    case disableTrack(MPVTrackType)
    /// Enables or disables text subtitle interception and delivery.
    case setTextSubtitleInterceptionEnabled(Bool)
    /// Enables or disables detailed diagnostics sampling.
    case setDiagnosticsEnabled(Bool)
    /// Sets a caller-owned native property.
    case setProperty(String, to: String)
    /// Executes a validated native command.
    case executeCommand(String, arguments: [String] = [])
    /// Adds an external track, optionally selecting it in a subtitle role.
    case loadExternalTrack(URL, type: MPVTrackType, select: Bool = true, subtitleRole: MPVSubtitleRole? = nil)
    /// Clears the last recoverable error without changing a failed lifecycle.
    case clearLastError
}

/// Identifies one accepted operation and the load generation it addresses.
public struct MPVSessionOperation: Equatable, Sendable {

    /// Monotonically increasing operation identity within this session.
    public let id: UInt64
    /// The load identity after this operation is submitted.
    public let generation: UInt64
}

public extension MPVSession {

    /// The most recent copied playback state.
    ///
    /// Access waits for previously enqueued session work to finish.
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

    /// Submits a command and returns its operation identifier and load generation.
    ///
    /// Submission waits for previously enqueued session work. Acceptance does not
    /// confirm native completion. Observe ``makeEventStream()`` for results and playback errors.
    ///
    /// - Throws: ``MPVPlayerError/clientUnavailable`` if the session is closed.
    @discardableResult
    func send(_ command: MPVSessionCommand) throws -> MPVSessionOperation {
        try queue.sync {
            guard !isClosed else { throw MPVPlayerError.clientUnavailable }

            let id = nextOperationID

            nextOperationID &+= 1

            var generation = currentGeneration

            switch command {
            case let .load(url, playAutomatically, startTime):
                generation &+= 1
                load(url, playAutomatically: playAutomatically, startTime: startTime, generation: generation)

            case .play: play()

            case .pause: pause()

            case .togglePlayback: togglePlayback()

            case .stop:
                generation &+= 1
                stop(generation: generation)

            case let .seek(time): seek(to: time)

            case let .seekByOffset(time): seek(by: time)

            case .stepForward: frameStep(backward: false)

            case .stepBackward: frameStep(backward: true)

            case let .setVolume(value): setVolume(value)

            case let .setMuted(value): setMuted(value)

            case .toggleMute: toggleMute()

            case let .setPlaybackRate(value): setPlaybackRate(value)

            case let .selectTrack(value): selectTrack(value)

            case let .selectSubtitle(value, role): selectSubtitle(value, for: role)

            case let .disableTrack(value): disableTrack(value)

            case let .setTextSubtitleInterceptionEnabled(value): setTextSubtitleInterceptionEnabled(value)

            case let .setDiagnosticsEnabled(value): setDiagnosticsEnabled(value)

            case let .setProperty(name, value): performPropertySet(name, value: value)

            case let .executeCommand(name, arguments):
                performCommand(name, arguments: arguments)

            case let .loadExternalTrack(url, type, select, role):
                loadExternalTrack(url, type: type, select: select, subtitleRole: role ?? .primary)

            case .clearLastError:
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
    @discardableResult
    func requestVideoFeatures(_ features: Set<MPVVideoFeature>) -> MPVVideoFeatureRequestResult {
        queue.sync {
            guard !isClosed else { return latestSnapshot.videoFeatureCapabilities.requestResult(for: features) }

            latestSnapshot.requestedVideoFeatures = (latestSnapshot.requestedVideoFeatures ?? []).union(features)
            record(.state(latestSnapshot.state))

            return latestSnapshot.videoFeatureCapabilities.requestResult(for: latestSnapshot.requestedVideoFeatures ?? features)
        }
    }

    /// Creates a stream of complete playback states and log messages in delivery order.
    ///
    /// Each stream starts with the current state and buffers all subsequent events.
    /// Canceling iteration removes the observer. Closing the session finishes every stream.
    /// A stream created after closing yields the final state and then finishes.
    func makeEventStream() -> AsyncStream<MPVSessionEvent> {
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
