#if os(macOS)
import Foundation
import Libmpv
@testable import MPVUI
import Testing

/// Opens the real system audio route (muted). Run explicitly on a Mac with an
/// audio output; the default lane uses null audio output.
@Suite(.tags(.system), .serialized, .enabled(if:
    ProcessInfo.processInfo.environment["MPVUI_RUN_NATIVE_AUDIO_TESTS"] == "1"
))
@MainActor
struct MPVNativeAudioIntegrationTests {
    @Test
    func `pcm keeps default buffering and supports transport`() async throws {
        let audio = try Session()
        defer { audio.close() }
        #expect(audio.string("options/ao-avfoundation-max-lookahead") == "0.000000"
            || audio.number("options/ao-avfoundation-max-lookahead") == 0)
        try await audio.load(TestPaths.baselineMedia)
        try await audio.wait("PCM output and advancing audio clock") {
            audio.string("current-ao") == "avfoundation" && audio.number("audio-pts") > 0.25
        }
        #expect(!audio.string("audio-out-params/format").contains("spdif"))
        try await audio.pauseAndSeek(to: 0.6)
        try audio.set("pause", "no")
        try await audio.wait("PCM EOF") { audio.eof }
    }

    @Test(arguments: ["ac3-short.mka", "eac3-short.mka"])
    func `compressed transport and EOF`(_ fixture: String) async throws {
        let audio = try Session(options: [
            "audio-spdif": "ac3,eac3",
        ])
        let format = fixture.contains("eac3") ? "spdif-eac3" : "spdif-ac3"
        defer { audio.close() }
        try await audio.load(TestPaths.testMedia(fixture))
        try await audio.wait("compressed output and advancing Apple audio clock") {
            audio.string("current-ao") == "avfoundation"
                && audio.string("audio-out-params/format") == format
                && audio.number("audio-pts") > 0.3
                && audio.nativeClockStarts > 0
        }
        let initialClockStarts = audio.nativeClockStarts
        try await audio.pauseAndSeek(to: 1.5)
        try audio.set("pause", "no")
        try await audio.wait("compressed post-seek clock") {
            audio.number("audio-pts") > 1.8 && audio.nativeClockStarts > initialClockStarts
        }
        #expect(audio.string("audio-out-params/format") == format)
        let clock = audio.number("audio-pts")
        try await audio.wait("continued compressed clock") { audio.number("audio-pts") > clock + 0.2 }
        #expect(audio.string("audio-out-params/format") == format)
        let postSeekClockStarts = audio.nativeClockStarts
        try audio.command(["seek", "5", "absolute+exact"])
        try await audio.wait("compressed output near EOF") {
            audio.number("audio-pts") > 5.1 && audio.nativeClockStarts > postSeekClockStarts
        }
        #expect(audio.string("audio-out-params/format") == format)
        try await audio.wait("compressed EOF") { audio.eof }
        #expect(audio.logs.contains("native compressed audio drained at"), "\(audio.logs)")
        #expect(!audio.logs.lowercased().contains("falling back to pcm"), "\(audio.logs)")
    }

    @Test(arguments: ["ac3-stream.mka", "eac3-stream.mka"])
    func `compressed bounded stream drains at natural EOF`(_ fixture: String) async throws {
        let audio = try Session(options: ["audio-spdif": "ac3,eac3"])
        defer { audio.close() }
        let format = fixture.contains("eac3") ? "spdif-eac3" : "spdif-ac3"
        try await audio.load(TestPaths.testMedia(fixture))
        try await audio.wait("bounded stream starts on Apple's clock") {
            audio.string("audio-out-params/format") == format && audio.nativeClockStarts > 0
                && audio.logs.contains("(bounded stream)")
        }
        let began = ContinuousClock.now
        try await audio.wait("bounded compressed stream reaches natural EOF", timeout: 35) {
            audio.eof
        }
        // The complete24-second stream must stay alive beyond queued input EOF.
        #expect(began.duration(to: .now) > .seconds(20))
        #expect(audio.logs.contains("native compressed audio drained at"), "\(audio.logs)")
        #expect(!audio.logs.lowercased().contains("falling back to pcm"), "\(audio.logs)")
    }

    @Test(arguments: [false, true])
    func `compressed close during startup is bounded`(paused: Bool) async throws {
        let audio = try Session(options: ["audio-spdif": "ac3,eac3", "gapless-audio": "yes"])
        defer { audio.close() }
        try await audio.load(TestPaths.testMedia("ac3-short.mka"), resume: !paused)
        #expect(audio.string("audio-out-params/format") == "spdif-ac3")
        // Close synchronously just after initialization/resume, before yielding
        // the main run loop to Apple preroll. Even a parked clock must finish.
        let start = ContinuousClock.now
        audio.close()
        #expect(start.duration(to: .now) < .seconds(14))
    }

    @Test
    func `explicit device uses PCM without affecting another compressed player`() async throws {
        let compressed = try Session(options: [
            "audio-spdif": "ac3,eac3",
            "loop-file": "inf",
        ])
        defer { compressed.close() }
        let devices = compressed.node("audio-device-list")
        guard case let .array(entries) = devices else {
            Issue.record("Audio device list unavailable")
            return
        }
        let names = entries.compactMap { entry -> String? in
            guard case let .map(values) = entry, case let .string(name) = values["name"],
                  name.hasPrefix("avfoundation/"), name != "avfoundation/"
            else { return nil }
            return name
        }
        let device = try #require(names.first, "This test needs an explicit AVFoundation output device.")
        let routed = try Session(options: ["audio-spdif": "ac3,eac3", "audio-device": device])
        defer { routed.close() }
        try await compressed.load(TestPaths.testMedia("ac3-short.mka"))
        try await compressed.wait("first compressed player clock") {
            compressed.string("audio-out-params/format") == "spdif-ac3"
                && compressed.number("audio-pts") > 0.2
                && compressed.nativeClockStarts > 0
        }
        try await routed.load(TestPaths.testMedia("eac3-short.mka"))
        try await routed.wait("explicit device PCM routing") {
            routed.string("current-ao") == "avfoundation" && routed.number("audio-pts") > 0.2
        }
        #expect(!routed.string("audio-out-params/format").contains("spdif"))
        #expect(routed.string("audio-device") == device)
        try await compressed.wait("independent compressed player") {
            compressed.string("audio-out-params/format") == "spdif-ac3"
                && compressed.number("audio-pts") > 0.2
        }
        try await compressed.wait("compressed output reopens across the first loop boundary") {
            compressed.nativeClockStarts >= 2
                && compressed.string("audio-out-params/format") == "spdif-ac3"
                && compressed.number("audio-pts") > 0.2
        }
        let clock = compressed.number("audio-pts")
        try await compressed.wait("concurrent compressed clock continues") {
            let now = compressed.number("audio-pts")
            return now > clock + 0.2 || (clock > 5 && now < clock - 1)
        }
        #expect(compressed.string("audio-out-params/format") == "spdif-ac3")
        #expect(!compressed.logs.lowercased().contains("falling back to pcm"), "\(compressed.logs)")
    }

    @MainActor
    private final class Session {
        private var handle: OpaquePointer?
        var eof = false
        var logs = ""
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
}
#endif
