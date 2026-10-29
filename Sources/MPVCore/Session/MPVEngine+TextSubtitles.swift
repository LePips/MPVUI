import CMPV
import Foundation

#if canImport(Darwin)
import Darwin
#endif

// Observes semantic subtitle snapshots and manages cancellable cue queries.
extension MPVSession {

    package struct SubtitleQuery {

        let cancellation: MPVSubtitleQueryCancellation
        let continuation: CheckedContinuation<[TimedTextSubtitleSnapshot], any Error>
    }

    package static let textSubtitleSnapshotRefreshProperties: Set<String> = [
        "sid",
        "secondary-sid",
        "sub-delay",
        "secondary-sub-delay",
        "secondary-sub-visibility",
        "sub-visibility",
    ]

    package static let textSubtitleObservationID = UInt64.max - 1

    /// Returns every nonempty text presentation for a loaded subtitle track.
    ///
    /// Results are ordered, nonoverlapping source-time intervals containing all
    /// overlapping cue regions. Gaps are omitted. Times exclude subtitle delay
    /// and speed adjustments. The query does not change playback or track selection.
    ///
    /// The query scans a finite, seekable source and may read the entire container
    /// or download it again. Retain the result for repeated lookups.
    ///
    /// - Parameter track: The identifier of a text subtitle track in the current media.
    /// - Throws: ``MPVPlayerError/commandFailed(context:code:message:)`` for an invalid track
    ///   or read failure, or `CancellationError` if the task is canceled, the source
    ///   is replaced, or the session stops or closes.
    public func textSubtitleSnapshots(
        for track: MPVMediaTrackIdentifier
    ) async throws -> [TimedTextSubtitleSnapshot] {
        let cancellation = MPVSubtitleQueryCancellation()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard let handle, isFileLoaded, track.type == .subtitle else {
                        continuation.resume(throwing: MPVPlayerError.commandFailed(
                            context: "Read text subtitles",
                            code: MPV_ERROR_INVALID_PARAMETER.rawValue,
                            message: "A loaded text subtitle track is required."
                        ))

                        return
                    }

                    let id = nextSubtitleQueryID

                    nextSubtitleQueryID &+= 1

                    subtitleQueries[id] = SubtitleQuery(
                        cancellation: cancellation,
                        continuation: continuation
                    )

                    let command = ["sub-text-cues", String(track.mpvID)]

                    var arguments: [UnsafePointer<CChar>?] = command.map { argument in
                        guard let duplicate = strdup(argument) else { return nil }

                        return UnsafePointer(duplicate)
                    }
                    arguments.append(nil)

                    defer {
                        for case let pointer? in arguments {
                            free(UnsafeMutablePointer(mutating: pointer))
                        }
                    }

                    let status = mpv_command_async(handle, id, &arguments)

                    if status < 0 {
                        subtitleQueries.removeValue(forKey: id)
                        continuation.resume(throwing: subtitleQueryError(status))
                    }
                }
            }
        } onCancel: { [weak self] in
            cancellation.cancel()

            self?.queue.async { [weak self] in
                self?.cancelSubtitleQueries(matching: cancellation)
            }
        }
    }

    package func setTextSubtitleInterceptionEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, enabled != self.isTextSubtitleInterceptionEnabled else { return }

            if let handle = self.handle {
                let status = self.setPropertyImmediately("sub-text-intercept", to: enabled ? "yes" : "no")

                guard status >= 0 else {
                    self.publishCommandError(status, context: "Set text subtitle interception")
                    return
                }

                if !enabled {
                    mpv_unobserve_property(handle, Self.textSubtitleObservationID)
                }
            }

            self.isTextSubtitleInterceptionEnabled = enabled
            self.lastTextSubtitleSnapshot = TextSubtitleSnapshot()
            self.publish(.textSubtitles(TextSubtitleSnapshot()))

            if enabled {
                self.observeTextSubtitleSnapshot()
                self.refreshTextSubtitleSnapshot()
            }
        }
    }

    package func subtitleQueryError(_ status: Int32) -> MPVPlayerError {
        .commandFailed(
            context: "Read text subtitles",
            code: status,
            message: String(cString: mpv_error_string(status))
        )
    }

    package func cancelSubtitleQueries(matching cancellation: MPVSubtitleQueryCancellation? = nil) {
        for (id, query) in subtitleQueries where cancellation == nil || query.cancellation === cancellation {
            if let handle {
                mpv_abort_async_command(handle, id)
            }

            subtitleQueries.removeValue(forKey: id)
            query.continuation.resume(throwing: CancellationError())
        }
    }

    package func textSubtitleInterceptionForTesting() async -> Bool? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.getFlag("sub-text-intercept"))
            }
        }
    }

    package func observeTextSubtitleSnapshot() {
        guard let handle else { return }

        let status = mpv_observe_property(
            handle,
            Self.textSubtitleObservationID,
            "sub-text-snapshot",
            MPV_FORMAT_NODE
        )

        if status < 0 {
            publishCommandError(status, context: "Observe sub-text-snapshot")
        }
    }

    package func refreshTextSubtitleSnapshot() {
        guard isTextSubtitleInterceptionEnabled else { return }

        updateTextSubtitleSnapshot(from: getNode("sub-text-snapshot"))
    }

    package func updateTextSubtitleSnapshot(from node: MPVNodeValue?) {
        guard isTextSubtitleInterceptionEnabled, !isSeeking else { return }

        let snapshot = MPVTextSubtitleParser.snapshot(from: node)
        guard snapshot != lastTextSubtitleSnapshot else { return }

        lastTextSubtitleSnapshot = snapshot
        publish(.textSubtitles(snapshot))
    }

    package func clearTextSubtitleSnapshot() {
        guard isTextSubtitleInterceptionEnabled, !lastTextSubtitleSnapshot.isEmpty else {
            return
        }

        lastTextSubtitleSnapshot = TextSubtitleSnapshot()
        publish(.textSubtitles(TextSubtitleSnapshot()))
    }
}
