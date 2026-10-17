import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
@MainActor
struct MPVPlayerEmissionTests {

    @Test
    func `scalar timeline changes preserve metadata and reset chapter and frame state on stop`() {
        let player = MPVPlayer()
        let video = MPVMediaTrack(id: 1, type: .video)
        let information = MPVMediaInformation(
            title: "Movie",
            dimensions: .init(width: 720, height: 576),
            metadata: ["artist": "Example"],
            tracks: [video]
        )
        player.applyTestEmission(.init(generation: nil, update: .media(information)))
        player.applyTestEmission(.init(generation: nil, update: .videoFrame(true)))
        player.applyTestEmission(.init(generation: nil, update: .chapter(2)))
        player.applyTestEmission(.init(generation: nil, update: .frameRate(23.976)))
        player.applyTestEmission(.init(generation: nil, update: .timing(position: .seconds(2), duration: .seconds(20), isSeekable: true)))
        #expect(player.hasVideoFrame)
        #expect(player.currentChapterIndex == 2)
        #expect(player.mediaInformation.framesPerSecond == 23.976)
        #expect(player.mediaInformation.duration == .seconds(20))
        #expect(player.mediaInformation.tracks == information.tracks)
        #expect(player.mediaInformation.metadata == information.metadata)
        player.applyTestEmission(.init(generation: nil, update: .state(.stopped)))
        #expect(!player.hasVideoFrame)
        #expect(player.currentChapterIndex == nil)
    }

    @Test
    func `cache defaults and explicit display matching policy are shared playback settings`() {
        let configuration = MPVPlayerConfiguration(cache: .init(maximumBytes: -1, maximumBackBytes: 4), displayMatching: .disabled)
        #expect(configuration.cache.maximumBytes == 0)
        #expect(configuration.cache.maximumBackBytes == 4)
        #expect(configuration.displayMatching == .disabled)
        #expect(MPVCacheConfiguration().maximumBytes == 64 * 1024 * 1024)
        #expect(MPVCacheConfiguration().maximumBackBytes == 16 * 1024 * 1024)
        #expect(MPVCacheConfiguration().mode == .automatic)
    }

    @Test
    func `superseded media updates cannot replace the current source but global failures remain visible`() {
        let player = MPVPlayer()
        player.load(TestPaths.baselineMedia)
        let previous = player.mediaGeneration
        player.load(TestPaths.baselineMedia)

        #expect(player.mediaGeneration != previous)
        player.applyTestEmission(.init(generation: previous, update: .state(.ended)))
        player.applyTestEmission(.init(
            generation: previous,
            update: .timing(position: .seconds(99), duration: .seconds(100), isSeekable: true)
        ))
        player.applyTestEmission(.init(generation: previous, update: .error(.eventQueueOverflow, fatal: true)))

        #expect(player.state == .loading)
        #expect(player.position == .zero && player.duration == .zero)
        #expect(player.lastError == nil)
        player.applyTestEmission(.init(generation: nil, update: .error(.clientCreationFailed, fatal: true)))

        #expect(player.state == .failed(.clientCreationFailed))
        #expect(player.lastError == .clientCreationFailed)
    }

    @Test
    func `fatal state reports its error while a recoverable error preserves playback`() {
        let player = MPVPlayer()
        player.applyTestEmission(.init(generation: nil, update: .state(.playing)))
        player.applyTestEmission(.init(generation: nil, update: .error(.eventQueueOverflow, fatal: false)))

        #expect(player.state == .playing)
        #expect(player.lastError == .eventQueueOverflow)
        player.clearLastError()

        #expect(player.lastError == nil)
        player.applyTestEmission(.init(generation: nil, update: .state(.failed(.clientUnavailable))))

        #expect(player.lastError == .clientUnavailable)
        #expect(player.isPlaybackPausedForPictureInPicture)
    }

    @Test
    func `current log messages reach the registered handler unchanged`() {
        let player = MPVPlayer()
        var messages: [MPVLogMessage] = []
        player.logHandler = { messages.append($0) }
        let log = MPVLogMessage(prefix: "decoder", level: .warning, message: "Decoded frame was dropped")
        player.applyTestEmission(.init(generation: player.mediaGeneration, update: .log(log)))

        #expect(messages == [log])
        player.logHandler = nil
        player.applyTestEmission(.init(generation: nil, update: .log(log)))

        #expect(messages.count == 1)
    }

    @Test
    func `track accessors separate media types and unknown codecs do not request composition`() {
        let player = MPVPlayer()
        let video = MPVMediaTrack(id: 1, type: .video)
        let audio = MPVMediaTrack(id: 2, type: .audio)
        let subtitle = MPVMediaTrack(id: 3, type: .subtitle)
        player.applyTestEmission(.init(generation: nil, update: .media(.init(tracks: [video, subtitle, audio]))))

        #expect(player.videoTracks == [video])
        #expect(player.audioTracks == [audio])
        #expect(player.subtitleTracks == [subtitle])
        player.selectSubtitle(subtitle.id)

        #expect(player.videoFeatureRequestResult == nil)
        #expect(player.lastError == nil)
    }

    @Test(arguments: [(Double.nan, 42.0), (.infinity, 100.0), (-.infinity, 0.0)])
    func `non finite volume cannot publish NaN and infinities clamp`(volume: Double, expected: Double) {
        let player = MPVPlayer(configuration: .init(volume: 42))
        player.setVolume(volume)

        #expect(player.volume == expected)
    }

    @Test(arguments: ["video-zoom", "video-pan-x", "video-pan-y", "video-scale-x", "video-scale-y"])
    func `non default geometry requests become explicit feature requirements`(property: String) {
        let player = MPVPlayer()
        player.setProperty(property, to: "2")

        #expect(player.videoFeatureRequestResult?.requestedFeatures == [.zoomAndPan])
        #expect(player.videoFeatureRequestResult?.outcome == .awaitingVideoMetadata)
    }

    @Test
    func `selected authored subtitles reevaluate feature policy when Dolby Vision metadata arrives`() {
        let player = MPVPlayer(configuration: .init(videoOutput: .sampleBuffer))
        let subtitle = MPVMediaTrack(id: 1, type: .subtitle, codec: "ass", isSelected: true)
        player.applyTestEmission(.init(generation: nil, update: .media(.init(tracks: [subtitle]))))
        player.updateDolbyVisionStatus(.init(sourceProfile: 5))

        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.videoFeatureRequestResult?.outcome == .unavailable)
        #expect(player.videoFeatureRequestResult?.requestedFeatures == [.nativeSubtitles])
        #expect(player.lastError == nil)
    }
}
