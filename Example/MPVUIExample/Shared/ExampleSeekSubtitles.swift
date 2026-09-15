import Foundation
import MPVUI
import Observation

/// Briefly presents the destination cue without changing the user's track selection.
@MainActor
@Observable
final class ExampleSeekSubtitles {
    private(set) var snapshot: TextSubtitleSnapshot?

    @ObservationIgnored
    private var preferredTrack: MPVMediaTrackIdentifier?
    @ObservationIgnored
    private var presentation: Task<Void, Never>?
    @ObservationIgnored
    private var requestID = UUID()
    @ObservationIgnored
    private var cache: TimelineCache?
    @ObservationIgnored
    private var pendingTarget: Duration?

    private struct TimelineCache {
        let id = UUID()
        let track: MPVMediaTrackIdentifier
        let task: Task<[TimedTextSubtitleSnapshot], any Error>
    }

    func tracksChanged(_ tracks: [MPVMediaTrack]) {
        let selected = tracks.first { $0.subtitleRole == .primary && Self.supports($0) }
            ?? tracks.first { $0.subtitleRole == .secondary && Self.supports($0) }
        if let selected {
            preferredTrack = selected.id
        }
        if tracks.contains(where: \.isSelected) {
            cancelPresentation()
        }
        if let cache, !tracks.contains(where: { $0.id == cache.track }) {
            cache.task.cancel()
            self.cache = nil
        }
    }

    func reset() {
        cancelPresentation()
        cache?.task.cancel()
        cache = nil
        preferredTrack = nil
    }

    func cancelPresentation() {
        requestID = UUID()
        presentation?.cancel()
        presentation = nil
        pendingTarget = nil
        snapshot = nil
    }

    func jump(by offset: Duration, player: MPVPlayer) {
        seek(to: (pendingTarget ?? player.position) + offset, player: player, jumpingBack: offset < .zero)
    }

    func seek(to requestedPosition: Duration, player: MPVPlayer, jumpingBack: Bool = false) {
        let origin = pendingTarget ?? player.position
        cancelPresentation()
        guard player.isSeekable else { return }
        let target = player.duration > .zero
            ? min(max(.zero, requestedPosition), player.duration)
            : max(.zero, requestedPosition)
        let distance = target >= origin ? target - origin : origin - target
        player.seek(to: target)
        guard distance > .zero else { return }
        pendingTarget = target
        let track = (jumpingBack || distance > .seconds(5))
            && !player.subtitleTracks.contains(where: \.isSelected)
            ? previewTrack(in: player.subtitleTracks) : nil

        let id = requestID
        presentation = Task { [weak self] in
            guard let self else { return }
            defer {
                if requestID == id {
                    snapshot = nil
                    presentation = nil
                    pendingTarget = nil
                }
            }
            do {
                try Task.checkCancellation()
                // A seek is asynchronous. Wait for the actual destination, even
                // when SwiftUI coalesces the brief `.seeking` state transition.
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(15))
                while !hasArrived(player, at: target) {
                    try Task.checkCancellation()
                    guard clock.now < deadline else { return }
                    try await Task.sleep(for: .milliseconds(25))
                }
                try Task.checkCancellation()
                pendingTarget = nil
                guard let track else { return }
                let destination = player.position
                let intervals = try await timeline(for: track.id, player: player)
                try Task.checkCancellation()
                guard requestID == id,
                      !player.subtitleTracks.contains(where: \.isSelected),
                      let interval = intervals.first(where: { $0.contains(destination) }),
                      interval.contains(player.position)
                else { return }

                snapshot = interval.snapshot
                let hideAt = clock.now.advanced(by: .seconds(5))
                while clock.now < hideAt, interval.contains(player.position) {
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                // Missing/unsupported subtitles and cancelled source loads must
                // not interrupt the seek or leave an old preview on screen.
            }
        }
    }

    private func hasArrived(_ player: MPVPlayer, at target: Duration) -> Bool {
        switch player.state {
        case .playing, .paused, .ready, .buffering, .ended:
            let distance = player.position >= target ? player.position - target : target - player.position
            return distance < .seconds(0.5)
        default:
            return false
        }
    }

    private func previewTrack(in tracks: [MPVMediaTrack]) -> MPVMediaTrack? {
        let textTracks = tracks.filter(Self.supports)
        return textTracks.first { $0.id == preferredTrack }
            ?? textTracks.first(where: \.isDefault)
            ?? textTracks.first
    }

    private static func supports(_ track: MPVMediaTrack) -> Bool {
        switch track.codec?.lowercased() {
        case "subrip", "srt", "webvtt", "webvtt-webm", "ttml", "mov_text", "text": true
        default: false
        }
    }

    private func timeline(
        for track: MPVMediaTrackIdentifier,
        player: MPVPlayer
    ) async throws -> [TimedTextSubtitleSnapshot] {
        let entry: TimelineCache
        if let cache, cache.track == track {
            entry = cache
        } else {
            cache?.task.cancel()
            entry = TimelineCache(track: track, task: Task {
                try await player.textSubtitleSnapshots(for: track)
            })
            cache = entry
        }
        do {
            return try await entry.task.value
        } catch {
            if cache?.id == entry.id {
                cache = nil
            }
            throw error
        }
    }
}
