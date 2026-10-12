import AVFoundation
import CoreMedia
import Libmpv

/// Hands an ``MPVPassthroughAudioSink`` to mpv's `spatial` audio output as the C sink it expects.
///
/// mpv keeps the sink's address, so the bridge must outlive every handle given ``address``.
final class MPVPassthroughAudioSinkBridge: @unchecked Sendable {

    let sink: any MPVPassthroughAudioSink
    private let fallback: @Sendable (MPVPassthroughAudioCodec, Int) -> Void
    private let cSink: UnsafeMutablePointer<mpv_spatial_audio_sink>
    private let lock = NSLock()
    /// Counts opens and closes, so a fallback can tell whether its output is still open.
    private var session = 0

    /// The value of mpv's `ao-spatial-sink` option.
    var address: String {
        String(Int(bitPattern: cSink))
    }

    /// `fallback` receives the failed codec and its session, which ``isOpen(_:)`` checks.
    init(sink: any MPVPassthroughAudioSink, fallback: @escaping @Sendable (MPVPassthroughAudioCodec, Int) -> Void) {
        self.sink = sink
        self.fallback = fallback
        cSink = .allocate(capacity: 1)
        cSink.initialize(to: mpv_spatial_audio_sink(
            version: MPV_SPATIAL_AUDIO_SINK_VERSION,
            ctx: nil,
            open: { ctx, codec, synchronizer in
                let bridge = MPVPassthroughAudioSinkBridge.bridge(ctx)
                guard let synchronizer, let codec = MPVPassthroughAudioCodec(codec) else { return false }
                let renderSynchronizer = Unmanaged<AVSampleBufferRenderSynchronizer>.fromOpaque(synchronizer)
                    .takeUnretainedValue()
                let fallback = bridge.fallback
                let session = bridge.nextSession()
                let opened = bridge.sink.open(codec: codec, synchronizer: renderSynchronizer) {
                    fallback(codec, session)
                }
                // Otherwise mpv's autoprobe could pass the stream through another output.
                if !opened {
                    fallback(codec, session)
                }
                return opened
            },
            begin: { ctx, time in
                MPVPassthroughAudioSinkBridge.bridge(ctx).sink.begin(at: CMTime(value: time, timescale: 1_000_000_000))
            },
            write: { ctx, data, size in
                guard let data else { return }
                MPVPassthroughAudioSinkBridge.bridge(ctx).sink.write(UnsafeRawBufferPointer(start: data, count: size))
            },
            is_ready: { ctx in
                MPVPassthroughAudioSinkBridge.bridge(ctx).sink.isReady
            },
            // Failures go through `fallback` instead, which decodes to PCM without mpv's
            // process-wide latch.
            has_failed: { _ in false },
            close: { ctx in
                let bridge = MPVPassthroughAudioSinkBridge.bridge(ctx)
                _ = bridge.nextSession()
                bridge.sink.close()
            },
            end: { ctx in
                MPVPassthroughAudioSinkBridge.bridge(ctx).sink.end()
            },
            set_volume: { ctx, volume in
                MPVPassthroughAudioSinkBridge.bridge(ctx).sink.setVolume(volume)
            }
        ))
        cSink.pointee.ctx = Unmanaged.passUnretained(self).toOpaque()
    }

    deinit {
        cSink.deinitialize(count: 1)
        cSink.deallocate()
    }

    /// Whether the output that opened `session` is still open.
    func isOpen(_ session: Int) -> Bool {
        lock.withLock { self.session == session }
    }

    private func nextSession() -> Int {
        lock.withLock {
            session += 1
            return session
        }
    }

    private static func bridge(_ ctx: UnsafeMutableRawPointer?) -> MPVPassthroughAudioSinkBridge {
        Unmanaged<MPVPassthroughAudioSinkBridge>.fromOpaque(ctx!).takeUnretainedValue()
    }
}

extension MPVPassthroughAudioCodec {

    init?(_ codec: mpv_spatial_audio_codec) {
        switch codec {
        case MPV_SPATIAL_AUDIO_CODEC_TRUEHD:
            self = .trueHD
        case MPV_SPATIAL_AUDIO_CODEC_DTSHD:
            self = .dtsHD
        default:
            return nil
        }
    }

    /// The codec's name in mpv's `audio-spdif` option.
    var spdifName: String {
        switch self {
        case .trueHD: "truehd"
        case .dtsHD: "dts-hd"
        }
    }
}
