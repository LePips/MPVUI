import Foundation
import Libmpv
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
struct MPVEngineActivityTests {
    @Test
    func `total cache bytes distinguish unavailable data and normalize native values`() {
        #expect(MPVBufferStatus.empty.totalBytes == nil)
        #expect(MPVBufferStatus(bytesAhead: 10, totalBytes: 100).totalBytes == 100)
        #expect(MPVBufferStatus(totalBytes: -1).totalBytes == 0)
        #expect(MPVBufferStatus(totalBytes: 0).totalBytes == 0)
    }

    @Test
    func `activity distinguishes wakeups empty drains and handled property work`() async {
        let engine = MPVEngine(configuration: .init()) { _ in }
        for _ in 0 ..< 3 {
            engine.scheduleEventDrain()
        }
        let idle = await engine.lifecycleSnapshot().engineActivity
        #expect(idle.nativeWakeups == 3)
        #expect(idle.eventDrainPasses == 3)
        #expect(idle.nativeEvents == 0)
        #expect(idle.publishedUpdates == 0)

        engine.queue.sync {
            var event = mpv_event()
            event.event_id = MPV_EVENT_NONE
            engine.handleEvent(event)
            engine.playbackRequestIsActive = true
            for name in ["time-pos", "time-pos", "demuxer-cache-state", "duration"] {
                name.withCString { namePointer in
                    var property = mpv_event_property()
                    property.name = namePointer
                    property.format = MPV_FORMAT_NONE
                    withUnsafeMutablePointer(to: &property) { pointer in
                        event.event_id = MPV_EVENT_PROPERTY_CHANGE
                        event.data = UnsafeMutableRawPointer(pointer)
                        engine.handleEvent(event)
                    }
                }
            }
            let activity = engine.lifecycleDiagnostics.engineActivity
            #expect(activity.nativeEvents == 4)
            #expect(activity.propertyChangeEvents == ["time-pos": 2, "demuxer-cache-state": 1, "duration": 1])
            #expect(activity.mediaSnapshots == 1)
            #expect(activity.bufferSnapshots == 1)
            #expect(activity.publishedUpdates == 6)
            // A missing handle performs no native reads, despite constructing
            // fallback snapshots. It also cannot build playback diagnostics.
            engine.refreshPlaybackDiagnostics()
            #expect(engine.lifecycleDiagnostics.engineActivity.propertyReads == 0)
            #expect(engine.lifecycleDiagnostics.engineActivity.diagnosticsSnapshots == 0)
            engine.destroyHandle(preservePlayback: false)
            #expect(engine.lifecycleDiagnostics.engineActivity == activity)
        }
    }

    @Test
    func `native property attempts and diagnostic publication have an exact snapshot boundary`() throws {
        let engine = MPVEngine(configuration: .init()) { _ in }
        // An uninitialized client safely rejects every property read. Failed
        // reads still cross the client API and must count toward bridge work.
        let handle = try #require(mpv_create())
        defer { mpv_destroy(handle) }
        engine.queue.sync {
            engine.handle = handle
            defer { engine.handle = nil }
            #expect(engine.getFlag("pause") == nil)
            #expect(engine.getInt64("file-size") == nil)
            #expect(engine.getDouble("time-pos") == nil)
            #expect(engine.getString("hwdec-current") == nil)
            #expect(engine.getNode("video-params") == nil)
            #expect(engine.lifecycleDiagnostics.engineActivity.propertyReads == 5)

            engine.refreshPlaybackDiagnostics()
            let snapshot = engine.playbackDiagnostics.engineActivity
            #expect(snapshot.diagnosticsSnapshots == 1)
            #expect(snapshot.propertyReads > 5)
            #expect(snapshot.publishedUpdates == 0)
            #expect(engine.lifecycleDiagnostics.engineActivity.publishedUpdates == 1)

            engine.refreshPlaybackDiagnostics()
            let next = engine.playbackDiagnostics.engineActivity
            #expect(next.diagnosticsSnapshots == 2)
            #expect(next.propertyReads - snapshot.propertyReads == snapshot.propertyReads - 5)
            #expect(next.publishedUpdates == 1)
        }
    }
}
