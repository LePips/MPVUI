import MediaAccessibilityKit
import MPVUI
import SwiftUI

struct TextSubtitleOverlay: View {
    let snapshot: TextSubtitleSnapshot
    let videoSize: CGSize?
    var scalesWithVideo = false
    var bottomClearance: CGFloat = 0

    var body: some View {
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
            let canvas = scalesWithVideo ? referenceCanvas : videoFrame
            let scale = scalesWithVideo ? videoScale : 1

            let bottomLetterbox = (geometry.size.height - videoFrame.height) / 2
            let bottomInset = max(0, bottomClearance - bottomLetterbox) / max(scale, 0.001)

            TextSubtitleOverlayContent(snapshot: snapshot, bottomInset: bottomInset)
                .frame(width: canvas.width, height: canvas.height)
                .clipped()
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.text)
        .accessibilityHidden(snapshot.isEmpty)
        .accessibilityIdentifier("textSubtitleOverlay")
    }

    /// Video overlays scale a reference canvas; ordinary overlays lay out at
    /// the displayed video size so caption fonts and effects retain their point sizes.
    private var referenceCanvasSize: CGSize {
        let referenceHeight: CGFloat = 540
        let fallback = CGSize(width: 960, height: referenceHeight)
        guard let videoSize,
              videoSize.width.isFinite, videoSize.height.isFinite,
              videoSize.width > 0, videoSize.height > 0
        else { return fallback }

        // PlayerView supplies display dimensions with pixel aspect and rotation applied.
        // Scale caption size with video height, including portrait footage.
        let width = referenceHeight * (videoSize.width / videoSize.height)
        guard width.isFinite, width > 0 else { return fallback }
        return CGSize(width: width, height: referenceHeight)
    }
}

private struct TextSubtitleOverlayContent: View {
    @State
    private var captionStyle = CaptionStyle.current
    @Environment(\.scenePhase)
    private var scenePhase

    let snapshot: TextSubtitleSnapshot
    let bottomInset: CGFloat

    private var basePointSize: CGFloat {
        #if os(tvOS)
        36
        #else
        21
        #endif
    }

    private var pointSize: CGFloat {
        basePointSize * captionStyle.text.sizeScale.value
    }

    var body: some View {
        GeometryReader { geometry in
            if !snapshot.isEmpty {
                SubtitleRegionsLayout(
                    regions: snapshot.regions,
                    pointSize: pointSize,
                    bottomInset: bottomInset
                ) {
                    ForEach(Array(snapshot.regions.enumerated()), id: \.offset) { index, _ in
                        let region = snapshot.regions[index]

                        switch region.role == .secondary ? .automatic : region.placement {
                        case .automatic:
                            SubtitleRegionText(
                                text: region.text,
                                captionStyle: captionStyle,
                                alignment: .center,
                                writingDirection: .horizontal,
                                constrainsHeight: false,
                                basePointSize: basePointSize,
                                pointSize: pointSize
                            )
                        case let .webVTT(placement):
                            SubtitleRegionText(
                                text: region.text,
                                captionStyle: captionStyle,
                                alignment: placement.textAlignment.swiftUIValue,
                                writingDirection: placement.writingDirection,
                                constrainsHeight: placement.maximumHeight != nil,
                                basePointSize: basePointSize,
                                pointSize: pointSize
                            )
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .transition(.opacity)
            }
        }
        .clipped()
        .task {
            for await _ in CaptionProfile.updates {
                guard !Task.isCancelled else { return }
                captionStyle = .current
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                captionStyle = .current
            }
        }
    }
}

private struct SubtitleRegionsLayout: Layout {
    let regions: [TextSubtitleRegion]
    let pointSize: CGFloat
    let bottomInset: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews _: Subviews,
        cache _: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let count = min(regions.count, subviews.count)
        guard count > 0 else { return }

        // Keep the secondary language at the top even if its authored WebVTT
        // cue asks for bottom placement. Primary WebVTT retains its placement.
        for role in MPVSubtitleRole.allCases {
            let indices = (0 ..< count).filter {
                (regions[$0].role ?? .primary) == role
                    && (role == .secondary || regions[$0].placement == .automatic)
            }
            placeAutomaticRegions(at: indices, role: role, in: bounds, subviews: subviews)
        }

        for index in 0 ..< count {
            guard regions[index].role != .secondary,
                  case let .webVTT(placement) = regions[index].placement else { continue }
            placeWebVTTRegion(
                subviews[index],
                placement: placement,
                in: bounds
            )
        }
    }

    private func placeAutomaticRegions(
        at indices: [Int],
        role: MPVSubtitleRole,
        in bounds: CGRect,
        subviews: Subviews
    ) {
        guard !indices.isEmpty else { return }

        let automaticBottom = max(bounds.minY, bounds.maxY - max(24, bounds.height * 0.08, bottomInset))
        let horizontalPadding = max(24, bounds.width * 0.08)
        let regionProposal = ProposedViewSize(
            width: max(0, bounds.width - horizontalPadding * 2),
            height: max(0, automaticBottom - bounds.minY)
        )
        let sizes = indices.map { subviews[$0].sizeThatFits(regionProposal) }
        let spacing = pointSize * 0.25
        let totalHeight = sizes.reduce(0) { $0 + $1.height }
            + spacing * CGFloat(max(0, sizes.count - 1))
        var originY = role == .secondary
            ? bounds.minY + max(24, bounds.height * 0.08)
            : automaticBottom - totalHeight

        for (offset, index) in indices.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.midX, y: originY),
                anchor: .top,
                proposal: regionProposal
            )
            originY += sizes[offset].height + spacing
        }
    }

    private func placeWebVTTRegion(
        _ subview: LayoutSubview,
        placement: WebVTTPlacement,
        in viewport: CGRect
    ) {
        let regionProposal = ProposedViewSize(
            width: placement.maximumWidth.map {
                max(0, CGFloat($0) * viewport.width)
            } ?? viewport.width,
            height: placement.maximumHeight.map {
                max(0, CGFloat($0) * viewport.height)
            } ?? viewport.height
        )
        let size = subview.sizeThatFits(regionProposal)
        let anchor = CGPoint(
            x: placement.horizontalAnchor.unitValue,
            y: placement.verticalAnchor.unitValue
        )
        var origin = CGPoint(
            x: viewport.minX
                + CGFloat(placement.horizontalPosition) * viewport.width
                - size.width * anchor.x,
            y: viewport.minY
                + CGFloat(placement.verticalPosition) * viewport.height
                - size.height * anchor.y
        )

        // Preserve authored placement unless a temporary preview would overlap controls.
        if bottomInset > 0 {
            origin.y = max(viewport.minY, min(origin.y, viewport.maxY - bottomInset - size.height))
        }

        subview.place(
            at: origin,
            anchor: .topLeading,
            proposal: regionProposal
        )
    }
}

private struct SubtitleRegionText: View {
    let text: String
    let captionStyle: CaptionStyle
    let alignment: SwiftUI.TextAlignment
    let writingDirection: WebVTTPlacement.WritingDirection
    let constrainsHeight: Bool
    let basePointSize: CGFloat
    let pointSize: CGFloat

    private var presentationText: String {
        guard writingDirection == .verticalGrowingRight else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reversed()
            .joined(separator: "\n")
    }

    private var styledText: some View {
        CaptionText(presentationText, baseSize: basePointSize, style: captionStyle)
            .multilineTextAlignment(alignment)
            .lineSpacing(pointSize * 0.12)
            .fixedSize(horizontal: false, vertical: !constrainsHeight)
    }

    var body: some View {
        switch writingDirection {
        case .horizontal:
            styledText
        case .verticalGrowingLeft, .verticalGrowingRight:
            VerticalSubtitleLayout {
                styledText
                    .rotationEffect(.degrees(90))
            }
        }
    }
}

private struct VerticalSubtitleLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(proposal.rotated)
        return CGSize(width: size.height, height: size.width)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: proposal.rotated
        )
    }
}

private extension ProposedViewSize {
    var rotated: ProposedViewSize {
        ProposedViewSize(width: height, height: width)
    }
}

private extension WebVTTPlacement.HorizontalAnchor {
    var unitValue: CGFloat {
        switch self {
        case .left: 0
        case .center: 0.5
        case .right: 1
        }
    }
}

private extension WebVTTPlacement.VerticalAnchor {
    var unitValue: CGFloat {
        switch self {
        case .top: 0
        case .center: 0.5
        case .bottom: 1
        }
    }
}

private extension WebVTTPlacement.TextAlignment {
    var swiftUIValue: SwiftUI.TextAlignment {
        switch self {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }
}
