@testable import MPVUI
import Testing

struct MPVModelTests {
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

        let error = MPVPlayerError(localizedDescription: "Could not open media")
        let failed = MPVPlaybackState.failed(error)
        #expect(failed.isTerminal)
        #expect(failed.error == error)
        #expect(error.localizedDescription == "Could not open media")
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

    @Test
    func `hdr detection uses transfer function rather than primaries`() {
        let wideGamutSDR = MPVHDRStatus(
            primaries: "bt.2020",
            transferFunction: .bt709
        )
        #expect(!wideGamutSDR.isHDRContent)

        #expect(MPVHDRStatus(transferFunction: .pq).isHDRContent)
        #expect(MPVHDRStatus(transferFunction: .hlg).isHDRContent)
        #expect(MPVTransferFunction(mpvValue: "smpte-st-2084") == .pq)
        #expect(MPVTransferFunction(mpvValue: "arib-std-b67") == .hlg)
    }

    @Test
    func `text subtitle snapshot preserves ordered regions and flattened text`() {
        let placement = WebVTTPlacement(
            horizontalPosition: 0.25,
            verticalPosition: 0.8,
            horizontalAnchor: .left,
            verticalAnchor: .top,
            maximumWidth: 0.6,
            textAlignment: .right,
            writingDirection: .verticalGrowingLeft
        )
        let snapshot = TextSubtitleSnapshot(regions: [
            TextSubtitleRegion(text: "first"),
            TextSubtitleRegion(text: "second", placement: .webVTT(placement)),
        ])

        #expect(snapshot.regions.map(\.text) == ["first", "second"])
        #expect(snapshot.text == "first\nsecond")
        #expect(!snapshot.isEmpty)
        #expect(TextSubtitleSnapshot().isEmpty)
    }
}
