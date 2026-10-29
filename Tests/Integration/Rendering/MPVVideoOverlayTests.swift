@testable import MPVCore
@testable import MPVUI
import SwiftUI
import Testing

@Suite(.tags(.integration), .serialized)
struct MPVVideoOverlayTests {

    @Test
    @MainActor
    func `semantic captions stay inside letterboxed video and clear with the snapshot`() throws {
        let snapshot = TextSubtitleSnapshot(regions: [
            .init(text: "Primary", role: .primary),
            .init(text: "Secondary", role: .secondary),
        ])

        // Keep independent render trees alive until all image comparisons finish.
        var renderers: [AnyObject] = []

        func render(_ snapshot: TextSubtitleSnapshot, videoSize: CGSize?) throws -> MPVVideoOverlayBitmap {
            let overlay = MPVTextSubtitleOverlay(snapshot: snapshot, videoSize: videoSize) { region in
                Rectangle()
                    .fill(region.role == .secondary ? Color.blue : Color.red)
                    .frame(width: 80, height: 20)
            }

            let renderer = ImageRenderer(content: overlay.frame(width: 400, height: 400))
            renderers.append(renderer)

            return try #require(renderer.cgImage.flatMap(MPVVideoOverlayBitmap.init))
        }

        let bitmap = try render(snapshot, videoSize: CGSize(width: 1600, height: 900))
        var redRows: [Int] = []
        var blueRows: [Int] = []

        for y in 0 ..< bitmap.height {
            let offset = y * bitmap.stride + bitmap.width / 2 * 4

            if bitmap.bytes[offset + 2] > 200 {
                redRows.append(y)
            }

            if bitmap.bytes[offset] > 200 {
                blueRows.append(y)
            }
        }

        let red = try #require(redRows.first)
        let blue = try #require(blueRows.first)
        #expect(blue > 90 && blue < 150)
        #expect(red > 250 && red < 300)
        #expect(redRows.count == 20 && blueRows.count == 20)

        let clearedBounds = try alphaBounds(in: render(.init(), videoSize: nil))
        #expect(clearedBounds == nil)

        let fallback = try render(snapshot, videoSize: nil)

        for invalid in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 100), CGSize(width: 100, height: -1)] {
            #expect(try render(snapshot, videoSize: invalid).bytes == fallback.bytes)
        }

        let defaultCaption = ImageRenderer(content: MPVTextSubtitleOverlay(snapshot: snapshot).frame(width: 400, height: 400))
        #expect(try alphaBounds(in: #require(defaultCaption.cgImage.flatMap(MPVVideoOverlayBitmap.init))) != nil)
    }

    @Test
    @MainActor
    func `content updates replace raster pixels without changing the overlay canvas`() async throws {
        var bitmaps: [MPVVideoOverlayBitmap] = []

        let renderer = MPVVideoOverlayRenderer(
            content: AnyView(Color(.sRGB, red: 1, green: 0, blue: 0)),
            submit: { bitmap in
                if let bitmap {
                    bitmaps.append(bitmap)
                }

                return bitmap != nil
            },
            availabilityChanged: { _ in }
        )
        defer { renderer.invalidate() }
        renderer.updateSize(CGSize(width: 8, height: 4), displayScale: 1)
        try await eventually("red overlay is rasterized") { !bitmaps.isEmpty }

        let first = try #require(bitmaps.first)
        #expect(Array(first.bytes.prefix(4)) == [0, 0, 255, 255])
        renderer.updateContent(AnyView(Color(.sRGB, red: 0, green: 0, blue: 1)))
        try await eventually("updated overlay has blue pixels") { bitmaps.last?.bytes.first == 255 }

        let last = try #require(bitmaps.last)
        #expect(Array(last.bytes.prefix(4)) == [255, 0, 0, 255])
        #expect(first.width == last.width && first.height == last.height)
        renderer.updateSize(CGSize(width: CGFloat.nan, height: 4))
        renderer.updateSize(CGSize(width: 8, height: 4), displayScale: 0)

        #expect(bitmaps.last?.width == last.width)
    }

    @Test
    @MainActor
    func `invalidating during submission ignores late compositor acceptance`() async throws {
        let (answers, continuation) = AsyncStream<Bool>.makeStream()
        defer { continuation.finish() }

        var submitted = false
        var resumed = false
        var availability: [Bool] = []

        let renderer = MPVVideoOverlayRenderer(
            content: AnyView(Color.white),
            submit: { _ in
                submitted = true

                for await answer in answers {
                    resumed = true
                    return answer
                }

                resumed = true

                return false
            },
            availabilityChanged: { availability.append($0) }
        )
        renderer.updateSize(CGSize(width: 8, height: 4))
        try await eventually("overlay submission is suspended") { submitted }
        renderer.invalidate()
        continuation.yield(true)
        try await eventually("cancelled submission has returned") { resumed }
        renderer.updateContent(AnyView(Color.black))

        #expect(availability.isEmpty)
    }

    @Test
    @MainActor
    func `supersampled raster resolution preserves text proportions and the full canvas`() async throws {
        var bitmaps: [MPVVideoOverlayBitmap] = []

        let renderer = MPVVideoOverlayRenderer(
            content: AnyView(Text("Caption stays on one line at the inline width.")
                .font(.system(size: 24))
                .foregroundStyle(.white)),
            submit: { bitmap in
                if let bitmap {
                    bitmaps.append(bitmap)
                }

                return bitmap != nil
            },
            availabilityChanged: { _ in }
        )
        defer { renderer.invalidate() }

        let canvas = CGSize(width: 640, height: 360)
        var previousBounds: CGRect?

        for (renderWidth, bitmapWidth) in [(320, 640), (640, 1280), (1280, 2048)] {
            let count = bitmaps.count

            renderer.updateSize(canvas, rasterSize: CGSize(width: renderWidth, height: renderWidth * 9 / 16))

            for _ in 0 ..< 100 where bitmaps.count == count {
                try await Task.sleep(for: .milliseconds(20))
            }

            try #require(bitmaps.count > count)

            let bitmap = try #require(bitmaps.last)
            #expect(bitmap.width == bitmapWidth && bitmap.height == bitmapWidth * 9 / 16)

            let bounds = try #require(alphaBounds(in: bitmap))

            // Intrinsic text must occupy part of a transparent full-size canvas.
            #expect(bounds.minX > 0.05 && bounds.maxX < 0.95)
            #expect(bounds.height < 0.1)

            if let previousBounds {
                #expect(abs(bounds.width - previousBounds.width) < 0.01)
                #expect(abs(bounds.height - previousBounds.height) < 0.01)
            }

            previousBounds = bounds
        }
    }

    @Test
    @MainActor
    func `bitmap preserves BGRA premultiplication and transparent pixels`() throws {
        let renderer = ImageRenderer(content:
            HStack(spacing: 0) {
                Color(.sRGB, red: 1, green: 0, blue: 0)
                    .opacity(0.5)

                Color.clear
            }.frame(width: 2, height: 1)
        )

        let bitmap = try #require(renderer.cgImage.flatMap(MPVVideoOverlayBitmap.init))
        #expect(bitmap.width == 2 && bitmap.height == 1 && bitmap.stride == 8)
        #expect(bitmap.bytes[0] == 0 && bitmap.bytes[1] == 0)
        #expect(abs(Int(bitmap.bytes[2]) - 128) <= 1)
        #expect(bitmap.bytes[2] == bitmap.bytes[3])
        #expect(Array(bitmap.bytes[4 ..< 8]) == [0, 0, 0, 0])
    }

    @Test
    @MainActor
    func `overlay is owned by its surface and removed without replacing video`() async throws {
        let player = MPVPlayer(configuration: .init(automaticallyPlays: false))
        let surface = MPVPlatformVideoPlayer(player: player)
        let layer = surface.metalLayer
        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        surface.setVideoOverlay(MPVVideoOverlay(content: AnyView(Text("Badge"))))
        weak let original = surface.videoOverlayHost

        #expect(original?.superview === surface)
        #expect(original?.frame.size == surface.bounds.size)
        surface.setVideoOverlay(MPVVideoOverlay(content: AnyView(Text("Caption"))))

        #expect(surface.videoOverlayHost === original)
        surface.setVideoOverlay(nil)

        #expect(surface.videoOverlayHost == nil)

        for _ in 0 ..< 50 where original != nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(original == nil)
        #expect(surface.metalLayer === layer)
    }
}

private func alphaBounds(in bitmap: MPVVideoOverlayBitmap) -> CGRect? {
    var minX = bitmap.width
    var minY = bitmap.height
    var maxX = -1
    var maxY = -1

    bitmap.bytes.withUnsafeBytes { bytes in
        let pixels = bytes.bindMemory(to: UInt8.self)

        for y in 0 ..< bitmap.height {
            for x in 0 ..< bitmap.width where pixels[y * bitmap.stride + x * 4 + 3] > 10 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }

    guard maxX >= minX, maxY >= minY else { return nil }

    return CGRect(
        x: CGFloat(minX) / CGFloat(bitmap.width),
        y: CGFloat(minY) / CGFloat(bitmap.height),
        width: CGFloat(maxX - minX + 1) / CGFloat(bitmap.width),
        height: CGFloat(maxY - minY + 1) / CGFloat(bitmap.height)
    )
}
