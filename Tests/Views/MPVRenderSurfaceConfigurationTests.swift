import CoreGraphics
@testable import MPVUI
import Testing

struct MPVRenderSurfaceConfigurationTests {
    private let sdr = MPVRenderSurfaceConfiguration(
        usesExtendedDynamicRange: false,
        displaySupportsExtendedDynamicRange: false,
        drawableSize: CGSize(width: 640, height: 360),
        scale: 2,
        outputHeadroom: 1
    )

    @Test
    func `scale changes require geometry but not renderer reconfiguration`() {
        let changed = MPVRenderSurfaceConfiguration(
            usesExtendedDynamicRange: false,
            displaySupportsExtendedDynamicRange: false,
            drawableSize: sdr.drawableSize,
            scale: 1,
            outputHeadroom: 1
        )

        #expect(!changed.requiresRendererReconfiguration(comparedTo: sdr))
        #expect(changed.requiresGeometryCommit(comparedTo: sdr))
    }

    @Test
    func `drawable size changes require geometry but not renderer reconfiguration`() {
        let changed = MPVRenderSurfaceConfiguration(
            usesExtendedDynamicRange: false,
            displaySupportsExtendedDynamicRange: false,
            drawableSize: CGSize(width: 1280, height: 720),
            scale: sdr.scale,
            outputHeadroom: 1
        )

        #expect(!changed.requiresRendererReconfiguration(comparedTo: sdr))
        #expect(changed.requiresGeometryCommit(comparedTo: sdr))
    }

    @Test
    func `drawable geometry uses MoltenVK half to even rounding`() {
        #expect(
            MPVRenderSurfaceConfiguration.drawableSize(
                for: CGSize(width: 50.25, height: 50.75),
                scale: 2
            ) == CGSize(width: 100, height: 102)
        )
    }

    @Test
    func `color and output contract changes require renderer reconfiguration`() {
        for changed in [
            MPVRenderSurfaceConfiguration(
                usesExtendedDynamicRange: true,
                displaySupportsExtendedDynamicRange: false,
                drawableSize: sdr.drawableSize,
                scale: 2,
                outputHeadroom: 1
            ),
            MPVRenderSurfaceConfiguration(
                usesExtendedDynamicRange: false,
                displaySupportsExtendedDynamicRange: true,
                drawableSize: sdr.drawableSize,
                scale: 2,
                outputHeadroom: 1
            ),
            MPVRenderSurfaceConfiguration(
                usesExtendedDynamicRange: false,
                displaySupportsExtendedDynamicRange: false,
                drawableSize: sdr.drawableSize,
                scale: 2,
                outputHeadroom: 2
            ),
        ] {
            #expect(changed.requiresRendererReconfiguration(comparedTo: sdr))
        }
    }

    @Test
    func `output headroom quantization prevents cumulative threshold drift`() {
        var previous = MPVRenderSurfaceConfiguration(
            usesExtendedDynamicRange: true,
            displaySupportsExtendedDynamicRange: true,
            drawableSize: sdr.drawableSize,
            scale: sdr.scale,
            outputHeadroom: 2
        )
        var decisions: [Bool] = []
        var normalizedHeadrooms: [Double] = []

        for headroom in [2.004, 2.008, 2.012, 2.016] {
            let sampled = MPVRenderSurfaceConfiguration(
                usesExtendedDynamicRange: true,
                displaySupportsExtendedDynamicRange: true,
                drawableSize: sdr.drawableSize,
                scale: sdr.scale,
                outputHeadroom: headroom
            )
            decisions.append(
                sampled.requiresRendererReconfiguration(comparedTo: previous)
            )
            normalizedHeadrooms.append(sampled.outputHeadroom)
            previous = sampled
        }

        #expect(decisions == [false, true, false, true])
        #expect(normalizedHeadrooms == [2, 2.01, 2.01, 2.02])
    }
}
