import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
@MainActor
struct MPVStoppedResourceTests {
    @Test
    func `stop cancels pending work but retains replay source and runtime settings`() {
        let engine = MPVEngine(configuration: .init()) { _ in }
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
            #expect(engine.playbackRequestIsActive && engine.needsSourceLoad && engine.isLoading)
            #expect(engine.pendingStartTime == .zero && engine.lastPosition == .zero)
            #expect(engine.sourceURL == TestPaths.baselineMedia)
            #expect(engine.handle == nil) // Awaiting a render surface.
        }
    }

    @Test
    func `stopped surfaces accept geometry without recreating a native client`() async {
        var errors: [MPVPlayerError] = []
        let engine = MPVEngine(configuration: .init(videoOutput: .metal)) { emission in
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
    func `explicit seek after stop controls replay while a new load replaces the retired source`() {
        let engine = MPVEngine(configuration: .init()) { _ in }
        engine.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(8), generation: 1)
        engine.stop(generation: 2)
        engine.seek(to: .seconds(2))
        engine.play()
        engine.queue.sync {
            #expect(engine.sourceURL == TestPaths.baselineMedia)
            #expect(engine.pendingStartTime == .seconds(2))
            #expect(!engine.isStoppedForResourceRelease)
        }
        engine.stop(generation: 3)
        engine.load(TestPaths.multitrackMedia, autoPlay: false, startTime: .seconds(4), generation: 4)
        engine.queue.sync {
            #expect(engine.currentGeneration == 4)
            #expect(engine.sourceURL == TestPaths.multitrackMedia)
            #expect(engine.pendingStartTime == .seconds(4))
            #expect(engine.needsSourceLoad && engine.playbackRequestIsActive)
            #expect(!engine.isStoppedForResourceRelease && engine.isPaused)
        }
    }
}
