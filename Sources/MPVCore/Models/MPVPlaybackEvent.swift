import Foundation

/// An ordered lifecycle or operation update from one player generation.
/// Position ticks, diagnostics, subtitle cues, and logs have separate delivery paths.
public struct MPVPlaybackEvent: Sendable {

    /// Lifecycle, metadata, and operation changes delivered without coalescing.
    public enum Change: Sendable {

        /// Current state on subscription and after a source load or stop.
        case snapshot(MPVSessionSnapshot)
        /// Playback lifecycle changed.
        case stateChanged(MPVPlaybackState)
        /// Play/pause intent changed, including while buffering or seeking.
        case pauseChanged(Bool)
        /// Initial playback became ready, or readiness was cleared.
        case readinessChanged(Bool)
        /// Source metadata or track selection changed. Duration travels with timing updates.
        case mediaInformationChanged(MPVMediaInformation)
        /// Volume, mute, or playback rate changed.
        case audioChanged(volume: Double, isMuted: Bool, playbackRate: Double)
        /// The current chapter changed.
        case chapterChanged(Int?)
        /// Video composition capabilities changed.
        case videoFeaturesChanged(MPVVideoFeatureCapabilities)
        /// A recoverable command error or fatal playback error occurred.
        case error(MPVPlayerError, fatal: Bool)
        /// An awaited seek reached a native destination.
        case seekCompleted(MPVSeekResult)
        /// An external track import completed, including imports requested through convenience APIs.
        case externalTrackLoaded(MPVExternalTrackLoadResult)
    }

    /// Identifies the playback generation. Loading or stopping invalidates older generations.
    public let generation: UInt64
    /// The state change or completed operation.
    public let change: Change

    package init(generation: UInt64, change: Change) {
        self.generation = generation
        self.change = change
    }
}

/// A coalescible timeline update, separate from ordered lifecycle events.
public struct MPVPlaybackTiming: Equatable, Sendable {

    /// The playback generation that owns this timeline.
    public let generation: UInt64
    /// Current playback position.
    public let position: Duration
    /// Media duration, or zero when unknown.
    public let duration: Duration
    /// Whether the source supports seeking.
    public let isSeekable: Bool
    /// The current cache and seekable ranges.
    public let buffer: MPVBufferStatus

    package init(snapshot: MPVSessionSnapshot) {
        generation = snapshot.generation
        position = snapshot.position
        duration = snapshot.duration
        isSeekable = snapshot.isSeekable
        buffer = snapshot.buffer
    }
}
