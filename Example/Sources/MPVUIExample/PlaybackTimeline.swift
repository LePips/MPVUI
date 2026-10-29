import SwiftUI

/// Position updates and scrub previews stay separate from menus and their anchors.
@MainActor
struct PlaybackTimeline: View {

    let model: PlayerModel

    @State
    var scrubPosition = 0.0
    @State
    var scrubbing = false

    var upperBound: Double {
        max(model.duration, 1)
    }

    var displayedPosition: Double {
        min(max(scrubbing ? scrubPosition : model.position, 0), upperBound)
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(Android)
            ComposeView {
                PlaybackTimelineComposer(
                    value: displayedPosition,
                    upperBound: upperBound,
                    enabled: model.seekable,
                    onChange: { scrubPosition = $0 },
                    onEditing: editingChanged
                )
            }
            .frame(height: 44)
            #elseif os(macOS)
            Slider(
                value: Binding(get: { displayedPosition }, set: updateScrubPosition),
                in: 0 ... upperBound,
                onEditingChanged: editingChanged
            )
            .tint(.white)
            .disabled(!model.seekable)
            .frame(height: 44)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(time(displayedPosition)) of \(time(model.duration))")
            #elseif os(tvOS)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.2))

                    Capsule()
                        .fill(.white)
                        .frame(width: geometry.size.width * displayedPosition / upperBound)
                }
                .frame(height: 12)
                .clipShape(Capsule())
                .frame(maxHeight: .infinity)
            }
            .frame(height: 44)
            .accessibilityLabel("Playback progress")
            #else
            AppleCapsuleSlider(
                value: Binding(get: { displayedPosition }, set: { scrubPosition = $0 }),
                upperBound: upperBound,
                isEnabled: model.seekable,
                accessibilityValue: "\(time(displayedPosition)) of \(time(model.duration))",
                onEditingChanged: editingChanged
            )
            #endif
            HStack {
                Text(time(displayedPosition))
                    .accessibilityLabel("Elapsed \(time(displayedPosition))")

                Spacer()

                Text(time(model.duration))
                    .accessibilityLabel("Duration \(time(model.duration))")
            }
            .font(.caption.weight(.medium))
            .monospaced()
            .foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityIdentifier("playbackTimeline")
        .onChange(of: model.selectedName) { _, _ in scrubbing = false }
    }

    func updateScrubPosition(_ position: Double) {
        scrubPosition = position

        if !scrubbing, model.seekable {
            model.player.seek(to: .seconds(min(max(position, 0), upperBound)))
        }
    }

    func editingChanged(_ editing: Bool) {
        if editing {
            if !scrubbing {
                scrubPosition = model.position
            }

            scrubbing = true
        } else if scrubbing {
            let target = min(max(scrubPosition, 0), upperBound)

            scrubbing = false

            if model.seekable {
                model.player.seek(to: .seconds(target))
            }
        }
    }

    func time(_ value: Double) -> String {
        let seconds = Int(value.isFinite ? max(0, value) : 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

#if SKIP
struct PlaybackTimelineComposer {

    let value: Double
    let upperBound: Double
    let enabled: Bool
    let onChange: (Double) -> Void
    let onEditing: (Bool) -> Void

    init(
        value: Double,
        upperBound: Double,
        enabled: Bool,
        onChange: @escaping (Double) -> Void,
        onEditing: @escaping (Bool) -> Void
    ) {
        self.value = value
        self.upperBound = upperBound
        self.enabled = enabled
        self.onChange = onChange
        self.onEditing = onEditing
    }
}

extension PlaybackTimelineComposer: ContentComposer {

    @Composable
    func Compose(context: ComposeContext) {
        PlayerChromeTimeline(
            value: value,
            upperBound: upperBound,
            enabled: enabled,
            onChange: onChange,
            onEditing: onEditing,
            modifier: context.modifier
        )
    }
}
#endif
