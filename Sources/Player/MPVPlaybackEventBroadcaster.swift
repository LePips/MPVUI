import Foundation
import MPVCore

@MainActor
final class MPVPlaybackEventBroadcaster {

    private(set) var snapshot = MPVSessionSnapshot()
    private var events: [UUID: AsyncStream<MPVPlaybackEvent>.Continuation] = [:]
    private var timing: [UUID: AsyncStream<MPVPlaybackTiming>.Continuation] = [:]
    private var features: MPVVideoFeatureCapabilities?

    func subscribe() -> AsyncStream<MPVPlaybackEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MPVPlaybackEvent>.makeStream()
        events[id] = continuation
        continuation.yield(.init(generation: snapshot.generation, change: .snapshot(snapshot)))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.events.removeValue(forKey: id)
            }
        }
        return stream
    }

    func subscribeToTiming() -> AsyncStream<MPVPlaybackTiming> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MPVPlaybackTiming>.makeStream(bufferingPolicy: .bufferingNewest(1))
        timing[id] = continuation
        continuation.yield(.init(snapshot: snapshot))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.timing.removeValue(forKey: id)
            }
        }
        return stream
    }

    func reset(_ value: MPVSessionSnapshot) {
        snapshot = value
        features = nil
        publish(.snapshot(value))
        publishTiming()
    }

    func update(_ value: MPVSessionSnapshot, features: MPVVideoFeatureCapabilities) {
        let previous = snapshot
        snapshot = value
        if previous.isPlaybackReady != value.isPlaybackReady {
            publish(.readinessChanged(value.isPlaybackReady))
        }
        if previous.isPaused != value.isPaused {
            publish(.pauseChanged(value.isPaused))
        }
        if previous.state != value.state {
            publish(.stateChanged(value.state))
        }
        // Timeline and frame-rate samples must not trigger track reconciliation.
        var previousMetadata = previous.mediaInformation
        previousMetadata.duration = value.mediaInformation.duration
        previousMetadata.framesPerSecond = value.mediaInformation.framesPerSecond
        if previousMetadata != value.mediaInformation {
            publish(.mediaInformationChanged(value.mediaInformation))
        }
        if previous.volume != value.volume || previous.isMuted != value.isMuted || previous.playbackRate != value.playbackRate {
            publish(.audioChanged(volume: value.volume, isMuted: value.isMuted, playbackRate: value.playbackRate))
        }
        if previous.currentChapterIndex != value.currentChapterIndex {
            publish(.chapterChanged(value.currentChapterIndex))
        }
        if self.features != features {
            self.features = features
            publish(.videoFeaturesChanged(features))
        }
        if MPVPlaybackTiming(snapshot: previous) != MPVPlaybackTiming(snapshot: value) {
            publishTiming()
        }
    }

    func publish(_ change: MPVPlaybackEvent.Change) {
        let event = MPVPlaybackEvent(generation: snapshot.generation, change: change)
        for continuation in events.values {
            continuation.yield(event)
        }
    }

    func terminate() {
        for continuation in events.values {
            continuation.finish()
        }
        for continuation in timing.values {
            continuation.finish()
        }
        events.removeAll()
        timing.removeAll()
    }

    private func publishTiming() {
        let value = MPVPlaybackTiming(snapshot: snapshot)
        for continuation in timing.values {
            continuation.yield(value)
        }
    }
}
