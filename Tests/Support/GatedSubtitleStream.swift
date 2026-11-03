import Foundation
import Libmpv

/// Holds a native subtitle read until released or canceled by libmpv.
final class GatedSubtitleStream: @unchecked Sendable {

    static let open: mpv_stream_cb_open_ro_fn = { context, _, info in
        guard let context, let info else {
            return -1
        }

        info.pointee.cookie = context
        info.pointee.read_fn = { context, buffer, count in
            guard let context, let buffer else {
                return -1
            }

            return Unmanaged<GatedSubtitleStream>.fromOpaque(context).takeUnretainedValue().read(buffer, count: count)
        }
        info.pointee.close_fn = { _ in }
        info.pointee.cancel_fn = { context in
            guard let context else {
                return
            }

            Unmanaged<GatedSubtitleStream>.fromOpaque(context).takeUnretainedValue().release(cancel: true)
        }
        return 0
    }

    private let condition = NSCondition()
    private let bytes = Array("1\n00:00:00,000 --> 00:00:10,000\nGated caption\n".utf8)
    private var offset = 0
    private var waiting = false
    private var released = false
    private var canceled = false

    var isWaiting: Bool {
        condition.lock()
        defer {
            condition.unlock()
        }
        return waiting
    }

    func release(cancel: Bool = false) {
        condition.lock()
        released = true
        canceled = canceled || cancel
        condition.broadcast()
        condition.unlock()
    }

    private func read(_ buffer: UnsafeMutablePointer<CChar>, count: UInt64) -> Int64 {
        condition.lock()
        defer {
            condition.unlock()
        }
        waiting = true
        let deadline = Date().addingTimeInterval(10)
        while !released {
            if !condition.wait(until: deadline) {
                canceled = true
                break
            }
        }
        waiting = false
        guard !canceled else {
            return -1
        }

        let length = min(bytes.count - offset, Int(min(count, UInt64(Int.max))))
        for index in 0 ..< length {
            buffer[index] = CChar(bitPattern: bytes[offset + index])
        }
        offset += length
        return Int64(length)
    }
}
