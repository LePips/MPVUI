import Foundation
import Libmpv
import MPVCore

/// Runs native media packaging on a worker queue and reports status through an async stream.
final class MPVMediaPackager: @unchecked Sendable {

    struct Info: Sendable {

        let videoCopied: Bool
        let audioCopied: Bool
        let hasVideo: Bool
        let hasAudio: Bool
        let requiresForeground: Bool
        let startTime: Double
        let frameRate: Double
        let videoCodec: String
        let audioCodec: String
        let audioChannels: String
        let videoRange: String
        let dolbyVisionProfile: Int
        let dolbyVisionLevel: Int

        var isTranscoding: Bool {
            (hasVideo && !videoCopied) || (hasAudio && !audioCopied)
        }

        init(_ info: mpvui_hls_info) {
            videoCopied = info.video_copied != 0
            audioCopied = info.audio_copied != 0
            hasVideo = info.has_video != 0
            hasAudio = info.has_audio != 0
            requiresForeground = info.requires_foreground != 0
            startTime = info.start_time
            frameRate = info.frame_rate
            videoCodec = withUnsafeBytes(of: info.video_codec) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            audioCodec = withUnsafeBytes(of: info.audio_codec) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            audioChannels = info.audio_joc != 0 ? "16/JOC" : String(info.audio_channels)
            videoRange = info.video_range == 1 ? "PQ" : info.video_range == 2 ? "HLG" : "SDR"
            dolbyVisionProfile = Int(info.dolby_vision_profile)
            dolbyVisionLevel = Int(info.dolby_vision_level)
        }
    }

    enum Update: Sendable {

        case prepared(Info)
        case finished
        case failed(String)
    }

    let updates: AsyncStream<Update>
    private let continuation: AsyncStream<Update>.Continuation
    private let queue = DispatchQueue(label: "com.lepips.MPVUI.packager", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "com.lepips.MPVUI.packager-control", qos: .userInitiated)
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var cancelled = false

    init() {
        (updates, continuation) = AsyncStream.makeStream()
    }

    func start(source: URL, playlist: URL, startTime: Duration, options: MPVMediaPackagingOptions) {
        queue.async { [self] in
            let scoped = source.isFileURL && source.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    source.stopAccessingSecurityScopedResource()
                }
                continuation.finish()
            }
            let client: OpaquePointer? = lock.withLock {
                guard !cancelled else { return nil }
                handle = mpvui_hls_create(
                    MPVSession.mpvPath(for: source),
                    playlist.path,
                    startTime.seconds,
                    options.videoIndex,
                    options.audioIndex
                )
                if let handle {
                    mpvui_hls_set_paused(handle, 1)
                }
                return handle
            }
            guard let client else {
                if !lock.withLock({ cancelled }) {
                    continuation.yield(.failed("Unable to create the media packager."))
                }
                return
            }
            defer {
                lock.withLock {
                    handle = nil
                    mpvui_hls_destroy(client)
                }
            }
            for (key, value) in options.input {
                guard mpvui_hls_set_option(client, key, value) >= 0 else {
                    continuation.yield(.failed("Unable to configure the media input."))
                    return
                }
            }
            var info = mpvui_hls_info()
            guard mpvui_hls_prepare(client, &info) >= 0 else {
                continuation.yield(.failed(String(cString: mpvui_hls_error(client))))
                return
            }
            continuation.yield(.prepared(Info(info)))
            if mpvui_hls_run(client) < 0 {
                if !lock.withLock({ cancelled }) {
                    continuation.yield(.failed(String(cString: mpvui_hls_error(client))))
                }
            } else {
                continuation.yield(.finished)
            }
        }
    }

    func setPaused(_ paused: Bool) {
        lock.withLock {
            if let handle {
                mpvui_hls_set_paused(handle, paused ? 1 : 0)
            }
        }
    }

    func updatePlaybackPosition(_ position: Duration) {
        // The native lock can wait for frame processing. Acquire it off the main actor to keep playback updates responsive.
        controlQueue.async { [self] in
            lock.withLock {
                if let handle {
                    mpvui_hls_set_playback_position(handle, position.seconds)
                }
            }
        }
    }

    func stop() async {
        lock.withLock {
            cancelled = true
            if let handle {
                mpvui_hls_cancel(handle)
            }
        }
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
