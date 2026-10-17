import Foundation
import MPVCore
import Observation
import Synchronization
import Testing

@MainActor
struct MPVSessionControllerTests {

    @Test
    func `observable projection copies complete states without another native client`() async throws {
        let session = MPVSession(settings: .init(autoPlay: false), platform: .init()) { _ in }
        defer { session.close() }
        var controller: MPVSessionController? = MPVSessionController(session: session)
        weak let weakController = controller
        let value = try #require(controller)
        #expect(value.session === session)
        #expect(value.configuration == session.configuration)
        let changes = Mutex(0)
        withObservationTracking { _ = value.position } onChange: { changes.withLock { $0 += 1 } }
        session.queue.sync { session.publish(.audio(volume: 32, isMuted: true, playbackRate: 1.25)) }
        try await wait { value.volume == 32 }
        #expect(changes.withLock { $0 } == 0)
        #expect(value.isMuted && value.playbackRate == 1.25)
        session.queue.sync {
            session.publish(.media(.init(
                title: "Shared state",
                dimensions: .init(width: 640, height: 360),
                tracks: [.init(id: 1, type: .video)],
                hdr: .init(presentation: .init(backend: .gpu))
            )))
            session.publish(.timing(position: .seconds(2), duration: .seconds(12), isSeekable: true))
            session.publish(.paused(false))
            session.publish(.state(.playing))
            session.publish(.videoFrame(true))
            session.publish(.chapter(1))
            session.publish(.buffer(.init(progress: 0.5, secondsBufferedAhead: .seconds(4))))
            var diagnostics = MPVPlaybackDiagnostics()
            diagnostics.startLatencySeconds = 0.25
            session.publish(.diagnostics(diagnostics))
            session.publish(.dolbyVision(.init(requestedPolicy: .profile7Compatibility)))
            session.publish(.color(.init(conversionOwner: .colorSync, precision: .unorm8)))
            session.publish(.textSubtitles(.init(regions: [.init(text: "Shared cue")])))
            session.publish(.error(.clientUnavailable, fatal: false))
        }
        _ = session.requestVideoFeatures([.inlineOverlays])
        try await wait { value.videoFeatureRequestResult != nil }
        #expect(value.state == .playing && !value.isPaused && value.hasVideoFrame)
        #expect(value.position == .seconds(2) && value.duration == .seconds(12) && value.isSeekable)
        #expect(value.mediaInformation.title == "Shared state")
        #expect(value.currentChapterIndex == 1 && value.bufferStatus.secondsBufferedAhead == .seconds(4))
        #expect(value.playbackDiagnostics.startLatencySeconds == 0.25)
        #expect(value.dolbyVisionStatus.requestedPolicy == .profile7Compatibility)
        #expect(value.renderColorStatus.conversionOwner == .colorSync)
        #expect(value.textSubtitles.text == "Shared cue" && value.lastError == .clientUnavailable)
        #expect(value.videoOutput == .gpu)
        #expect(value.videoFeatureCapabilities[.inlineOverlays].availability == .available)
        #expect(changes.withLock { $0 } == 1)
        #expect(session.queue.sync { session.lifecycleDiagnostics.handlesCreated == 0 })
        value.clearLastError()
        try await wait { value.lastError == nil }
        controller = nil
        // The explicit local reference keeps the projection alive until scope exit.
        #expect(weakController === value)
    }

    @Test
    func `controller forwards deferred controls and ignores replaced load states`() async throws {
        let session = MPVSession(settings: .init(autoPlay: false), platform: .init()) { _ in }
        defer { session.close() }
        var controller: MPVSessionController? = MPVSessionController(session: session)
        weak let weakController = controller
        controller?.load(URL(fileURLWithPath: "/pending-one.mp4"), startTime: .seconds(2))
        controller?.pause()
        controller?.seek(to: .seconds(5))
        controller?.seek(by: .seconds(1))
        try await wait { controller?.position == .seconds(6) }
        controller?.play()
        try await wait { controller?.isPaused == false }
        controller?.togglePlayback()
        let toggledPause = session.snapshot.isPaused
        try await wait { controller?.isPaused == toggledPause }
        controller?.pause()
        try await wait { controller?.isPaused == true }
        controller?.setDiagnosticsEnabled(true)
        controller?.setTextSubtitleInterceptionEnabled(true)
        controller?.selectTrack(.init(type: .audio, mpvID: 2))
        controller?.selectSubtitle(nil, for: .secondary)
        #expect(session.snapshot.isDiagnosticsEnabled)
        #expect(session.snapshot.interceptsTextSubtitles)
        controller?.load(URL(fileURLWithPath: "/pending-two.mp4"), autoPlay: false, startTime: .seconds(3))
        let generation = session.snapshot.generation
        session.queue.sync {
            var stale = session.latestSnapshot
            stale.generation = generation - 1
            stale.position = .seconds(99)
            for observer in session.observers.values {
                observer.yield(.snapshot(stale))
            }
            session.record(.log(.init(prefix: "test", level: .info, message: "delivery barrier")))
        }
        try await wait { controller?.mediaInformation.sourceURL?.lastPathComponent == "pending-two.mp4" }
        #expect(controller?.position == .seconds(3))
        controller?.stop()
        try await wait { controller?.state == .stopped }
        session.close()
        controller?.play()
        #expect(controller?.lastError == .clientUnavailable)
        controller = nil
        #expect(weakController == nil)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate(), "Observable session delivery did not complete")
    }
}
