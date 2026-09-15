import MPVUI
import SwiftUI

/// Keep the frequently changing position and scrub preview inside this observation
/// boundary so playback ticks do not invalidate the surrounding controls or menus.
@MainActor
struct ExamplePlaybackTimeline: View {
    let player: MPVPlayer
    @Binding
    var isScrubbing: Bool
    let onInteraction: () -> Void
    let seek: (Duration) -> Void

    @State
    private var scrubPosition: Duration = .zero

    var body: some View {
        VStack(spacing: 0) {
            timelineControl

            HStack {
                Text(ExampleDisplayFormat.duration(displayedPosition))
                Spacer()
                Text("−" + ExampleDisplayFormat.duration(max(.zero, player.duration - displayedPosition)))
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var timelineControl: some View {
        #if os(tvOS)
        ExampleCapsuleProgress(
            value: seconds(player.position),
            upperBound: seconds(scrubberUpperBound),
            accessibilityValue: playbackPositionDescription
        )
        .accessibilityIdentifier("playbackProgress")
        #else
        ExampleCapsuleSlider(
            value: scrubberBinding,
            upperBound: seconds(scrubberUpperBound),
            isEnabled: canSeek,
            accessibilityValue: playbackPositionDescription,
            onEditingChanged: scrubberEditingChanged
        )
        .accessibilityIdentifier("playbackSlider")
        #endif
    }

    private var scrubberBinding: Binding<Double> {
        Binding(
            get: { seconds(displayedPosition) },
            set: { scrubPosition = normalizedPosition(.seconds($0)) }
        )
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private var scrubberUpperBound: Duration {
        player.duration > .zero ? player.duration : .seconds(1)
    }

    private var displayedPosition: Duration {
        isScrubbing ? scrubPosition : normalizedPosition(player.position)
    }

    private var canSeek: Bool {
        player.isSeekable && player.duration > .zero
    }

    private var playbackPositionDescription: String {
        "\(ExampleDisplayFormat.duration(displayedPosition)) of \(ExampleDisplayFormat.duration(player.duration))"
    }

    private func scrubberEditingChanged(_ editing: Bool) {
        if editing {
            scrubPosition = normalizedPosition(player.position)
            isScrubbing = true
        } else {
            guard isScrubbing else { return }
            let target = normalizedPosition(scrubPosition)
            isScrubbing = false
            if canSeek {
                seek(target)
            }
        }
        onInteraction()
    }

    private func normalizedPosition(_ position: Duration) -> Duration {
        clamp(position, to: .zero ... scrubberUpperBound)
    }
}
