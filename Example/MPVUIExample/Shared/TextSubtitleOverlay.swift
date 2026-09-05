import MediaAccessibilityKit
import MPVUI
import SwiftUI

struct TextSubtitleOverlay: View {
    let snapshot: TextSubtitleSnapshot
    let videoSize: CGSize?

    var body: some View {
        TextSubtitleOverlayContent(
            snapshot: snapshot,
            videoSize: videoSize
        )
        .mediaCaptionStyle()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.text)
        .accessibilityHidden(snapshot.isEmpty)
        .accessibilityIdentifier("textSubtitleOverlay")
    }
}

private struct TextSubtitleOverlayContent: View {
    @Environment(\.mediaCaptionStyle)
    private var captionStyle

    let snapshot: TextSubtitleSnapshot
    let videoSize: CGSize?

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
                    videoViewport: videoViewport(in: geometry.size),
                    automaticBottom: automaticSubtitleBottom(in: geometry),
                    pointSize: pointSize
                ) {
                    ForEach(Array(snapshot.regions.enumerated()), id: \.offset) { index, _ in
                        let region = snapshot.regions[index]

                        switch region.placement {
                        case .automatic:
                            SubtitleRegionText(
                                text: region.text,
                                alignment: .center,
                                writingDirection: .horizontal,
                                constrainsHeight: false,
                                basePointSize: basePointSize,
                                pointSize: pointSize
                            )
                        case let .webVTT(placement):
                            SubtitleRegionText(
                                text: region.text,
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
    }

    private func automaticSubtitleBottom(in geometry: GeometryProxy) -> CGFloat {
        geometry.size.height - max(24, geometry.size.height * 0.08)
    }

    private func videoViewport(in containerSize: CGSize) -> CGRect {
        guard containerSize.width > 0,
              containerSize.height > 0,
              containerSize.width.isFinite,
              containerSize.height.isFinite,
              let videoSize,
              videoSize.width > 0,
              videoSize.height > 0,
              videoSize.width.isFinite,
              videoSize.height.isFinite
        else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let sourceAspectRatio = videoSize.width / videoSize.height
        guard sourceAspectRatio > 0, sourceAspectRatio.isFinite else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let containerAspectRatio = containerSize.width / containerSize.height
        let viewportSize = sourceAspectRatio > containerAspectRatio
            ? CGSize(width: containerSize.width, height: containerSize.width / sourceAspectRatio)
            : CGSize(width: containerSize.height * sourceAspectRatio, height: containerSize.height)

        return CGRect(
            x: (containerSize.width - viewportSize.width) / 2,
            y: (containerSize.height - viewportSize.height) / 2,
            width: viewportSize.width,
            height: viewportSize.height
        )
    }
}

private struct SubtitleRegionsLayout: Layout {
    let regions: [TextSubtitleRegion]
    let videoViewport: CGRect
    let automaticBottom: CGFloat
    let pointSize: CGFloat

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

        let automaticIndices = (0 ..< count).filter {
            regions[$0].placement == .automatic
        }
        placeAutomaticRegions(
            at: automaticIndices,
            in: bounds,
            subviews: subviews
        )

        let viewport = videoViewport.offsetBy(dx: bounds.minX, dy: bounds.minY)
        for index in 0 ..< count {
            guard case let .webVTT(placement) = regions[index].placement else { continue }
            placeWebVTTRegion(
                subviews[index],
                placement: placement,
                in: viewport
            )
        }
    }

    private func placeAutomaticRegions(
        at indices: [Int],
        in bounds: CGRect,
        subviews: Subviews
    ) {
        guard !indices.isEmpty else { return }

        let horizontalPadding = max(24, bounds.width * 0.08)
        let regionProposal = ProposedViewSize(
            width: max(0, bounds.width - horizontalPadding * 2),
            height: max(0, automaticBottom - bounds.minY)
        )
        let sizes = indices.map { subviews[$0].sizeThatFits(regionProposal) }
        let spacing = pointSize * 0.25
        let totalHeight = sizes.reduce(0) { $0 + $1.height }
            + spacing * CGFloat(max(0, sizes.count - 1))
        var originY = automaticBottom - totalHeight

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
        let origin = CGPoint(
            x: viewport.minX
                + CGFloat(placement.horizontalPosition) * viewport.width
                - size.width * anchor.x,
            y: viewport.minY
                + CGFloat(placement.verticalPosition) * viewport.height
                - size.height * anchor.y
        )

        subview.place(
            at: origin,
            anchor: .topLeading,
            proposal: regionProposal
        )
    }
}

private struct SubtitleRegionText: View {
    let text: String
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
        CaptionText(presentationText, baseSize: basePointSize)
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
