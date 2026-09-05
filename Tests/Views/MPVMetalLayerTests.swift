import CoreGraphics
@testable import MPVUI
import QuartzCore
import Testing

@Suite(.serialized)
struct MPVMetalLayerTests {
    @Test
    @MainActor
    func `shared layer preserves its rendering policy and last valid drawable`() throws {
        let layer = MPVMetalLayer()
        let validSize = CGSize(width: 640, height: 360)
        let originalColorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let duplicateColorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))

        layer.isOpaque = false
        layer.contentsGravity = .resize
        layer.pixelFormat = .bgra8Unorm
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = originalColorSpace
        let retainedColorSpace = try #require(layer.colorspace)
        layer.colorspace = duplicateColorSpace
        layer.drawableSize = validSize

        #expect(layer.isOpaque)
        #expect(layer.contentsGravity == .resizeAspectFill)
        #expect(layer.pixelFormat == .bgra8Unorm)
        #expect(layer.colorspace === retainedColorSpace)

        for invalidSize in [
            CGSize.zero,
            CGSize(width: 1, height: 1),
            CGSize(width: CGFloat.infinity, height: 360),
            CGSize(width: 640, height: CGFloat.nan),
            CGSize(
                width: MPVMetalLayer.maximumDrawableDimension + 1,
                height: 360
            ),
            CGSize(
                width: 640,
                height: MPVMetalLayer.maximumDrawableDimension + 1
            ),
        ] {
            layer.drawableSize = invalidSize
            #expect(layer.drawableSize == validSize)
        }
    }

    @Test
    @MainActor
    func `shared layer accepts retirement sentinel only during native resize`() async {
        let layer = MPVMetalLayer()
        let validSize = CGSize(width: 320, height: 180)
        layer.drawableSize = validSize
        let box = MPVMetalLayerSendableBox(layer)

        await Task.detached {
            box.value.drawableSize = CGSize(width: 1, height: 1)
        }.value

        #expect(layer.drawableSize == validSize)

        layer.beginNativeResizeTransaction()
        layer.beginNativeResizeTransaction()
        await Task.detached {
            box.value.drawableSize = CGSize(width: 1, height: 1)
        }.value

        #expect(layer.drawableSize == CGSize(width: 1, height: 1))

        layer.endNativeResizeTransaction()

        #expect(layer.drawableSize == CGSize(width: 1, height: 1))

        layer.endNativeResizeTransaction()

        #expect(layer.drawableSize == validSize)

        await Task.detached {
            box.value.drawableSize = CGSize(width: 1, height: 1)
        }.value

        #expect(layer.drawableSize == validSize)
    }

    #if canImport(UIKit)
    @Test
    @MainActor
    func `UIKit filter requests from the render queue are marshalled to main`() async {
        let layer = MPVMetalLayer()
        layer.minificationFilter = .nearest
        layer.magnificationFilter = .nearest
        let box = MPVMetalLayerSendableBox(layer)

        await Task.detached {
            box.value.minificationFilter = .linear
            box.value.magnificationFilter = .linear
        }.value
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(layer.minificationFilter == .linear)
        #expect(layer.magnificationFilter == .linear)
    }
    #endif

    #if os(iOS)
    @Test
    @MainActor
    func `iOS EDR requests from the render queue preserve host policy`() async {
        let layer = MPVMetalLayer()
        layer.configureExtendedDynamicRangeContent(true)
        let hostValue = layer.wantsExtendedDynamicRangeContent
        let box = MPVMetalLayerSendableBox(layer)

        await Task.detached {
            // A stale native request must not override the MainActor-owned
            // display policy. The setter marshals this request asynchronously.
            box.value.wantsExtendedDynamicRangeContent = false
        }.value
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(layer.wantsExtendedDynamicRangeContent == hostValue)
    }

    @Test
    @MainActor
    func `iOS 26 layer applies the complete EDR color contract`() throws {
        guard #available(iOS 26.0, *) else { return }

        let surface = MPVPlatformVideoPlayer(player: MPVPlayer())
        surface.configureMetalLayer(
            usesExtendedDynamicRange: true,
            scale: 3,
            outputHeadroom: 4
        )

        let layer = surface.metalLayer
        #expect(layer.contentsScale == 3)
        #expect(layer.pixelFormat == .rgba16Float)
        #expect(
            try #require(layer.colorspace).name
                == CGColorSpace.extendedLinearDisplayP3
        )
        #expect(layer.edrMetadata == nil)
        #expect(layer.preferredDynamicRange == .high)
        #expect(layer.contentsHeadroom == 4)
    }
    #elseif os(tvOS)
    @Test
    @MainActor
    func `tvOS layer remains in the SDR color contract`() throws {
        let surface = MPVPlatformVideoPlayer(player: MPVPlayer())

        // tvOS deliberately remains SDR even if a caller supplies an EDR
        // configuration. This protects the platform-specific contract at the
        // shared implementation boundary.
        surface.configureMetalLayer(
            usesExtendedDynamicRange: true,
            scale: 2,
            outputHeadroom: 4
        )

        let layer = surface.metalLayer
        #expect(layer.contentsScale == 2)
        #expect(layer.pixelFormat == .bgra8Unorm)
        #expect(try #require(layer.colorspace).name == CGColorSpace.sRGB)
        if #available(tvOS 26.0, *) {
            #expect(layer.preferredDynamicRange == .standard)
        }
    }
    #endif
}

private struct MPVMetalLayerSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
