#if os(macOS)
import AppKit
import Darwin
import Foundation
import Libmpv
@testable import MPVUI
import Testing

@Suite(.tags(.integration, .nativePatch), .serialized)
struct MPVMetadataObservationTests {
    private static let videoProperties = [
        "video-params", "video-dec-params", "video-out-params", "video-target-params",
    ]

    @Test
    func `typed video metadata observations suppress unchanged ticks and retain changes`() throws {
        let handle = try #require(mpv_create())
        var initialized = false
        defer {
            if initialized {
                mpv_terminate_destroy(handle)
            } else {
                mpv_destroy(handle)
            }
        }
        for (name, value) in [
            ("vo", "null"), ("ao", "null"), ("idle", "yes"),
            ("pause", "yes"), ("keep-open", "yes"), ("hwdec", "no"), ("speed", "0.25"),
        ] {
            try #require(mpv_set_option_string(handle, name, value) >= 0)
        }
        try #require(mpv_initialize(handle) >= 0)
        initialized = true

        // Observe each actual native property both ways on the same handle.
        // This tests libmpv's value comparison without timing thresholds or
        // changing the production event queue to add test counters.
        for (index, name) in Self.videoProperties.enumerated() {
            try #require(mpv_observe_property(handle, UInt64(index + 1), name, MPV_FORMAT_NODE) >= 0)
            try #require(mpv_observe_property(handle, UInt64(index + 101), name, MPV_FORMAT_NONE) >= 0)
        }
        var initial: [UInt64: NativePropertyEvent] = [:]
        try collect(handle, until: { initial.count == Self.videoProperties.count }) { event in
            if event.id < 100 {
                initial[event.id] = event
            }
        }
        #expect(initial.values.allSatisfy { $0.format == MPV_FORMAT_NONE && $0.value == nil })

        try #require(runCommand(handle, ["loadfile", TestPaths.baselineMedia.path, "replace"]) >= 0)
        var latest: [UInt64: MPVNodeValue] = [:]
        try collect(handle, until: { (1 ... 3).allSatisfy { latest[UInt64($0)]?.mapValue != nil } }) { event in
            if event.id < 100 {
                latest[event.id] = event.value
            }
        }
        // Finish initial decoder/VO configuration before counting stable ticks.
        drain(handle, seconds: 0.15) { event in
            if event.id < 100 {
                latest[event.id] = event.value
            }
        }
        var typedCounts: [UInt64: Int] = [:]
        var notificationCounts: [UInt64: Int] = [:]
        try #require(mpv_set_property_string(handle, "pause", "no") >= 0)
        try collect(handle, until: {
            (101 ... 104).allSatisfy { notificationCounts[UInt64($0), default: 0] >= 3 }
        }) { event in
            if event.id < 100 {
                // Real value changes may occur during playback. An identical
                // already-delivered value must not be repeated.
                #expect(event.value != latest[event.id])
                typedCounts[event.id, default: 0] += 1
                latest[event.id] = event.value
            } else {
                notificationCounts[event.id, default: 0] += 1
            }
        }
        for id in UInt64(1) ... 4 {
            #expect(typedCounts[id, default: 0] < notificationCounts[id + 100, default: 0])
        }

        try #require(mpv_set_property_string(handle, "pause", "yes") >= 0)
        drain(handle, seconds: 0.1) { _ in }
        let originalWidth = try #require(latest[3]?.mapValue?["w"]?.integerValue)
        let originalHeight = try #require(latest[3]?.mapValue?["h"]?.integerValue)
        let width = originalWidth + 16
        let height = originalHeight + 16
        try #require(mpv_set_property_string(handle, "vf", "scale=\(width):\(height)") >= 0)
        var resized: MPVNodeValue?
        try collect(handle, until: { resized?.mapValue?["w"]?.integerValue == width }) { event in
            if event.id == 3 {
                resized = event.value
            }
        }
        #expect(resized?.mapValue?["h"]?.integerValue == height)

        // Stopping retires the decoder and VO. Previously available maps must
        // explicitly become unavailable, then become available on a new load.
        try #require(runCommand(handle, ["stop"]) >= 0)
        var unavailable: Set<UInt64> = []
        try collect(handle, until: { (1 ... 3).allSatisfy { unavailable.contains(UInt64($0)) } }) { event in
            if event.id < 100, event.format == MPV_FORMAT_NONE, event.value == nil {
                unavailable.insert(event.id)
            }
        }
        try #require(runCommand(handle, ["loadfile", TestPaths.baselineMedia.path, "replace"]) >= 0)
        var restored: Set<UInt64> = []
        try collect(handle, until: { (1 ... 3).allSatisfy { restored.contains(UInt64($0)) } }) { event in
            if event.id < 100, event.value?.mapValue != nil {
                restored.insert(event.id)
            }
        }
    }

    @MainActor @Test
    func `paused player metadata follows filter formats and video track availability`() async throws {
        let player = MPVPlayer(configuration: .init(
            autoPlay: false, hardwareDecoding: .disabled, hdrPolicy: .disabled,
            sdrOutput: .compatibility8Bit, logLevel: .none,
            additionalOptions: ["ao": "null", "vf": "format=fmt=nv12"]
        ))
        let surface = MPVPlatformVideoPlayer(player: player)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.activateRenderingSurface()
        defer {
            player.stop()
            surface.detach()
            window.contentView = nil
        }
        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .milliseconds(400))
        try await waitUntil {
            player.state == .paused
                && player.mediaInformation.hdr.videoOutputInput.pixelFormat == "nv12"
                && player.mediaInformation.hdr.output.pixelFormat != nil
        }
        let original = player.mediaInformation
        let track = try #require(original.tracks.first { $0.type == .video && $0.isSelected })
        let lifecycle = await player.lifecycleDiagnostics()

        player.setProperty("vf", to: "format=fmt=p010")
        try await waitUntil { player.mediaInformation.hdr.videoOutputInput.pixelFormat == "p010" }
        #expect(player.mediaInformation.hdr.source == original.hdr.source)
        #expect(player.mediaInformation.hdr.decoded == original.hdr.decoded)
        #expect(player.mediaInformation.dimensions == original.dimensions)
        #expect(player.isPaused)
        #expect(player.lastError == nil)

        player.setProperty("vf", to: "format=fmt=nv12")
        try await waitUntil { player.mediaInformation.hdr.videoOutputInput.pixelFormat == "nv12" }
        #expect(player.mediaInformation.hdr.output == original.hdr.output)

        player.disableTrack(.video)
        try await waitUntil {
            player.mediaInformation.dimensions == nil
                && player.mediaInformation.hdr.videoOutputInput.pixelFormat == nil
        }
        player.selectTrack(track.id)
        try await waitUntil {
            player.mediaInformation.dimensions == original.dimensions
                && player.mediaInformation.hdr.videoOutputInput.pixelFormat == "nv12"
        }
        #expect(player.mediaInformation.hdr.source == original.hdr.source)
        #expect(player.isPaused)
        #expect(player.lastError == nil)
        let finished = await player.lifecycleDiagnostics()
        #expect(finished.handlesCreated == lifecycle.handlesCreated)
        #expect(finished.handlesDestroyed == lifecycle.handlesDestroyed)
        #expect(finished.loadCommands == lifecycle.loadCommands)
    }

    private struct NativePropertyEvent {
        let id: UInt64
        let format: mpv_format
        let value: MPVNodeValue?
    }

    private func readPropertyEvent(_ handle: OpaquePointer, timeout: Double) -> NativePropertyEvent? {
        guard let event = mpv_wait_event(handle, timeout)?.pointee,
              event.event_id == MPV_EVENT_PROPERTY_CHANGE, let data = event.data else { return nil }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        return NativePropertyEvent(
            id: event.reply_userdata, format: property.format,
            value: MPVNodeValue(copying: property)
        )
    }

    private func collect(
        _ handle: OpaquePointer,
        until complete: () -> Bool,
        receive: (NativePropertyEvent) -> Void
    ) throws {
        let deadline = Date().addingTimeInterval(5)
        while !complete(), Date() < deadline {
            if let event = readPropertyEvent(handle, timeout: 0.02) {
                receive(event)
            }
        }
        try #require(complete(), "Native video metadata did not reach the expected state within five seconds.")
    }

    private func drain(_ handle: OpaquePointer, seconds: Double, receive: (NativePropertyEvent) -> Void) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let event = readPropertyEvent(handle, timeout: 0.02) {
                receive(event)
            }
        }
    }

    private func runCommand(_ handle: OpaquePointer, _ arguments: [String]) -> Int32 {
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = strings.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
        pointers.append(nil)
        return mpv_command(handle, &pointers)
    }

    @MainActor
    private func waitUntil(_ complete: () -> Bool) async throws {
        try await eventually("metadata change", timeout: .seconds(5)) { complete() }
    }
}
#endif
