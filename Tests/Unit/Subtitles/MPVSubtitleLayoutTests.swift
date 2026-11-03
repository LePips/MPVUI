import ImageIO
@testable import MPVCore
@testable import MPVUI
import SwiftUI
import Testing

@Suite(.tags(.unit), .serialized)
@MainActor
struct MPVSubtitleLayoutTests {

    @Test
    func `viewport geometry handles letterboxing cropping and invalid sizes`() {
        let bounds = CGRect(x: 20, y: 30, width: 800, height: 600)

        let fit = MPVSubtitleGeometry.viewport(in: bounds, videoSize: CGSize(width: 1920, height: 1080), override: nil)

        #expect(fit == CGRect(x: 20, y: 105, width: 800, height: 450))

        let crop = CGRect(x: -100, y: 0, width: 1000, height: 600)

        #expect(MPVSubtitleGeometry.viewport(in: bounds, videoSize: nil, override: crop) == crop)

        let fallback = MPVSubtitleGeometry.viewport(in: bounds, videoSize: CGSize(width: CGFloat.infinity, height: 0), override: .null)

        #expect(fallback == fit)
        #expect(MPVSubtitleGeometry.captionArea(in: CGRect(x: 0, y: 0, width: 10, height: 10), insets: nil).size == .zero)
    }

    @Test
    func `authored positions use video coordinates without clamping deliberate overflow`() {
        let placement = WebVTTPlacement(
            horizontalPosition: 0.25,
            verticalPosition: 1.1,
            horizontalAnchor: .right,
            verticalAnchor: .top,
            maximumWidth: 0.5,
            maximumHeight: 0.3
        )

        let box = MPVSubtitleGeometry.cueBox(placement, in: CGRect(x: 100, y: 50, width: 800, height: 400))

        #expect(box.position.x == 300 && abs(box.position.y - 490) < 0.001)
        #expect(box.anchor == UnitPoint(x: 1, y: 0))
        #expect(box.proposal.width == 400 && abs((box.proposal.height ?? 0) - 120) < 0.001)
    }

    @Test
    func `secondary policy and vertical column order preserve semantic source text`() {
        let placement = WebVTTPlacement(horizontalPosition: 0.5, verticalPosition: 0.5, writingDirection: .verticalGrowingRight)
        let region = TextSubtitleRegion(text: "one\n\ntwo", placement: .webVTT(placement), role: .secondary)

        let authored = MPVSubtitleGeometry.presentation(region, policy: .authored)

        #expect(authored.text == "two\n\none" && authored.placement == region.placement)
        #expect(region.text == "one\n\ntwo")

        let secondary = MPVSubtitleGeometry.presentation(region, policy: .primaryAuthored)

        #expect(secondary.placement == .automatic && secondary.text == region.text && secondary.role == .secondary)
        #expect(MPVSubtitleGeometry.presentation(region, policy: .roles).placement == .automatic)
    }

    @Test
    func `custom captions render authored primary and automatic secondary regions`() throws {
        let snapshot = TextSubtitleSnapshot(
            regions: [
                .init(text: "Secondary captions stay at the top", role: .secondary),
                .init(
                    text: "Authored caption at 30 percent",
                    placement: .webVTT(.init(horizontalPosition: 0.3, verticalPosition: 0.7, maximumWidth: 0.5))
                ),
                .init(
                    text: "Vertical one\nVertical two",
                    placement: .webVTT(
                        .init(
                            horizontalPosition: 0.9,
                            verticalPosition: 0.5,
                            verticalAnchor: .center,
                            maximumHeight: 0.65,
                            writingDirection: .verticalGrowingRight
                        )
                    )
                )
            ]
        )
        let content = MPVTextSubtitleOverlay(snapshot: snapshot, videoSize: CGSize(width: 16, height: 9)) { region in
            Text(region.text)
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .padding(5)
                .background(.black
                    .opacity(0.8))
        }
        .frame(width: 800, height: 600)
        .background(Color.gray)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)

        #expect(image.width == 800 && image.height == 600)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mpvui-subtitle-layout-preview.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)

        #expect(CGImageDestinationFinalize(destination))
    }
}
