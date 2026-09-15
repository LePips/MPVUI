@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVModelTests {
    @Test
    func `changing timing configuration keeps negative durations out of native options`() {
        var configuration = MPVPlayerConfiguration()
        configuration.startTime = .seconds(-1)
        configuration.networkCacheSeconds = .seconds(-10)
        configuration.initialBufferSeconds = .seconds(-2)
        #expect(configuration.startTime == .zero)
        #expect(configuration.networkCacheSeconds == .zero)
        #expect(configuration.initialBufferSeconds == .zero)
        configuration.startTime = nil
        configuration.networkCacheSeconds = .seconds(30)
        configuration.initialBufferSeconds = .seconds(3)
        #expect(configuration.startTime == nil)
        #expect(configuration.networkCacheSeconds == .seconds(30))
        #expect(configuration.initialBufferSeconds == .seconds(3))
    }

    @Test
    func `latched decoder and rendering options tell callers that reload is required`() {
        let dolbyVision = MPVDolbyVisionStatus.unknown
        #expect(dolbyVision.policyChangesRequireReload)
        #expect(dolbyVision.reloadReason == "The native Dolby Vision policy is latched when the decoder is created.")
        #expect(MPVRenderingQualityStatus().requiresReload)
    }

    @Test
    func `playback state helpers`() {
        #expect(MPVPlaybackState.playing.isPlaying)
        #expect(!MPVPlaybackState.paused.isPlaying)

        #expect(MPVPlaybackState.loading.isTransient)
        #expect(MPVPlaybackState.buffering.isTransient)
        #expect(MPVPlaybackState.seeking.isTransient)
        #expect(!MPVPlaybackState.ready.isTransient)

        #expect(MPVPlaybackState.ended.isTerminal)
        #expect(MPVPlaybackState.stopped.isTerminal)

        let error = MPVPlayerError.loadFailed(code: -13, message: "Could not open media")
        let failed = MPVPlaybackState.failed(error)
        #expect(failed.isTerminal)
        #expect(failed.error == error)
        #expect(error.localizedDescription == "Load media: Could not open media")
    }

    @Test
    func `buffer progress is normalized`() {
        #expect(MPVBufferStatus(progress: -0.25).progress == 0)
        #expect(MPVBufferStatus(progress: 0.45).progress == 0.45)
        #expect(MPVBufferStatus(progress: 2).progress == 1)
        #expect(MPVBufferStatus(progress: .nan).progress == 0)
    }

    @Test
    func `configuration clamps volume and invalid playback rate`() {
        var configuration = MPVPlayerConfiguration(volume: 120, playbackRate: 0)
        #expect(configuration.volume == 100)
        #expect(configuration.playbackRate == MPVPlayerConfiguration.defaultPlaybackRate)

        configuration.volume = -1
        configuration.playbackRate = 1.5
        #expect(configuration.volume == 0)
        #expect(configuration.playbackRate == 1.5)

        configuration.volume = .nan
        configuration.playbackRate = -.infinity
        #expect(configuration.volume == MPVPlayerConfiguration.defaultVolume)
        #expect(configuration.playbackRate == MPVPlayerConfiguration.defaultPlaybackRate)

        configuration.playbackRate = 1000
        #expect(configuration.playbackRate == MPVPlayerConfiguration.maximumPlaybackRate)

        configuration.playbackRate = 0.001
        #expect(configuration.playbackRate == MPVPlayerConfiguration.minimumPlaybackRate)
    }
}
