import AVFoundation
import CoreMedia

/// Renders TrueHD and DTS-HD for ``MPVPlayer`` instead of mpv decoding them to PCM, for example as Apple
/// spatial audio.
///
/// Set ``MPVAudioConfiguration/passthroughSink`` to receive these codecs. mpv writes the bitstream as
/// IEC 61937 bursts and keeps its clock on the synchronizer passed to
/// ``open(codec:synchronizer:fallback:)``: render into it, and playback waits until ``isReady`` is true.
/// Other codecs, and these at a playback rate other than 1, still play through mpv's own audio output.
///
/// mpv serializes these calls, though not on one thread: opening, closing and resets run outside its audio
/// thread. ``setVolume(_:)`` comes from its core thread, concurrently with the others.
public protocol MPVPassthroughAudioSink: AnyObject, Sendable {

    /// Prepares to render `codec` into `synchronizer`, which stays valid until ``close()``.
    ///
    /// Return `false` to refuse, and mpv decodes the track to PCM. If rendering fails later, call `fallback`:
    /// the player then decodes this codec to PCM until another track or file loads.
    func open(
        codec: MPVPassthroughAudioCodec,
        synchronizer: AVSampleBufferRenderSynchronizer,
        fallback: @escaping @Sendable () -> Void
    ) -> Bool

    /// Starts a new timeline at `time` on the synchronizer's clock, dropping everything queued.
    func begin(at time: CMTime)

    /// IEC 61937 bursts as mpv's passthrough produces them, split anywhere, continuing the timeline.
    ///
    /// The bytes are only valid until this returns: copy what you keep.
    func write(_ bursts: UnsafeRawBufferPointer)

    /// Whether enough audio is queued to start the clock.
    var isReady: Bool { get }

    /// Nothing more is written until the next ``begin(at:)``: render everything written and become ready.
    func end()

    /// Releases what ``open(codec:synchronizer:fallback:)`` prepared.
    func close()

    /// mpv's volume, volume gain, replay gain and mute as a linear gain, 0 when muted.
    ///
    /// Called after opening and whenever it changes, also while paused. Above 1 is amplification the sink
    /// may clamp.
    func setVolume(_ volume: Float)
}

/// A codec that ``MPVPassthroughAudioSink`` receives.
public enum MPVPassthroughAudioCodec: Sendable {
    case trueHD
    case dtsHD
}
