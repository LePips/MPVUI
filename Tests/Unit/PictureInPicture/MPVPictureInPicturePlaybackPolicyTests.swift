import CoreMedia
@testable import MPVUI
import Testing

@Suite(.tags(.unit, .pictureInPicture))
struct MPVPictureInPicturePlaybackPolicyTests {
    @Test(arguments: [MPVPlaybackState.idle, .loading, .stopped, .failed(.clientUnavailable)])
    func `unavailable playback has no PiP timeline`(state: MPVPlaybackState) {
        let range = MPVPictureInPicturePlaybackPolicy.playbackTimeRange(
            hasMedia: true,
            state: state,
            duration: .seconds(120),
            displayTime: CMTime(seconds: 20, preferredTimescale: 600)
        )
        #expect(!range.isValid)
    }

    @Test
    func `unknown duration uses live timeline while known duration permits seeking`() {
        let live = MPVPictureInPicturePlaybackPolicy.playbackTimeRange(
            hasMedia: true, state: .playing, duration: .zero, displayTime: .zero
        )
        #expect(live.isValid)
        #expect(live.duration == .positiveInfinity)

        let movie = MPVPictureInPicturePlaybackPolicy.playbackTimeRange(
            hasMedia: true, state: .paused, duration: .seconds(120), displayTime: .zero
        )
        #expect(movie.start == .zero)
        #expect(movie.duration.seconds == 120)
    }

    @Test(arguments: [-0.25, 20.0, 120.0, 120.25])
    func `finite range contains native presentation time including endpoint and preroll`(seconds: Double) {
        let displayTime = CMTime(seconds: seconds, preferredTimescale: 600)
        let range = MPVPictureInPicturePlaybackPolicy.playbackTimeRange(
            hasMedia: true, state: .ended, duration: .seconds(120), displayTime: displayTime
        )
        #expect(CMTimeRangeContainsTime(range, time: displayTime))
    }

    @Test
    func `skip is clamped and invalid or nonseekable requests are rejected`() {
        let target = MPVPictureInPicturePlaybackPolicy.seekTarget
        #expect(target(.seconds(5), CMTime(seconds: -15, preferredTimescale: 600), .seconds(60), true) == .zero)
        #expect(target(.seconds(55), CMTime(seconds: 15, preferredTimescale: 600), .seconds(60), true) == .seconds(60))
        #expect(target(.seconds(5), CMTime(seconds: 15, preferredTimescale: 600), .zero, true) == .seconds(20))
        #expect(target(.seconds(5), .positiveInfinity, .seconds(60), true) == nil)
        #expect(target(.seconds(5), .indefinite, .seconds(60), true) == nil)
        #expect(target(.seconds(5), .invalid, .seconds(60), true) == nil)
        #expect(target(.seconds(5), .zero, .seconds(60), false) == nil)
    }
}
