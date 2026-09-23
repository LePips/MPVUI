@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVModelTests {
    @Test
    func `timing configuration keeps negative durations out of native options`() {
        let configuration = MPVPlayerConfiguration(
            initialBufferSeconds: .seconds(-2),
            networkCacheSeconds: .seconds(-10),
            startTime: .seconds(-1)
        )
        #expect(configuration.startTime == .zero)
        #expect(configuration.networkCacheSeconds == .zero)
        #expect(configuration.initialBufferSeconds == .zero)
        let positive = MPVPlayerConfiguration(
            initialBufferSeconds: .seconds(3),
            networkCacheSeconds: .seconds(30),
            startTime: nil
        )
        #expect(positive.startTime == nil)
        #expect(positive.networkCacheSeconds == .seconds(30))
        #expect(positive.initialBufferSeconds == .seconds(3))
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

    @Test(arguments: [(120.0, 100.0), (-1, 0), (.nan, 100), (.infinity, 100), (-.infinity, 0), (75, 75)])
    func `configuration normalizes initial volume`(value: Double, expected: Double) {
        #expect(MPVPlayerConfiguration(volume: value).volume == expected)
    }

    @Test(arguments: [(0.0, 1.0), (-1, 1), (.nan, 1), (.infinity, 1), (-.infinity, 1), (1000, 100), (0.001, 0.01), (1.5, 1.5)])
    func `configuration normalizes initial playback rate`(value: Double, expected: Double) {
        #expect(MPVPlayerConfiguration(playbackRate: value).playbackRate == expected)
    }
}
