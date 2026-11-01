#if os(macOS)
import Foundation
import Libmpv
@testable import MPVCore
@testable import MPVUI
import Testing

/// Opens the actual audio output paused and mutes the sink before playback.
@MainActor
final class NativeAudioSession {

    var eof = false
    var logs = ""
    private var handle: OpaquePointer?

    var nativeClockStarts: Int {
        logs.components(separatedBy: "native compressed clock started at").count - 1
    }

    init(options: [String: String] = [:]) throws {
        let h = try #require(mpv_create())
        handle = h

        do {
            var defaults = [
                "vo": "null",
                "ao": "avfoundation",
                "idle": "yes",
                "keep-open": "no",
                "volume": "0",
                "cache": "no",
                "audio-display": "no",
                "vid": "no",
                "terminal": "no",
                "pause": "yes"
            ]
            defaults.merge(MPVAudioConfiguration().mpvOptions) { _, new in new }
            defaults.merge(options) { _, new in new }

            for (name, value) in defaults {
                try #require(mpv_set_option_string(h, name, value) >= 0, "\(name)=\(value)")
            }

            try #require(mpv_request_log_messages(h, "v") >= 0)
            try #require(mpv_initialize(h) >= 0)
        } catch {
            mpv_destroy(h)
            handle = nil
            throw error
        }
    }

    func close() {
        guard let h = handle else { return }

        handle = nil
        mpv_terminate_destroy(h)
    }

    func set(_ name: String, _ value: String) throws {
        try #require(mpv_set_property_string(handle, name, value) >= 0)
    }

    func command(_ arguments: [String]) throws {
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }

        var pointers = strings.map { UnsafePointer<CChar>($0) } + [nil]
        let result = pointers.withUnsafeMutableBufferPointer { mpv_command(handle, $0.baseAddress) }
        try #require(result >= 0)
    }

    func load(_ url: URL, resume: Bool = true) async throws {
        eof = false
        try command(["loadfile", url.path])

        try await wait("paused audio output initialization") {
            !self.string("current-ao").isEmpty
        }

        // Software volume cannot be assumed to mute an IEC 61937 stream.
        // Mute the real sink before allowing it to start playback.
        try set("ao-mute", "yes")

        #expect(string("ao-mute") == "yes")

        if resume {
            try set("pause", "no")
        }
    }

    func string(_ name: String) -> String {
        guard let p = mpv_get_property_string(handle, name) else { return "" }

        defer { mpv_free(p) }
        return String(cString: p)
    }

    func number(_ name: String) -> Double {
        var value = Double.nan
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return .nan }

        return value
    }

    func node(_ name: String) -> MPVNodeValue? {
        var value = mpv_node()
        guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &value) >= 0 else { return nil }

        defer { mpv_free_node_contents(&value) }

        return MPVNodeValue(copying: value)
    }

    func drainEvents() {
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            if event.pointee.event_id == MPV_EVENT_LOG_MESSAGE, let data = event.pointee.data {
                let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                logs += String(cString: message.text)
            }

            if event.pointee.event_id == MPV_EVENT_END_FILE, let data = event.pointee.data {
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                eof = end.reason == MPV_END_FILE_REASON_EOF

                #expect(end.reason != MPV_END_FILE_REASON_ERROR, "Native audio failed: \(logs)")
            }
        }
    }

    func wait(_ context: String, timeout: Double = 15, until predicate: () -> Bool) async throws {
        for _ in 0 ..< Int(timeout * 50) {
            drainEvents()

            if predicate() {
                return
            }

            try await Task.sleep(for: .milliseconds(20))
        }

        try #require(predicate(), "Timed out: \(context)\n\(logs)")
    }

    func pauseAndSeek(to destination: Double) async throws {
        try set("pause", "yes")

        // A property write acknowledges the request before the sink's last
        // clock update has reached time-pos. Wait for a paused core and a
        // stable timeline; a fixed 100 ms delay races that final update.
        let clock = ContinuousClock()
        var lastPosition = number("time-pos")
        var stableSince = clock.now

        try await wait("paused output clock settles", timeout: 3) {
            let position = self.number("time-pos")

            if !position.isFinite || abs(position - lastPosition) > 0.01 {
                lastPosition = position
                stableSince = clock.now
                return false
            }

            return self.string("pause") == "yes" && self.string("core-idle") == "yes"
                && stableSince.duration(to: clock.now) >= .milliseconds(300)
        }

        let paused = number("time-pos")

        try await Task.sleep(for: .milliseconds(150))

        #expect(abs(number("time-pos") - paused) < 0.1)
        try command(["seek", String(destination), "absolute+exact"])
        try await wait("paused seek") { abs(self.number("time-pos") - destination) < 0.15 }

        #expect(string("pause") == "yes")
    }
}

#endif
