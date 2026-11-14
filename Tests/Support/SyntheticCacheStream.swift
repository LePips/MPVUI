import Foundation
import Libmpv

/// Supplies seekable test media with optional controlled read throughput.
final class SyntheticCacheStream: @unchecked Sendable {

    static let bytesPerSecond: Int64 = 384_000 * 8 * 4
    // The raw audio demuxer emits one eighth of a second per packet.
    static let packetBytes = bytesPerSecond / 8
    static let open: mpv_stream_cb_open_ro_fn = { context, _, info in
        guard let context, let info else { return -1 }

        info.pointee.cookie = context
        info.pointee.read_fn = { context, buffer, count in
            guard let context, let buffer else { return -1 }

            return Unmanaged<SyntheticCacheStream>.fromOpaque(context).takeUnretainedValue().read(buffer, count: count)
        }
        info.pointee.seek_fn = { context, offset in
            guard let context else { return -1 }

            return Unmanaged<SyntheticCacheStream>.fromOpaque(context).takeUnretainedValue().seek(offset)
        }
        info.pointee.size_fn = { context in
            guard let context else { return -1 }

            return Unmanaged<SyntheticCacheStream>.fromOpaque(context).takeUnretainedValue().length
        }
        info.pointee.close_fn = { _ in }
        return 0
    }

    private let length: Int64
    private let contents: Data?
    private let deliveryBytesPerSecond: Double?
    private let lock = NSLock()
    private var position: Int64 = 0

    init(length: Int64 = SyntheticCacheStream.bytesPerSecond * 60, deliveryBytesPerSecond: Double? = nil) {
        self.length = length
        self.deliveryBytesPerSecond = deliveryBytesPerSecond
        contents = nil
    }

    init(contents: Data) {
        self.contents = contents
        length = Int64(contents.count)
        deliveryBytesPerSecond = nil
    }

    private func read(_ buffer: UnsafeMutablePointer<CChar>, count: UInt64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let requested = min(count, deliveryBytesPerSecond == nil ? UInt64(Int.max) : 8192)
        let amount = min(length - position, Int64(requested))
        if let deliveryBytesPerSecond {
            Thread.sleep(forTimeInterval: Double(amount) / deliveryBytesPerSecond)
        }
        if let contents {
            let start = contents.startIndex + Int(position)
            let output = UnsafeMutableRawBufferPointer(start: buffer, count: Int(amount))
            _ = contents.copyBytes(to: output, from: start ..< start + output.count)
        } else {
            memset(buffer, 0, Int(amount))
        }
        position += amount
        return amount
    }

    private func seek(_ offset: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard (0 ... length).contains(offset) else { return -1 }

        position = offset
        return offset
    }
}
