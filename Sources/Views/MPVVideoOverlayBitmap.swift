import CoreGraphics
import Foundation
import MPVCore

/// Immutable, premultiplied BGRA storage copied by mpv before overlay-add returns.
extension MPVVideoOverlayBitmap {

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

        let width = Int(pixelWidth)
        let height = Int(pixelHeight)
        var data = Data(count: width * height * 4)

        let rendered = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }

            context.scaleBy(x: scale, y: scale)
            draw(context)

            return true
        }

        guard rendered else { return nil }

        self.init(width: width, height: height, bytes: data)
    }
}
