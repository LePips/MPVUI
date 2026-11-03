import CMPV
import Foundation

public extension MPVSession {

    /// Seeks and waits for playback to restart at the destination, preserving playback intent.
    /// Requests during loading wait for readiness. Seeking after EOF reopens the same source.
    /// A newer seek, source replacement, stop, or task cancellation cancels the wait.
    /// Cancellation does not undo an already accepted native seek.
    ///
    /// - Throws: `MPVPlayerError` if seeking is unavailable, fails, or times out,
    ///   or `CancellationError` if the request is canceled or superseded.
    func seekAndWait(to position: Duration, timeout: Duration = .seconds(8)) async throws -> MPVSeekResult {
        try await performSeek(to: position, timeout: timeout, pausesAfterEnd: false)
    }
}

package extension MPVSession {

    struct SeekRequest {

        let id: UUID
        let generation: UInt64
        var target: Duration
        let cancellation: MPVOperationCancellation
        let continuation: CheckedContinuation<MPVSeekResult, any Error>
        var timeout: Task<Void, Never>?
        var sawSeek = false
    }

    func performSeek(to position: Duration, timeout: Duration, pausesAfterEnd: Bool) async throws -> MPVSeekResult {
        let cancellation = MPVOperationCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard !isClosed, sourceURL != nil, isFileLoaded || isLoading || didReachEnd else {
                        continuation.resume(throwing: MPVPlayerError.seekUnavailable)
                        return
                    }
                    guard timeout > .zero else {
                        continuation.resume(throwing: MPVPlayerError.seekTimedOut)
                        return
                    }

                    cancelPendingSeek()
                    // Drain older restarts before this operation can claim one.
                    drainEvents()
                    guard isFileLoaded || isLoading || didReachEnd, isLoading || lastSeekable else {
                        continuation.resume(throwing: MPVPlayerError.seekUnavailable)
                        return
                    }

                    let target = normalizedSeekTarget(position)
                    if didReachEnd, lastDuration > .zero, target >= lastDuration {
                        let result = MPVSeekResult(generation: currentGeneration, target: target, position: lastDuration)
                        publish(.seekCompleted(result))
                        continuation.resume(returning: result)
                        return
                    }

                    let id = UUID()
                    pendingSeek = SeekRequest(
                        id: id,
                        generation: currentGeneration,
                        target: target,
                        cancellation: cancellation,
                        continuation: continuation
                    )
                    pendingSeek?.timeout = Task { [weak self] in
                        do {
                            try await Task.sleep(for: timeout)
                        } catch {
                            return
                        }
                        self?.queue.async { [weak self] in
                            guard let self, self.pendingSeek?.id == id else {
                                return
                            }

                            self.failPendingSeek(MPVPlayerError.seekTimedOut)
                        }
                    }

                    if didReachEnd, let sourceURL {
                        pendingSeek?.sawSeek = true
                        pendingStartTime = target
                        pendingSeekAfterLoad = nil
                        lastPosition = target
                        if pausesAfterEnd {
                            shouldAutoPlay = false
                        }
                        isPaused = !shouldAutoPlay
                        didReachEnd = false
                        playbackRequestIsActive = true
                        fatalPlaybackError = nil
                        needsSourceLoad = true
                        isLoading = true
                        for index in externalTracks.indices {
                            externalTracks[index].isLoaded = false
                        }
                        pendingExternalTracks = externalTracks
                        startSecurityScopedAccessIfNeeded(for: sourceURL)
                        publishState(.loading)
                        loadPendingSourceIfPossible()
                    } else if !isFileLoaded {
                        pendingSeek?.sawSeek = true
                        if handle != nil, isLoading, !needsSourceLoad {
                            pendingSeekAfterLoad = target
                        } else {
                            pendingStartTime = target
                        }
                    } else {
                        let status = runCommand(["seek", Self.format(target), "absolute+exact"])
                        if status < 0 {
                            let error = MPVPlayerError.seekFailed(code: status, message: mpvErrorMessage(status))
                            failPendingSeek(error)
                            publish(.error(error, fatal: false))
                        }
                    }
                }
            }
        } onCancel: { [weak self] in
            cancellation.cancel()
            self?.queue.async { [weak self] in
                guard let self, self.pendingSeek?.cancellation === cancellation else {
                    return
                }

                self.cancelPendingSeek()
            }
        }
    }

    func normalizedSeekTarget(_ position: Duration) -> Duration {
        lastDuration > .zero ? clamped(position, to: .zero ... lastDuration) : position.clampPositiveOrZero
    }

    func preparePendingSeekAfterLoad() {
        guard let request = pendingSeek else {
            return
        }
        guard lastSeekable else {
            pendingSeekAfterLoad = nil
            failPendingSeek(MPVPlayerError.seekUnavailable)
            return
        }

        let target = normalizedSeekTarget(request.target)
        pendingSeek?.target = target
        if pendingSeekAfterLoad != nil {
            pendingSeekAfterLoad = target
        }
    }

    func completePendingSeek(at position: Duration) {
        guard let request = pendingSeek else {
            return
        }

        pendingSeek = nil
        request.timeout?.cancel()
        guard !request.cancellation.isCancelled, request.generation == currentGeneration else {
            request.continuation.resume(throwing: CancellationError())
            return
        }

        let result = MPVSeekResult(generation: currentGeneration, target: request.target, position: position)
        publish(.seekCompleted(result))
        request.continuation.resume(returning: result)
    }

    func failPendingSeek(_ error: any Error) {
        let request = pendingSeek
        pendingSeek = nil
        request?.timeout?.cancel()
        request?.continuation.resume(throwing: error)
    }

    func cancelPendingSeek() {
        failPendingSeek(CancellationError())
    }
}
