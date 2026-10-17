import Foundation
import Libmpv
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
@MainActor
struct MPVStoppedResourceTests {

    // libmpv wakes clients from its own core thread, outside the test actor.
    private nonisolated static let wakeupCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
        guard let context else { return }
        Unmanaged<MPVSession>.fromOpaque(context).takeUnretainedValue().scheduleEventDrain()
    }

    @Test
    func `shutdown clears deferred media ownership even before a native handle exists`() async {
        let engine = MPVSession(configuration: .init()) { _ in }
        let source = TestPaths.baselineMedia
        let subtitle = URL(fileURLWithPath: "/tmp/deferred-shutdown.srt")
        let cancellation = MPVSubtitleQueryCancellation()
        do {
            let _: [TimedTextSubtitleSnapshot] = try await withCheckedThrowingContinuation { continuation in
                engine.queue.sync {
                    engine.sourceURL = source
                    engine.securityScopedURL = source
                    engine.externalSecurityScopedURLs = [subtitle]
                    engine.externalTracks = [.init(url: subtitle, type: .subtitle, select: true, subtitleRole: .primary)]
                    engine.pendingExternalTracks = engine.externalTracks
                    engine.playbackRequestIsActive = true
                    engine.isLoading = true
                    engine.needsSourceLoad = true
                    engine.pendingStartTime = .seconds(7)
                    engine.pendingSeekAfterLoad = .seconds(8)
                    engine.lastPosition = .seconds(6)
                    engine.lastDuration = .seconds(60)
                    engine.lastSeekable = true
                    engine.requestedPlaylistEntryID = 1
                    engine.activePlaylistEntryID = 1
                    engine.requestedLoadUptime = 10
                    engine.seekUptime = 11
                    engine.subtitleQueries[1] = .init(cancellation: cancellation, continuation: continuation)
                    engine.isTextSubtitleInterceptionEnabled = true
                    engine.lastTextSubtitleSnapshot = TextSubtitleSnapshot(regions: [.init(text: "pending")])
                    engine.startDiagnosticsTimer()
                    engine.destroyHandle(preservePlayback: false)
                }
            }

            Issue.record("Shutdown must cancel a pending subtitle query")
        } catch {
            #expect(error is CancellationError)
        }
        engine.queue.sync {
            #expect(engine.sourceURL == nil && engine.securityScopedURL == nil)
            #expect(engine.externalSecurityScopedURLs.isEmpty)
            #expect(engine.externalTracks.isEmpty && engine.pendingExternalTracks.isEmpty)
            #expect(engine.handle == nil && engine.diagnosticsTimer == nil)
            #expect(engine.subtitleQueries.isEmpty && engine.lastTextSubtitleSnapshot.isEmpty)
            #expect(engine.pendingStartTime == nil && engine.pendingSeekAfterLoad == nil)
            #expect(engine.requestedPlaylistEntryID == nil && engine.activePlaylistEntryID == nil)
            #expect(engine.requestedLoadUptime == nil && engine.seekUptime == nil)
            #expect(!engine.playbackRequestIsActive && !engine.needsSourceLoad && !engine.isLoading)
            #expect(engine.lastPosition == .zero && engine.lastDuration == .zero && !engine.lastSeekable)
            #expect(engine.isStoppedForResourceRelease && engine.isPaused && engine.lastState == .stopped)
            #expect(engine.lifecycleDiagnostics.handlesDestroyed == 0)
            engine.destroyHandle(preservePlayback: false)

            #expect(engine.lifecycleDiagnostics.handlesDestroyed == 0)
        }
    }

    @Test
    func `native quit cancels diagnostics and clears media ownership exactly once`() async throws {
        let engine = MPVSession(configuration: .init()) { _ in }
        try engine.queue.sync {
            let handle = try #require(mpv_create())
            engine.handle = handle
            mpv_set_wakeup_callback(handle, Self.wakeupCallback, Unmanaged.passUnretained(engine).toOpaque())
            try #require(mpv_set_option_string(handle, "vo", "null") >= 0)
            try #require(mpv_set_option_string(handle, "ao", "null") >= 0)
            try #require(mpv_initialize(handle) >= 0)
            engine.lifecycleDiagnostics.handlesCreated = 1
            engine.sourceURL = TestPaths.baselineMedia
            engine.securityScopedURL = TestPaths.baselineMedia
            engine.externalSecurityScopedURLs = [URL(fileURLWithPath: "/tmp/quit.srt")]
            engine.externalTracks = [.init(
                url: URL(fileURLWithPath: "/tmp/quit.srt"),
                type: .subtitle,
                select: true,
                subtitleRole: .primary
            )]
            engine.pendingExternalTracks = engine.externalTracks
            engine.isLoading = true
            engine.isSeeking = true
            engine.playbackRequestIsActive = true
            engine.startDiagnosticsTimer()
            try #require(engine.runCommand(["quit"]) >= 0)
        }
        try await eventually("native quit clears its handle and owned work") {
            engine.queue.sync { engine.handle == nil }
        }
        engine.queue.sync {
            #expect(engine.diagnosticsTimer == nil)
            #expect(engine.sourceURL == nil && engine.securityScopedURL == nil)
            #expect(engine.externalSecurityScopedURLs.isEmpty)
            #expect(engine.externalTracks.isEmpty && engine.pendingExternalTracks.isEmpty)
            #expect(!engine.playbackRequestIsActive && !engine.isLoading && !engine.isSeeking)
            #expect(engine.isStoppedForResourceRelease && engine.isPaused && engine.lastState == .stopped)
            #expect(engine.lifecycleDiagnostics.handlesDestroyed == 1)
            engine.destroyHandle(preservePlayback: false)

            #expect(engine.lifecycleDiagnostics.handlesDestroyed == 1)
        }
    }

    @Test
    func `stop cancels pending work but retains replay source and runtime settings`() {
        let engine = MPVSession(configuration: .init(additionalOptions: ["ao": "null"])) { _ in }
        engine.queue.sync {
            engine.sourceURL = TestPaths.baselineMedia
            engine.playbackRequestIsActive = true
            engine.isLoading = true
            engine.needsSourceLoad = true
            engine.pendingStartTime = .seconds(7)
            engine.pendingSeekAfterLoad = .seconds(8)
            engine.lastPosition = .seconds(6)
            engine.desiredProperties["audio-delay"] = "0.25"
            engine.externalTracks = [.init(
                url: URL(fileURLWithPath: "/tmp/replay.srt"),
                type: .subtitle,
                select: true,
                subtitleRole: .primary
            )]
        }
        engine.stop(generation: 17)
        engine.queue.sync {
            #expect(engine.currentGeneration == 17)
            #expect(engine.sourceURL == TestPaths.baselineMedia)
            #expect(engine.isStoppedForResourceRelease)
            #expect(engine.handle == nil && engine.diagnosticsTimer == nil)
            #expect(!engine.playbackRequestIsActive && !engine.needsSourceLoad && !engine.isLoading)
            #expect(engine.pendingStartTime == nil && engine.pendingSeekAfterLoad == nil)
            #expect(engine.lastPosition == .zero && engine.isPaused)
            #expect(engine.securityScopedURL == nil && engine.externalSecurityScopedURLs.isEmpty)
            #expect(engine.externalTracks.count == 1 && engine.pendingExternalTracks.count == 1)
            #expect(engine.desiredProperties["audio-delay"] == "0.25")
        }
        engine.togglePlayback()
        engine.queue.sync {
            #expect(!engine.isStoppedForResourceRelease)
            #expect(engine.playbackRequestIsActive && !engine.needsSourceLoad && engine.isLoading)
            #expect(engine.pendingStartTime == nil && engine.lastPosition == .zero)
            #expect(engine.sourceURL == TestPaths.baselineMedia)
            #expect(engine.handle != nil) // Replay works without a view.
        }
    }

    @Test
    func `stopped surfaces accept geometry without recreating a native client`() async {
        var errors: [MPVPlayerError] = []
        let engine = MPVSession(configuration: .init(videoOutput: .metal)) { emission in
            if case let .error(error, _) = emission.update {
                errors.append(error)
            }
        }
        engine.stop()
        let owner = NSObject()
        func target(width: Int, headroom: Double) -> MPVRenderTarget {
            .init(
                layerAddress: 1,
                layerOwner: owner,
                drawableWidth: width,
                drawableHeight: 360,
                usesExtendedDynamicRange: false,
                displaySupportsExtendedDynamicRange: false,
                outputHeadroom: headroom
            )
        }
        engine.attach(to: target(width: 640, headroom: 1))
        engine.queue.sync {
            #expect(engine.handle == nil)
            #expect(engine.renderTarget?.drawableWidth == 640)
            #expect(engine.lifecycleDiagnostics.handlesCreated == 0)
        }
        #expect(await engine.resizeRenderTargetAndWait(width: 800, height: 450, forLayerAddress: 1))
        #expect(engine.beginColorUpdate(forLayerAddress: 1))
        engine.finishColorUpdate(target: target(width: 900, headroom: 2))
        engine.detachSynchronously(fromLayerAddress: 1)
        engine.attach(to: target(width: 960, headroom: 1))
        engine.queue.sync {
            #expect(engine.handle == nil && engine.renderTarget?.drawableWidth == 960)
            #expect(engine.lifecycleDiagnostics.handlesCreated == 0)
            #expect(engine.liveConfigurationFailure == nil)
        }
        await Task.yield()

        #expect(errors.isEmpty)
    }

    @Test
    func `explicit seek after stop controls replay while a new load replaces the retired source`() async throws {
        let engine = MPVSession(configuration: .init(additionalOptions: ["ao": "null"])) { _ in }
        engine.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(8), generation: 1)
        engine.stop(generation: 2)
        engine.seek(to: .seconds(2))
        engine.play()
        try await eventually("headless replay at the requested seek") {
            engine.queue.sync { engine.isFileLoaded && abs((engine.getDouble("time-pos") ?? -1) - 2) < 0.2 }
        }
        engine.queue.sync {
            #expect(engine.sourceURL == TestPaths.baselineMedia)
            #expect(engine.pendingStartTime == nil)
            #expect(!engine.isStoppedForResourceRelease)
        }
        engine.stop(generation: 3)
        engine.load(TestPaths.multitrackMedia, autoPlay: false, startTime: .seconds(4), generation: 4)
        try await eventually("replacement source at its configured position") {
            engine.queue.sync { engine.isFileLoaded && abs((engine.getDouble("time-pos") ?? -1) - 4) < 0.2 }
        }
        engine.queue.sync {
            #expect(engine.currentGeneration == 4)
            #expect(engine.sourceURL == TestPaths.multitrackMedia)
            #expect(engine.pendingStartTime == nil)
            #expect(!engine.needsSourceLoad && engine.playbackRequestIsActive)
            #expect(!engine.isStoppedForResourceRelease && engine.isPaused)
        }
    }
}
