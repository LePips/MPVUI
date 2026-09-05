import Foundation
import Libmpv

/// A copied Swift representation of an `mpv_node`.
///
/// libmpv owns node values attached to events and invalidates them when the
/// next event is read. Converting them at the engine boundary keeps all of the
/// public player state independent from C pointer lifetimes.
indirect enum MPVNodeValue: Equatable, Sendable {
    case none
    case string(String)
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case array([MPVNodeValue])
    case map([String: MPVNodeValue])
    case data(Data)

    init(copying node: mpv_node) {
        switch node.format {
        case MPV_FORMAT_STRING, MPV_FORMAT_OSD_STRING:
            if let string = node.u.string {
                self = .string(String(cString: string))
            } else {
                self = .none
            }

        case MPV_FORMAT_FLAG:
            self = .bool(node.u.flag != 0)

        case MPV_FORMAT_INT64:
            self = .integer(node.u.int64)

        case MPV_FORMAT_DOUBLE:
            self = .double(node.u.double_)

        case MPV_FORMAT_NODE_ARRAY, MPV_FORMAT_NODE_MAP:
            guard let listPointer = node.u.list else {
                self = node.format == MPV_FORMAT_NODE_MAP ? .map([:]) : .array([])
                return
            }

            let list = listPointer.pointee
            let count = max(0, Int(list.num))

            if node.format == MPV_FORMAT_NODE_MAP {
                var result: [String: MPVNodeValue] = [:]
                result.reserveCapacity(count)

                guard let values = list.values, let keys = list.keys else {
                    self = .map(result)
                    return
                }

                for index in 0 ..< count {
                    guard let key = keys.advanced(by: index).pointee else { continue }
                    result[String(cString: key)] = MPVNodeValue(
                        copying: values.advanced(by: index).pointee
                    )
                }
                self = .map(result)
            } else {
                guard let values = list.values else {
                    self = .array([])
                    return
                }

                self = .array((0 ..< count).map { index in
                    MPVNodeValue(copying: values.advanced(by: index).pointee)
                })
            }

        case MPV_FORMAT_BYTE_ARRAY:
            guard let byteArray = node.u.ba?.pointee,
                  let bytes = byteArray.data,
                  byteArray.size > 0
            else {
                self = .data(Data())
                return
            }
            self = .data(Data(bytes: bytes, count: byteArray.size))

        default:
            self = .none
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        switch self {
        case let .bool(value):
            value
        case let .integer(value):
            value != 0
        default:
            nil
        }
    }

    var integerValue: Int64? {
        switch self {
        case let .integer(value):
            return value
        case let .double(value):
            guard value.isFinite,
                  value >= -9_223_372_036_854_775_808.0,
                  value < 9_223_372_036_854_775_808.0
            else { return nil }
            return Int64(value)
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .double(value):
            value
        case let .integer(value):
            Double(value)
        default:
            nil
        }
    }

    var arrayValue: [MPVNodeValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var mapValue: [String: MPVNodeValue]? {
        guard case let .map(value) = self else { return nil }
        return value
    }
}
