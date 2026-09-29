import Foundation
import Libmpv

/// Delays a demuxer's seek without relying on disk or network timing.
/// Keep alive until the registered native session has closed.
final class SeekGatedMediaStream: @unchecked Sendable {
    private let file: FileHandle
    private let size: Int64
    private let condition = NSCondition()
    private var gateNextSeek = false
    private var blocked = false
    private var cancelled = false

    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        size = try Int64(file.seekToEnd())
        try file.seek(toOffset: 0)
    }

    deinit { try? file.close() }

    var isBlocked: Bool {
        condition.lock()
        defer { condition.unlock() }
        return blocked
    }

    func arm() {
        condition.lock()
        gateNextSeek = true
        condition.unlock()
    }

    func resume() {
        condition.lock()
        gateNextSeek = false
        blocked = false
        condition.broadcast()
        condition.unlock()
    }

    private func cancel() {
        condition.lock()
        cancelled = true
        blocked = false
        condition.broadcast()
        condition.unlock()
    }

    private func seek(to offset: Int64) -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        if gateNextSeek {
            gateNextSeek = false
            blocked = true
            let deadline = Date().addingTimeInterval(10)
            while blocked && !cancelled {
                if !condition.wait(until: deadline) {
                    return -1
                }
            }
        }
        guard !cancelled, offset >= 0 else { return -1 }
        do {
            try file.seek(toOffset: UInt64(offset))
            return offset
        } catch { return -1 }
    }

    private func read(into buffer: UnsafeMutablePointer<CChar>, count: UInt64) -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled else { return -1 }
        do {
            let data = try file.read(upToCount: Int(min(count, UInt64(Int.max)))) ?? Data()
            data.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer, count: data.count))
            return Int64(data.count)
        } catch { return -1 }
    }

    static let open: mpv_stream_cb_open_ro_fn = { context, _, info in
        guard let context, let info else { return -1 }
        info.pointee.cookie = context
        info.pointee.read_fn = { context, buffer, count in
            guard let context, let buffer else { return -1 }
            return Unmanaged<SeekGatedMediaStream>.fromOpaque(context).takeUnretainedValue().read(into: buffer, count: count)
        }
        info.pointee.seek_fn = { context, offset in
            guard let context else { return -1 }
            return Unmanaged<SeekGatedMediaStream>.fromOpaque(context).takeUnretainedValue().seek(to: offset)
        }
        info.pointee.size_fn = { context in
            guard let context else { return -1 }
            return Unmanaged<SeekGatedMediaStream>.fromOpaque(context).takeUnretainedValue().size
        }
        info.pointee.close_fn = { _ in }
        info.pointee.cancel_fn = { context in
            guard let context else { return }
            Unmanaged<SeekGatedMediaStream>.fromOpaque(context).takeUnretainedValue().cancel()
        }
        return 0
    }
}
