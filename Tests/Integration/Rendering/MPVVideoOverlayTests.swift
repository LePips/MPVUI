@testable import MPVUI
import SwiftUI
import Testing

@Suite(.tags(.integration), .serialized)
struct MPVVideoOverlayTests {
    @Test @MainActor
    func `content updates replace raster pixels without changing the overlay canvas`() async throws {
        var bitmaps: [MPVVideoOverlayBitmap] = []
        let renderer = MPVVideoOverlayRenderer(
            content: AnyView(Color(.sRGB, red: 1, green: 0, blue: 0)),
            submit: { bitmap in
                if let bitmap {
                    bitmaps.append(bitmap)
                }
                return bitmap != nil
            }, availabilityChanged: { _ in }
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

    @Test @MainActor
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
            }, availabilityChanged: { availability.append($0) }
        )
        renderer.updateSize(CGSize(width: 8, height: 4))
        try await eventually("overlay submission is suspended") { submitted }
        renderer.invalidate()
        continuation.yield(true)
        try await eventually("cancelled submission has returned") { resumed }
        renderer.updateContent(AnyView(Color.black))
        #expect(availability.isEmpty)
    }

    @Test @MainActor
    func `supersampled raster resolution preserves text proportions and the full canvas`() async throws {
        var bitmaps: [MPVVideoOverlayBitmap] = []
        let renderer = MPVVideoOverlayRenderer(
            content: AnyView(Text("Caption stays on one line at the inline width.")
                .font(.system(size: 24)).foregroundStyle(.white)),
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

    @Test @MainActor
    func `bitmap preserves BGRA premultiplication and transparent pixels`() throws {
        let renderer = ImageRenderer(content:
            HStack(spacing: 0) {
                Color(.sRGB, red: 1, green: 0, blue: 0).opacity(0.5)
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

    @Test @MainActor
    func `overlay is owned by its surface and removed without replacing video`() async throws {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
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
    var minX = bitmap.width, minY = bitmap.height, maxX = -1, maxY = -1
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
        x: CGFloat(minX) / CGFloat(bitmap.width), y: CGFloat(minY) / CGFloat(bitmap.height),
        width: CGFloat(maxX - minX + 1) / CGFloat(bitmap.width),
        height: CGFloat(maxY - minY + 1) / CGFloat(bitmap.height)
    )
}
