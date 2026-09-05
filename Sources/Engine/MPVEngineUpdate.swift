enum MPVEngineUpdate: Sendable {
    case state(MPVPlaybackState)
    case timing(position: Duration, duration: Duration, isSeekable: Bool)
    case buffer(MPVBufferStatus)
    case media(MPVMediaInformation)
    case audio(volume: Double, isMuted: Bool, playbackRate: Double)
    case textSubtitles(TextSubtitleSnapshot)
    case error(MPVPlayerError, fatal: Bool)
    case log(MPVEngineLog)
}
