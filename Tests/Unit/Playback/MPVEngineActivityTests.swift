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
    func `activity distinguishes wakeups empty drains and handled property work`() async throws {
        let engine = MPVEngine(configuration: .init()) { _ in }
        engine.queue.sync {
            for _ in 0 ..< 3 {
                engine.scheduleEventDrain()
            }
        }
        try await eventually("pending wakeups are drained") {
            await engine.lifecycleSnapshot().engineActivity.nativeWakeups == 3
        }
        let idle = await engine.lifecycleSnapshot().engineActivity
        #expect(idle.nativeWakeups == 3)
        #expect(idle.eventDrainPasses == 1)
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
            var stoppedActivity = activity
            stoppedActivity.publishedUpdates += 2
            #expect(engine.lifecycleDiagnostics.engineActivity == stoppedActivity)
        }
    }

    @Test
    func `concurrent wakeup bursts are lossless and rearm after a completed drain`() async throws {
        let engine = MPVEngine(configuration: .init()) { _ in }
        let producers = 8
        let wakeupsPerProducer = 1000
        let burstCount = Int64(producers * wakeupsPerProducer)
        // Hold the engine queue while several native callback threads signal
        // it. The complete pending burst needs exactly one drain.
        engine.queue.sync {
            DispatchQueue.concurrentPerform(iterations: producers) { _ in
                for _ in 0 ..< wakeupsPerProducer {
                    engine.scheduleEventDrain()
                }
            }
        }
        try await eventually("one drain consumes the concurrent pending burst") {
            await engine.lifecycleSnapshot().engineActivity.nativeWakeups == burstCount
        }
        #expect(await engine.lifecycleSnapshot().engineActivity.eventDrainPasses == 1)

        // Allow drains to overlap further callbacks, exercising dispatch's
        // rearming at the handler boundary instead of only pending coalescing.
        DispatchQueue.concurrentPerform(iterations: producers) { _ in
            for _ in 0 ..< wakeupsPerProducer {
                engine.scheduleEventDrain()
            }
        }
        try await eventually("callbacks arriving during drains are not lost") {
            await engine.lifecycleSnapshot().engineActivity.nativeWakeups == 2 * burstCount
        }
        let beforeLateWakeup = await engine.lifecycleSnapshot().engineActivity
        engine.shutdownSynchronously()
        engine.scheduleEventDrain()
        try await eventually("a late callback after shutdown safely drains the empty engine") {
            await engine.lifecycleSnapshot().engineActivity.nativeWakeups == 2 * burstCount + 1
        }
        let final = await engine.lifecycleSnapshot().engineActivity
        #expect(final.eventDrainPasses == beforeLateWakeup.eventDrainPasses + 1)
        #expect(final.nativeEvents == 0)
    }

    @Test @MainActor
    func `pending event delivery does not retain the engine and cancels on release`() async throws {
        weak var releasedEngine: MPVEngine?
        let source = autoreleasepool {
            let engine = MPVEngine(configuration: .init()) { _ in }
            releasedEngine = engine
            engine.queue.sync {
                for _ in 0 ..< 1000 {
                    engine.scheduleEventDrain()
                }
            }
            return engine.eventDrainSource
        }
        try await eventually("the engine releases its active dispatch source") {
            releasedEngine == nil && source.isCancelled
        }
        source.add(data: 1)
        #expect(source.isCancelled)
    }

    @Test(arguments: [MPVPlayerConfiguration.LogLevel.none, .fatal, .error, .warning, .info, .status, .verbose, .debug, .trace])
    func `render diagnostics only construct messages when their level is enabled`(_ level: MPVPlayerConfiguration.LogLevel) {
        let engine = MPVEngine(configuration: .init(logLevel: level)) { _ in }
        var evaluations = 0
        func message() -> String {
            evaluations += 1
            return "render surface diagnostic"
        }
        let enabled = [.verbose, .debug, .trace].contains(level)
        engine.queue.sync {
            engine.publishRenderSurfaceDiagnostic(message())
            #expect(evaluations == (enabled ? 1 : 0))
            #expect(engine.lifecycleDiagnostics.engineActivity.publishedUpdates == (enabled ? 1 : 0))
        }
    }

    @Test
    func `cache and media property bursts rebuild each complete snapshot once`() {
        let engine = MPVEngine(configuration: .init()) { _ in }
        engine.queue.sync {
            engine.playbackRequestIsActive = true
            engine.coalescingPropertySnapshots {
                for _ in 0 ..< 20 {
                    for name in ["cache-buffering-state", "demuxer-cache-duration", "demuxer-cache-state"] {
                        sendProperty(name, to: engine)
                    }
                    for name in ["metadata", "media-title", "video-params", "video-out-params"] {
                        sendProperty(name, to: engine)
                    }
                }
                #expect(engine.lifecycleDiagnostics.engineActivity.bufferSnapshots == 0)
                #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == 0)
            }
            let activity = engine.lifecycleDiagnostics.engineActivity
            #expect(activity.nativeEvents == 140)
            #expect(activity.bufferSnapshots == 1)
            #expect(activity.mediaSnapshots == 1)
            #expect(activity.publishedUpdates == 3)
            #expect(!engine.pendingBufferSnapshot && !engine.pendingMediaSnapshot)
            // A new drain must publish later changes, not suppress them as an
            // already-consumed batch.
            engine.coalescingPropertySnapshots {
                sendProperty("demuxer-cache-state", to: engine)
                sendProperty("metadata", to: engine)
            }
            #expect(engine.lifecycleDiagnostics.engineActivity.bufferSnapshots == 2)
            #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == 2)
        }
    }

    @Test
    func `pending snapshots flush before seek and native cache pause transitions`() {
        let engine = MPVEngine(configuration: .init()) { _ in }
        engine.queue.sync {
            engine.playbackRequestIsActive = true
            engine.hasPlaybackStarted = true
            engine.isFileLoaded = true
            engine.isIdle = false
            engine.coalescingPropertySnapshots {
                sendProperty("demuxer-cache-state", to: engine)
                sendProperty("metadata", to: engine)
                var seek = mpv_event()
                seek.event_id = MPV_EVENT_SEEK
                engine.handleEvent(seek)
                #expect(engine.lastState == .seeking)
                #expect(engine.lifecycleDiagnostics.engineActivity.bufferSnapshots == 1)
                #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == 1)
                engine.isSeeking = false

                sendProperty("metadata", to: engine)
                sendCachePaused(true, to: engine)
                #expect(engine.isPausedForCache)
                #expect(engine.lastState == .buffering)
                #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == 2)
                let pausedSnapshots = engine.lifecycleDiagnostics.engineActivity.bufferSnapshots
                sendCachePaused(true, to: engine)
                #expect(engine.lifecycleDiagnostics.engineActivity.bufferSnapshots == pausedSnapshots)
                sendCachePaused(false, to: engine)
                #expect(!engine.isPausedForCache)
                #expect(engine.lastState == .playing)
                #expect(engine.lifecycleDiagnostics.engineActivity.bufferSnapshots == pausedSnapshots + 1)
            }
            #expect(engine.lifecycleDiagnostics.bufferingStateTransitions == 1)
            #expect(!engine.pendingBufferSnapshot && !engine.pendingMediaSnapshot)
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

    private func sendCachePaused(_ value: Bool, to engine: MPVEngine) {
        var flag: Int32 = value ? 1 : 0
        withUnsafeMutablePointer(to: &flag) { pointer in
            sendProperty("paused-for-cache", format: MPV_FORMAT_FLAG, data: UnsafeMutableRawPointer(pointer), to: engine)
        }
    }

    private func sendProperty(
        _ name: String,
        format: mpv_format = MPV_FORMAT_NONE,
        data: UnsafeMutableRawPointer? = nil,
        to engine: MPVEngine
    ) {
        name.withCString { name in
            var property = mpv_event_property()
            property.name = name
            property.format = format
            property.data = data
            withUnsafeMutablePointer(to: &property) { pointer in
                var event = mpv_event()
                event.event_id = MPV_EVENT_PROPERTY_CHANGE
                event.data = UnsafeMutableRawPointer(pointer)
                engine.handleEvent(event)
            }
        }
    }
}
