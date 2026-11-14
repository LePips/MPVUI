import Darwin
import Foundation
import Libmpv
@testable import MPVCore
@testable import MPVUI
import Testing

/// Owns a software-decoded libmpv session without a platform presenter.
/// Call `close()` from `defer`. Keep assertions in the behavior's test suite.
@MainActor
final class NativePlaybackSession {

    private let handle: OpaquePointer

    init(options: [String: String] = [:]) throws {
        handle = try #require(mpv_create())

        do {
            #if os(macOS)
            // Only the macOS build includes the Lua downloader. Exercise the native protocol handlers directly.
            try #require(mpv_set_option_string(handle, "ytdl", "no") >= 0)
            #endif
            for (name, value) in [
                "vo": "null",
                "ao": "null",
                "idle": "yes",
                "pause": "yes",
                "keep-open": "yes",
                "hwdec": "no",
                "audio": "no",
                "image-display-duration": "inf",
                "msg-level": "all=error",
            ].merging(options, uniquingKeysWith: { _, new in new }) {
                try #require(mpv_set_option_string(handle, name, value) >= 0, "Setting libmpv option \(name)")
            }

            try #require(mpv_initialize(handle) >= 0)
        } catch {
            mpv_destroy(handle)
            throw error
        }
    }

    func close() {
        mpv_terminate_destroy(handle)
    }

    func registerStream(
        protocol name: String,
        userData: UnsafeMutableRawPointer,
        open: mpv_stream_cb_open_ro_fn
    ) throws {
        try #require(mpv_stream_cb_add_ro(handle, name, userData, open) >= 0)
    }

    func property(_ name: String) -> MPVNodeValue? {
        var node = mpv_node()
        guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &node) >= 0 else { return nil }

        defer { mpv_free_node_contents(&node) }

        return MPVNodeValue(copying: node)
    }

    func consumePlaybackRestart() -> Bool {
        consumeEvent(MPV_EVENT_PLAYBACK_RESTART)
    }

    func consumeEndFileStatus() -> Int32? {
        while let event = mpv_wait_event(handle, 0)?.pointee {
            if event.event_id == MPV_EVENT_NONE {
                return nil
            }

            if event.event_id == MPV_EVENT_END_FILE, let data = event.data {
                return data.assumingMemoryBound(to: mpv_event_end_file.self).pointee.error
            }
        }

        return nil
    }

    @discardableResult
    func command(_ arguments: [String]) throws -> MPVNodeValue? {
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }

        var pointers: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer($0) } } + [nil]
        var node = mpv_node()
        defer { mpv_free_node_contents(&node) }
        try #require(mpv_command_ret(handle, &pointers, &node) >= 0, "Command failed: \(arguments)")

        return MPVNodeValue(copying: node)
    }

    func load(_ url: URL) async throws {
        if url.isFileURL {
            try #require(FileManager.default.fileExists(atPath: url.path))
        }
        try await load(argument: url.isFileURL ? url.path : url.absoluteString, named: url.lastPathComponent)
    }

    func load(argument: String, named name: String) async throws {
        // A replacement can leave the previous item's video properties readable until FILE_LOADED.
        while consumeEvent(MPV_EVENT_FILE_LOADED) {}
        try command(["loadfile", argument])
        try await eventually("libmpv loads \(name)") { self.consumeEvent(MPV_EVENT_FILE_LOADED) }
        try await eventually("decoded frame from \(name)") {
            self.property("video-out-params/w")?.integerValue != nil
                && self.property("time-pos")?.doubleValue != nil
        }
    }

    private func consumeEvent(_ id: mpv_event_id) -> Bool {
        while let event = mpv_wait_event(handle, 0)?.pointee {
            if event.event_id == MPV_EVENT_NONE {
                return false
            }

            if event.event_id == id {
                return true
            }
        }

        return false
    }
}
