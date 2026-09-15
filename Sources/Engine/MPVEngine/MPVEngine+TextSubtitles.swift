import Foundation
import Libmpv

#if canImport(Darwin)
import Darwin
#endif

// Observes semantic subtitle snapshots and manages cancellable cue queries.
extension MPVEngine {
    private static let textSubtitleObservationID = UInt64.max - 1

    static let textSubtitleSnapshotRefreshProperties: Set<String> = [
        "sid",
        "secondary-sid",
        "sub-delay",
        "secondary-sub-delay",
        "secondary-sub-visibility",
        "sub-visibility",
    ]

    struct SubtitleQuery {
        let cancellation: MPVSubtitleQueryCancellation
        let continuation: CheckedContinuation<[TimedTextSubtitleSnapshot], any Error>
    }

    func enableTextSubtitleInterception() {
        queue.async { [weak self] in
            guard let self, !self.isTextSubtitleInterceptionEnabled else { return }
            self.isTextSubtitleInterceptionEnabled = true
            self.lastTextSubtitleSnapshot = TextSubtitleSnapshot()
            guard self.handle != nil else { return }

            let status = self.setPropertyImmediately("sub-text-intercept", to: "yes")
            guard status >= 0 else {
                self.publishCommandError(status, context: "Enable text subtitle interception")
                return
            }
            self.observeTextSubtitleSnapshot()
            self.refreshTextSubtitleSnapshot()
        }
    }

    func textSubtitleSnapshots(
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

    func subtitleQueryError(_ status: Int32) -> MPVPlayerError {
        .commandFailed(
            context: "Read text subtitles",
            code: status,
            message: String(cString: mpv_error_string(status))
        )
    }

    func cancelSubtitleQueries(matching cancellation: MPVSubtitleQueryCancellation? = nil) {
        for (id, query) in subtitleQueries where cancellation == nil || query.cancellation === cancellation {
            if let handle {
                mpv_abort_async_command(handle, id)
            }
            subtitleQueries.removeValue(forKey: id)
            query.continuation.resume(throwing: CancellationError())
        }
    }

    func textSubtitleInterceptionForTesting() async -> Bool? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.getFlag("sub-text-intercept"))
            }
        }
    }

    func observeTextSubtitleSnapshot() {
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

    func refreshTextSubtitleSnapshot() {
        guard isTextSubtitleInterceptionEnabled else { return }
        updateTextSubtitleSnapshot(from: getNode("sub-text-snapshot"))
    }

    func updateTextSubtitleSnapshot(from node: MPVNodeValue?) {
        guard isTextSubtitleInterceptionEnabled, !isSeeking else { return }
        let snapshot = MPVTextSubtitleParser.snapshot(from: node)
        guard snapshot != lastTextSubtitleSnapshot else { return }
        lastTextSubtitleSnapshot = snapshot
        publish(.textSubtitles(snapshot))
    }

    func clearTextSubtitleSnapshot() {
        guard isTextSubtitleInterceptionEnabled, !lastTextSubtitleSnapshot.isEmpty else {
            return
        }
        lastTextSubtitleSnapshot = TextSubtitleSnapshot()
        publish(.textSubtitles(TextSubtitleSnapshot()))
    }
}
