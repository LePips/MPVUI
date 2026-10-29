import Foundation

/// Premultiplied BGRA pixels copied by the native overlay command.
package struct MPVVideoOverlayBitmap: Sendable {

    package let width: Int
    package let height: Int
    package let bytes: Data

    package var stride: Int {
        width * 4
    }

    package init(width: Int, height: Int, bytes: Data) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}
