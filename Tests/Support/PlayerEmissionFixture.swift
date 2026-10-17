import MPVCore
@testable import MPVUI

/// Injects a complete core-produced state when testing the observable projection.
@MainActor
struct PlayerTestEmission {

    let generation: UInt64?
    let update: MPVEngineUpdate
}

@MainActor
extension MPVPlayer {

    func applyTestEmission(_ emission: PlayerTestEmission) {
        var snapshot = MPVSessionSnapshot()
        snapshot.state = state
        snapshot.position = position
        snapshot.duration = duration
        snapshot.isSeekable = isSeekable
        snapshot.isPaused = isPaused
        snapshot.hasPlaybackFrame = hasVideoFrame
        snapshot.currentChapterIndex = currentChapterIndex
        snapshot.mediaInformation = mediaInformation
        snapshot.volume = volume
        snapshot.playbackRate = playbackRate
        snapshot.error = lastError
        snapshot.apply(emission.update)
        apply(.init(generation: emission.generation, update: emission.update, snapshot: snapshot))
    }
}
