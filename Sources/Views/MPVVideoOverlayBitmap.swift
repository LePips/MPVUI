import CoreGraphics
import Foundation

/// Immutable, premultiplied BGRA storage copied by mpv before overlay-add returns.
struct MPVVideoOverlayBitmap: Sendable {
    let width: Int
    let height: Int
    let bytes: Data
    var stride: Int {
        width * 4
    }

    init?(image: CGImage) {
        self.init(size: CGSize(width: image.width, height: image.height), scale: 1) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    init?(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) {
        let pixelWidth = ceil(size.width * scale)
        let pixelHeight = ceil(size.height * scale)
        guard pixelWidth.isFinite, pixelHeight.isFinite, scale > 0,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 2048, pixelHeight <= 2048,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        width = Int(pixelWidth)
        height = Int(pixelHeight)
        var data = Data(count: width * height * 4)
        let width = width, height = height
        let rendered = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.scaleBy(x: scale, y: scale)
            draw(context)
            return true
        }
        guard rendered else { return nil }
        bytes = data
    }
}
