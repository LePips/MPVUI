import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
struct MPVEngineDetachedRenderingTests {
    @Test
    func `resizing before client creation preserves geometry and rejects stale or invalid targets`() async {
        let engine = MPVEngine(configuration: .init()) { _ in }
        let original = target()
        engine.queue.sync { engine.renderTarget = original }
        #expect(await engine.resizeRenderTargetAndWait(width: 800, height: 450, forLayerAddress: 1))
        let resized = engine.queue.sync { engine.renderTarget }
        #expect(resized?.drawableWidth == 800 && resized?.drawableHeight == 450)
        #expect(resized?.layerOwner === original.layerOwner)
        #expect(resized?.matchesSurfaceConfiguration(original) == true)
        #expect(resized?.matches(original) == false)
        #expect(await engine.resizeRenderTargetAndWait(width: 800, height: 450, forLayerAddress: 1))
        #expect(await !engine.resizeRenderTargetAndWait(width: 900, height: 600, forLayerAddress: 2))
        for size in [(0, 20), (20, 1), (Int.max, 20), (20, Int.max)] {
            #expect(await !engine.resizeRenderTargetAndWait(width: size.0, height: size.1, forLayerAddress: 1))
        }
        #expect(engine.queue.sync { engine.renderTarget === resized })
        #expect(await engine.renderOutputSize() == nil)
    }

    @Test
    func `color update ownership rejects other layers and clears when its surface detaches`() {
        let engine = MPVEngine(configuration: .init()) { _ in }
        engine.queue.sync { engine.renderTarget = target() }
        #expect(!engine.beginColorUpdate(forLayerAddress: 2))
        #expect(engine.beginColorUpdate(forLayerAddress: 1))
        #expect(!engine.beginColorUpdate(forLayerAddress: 1))
        engine.finishColorUpdate(target: target(address: 2))
        #expect(engine.queue.sync { engine.colorUpdateLayerAddress == 1 })
        engine.queue.sync { engine.detachSynchronously(fromLayerAddress: 1) }
        engine.finishColorUpdate(target: target())
        #expect(engine.queue.sync { engine.colorUpdateLayerAddress == nil && !engine.colorUpdateHasNativeFence })
        #expect(engine.queue.sync { engine.renderTarget == nil && engine.handle == nil })
    }

    @Test
    func `switching a retired backend on the engine queue clears obsolete load intent`() {
        let engine = MPVEngine(configuration: .init(videoOutput: .sampleBuffer)) { _ in }
        engine.queue.sync {
            engine.renderTarget = target()
            engine.sourceURL = TestPaths.baselineMedia
            engine.needsSourceLoad = true
            engine.playbackRequestIsActive = true
            engine.pendingStartTime = .seconds(12)
            engine.switchVideoOutputSynchronously(to: .metal, preservePlayback: false)
            #expect(engine.videoOutput == .metal)
            #expect(engine.renderTarget == nil && engine.sourceURL == nil)
            #expect(!engine.needsSourceLoad && !engine.playbackRequestIsActive)
            #expect(engine.pendingStartTime == nil)
            engine.shutdownSynchronously()
        }
    }

    @Test
    func `queued detach retires only its own target and remains safe on repeated shutdown`() async {
        let engine = MPVEngine(configuration: .init()) { _ in }
        engine.queue.sync { engine.renderTarget = target() }
        engine.detach(fromLayerAddress: 2)
        _ = await engine.lifecycleSnapshot()
        #expect(engine.queue.sync { engine.renderTarget != nil })
        engine.detach(fromLayerAddress: 1)
        engine.shutdown()
        _ = await engine.lifecycleSnapshot()
        #expect(engine.queue.sync { engine.renderTarget == nil && engine.handle == nil })
        engine.queue.sync {
            engine.renderTarget = target()
            engine.detachCurrentRenderTargetSynchronously()
            #expect(engine.renderTarget == nil)
            engine.detachCurrentRenderTargetSynchronously()
        }
    }

    private func target(address: Int64 = 1) -> MPVRenderTarget {
        MPVRenderTarget(
            layerAddress: address, layerOwner: NSObject(), drawableWidth: 320, drawableHeight: 180,
            usesExtendedDynamicRange: false, displaySupportsExtendedDynamicRange: false, outputHeadroom: 1
        )
    }
}
