import Darwin
import Foundation
import Libmpv
@testable import MPVUI
import Testing

/// Owns a software-decoded libmpv session without a platform presenter.
/// Call close() from defer; assertions belong in the behavior's test suite.
@MainActor
final class NativePlaybackSession {
    private let handle: OpaquePointer

    init(options: [String: String] = [:]) throws {
        handle = try #require(mpv_create())
        do {
            for (name, value) in [
                "vo": "null", "ao": "null", "idle": "yes", "pause": "yes",
                "keep-open": "yes", "hwdec": "no", "audio": "no",
                "image-display-duration": "inf", "msg-level": "all=error",
            ].merging(options, uniquingKeysWith: { _, new in new }) {
                try #require(mpv_set_option_string(handle, name, value) >= 0)
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

    func property(_ name: String) -> MPVNodeValue? {
        var node = mpv_node()
        guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &node) >= 0 else { return nil }
        defer { mpv_free_node_contents(&node) }
        return MPVNodeValue(copying: node)
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
        try #require(FileManager.default.fileExists(atPath: url.path))
        try command(["loadfile", url.path])
        try await eventually("decoded frame from \(url.lastPathComponent)") {
            self.property("video-out-params/w")?.integerValue != nil
                && self.property("time-pos")?.doubleValue != nil
        }
    }
}
