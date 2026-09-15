import SwiftUI

/// Read-only playback progress with the same capsule appearance as the slider.
struct ExampleCapsuleProgress: View {
    let value: Double
    let upperBound: Double
    let accessibilityValue: String

    var body: some View {
        ProgressView(value: upperBound > 0 ? min(max(value / upperBound, 0), 1) : 0)
            .progressViewStyle(CapsuleProgressStyle())
            .frame(height: 56)
            .allowsHitTesting(false)
            .accessibilityLabel("Playback progress")
            .accessibilityValue(accessibilityValue)
    }

    private struct CapsuleProgressStyle: ProgressViewStyle {
        func makeBody(configuration: Configuration) -> some View {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule()
                        .fill(.white)
                        .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
                }
                .frame(height: 12)
                .clipShape(Capsule())
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

#if !os(tvOS)
/// A timeline with no thumb: the entire capsule is the seeking surface.
struct ExampleCapsuleSlider: View {
    @Binding
    var value: Double
    let upperBound: Double
    let isEnabled: Bool
    let accessibilityValue: String
    let onEditingChanged: (Bool) -> Void

    @State
    private var isDragging = false
    @GestureState
    private var gestureIsActive = false
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule()
                    .fill(.white)
                    .frame(width: geometry.size.width * fraction)
            }
            .frame(height: isDragging ? 20 : 12)
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($gestureIsActive) { _, active, _ in active = true }
                    .onChanged { gesture in
                        guard isEnabled, geometry.size.width > 0 else { return }
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        value = min(max(gesture.location.x / geometry.size.width, 0), 1) * upperBound
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
                set: { position in
                    guard isEnabled else { return }
                    onEditingChanged(true)
                    value = position
                    onEditingChanged(false)
                }
            ), in: 0 ... upperBound)
                .disabled(!isEnabled)
                .accessibilityLabel("Playback position")
                .accessibilityValue(accessibilityValue)
                .accessibilityHint("Swipe up or down to seek by ten seconds.")
                .accessibilityAdjustableAction { direction in
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
        }
        // Gesture state also resets on cancellation (for example, a system gesture).
        .onChange(of: gestureIsActive) { _, active in
            if !active {
                finishDragging()
            }
        }
        .onDisappear(perform: finishDragging)
    }

    private var fraction: Double {
        guard upperBound > 0 else { return 0 }
        return min(max(value / upperBound, 0), 1)
    }

    private func finishDragging() {
        guard isDragging else { return }
        isDragging = false
        onEditingChanged(false)
    }
}
#endif
