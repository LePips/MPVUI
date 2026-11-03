import MPVCore
import SwiftUI

/// Places semantic captions using authored WebVTT geometry and subtitle roles.
/// The caller supplies styling and can supply the video's actual crop or zoom viewport.
/// Vertical cues rotate text columns, preserving the requested column growth direction.
@MainActor
public struct MPVTextSubtitleOverlay<Caption: View>: View {

    let snapshot: TextSubtitleSnapshot
    let videoSize: CGSize?
    let videoFrame: ((CGRect) -> CGRect)?
    let placementPolicy: MPVSubtitlePlacementPolicy
    let automaticPlacement: MPVSubtitleAutomaticPlacement
    let insets: EdgeInsets?
    let spacing: CGFloat
    let caption: (TextSubtitleRegion) -> Caption

    /// Creates an overlay with caller-provided caption styling.
    ///
    /// - Parameters:
    ///   - snapshot: The complete semantic presentation.
    ///   - videoSize: Presentation dimensions after pixel-aspect correction and rotation. Defaults to 16:9.
    ///   - videoFrame: Resolves the displayed video rectangle in overlay coordinates from the layout bounds.
    ///     Overrides `videoSize` and may extend beyond those bounds for cropped or zoomed video.
    ///   - placementPolicy: How authored positions interact with subtitle roles.
    ///   - automaticPlacement: Whether unpositioned captions use visible video or the entire container.
    ///   - insets: Margins for unpositioned captions. Defaults to 8 percent per axis, with a 24-point minimum.
    ///   - spacing: Vertical space between unpositioned regions of the same role.
    ///   - caption: Styles a display region. Its text has display column order for vertical cues.
    ///     Alignment, measurement, rotation, clipping, and semantic accessibility text are supplied by the overlay.
    public init(
        snapshot: TextSubtitleSnapshot,
        videoSize: CGSize? = nil,
        videoFrame: ((CGRect) -> CGRect)? = nil,
        placementPolicy: MPVSubtitlePlacementPolicy = .primaryAuthored,
        automaticPlacement: MPVSubtitleAutomaticPlacement = .video,
        insets: EdgeInsets? = nil,
        spacing: CGFloat = 6,
        @ViewBuilder caption: @escaping (TextSubtitleRegion) -> Caption
    ) {
        self.snapshot = snapshot
        self.videoSize = videoSize
        self.videoFrame = videoFrame
        self.placementPolicy = placementPolicy
        self.automaticPlacement = automaticPlacement
        self.insets = insets
        self.spacing = spacing.isFinite ? max(0, spacing) : 6
        self.caption = caption
    }

    /// The placed caption views, clipped to the overlay bounds.
    public var body: some View {
        let regions = snapshot.regions.map { MPVSubtitleGeometry.presentation($0, policy: placementPolicy) }

        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)

            MPVSubtitleRegionsLayout(
                regions: regions,
                viewport: MPVSubtitleGeometry.viewport(in: bounds, videoSize: videoSize, override: videoFrame?(bounds)),
                automaticPlacement: automaticPlacement,
                insets: insets,
                spacing: spacing
            ) {
                ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                    let placement = MPVSubtitleGeometry.placement(region)
                    let vertical = placement.map { $0.writingDirection != .horizontal } ?? false

                    MPVSubtitleWritingLayout(vertical: vertical) {
                        caption(region)
                            .multilineTextAlignment(MPVSubtitleGeometry.textAlignment(placement))
                            .fixedSize(horizontal: false, vertical: placement?.maximumHeight == nil)
                            .rotationEffect(.degrees(vertical ? 90 : 0))
                    }
                }
            }
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.text)
        .accessibilityHidden(snapshot.isEmpty)
        .accessibilityIdentifier("textSubtitleOverlay")
    }
}

public extension MPVTextSubtitleOverlay where Caption == Text {

    /// Creates authored captions with white text in the system title-3 font.
    init(
        snapshot: TextSubtitleSnapshot,
        videoSize: CGSize? = nil,
        videoFrame: ((CGRect) -> CGRect)? = nil,
        placementPolicy: MPVSubtitlePlacementPolicy = .primaryAuthored,
        automaticPlacement: MPVSubtitleAutomaticPlacement = .video
    ) {
        self.init(
            snapshot: snapshot,
            videoSize: videoSize,
            videoFrame: videoFrame,
            placementPolicy: placementPolicy,
            automaticPlacement: automaticPlacement
        ) { region in
            Text(region.text)
                .font(.title3)
                .foregroundColor(.white)
        }
    }
}

/// How authored cue placement interacts with primary and secondary subtitle roles.
public enum MPVSubtitlePlacementPolicy: Sendable {

    /// Honors authored WebVTT placement for both roles. Unpositioned cues use role placement.
    case authored
    /// Honors primary WebVTT placement and keeps secondary captions at the top.
    case primaryAuthored
    /// Places primary captions at the bottom and secondary captions at the top.
    case roles
}

/// The area used for captions without authored positions.
public enum MPVSubtitleAutomaticPlacement: Sendable {

    /// Uses the visible intersection of the video viewport and overlay bounds.
    case video
    /// Uses the entire overlay, including letterbox space.
    case container
}

struct MPVSubtitleRegionsLayout {

    let regions: [TextSubtitleRegion]
    let viewport: CGRect
    let automaticPlacement: MPVSubtitleAutomaticPlacement
    let insets: EdgeInsets?
    let spacing: CGFloat
}

extension MPVSubtitleRegionsLayout: Layout {

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let viewport = viewport.offsetBy(dx: bounds.minX, dy: bounds.minY)
        let visible = automaticPlacement == .container ? bounds : viewport.intersection(bounds)
        let area = MPVSubtitleGeometry.captionArea(in: visible, insets: insets)
        let proposal = ProposedViewSize(width: area.width, height: area.height)
        let indices = 0 ..< min(regions.count, subviews.count)

        for role in MPVSubtitleRole.allCases {
            let automatic = indices.filter { regions[$0].placement == .automatic && (regions[$0].role ?? .primary) == role }
            let heights = automatic.map { subviews[$0].sizeThatFits(proposal).height }
            let height = heights.reduce(0, +) + spacing * CGFloat(max(0, automatic.count - 1))
            var y = role == .secondary ? area.minY : area.maxY - height

            for (offset, index) in automatic.enumerated() {
                subviews[index].place(at: CGPoint(x: area.midX, y: y), anchor: .top, proposal: proposal)
                y += heights[offset] + spacing
            }
        }

        for index in indices {
            guard let placement = MPVSubtitleGeometry.placement(regions[index]) else {
                continue
            }

            let box = MPVSubtitleGeometry.cueBox(placement, in: viewport)
            subviews[index].place(at: box.position, anchor: box.anchor, proposal: box.proposal)
        }
    }
}

struct MPVSubtitleWritingLayout {

    let vertical: Bool
}

extension MPVSubtitleWritingLayout: Layout {

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let source = vertical ? ProposedViewSize(width: proposal.height, height: proposal.width) : proposal
        let size = subviews.first?.sizeThatFits(source) ?? .zero
        return vertical ? CGSize(width: size.height, height: size.width) : size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let size = vertical ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(size))
    }
}

enum MPVSubtitleGeometry {

    static func placement(_ region: TextSubtitleRegion) -> WebVTTPlacement? {
        if case let .webVTT(value) = region.placement {
            value
        } else {
            nil
        }
    }

    static func presentation(_ region: TextSubtitleRegion, policy: MPVSubtitlePlacementPolicy) -> TextSubtitleRegion {
        if policy == .roles || (policy == .primaryAuthored && region.role == .secondary) {
            return .init(text: region.text, trackID: region.trackID, role: region.role)
        }
        guard placement(region)?.writingDirection == .verticalGrowingRight else {
            return region
        }

        let text = region.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reversed()
            .joined(separator: "\n")
        return .init(text: text, placement: region.placement, trackID: region.trackID, role: region.role)
    }

    static func viewport(in bounds: CGRect, videoSize: CGSize?, override: CGRect?) -> CGRect {
        if let override, valid(override.size), override.minX.isFinite, override.minY.isFinite {
            return override
        }
        let size = videoSize.flatMap { valid($0) ? $0 : nil } ?? CGSize(width: 16, height: 9)
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale

        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    static func captionArea(in frame: CGRect, insets: EdgeInsets?) -> CGRect {
        guard !frame.isNull, !frame.isInfinite else {
            return .zero
        }

        let horizontal = max(24, frame.width * 0.08)
        let vertical = max(24, frame.height * 0.08)
        let insets = insets ?? EdgeInsets(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)

        func padding(_ value: CGFloat) -> CGFloat {
            value.isFinite ? max(0, value) : 0
        }

        let left = min(frame.width / 2, padding(insets.leading))
        let right = min(frame.width / 2, padding(insets.trailing))
        let top = min(frame.height / 2, padding(insets.top))
        let bottom = min(frame.height / 2, padding(insets.bottom))

        return CGRect(
            x: frame.minX + left,
            y: frame.minY + top,
            width: max(0, frame.width - left - right),
            height: max(0, frame.height - top - bottom)
        )
    }

    static func cueBox(
        _ placement: WebVTTPlacement,
        in frame: CGRect
    ) -> (position: CGPoint, anchor: UnitPoint, proposal: ProposedViewSize) {
        let x: CGFloat = switch placement.horizontalAnchor {
        case .left:
            0
        case .center:
            0.5
        case .right:
            1
        }
        let y: CGFloat = switch placement.verticalAnchor {
        case .top:
            0
        case .center:
            0.5
        case .bottom:
            1
        }
        let position = CGPoint(
            x: frame.minX + CGFloat(placement.horizontalPosition) * frame.width,
            y: frame.minY + CGFloat(placement.verticalPosition) * frame.height
        )
        let proposal = ProposedViewSize(
            width: frame.width * CGFloat(placement.maximumWidth ?? 1),
            height: frame.height * CGFloat(placement.maximumHeight ?? 1)
        )

        return (position, UnitPoint(x: x, y: y), proposal)
    }

    static func textAlignment(_ placement: WebVTTPlacement?) -> TextAlignment {
        switch placement?.textAlignment {
        case .left:
            .leading
        case .right:
            .trailing
        default:
            .center
        }
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
