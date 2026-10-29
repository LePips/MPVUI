import MPVCore
import SwiftUI

/// A noninteractive overlay that fits text subtitles to the video's displayed aspect ratio.
///
/// Primary subtitles appear at the bottom and secondary subtitles at the top.
/// The overlay uses subtitle roles rather than authored WebVTT placement.
@MainActor
public struct MPVTextSubtitleOverlay<Caption: View> {

    let snapshot: TextSubtitleSnapshot
    let videoSize: CGSize?
    let caption: (TextSubtitleRegion) -> Caption

    private var referenceCanvasSize: CGSize {
        let referenceHeight: CGFloat = 540
        let fallback = CGSize(width: 960, height: referenceHeight)

        guard let videoSize,
              videoSize.width.isFinite, videoSize.height.isFinite,
              videoSize.width > 0, videoSize.height > 0
        else { return fallback }

        let width = referenceHeight * (videoSize.width / videoSize.height)
        guard width.isFinite, width > 0 else { return fallback }

        return CGSize(width: width, height: referenceHeight)
    }

    /// Creates an overlay with caller-provided caption styling.
    ///
    /// - Parameters:
    ///   - snapshot: The complete subtitle presentation to display.
    ///   - videoSize: The video's display dimensions. Uses a 16:9 aspect ratio when absent or invalid.
    ///   - caption: A view builder that styles each text region.
    public init(snapshot: TextSubtitleSnapshot, videoSize: CGSize? = nil, @ViewBuilder caption: @escaping (TextSubtitleRegion) -> Caption) {
        self.snapshot = snapshot
        self.videoSize = videoSize
        self.caption = caption
    }
}

extension MPVTextSubtitleOverlay: View {

    /// The primary and secondary subtitle views within the video frame.
    public var body: some View {
        GeometryReader { geometry in
            let referenceCanvas = referenceCanvasSize

            let videoScale = min(
                geometry.size.width / referenceCanvas.width,
                geometry.size.height / referenceCanvas.height
            )

            let videoFrame = CGSize(
                width: referenceCanvas.width * videoScale,
                height: referenceCanvas.height * videoScale
            )

            ZStack {
                if !snapshot.isEmpty {
                    subtitleStack(for: .secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    subtitleStack(for: .primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
            .padding(.horizontal, max(24, videoFrame.width * 0.08))
            .padding(.vertical, max(24, videoFrame.height * 0.08))
            .frame(width: videoFrame.width, height: videoFrame.height)
            .clipped()
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.text)
        .accessibilityHidden(snapshot.isEmpty)
        .accessibilityIdentifier("textSubtitleOverlay")
    }

    @ViewBuilder
    private func subtitleStack(for role: MPVSubtitleRole) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(snapshot.regions.enumerated()), id: \.offset) { _, region in
                if (region.role ?? .primary) == role {
                    caption(region)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

public extension MPVTextSubtitleOverlay where Caption == Text {

    /// Creates an overlay with white text in the system title-3 font.
    /// Uses a 16:9 aspect ratio when `videoSize` is absent or invalid.
    init(snapshot: TextSubtitleSnapshot, videoSize: CGSize? = nil) {
        self.init(snapshot: snapshot, videoSize: videoSize) { region in
            Text(region.text).font(.title3).foregroundColor(.white)
        }
    }
}
