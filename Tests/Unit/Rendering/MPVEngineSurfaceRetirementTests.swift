import CoreGraphics
import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
struct MPVEngineSurfaceRetirementTests {
    @MainActor
    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases)
    func `teardown authorizes only its retained Metal layer and restores host geometry`(
        output: MPVPlayerConfiguration.VideoOutput
    ) async {
        let ownedLayer = MPVMetalLayer()
        let otherLayer = MPVMetalLayer()
        let ownedSize = CGSize(width: 640, height: 360)
        let otherSize = CGSize(width: 800, height: 450)
        ownedLayer.drawableSize = ownedSize
        otherLayer.drawableSize = otherSize
        let ownedTarget = target(ownedLayer, size: ownedSize)
        let otherTarget = target(otherLayer, size: otherSize)
        let engine = MPVEngine(configuration: .init(videoOutput: output)) { _ in }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engine.queue.async {
                engine.renderTarget = ownedTarget
                let owned = ownedTarget.layerOwner as! MPVMetalLayer
                let other = otherTarget.layerOwner as! MPVMetalLayer
                let sentinel = CGSize(width: 1, height: 1)
                #expect(!owned.invalidateDrawablePoolAfterNativeTeardown())
                let invalidated = engine.withNativeSurfaceRetirement {
                    owned.drawableSize = sentinel
                    other.drawableSize = sentinel
                    #expect(owned.drawableSize == (output == .metal ? sentinel : ownedSize))
                    #expect(other.drawableSize == otherSize)
                    // Scope cleanup must use the captured owner even if the
                    // engine subsequently points at another retained target.
                    engine.renderTarget = otherTarget
                }
                #expect(invalidated == (output == .metal))
                #expect(owned.drawableSize == ownedSize)
                #expect(other.drawableSize == otherSize)
                #expect(!owned.invalidateDrawablePoolAfterNativeTeardown())
                #expect(!other.invalidateDrawablePoolAfterNativeTeardown())
                owned.drawableSize = sentinel
                other.drawableSize = sentinel
                #expect(owned.drawableSize == ownedSize)
                #expect(other.drawableSize == otherSize)
                #expect(engine.handle == nil)
                #expect(!engine.playbackRequestIsActive)
                continuation.resume()
            }
        }
        #expect(ownedLayer.drawableSize == ownedSize)
        #expect(otherLayer.drawableSize == otherSize)
    }

    @MainActor
    private func target(_ layer: MPVMetalLayer, size: CGSize) -> MPVRenderTarget {
        MPVRenderTarget(
            layerAddress: Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque())),
            layerOwner: layer,
            drawableWidth: Int(size.width), drawableHeight: Int(size.height),
            usesExtendedDynamicRange: false, displaySupportsExtendedDynamicRange: false,
            outputHeadroom: 1
        )
    }
}
