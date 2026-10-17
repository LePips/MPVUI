#if os(Android)
@_exported import MPVCore

typealias MPVPlayer = AndroidPlayer
typealias MPVPlayerConfiguration = MPVCore.MPVSessionConfiguration
#else
import MPVUI

// Keep the screen's player API identical on both platforms.
typealias MPVPlayer = MPVUI.MPVPlayer
typealias MPVPlayerConfiguration = MPVUI.MPVPlayerConfiguration
typealias MPVVideoPlayer = MPVUI.MPVVideoPlayer
typealias MPVMediaTrack = MPVUI.MPVMediaTrack
typealias MPVTrackType = MPVUI.MPVTrackType
typealias MPVSubtitleRole = MPVUI.MPVSubtitleRole
#endif

extension Duration {

    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
