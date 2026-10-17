import Foundation
import Libmpv
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVBufferObservationTests {

    @Test
    func `typed cache observations retain native progress duration and resume state`() async throws {
        var buffers: [MPVBufferStatus] = []
        let engine = MPVSession(configuration: .init()) { emission in
            if case let .buffer(status) = emission.update {
                buffers.append(status)
            }
        }

        let handle = try #require(mpv_create())
        var initialized = false
        defer {
            engine.queue.sync { engine.handle = nil }
            if initialized {
                mpv_terminate_destroy(handle)
            } else {
                mpv_destroy(handle)
            }
        }
        for (name, value) in [
            ("vo", "null"),
            ("ao", "null"),
            ("idle", "yes"),
            ("pause", "yes"),
            ("keep-open", "yes"),
            ("hwdec", "no"),
            ("cache", "yes"),
            ("cache-secs", "1"),
            ("cache-pause-wait", "0.1"),
        ] {
            try #require(mpv_set_option_string(handle, name, value) >= 0)
        }
        try #require(mpv_initialize(handle) >= 0)
        initialized = true
        try engine.queue.sync {
            engine.handle = handle
            engine.playbackRequestIsActive = true
            engine.observeProperties()
            try #require(engine.runCommand(["loadfile", TestPaths.baselineMedia.path, "replace"]) >= 0)
            let expected: [String: mpv_format] = [
                "paused-for-cache": MPV_FORMAT_FLAG,
                "cache-buffering-state": MPV_FORMAT_INT64,
                "demuxer-cache-duration": MPV_FORMAT_DOUBLE,
            ]
            var observed: Set<String> = []
            var sawFullProgress = false
            var sawResumedCache = false
            let deadline = Date().addingTimeInterval(5)
            engine.coalescingPropertySnapshots {
                while observed.count < expected.count || !sawFullProgress || !sawResumedCache, Date() < deadline {
                    guard let event = mpv_wait_event(handle, 0.02)?.pointee else { continue }
                    if event.event_id == MPV_EVENT_PROPERTY_CHANGE, let data = event.data {
                        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                        if let name = property.name.map({ String(cString: $0) }),
                           let format = expected[name], property.format == format,
                           let value = property.data
                        {
                            observed.insert(name)
                            if name == "cache-buffering-state" {
                                sawFullProgress = value.assumingMemoryBound(to: Int64.self).pointee == 100
                            }
                            if name == "paused-for-cache", value.assumingMemoryBound(to: Int32.self).pointee == 0 {
                                sawResumedCache = true
                                // Model a preceding buffering state to prove the
                                // native FLAG payload drives the resume transition.
                                engine.isPausedForCache = true
                            }
                        }
                    }
                    engine.handleEvent(event)
                }
            }

            #expect(observed == Set(expected.keys))
            #expect(sawFullProgress && sawResumedCache)
            #expect(!engine.isPausedForCache)
        }
        try await eventually("native cache snapshot reaches the main actor") {
            buffers.contains { !$0.isBuffering && $0.progress == 1 && $0.secondsBufferedAhead >= .zero }
        }
    }
}
