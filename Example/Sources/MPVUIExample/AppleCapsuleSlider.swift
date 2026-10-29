import SwiftUI

#if !os(tvOS) && !os(Android) && !os(macOS)
/// A mobile timeline that scrubs by drag offset from the initial playback position.
struct AppleCapsuleSlider {

    @Binding
    var value: Double

    let upperBound: Double
    let isEnabled: Bool
    let accessibilityValue: String
    let onEditingChanged: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @Environment(\.layoutDirection)
    private var layoutDirection

    @State
    private var isDragging = false
    @State
    private var dragStartValue = 0.0

    @GestureState
    private var gestureIsActive = false

    private var fraction: Double {
        guard upperBound > 0 else { return 0 }

        return min(max(value / upperBound, 0), 1)
    }
}

extension AppleCapsuleSlider: View {

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.2))

                Capsule()
                    .fill(.white)
                    .frame(width: geometry.size.width * fraction)
            }
            .frame(height: isDragging ? 20 : 12)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($gestureIsActive) { _, active, _ in active = true }
                    .onChanged { gesture in
                        updateDragging(gesture, width: geometry.size.width)
                    }
                    .onEnded { _ in finishDragging() }
            )
        }
        .frame(height: 44)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isDragging)
        .accessibilityRepresentation {
            Slider(value: Binding(
                get: { value },
                set: { updatePosition($0) }
            ), in: 0 ... upperBound)
                .disabled(!isEnabled)
                .accessibilityLabel("Playback position")
                .accessibilityValue(accessibilityValue)
                .accessibilityHint("Swipe up or down to seek by ten seconds.")
                .accessibilityAdjustableAction(adjustPosition)
        }

        // Gesture state also resets on cancellation (for example, a system gesture).
        .onChange(of: gestureIsActive) { _, active in
            if !active {
                finishDragging()
            }
        }
        .onDisappear(perform: finishDragging)
    }

    private func updateDragging(_ gesture: DragGesture.Value, width: CGFloat) {
        guard isEnabled, width > 0 else { return }

        if !isDragging {
            dragStartValue = value
            isDragging = true
            onEditingChanged(true)
        }

        let direction = layoutDirection == .rightToLeft ? -1.0 : 1.0
        let offset = gesture.translation.width / width * upperBound * direction

        value = min(max(dragStartValue + offset, 0), upperBound)
    }

    private func updatePosition(_ position: Double) {
        guard isEnabled else { return }

        onEditingChanged(true)
        value = position
        onEditingChanged(false)
    }

    private func adjustPosition(_ direction: AccessibilityAdjustmentDirection) {
        guard isEnabled else { return }

        let offset: Double

        switch direction {
        case .increment: offset = 10
        case .decrement: offset = -10
        @unknown default: return
        }

        onEditingChanged(true)
        value = min(max(value + offset, 0), upperBound)
        onEditingChanged(false)
    }

    private func finishDragging() {
        guard isDragging else { return }

        isDragging = false
        onEditingChanged(false)
    }
}
#endif
