import Foundation
import Libmpv
import MPVCore

/// Encodes HLS through a separate mpv client while preserving the local playback client's renderer.
/// Serializes conversion commands and event handling on a dedicated queue.
final class MPVMediaTranscoder: @unchecked Sendable {

    enum Update: Sendable {

        case progress(Double)
        case finished
        case failed(String)
    }

    struct Request: Sendable {

        let source: URL
        let playlist: URL
        let startTime: Duration
        let options: [String: String]
        var toneMapHDR = false
        var initiallyPaused = false
    }

    private struct ConversionError: Error {

        let message: String
    }

    let updates: AsyncStream<Update>
    private let queue = DispatchQueue(label: "com.lepips.MPVUI.transcoder", qos: .userInitiated)
    private let events: DispatchSourceUserDataAdd
    private var handle: OpaquePointer?
    private var context: WeakBox<MPVMediaTranscoder>?
    private var securityScopedURL: URL?
    private var failureMessage: String?
    private var isFinished = false
    private let continuation: AsyncStream<Update>.Continuation

    init() {
        (updates, continuation) = AsyncStream.makeStream()
        events = DispatchSource.makeUserDataAddSource(queue: queue)
        events.setEventHandler { [weak self] in self?.drainEvents() }
        events.activate()
    }

    deinit {
        events.cancel()

        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
        }

        securityScopedURL?.stopAccessingSecurityScopedResource()
        continuation.finish()
    }

    static func options(for request: Request) -> [String: String] {
        var options = request.options
        let scale = "w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"

        let filter = request.toneMapHDR
            ? "libplacebo=\(scale):format=yuv420p:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv"
            : "scale=\(scale),format=yuv420p"

        let owned = [
            "config": "no",
            "load-scripts": "no",
            "osc": "no",
            "osd-level": "0",
            "input-default-bindings": "no",
            "input-vo-keyboard": "no",
            "terminal": "no",
            "idle": "once",
            "keep-open": "no",
            "pause": request.initiallyPaused ? "yes" : "no",
            "o": request.playlist.path,
            "of": "hls",
            "ocopy-metadata": "no",
            "ofopts": "hls_time=2,hls_list_size=30,hls_flags=delete_segments+independent_segments+temp_file",
            "ovc": "h264_videotoolbox",
            "ovcopts": "b=6000000,g=60,bf=0,allow_sw=1,profile=high,level=4.1",
            "oac": "aac",
            "oacopts": "b=192000",
            "audio-channels": "stereo",
            "audio-samplerate": "48000",
            "hwdec": "videotoolbox-copy",
            "start": MPVSession.format(request.startTime),
            "vf": "lavfi=[\(filter),fps=30]",
        ]
        options.merge(owned) { _, owned in owned }

        return options
    }

    private static func message(_ status: Int32) -> String {
        String(cString: mpv_error_string(status))
    }

    func start(_ request: Request) {
        queue.async { [self] in
            guard handle == nil, !isFinished else { return }

            if request.source.isFileURL, request.source.startAccessingSecurityScopedResource() {
                securityScopedURL = request.source
            }

            guard let client = mpv_create() else {
                fail("Unable to create the media conversion client.")
                return
            }

            handle = client

            do {
                for (name, value) in Self.options(for: request).sorted(by: { $0.key < $1.key }) {
                    let result = mpv_set_option_string(client, name, value)

                    // Builds without scripting support do not expose load-scripts or osc.
                    if result == MPV_ERROR_OPTION_NOT_FOUND.rawValue, ["load-scripts", "osc"].contains(name) {
                        continue
                    }

                    guard result >= 0 else { throw ConversionError(message: "Configure \(name): \(Self.message(result))") }
                }

                mpv_request_log_messages(client, "error")

                let result = mpv_initialize(client)

                guard result >= 0 else {
                    throw ConversionError(
                        message: "Initialize HLS conversion: \(Self.message(result)). Use a Libmpv build with the HLS muxer enabled."
                    )
                }

                context = WeakBox(self)

                mpv_set_wakeup_callback(client, { pointer in
                    guard let pointer else { return }

                    Unmanaged<WeakBox<MPVMediaTranscoder>>.fromOpaque(pointer).takeUnretainedValue().value?.events.add(data: 1)
                }, Unmanaged.passUnretained(context!).toOpaque())

                mpv_observe_property(client, 1, "time-pos", MPV_FORMAT_DOUBLE)

                let arguments = ["loadfile", MPVSession.mpvPath(for: request.source), "replace"]
                let strings = arguments.map { strdup($0) }
                defer { strings.forEach { free($0) } }

                var pointers: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer($0) } } + [nil]
                let status = mpv_command(client, &pointers)
                guard status >= 0 else { throw ConversionError(message: "Open conversion source: \(Self.message(status))") }
            } catch {
                fail((error as? ConversionError)?.message ?? error.localizedDescription)
            }
        }
    }

    /// Pauses conversion to limit disk use and retain the current playback position in the HLS window.
    func setPaused(_ paused: Bool, synchronously: Bool = false) {
        let update: @Sendable () -> Void = { [self] in
            guard let handle, !isFinished else { return }

            mpv_set_property_string(handle, "pause", paused ? "yes" : "no")
        }

        if synchronously {
            queue.sync(execute: update)
        } else {
            queue.async(execute: update)
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finish()
                continuation.resume()
            }
        }
    }

    private func drainEvents() {
        guard let handle, !isFinished else { return }

        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_property.self),
                      data.pointee.format == MPV_FORMAT_DOUBLE,
                      let value = data.pointee.data?.assumingMemoryBound(to: Double.self).pointee,
                      value.isFinite else { continue }

                continuation.yield(.progress(value))

            case MPV_EVENT_LOG_MESSAGE:
                if let log = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self),
                   let message = log.pointee.text
                {
                    failureMessage = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
                }

            case MPV_EVENT_END_FILE:
                guard let end = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self) else { continue }

                if end.pointee.reason == MPV_END_FILE_REASON_ERROR {
                    fail(failureMessage ?? Self.message(end.pointee.error))
                    return
                }

            case MPV_EVENT_SHUTDOWN:
                // Shutdown follows the final segment write and ENDLIST marker.
                // END_FILE can arrive before those writes finish.
                continuation.yield(.finished)
                finish()
                return

            default:
                break
            }
        }
    }

    private func fail(_ message: String) {
        continuation.yield(.failed(message))
        finish()
    }

    private func finish() {
        isFinished = true

        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            self.handle = nil
        }

        context = nil
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        continuation.finish()
    }
}
