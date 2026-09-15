import Foundation
import Libmpv
@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVNodeValueTests {
    @Test(arguments: [MPV_FORMAT_NODE_MAP.rawValue, MPV_FORMAT_NODE_ARRAY.rawValue])
    func `absent and malformed native lists produce empty owned collections`(format: UInt32) {
        var node = mpv_node()
        node.format = mpv_format(rawValue: format)
        let empty: MPVNodeValue = node.format == MPV_FORMAT_NODE_MAP ? .map([:]) : .array([])
        #expect(MPVNodeValue(copying: node) == empty)
        var list = mpv_node_list()
        list.num = 2
        withUnsafeMutablePointer(to: &list) { pointer in
            node.u.list = pointer
            #expect(MPVNodeValue(copying: node) == empty)
            pointer.pointee.num = -1
            #expect(MPVNodeValue(copying: node) == empty)
        }
    }

    @Test
    func `byte arrays own their bytes after the native event storage changes`() {
        var bytes: [UInt8] = [0, 17, 128, 255]
        let copied = bytes.withUnsafeMutableBytes { buffer -> MPVNodeValue in
            var byteArray = mpv_byte_array()
            byteArray.data = buffer.baseAddress
            byteArray.size = buffer.count
            return withUnsafeMutablePointer(to: &byteArray) { pointer in
                var node = mpv_node()
                node.format = MPV_FORMAT_BYTE_ARRAY
                node.u.ba = pointer
                return MPVNodeValue(copying: node)
            }
        }
        bytes[1] = 99
        #expect(copied == .data(Data([0, 17, 128, 255])))
        var empty = mpv_node()
        empty.format = MPV_FORMAT_BYTE_ARRAY
        #expect(MPVNodeValue(copying: empty) == .data(Data()))
        var byteArray = mpv_byte_array()
        withUnsafeMutablePointer(to: &byteArray) { pointer in
            empty.u.ba = pointer
            #expect(MPVNodeValue(copying: empty) == .data(Data()))
        }
    }

    @Test
    func `native maps skip missing keys while preserving the remaining owned values`() {
        var value = mpv_node()
        value.format = MPV_FORMAT_INT64
        value.u.int64 = 42
        var values = [value, value]
        var name = Array("answer".utf8CString)
        let copied = name.withUnsafeMutableBufferPointer { text in
            var keys: [UnsafeMutablePointer<CChar>?] = [nil, text.baseAddress]
            return keys.withUnsafeMutableBufferPointer { keys in
                values.withUnsafeMutableBufferPointer { values in
                    var list = mpv_node_list()
                    list.num = 2
                    list.values = values.baseAddress
                    list.keys = keys.baseAddress
                    return withUnsafeMutablePointer(to: &list) { pointer in
                        var node = mpv_node()
                        node.format = MPV_FORMAT_NODE_MAP
                        node.u.list = pointer
                        return MPVNodeValue(copying: node)
                    }
                }
            }
        }
        name[0] = 0
        values[1].u.int64 = 0
        #expect(copied == .map(["answer": .integer(42)]))
    }

    @Test
    func `unavailable strings and unsupported property formats stay absent`() {
        var node = mpv_node()
        node.format = MPV_FORMAT_OSD_STRING
        #expect(MPVNodeValue(copying: node) == .none)
        var flag: Int32 = 1
        withUnsafeMutablePointer(to: &flag) { pointer in
            var property = mpv_event_property()
            property.format = MPV_FORMAT_FLAG
            property.data = UnsafeMutableRawPointer(pointer)
            #expect(MPVNodeValue(copying: property) == nil)
        }
        #expect(MPVNodeValue.integer(-1).boolValue == true)
        #expect(MPVNodeValue.integer(0).boolValue == false)
        #expect(MPVNodeValue.string("1").boolValue == nil)
        #expect(MPVNodeValue.bool(true).integerValue == nil)
    }

    @Test
    func `property event values survive their native storage being reused`() {
        var position = 12.5
        let copiedPosition = withUnsafeMutablePointer(to: &position) { pointer in
            var property = mpv_event_property()
            property.format = MPV_FORMAT_DOUBLE
            property.data = UnsafeMutableRawPointer(pointer)
            return MPVNodeValue(copying: property)
        }
        position = 30
        #expect(copiedPosition == .double(12.5))

        var node = mpv_node()
        node.format = MPV_FORMAT_INT64
        node.u.int64 = 42
        let copiedNode = withUnsafeMutablePointer(to: &node) { pointer in
            var property = mpv_event_property()
            property.format = MPV_FORMAT_NODE
            property.data = UnsafeMutableRawPointer(pointer)
            return MPVNodeValue(copying: property)
        }
        node.u.int64 = 99
        #expect(copiedNode == .integer(42))
    }

    @Test
    func `unavailable property event values remain absent`() {
        var property = mpv_event_property()
        property.format = MPV_FORMAT_NONE
        #expect(MPVNodeValue(copying: property) == nil)
        property.format = MPV_FORMAT_DOUBLE
        #expect(MPVNodeValue(copying: property) == nil)
        property.format = MPV_FORMAT_NODE
        #expect(MPVNodeValue(copying: property) == nil)
    }

    @Test
    func `node integer conversion rejects non finite and out of range doubles`() {
        #expect(MPVNodeValue.double(.nan).integerValue == nil)
        #expect(MPVNodeValue.double(.infinity).integerValue == nil)
        #expect(MPVNodeValue.double(9_223_372_036_854_775_808.0).integerValue == nil)
        #expect(MPVNodeValue.double(42.75).integerValue == 42)
    }
}
