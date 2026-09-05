@testable import MPVUI
import Testing

private final class WeakBoxValue {}

private final class RegistrySurface {
    var isAttachedToWindow = true
    var activationCount = 0
}

struct UtilityTests {
    @Test
    func `clamp constrains comparable values`() {
        #expect(clamp(-1, to: 0 ... 10) == 0)
        #expect(clamp(4, to: 0 ... 10) == 4)
        #expect(clamp(11, to: 0 ... 10) == 10)
        #expect(clamp(Duration.seconds(12), to: .zero ... .seconds(10)) == .seconds(10))
    }

    @Test
    func `weak box does not retain its value`() {
        let box: WeakBox<WeakBoxValue> = {
            let value = WeakBoxValue()
            let box = WeakBox(value)
            #expect(box.value === value)
            return box
        }()

        #expect(box.value == nil)
    }

    @MainActor
    @Test
    func `surface registry activates the most recent attached surface`() {
        let player = MPVPlayer()
        let registry = MPVSwiftUISurfaceRegistry<RegistrySurface>(
            isAttachedToWindow: { $0.isAttachedToWindow },
            activate: { $0.activationCount += 1 }
        )
        let first = RegistrySurface()
        let second = RegistrySurface()

        registry.register(first, for: player)
        registry.register(second, for: player)
        registry.surfaceDidMoveToWindow(
            first,
            player: player,
            isInWindow: true,
            shouldRestorePreviousSurface: false
        )
        registry.surfaceDidMoveToWindow(
            second,
            player: player,
            isInWindow: true,
            shouldRestorePreviousSurface: false
        )

        registry.activateMostRecentSurface(for: player)
        #expect(first.activationCount == 0)
        #expect(second.activationCount == 1)

        registry.surfaceDidMoveToWindow(
            first,
            player: player,
            isInWindow: true,
            shouldRestorePreviousSurface: false
        )
        registry.activateMostRecentSurface(for: player)
        #expect(first.activationCount == 1)

        first.isAttachedToWindow = false
        registry.activateMostRecentSurface(for: player)
        #expect(first.activationCount == 1)
        #expect(second.activationCount == 2)
    }
}
