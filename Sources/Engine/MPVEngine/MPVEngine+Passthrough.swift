import Foundation

extension MPVEngine {

    /// mpv's `audio-spdif` with a passthrough sink: the configured codecs, with TrueHD and DTS-HD only for the sink
    /// at rate 1, because it renders at the synchronizer's normal rate. A codec the sink failed on stays out until
    /// another track or file loads.
    var spdifCodecs: String {
        let configured = desiredProperties["audio-spdif"] ?? configuration.additionalOptions["audio-spdif"]
            ?? configuration.audio.mpvOptions["audio-spdif"] ?? ""
        let rate = desiredProperties["speed"].flatMap(Double.init) ?? configuration.playbackRate
        let sinkCodecs = [MPVPassthroughAudioCodec.trueHD, .dtsHD]
        let others = configured.split(separator: ",").map(String.init)
            .filter { codec in !sinkCodecs.contains { $0.spdifName == codec } }
        let offered = sinkCodecs
            .filter { rate == 1 && $0 != passthroughFallback?.codec }
            .map(\.spdifName)
        return (others + offered).joined(separator: ",")
    }

    /// Decodes the current track to PCM after the passthrough sink failed on it. Ignores a fallback from an output
    /// mpv has since closed.
    func fallBackToPCM(_ codec: MPVPassthroughAudioCodec, session: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard passthroughSinkBridge?.isOpen(session) == true, passthroughFallback?.codec != codec else { return }
        passthroughFallback = (getInt64("current-tracks/audio/id"), codec)
        applySpdifCodecs(reloadingAudio: true)
    }

    /// Offers TrueHD and DTS-HD to the passthrough sink again when another audio track is selected, by any means.
    func passthroughAudioTrackDidChange() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let fallback = passthroughFallback, let track = getInt64("current-tracks/audio/id"),
              track != fallback.track
        else { return }
        passthroughFallback = nil
        applySpdifCodecs(reloadingAudio: true)
    }

    /// Offers TrueHD and DTS-HD to the passthrough sink again before and as a file starts.
    func resetPassthroughFallback() {
        dispatchPrecondition(condition: .onQueue(queue))
        passthroughFallback = nil
        applySpdifCodecs(reloadingAudio: false)
    }

    /// Updates `audio-spdif` for the passthrough sink. When it changed during TrueHD or DTS playback, reselects the
    /// audio track, so mpv rebuilds the decoder and output as for a track switch.
    func applySpdifCodecs(reloadingAudio: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard passthroughSinkBridge != nil, handle != nil else { return }
        let codecs = spdifCodecs
        guard getString("audio-spdif") != codecs else { return }
        _ = setPropertyImmediately("audio-spdif", to: codecs)
        guard reloadingAudio,
              ["truehd", "dts"].contains(getString("current-tracks/audio/codec")),
              let track = getInt64("current-tracks/audio/id")
        else { return }
        _ = setPropertyImmediately("aid", to: "no")
        _ = setPropertyImmediately("aid", to: String(track))
    }
}
