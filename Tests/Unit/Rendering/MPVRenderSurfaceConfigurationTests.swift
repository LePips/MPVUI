import CoreGraphics
@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVRenderSurfaceConfigurationTests {
    private let sdr = MPVRenderSurfaceConfiguration(
        displaySupportsExtendedDynamicRange: false,
        drawableSize: CGSize(width: 640, height: 360),
        outputHeadroom: 1,
        scale: 2,
        usesExtendedDynamicRange: false
    )

    @Test
    func `scale changes require geometry but not renderer reconfiguration`() {
        let changed = MPVRenderSurfaceConfiguration(
            displaySupportsExtendedDynamicRange: false,
            drawableSize: sdr.drawableSize,
            outputHeadroom: 1,
            scale: 1,
            usesExtendedDynamicRange: false
        )

        #expect(!changed.requiresRendererReconfiguration(comparedTo: sdr))
        #expect(changed.requiresGeometryCommit(comparedTo: sdr))
    }

    @Test
    func `drawable size changes require geometry but not renderer reconfiguration`() {
        let changed = MPVRenderSurfaceConfiguration(
            displaySupportsExtendedDynamicRange: false,
            drawableSize: CGSize(width: 1280, height: 720),
            outputHeadroom: 1,
            scale: sdr.scale,
            usesExtendedDynamicRange: false
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
                displaySupportsExtendedDynamicRange: false,
                drawableSize: sdr.drawableSize,
                outputHeadroom: 1,
                scale: 2,
                usesExtendedDynamicRange: true
            ),
            MPVRenderSurfaceConfiguration(
                displaySupportsExtendedDynamicRange: true,
                drawableSize: sdr.drawableSize,
                outputHeadroom: 1,
                scale: 2,
                usesExtendedDynamicRange: false
            ),
            MPVRenderSurfaceConfiguration(
                displaySupportsExtendedDynamicRange: false,
                drawableSize: sdr.drawableSize,
                outputHeadroom: 2,
                scale: 2,
                usesExtendedDynamicRange: false
            ),
        ] {
            #expect(changed.requiresRendererReconfiguration(comparedTo: sdr))
        }
    }

    @Test
    func `output headroom quantization prevents cumulative threshold drift`() {
        var previous = MPVRenderSurfaceConfiguration(
            displaySupportsExtendedDynamicRange: true,
            drawableSize: sdr.drawableSize,
            outputHeadroom: 2,
            scale: sdr.scale,
            usesExtendedDynamicRange: true
        )
        var decisions: [Bool] = []
        var normalizedHeadrooms: [Double] = []

        for headroom in [2.004, 2.008, 2.012, 2.016] {
            let sampled = MPVRenderSurfaceConfiguration(
                displaySupportsExtendedDynamicRange: true,
                drawableSize: sdr.drawableSize,
                outputHeadroom: headroom,
                scale: sdr.scale,
                usesExtendedDynamicRange: true
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
