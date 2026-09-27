import Foundation
import Libmpv
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
struct MPVMetadataObservationActivityTests {
    @Test
    func `unchanged target signals containing unknown aspect ratio avoid complete media rereads`() {
        let engine = MPVEngine(configuration: .init()) { _ in }
        engine.queue.sync {
            engine.playbackRequestIsActive = true
            let parameters: [String: MPVNodeValue] = [
                "primaries": .string("bt.709"), "gamma": .string("srgb"),
                "par": .double(.nan), "w": .integer(2048), "h": .integer(1536),
            ]
            sendTarget(parameters, to: engine)
            let first = engine.lifecycleDiagnostics.engineActivity
            for _ in 0 ..< 24 {
                sendTarget(parameters, to: engine)
            }
            let repeated = engine.lifecycleDiagnostics.engineActivity
            #expect(repeated.nativeEvents == first.nativeEvents + 24)
            #expect(repeated.mediaSnapshots == first.mediaSnapshots)
            #expect(repeated.publishedUpdates == first.publishedUpdates)
            #expect(repeated.propertyReads == first.propertyReads)
        }
    }

    @Test
    func `target color dynamic HDR metadata and availability transitions remain observable`() {
        let engine = MPVEngine(configuration: .init()) { _ in }
        engine.queue.sync {
            engine.playbackRequestIsActive = true
            var parameters: [String: MPVNodeValue] = [
                "primaries": .string("bt.709"), "gamma": .string("srgb"), "par": .double(.nan),
            ]
            sendTarget(parameters, to: engine)
            var snapshots = engine.lifecycleDiagnostics.engineActivity.mediaSnapshots
            for (key, value) in [
                ("primaries", MPVNodeValue.string("bt.2020")),
                ("gamma", .string("pq")),
                ("max-luma", .double(1000)),
                ("scene-max-r", .double(800)),
                ("scene-avg", .double(150)),
                ("max-luma", .double(4000)),
            ] {
                parameters[key] = value
                sendTarget(parameters, to: engine)
                snapshots += 1
                #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == snapshots)
                #expect(engine.lastVideoTargetObservation == .available(MPVVideoSignalParser.parse(.map(parameters))))
                sendTarget(parameters, to: engine)
                #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == snapshots)
            }
            sendTarget(nil, to: engine)
            #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == snapshots + 1)
            #expect(engine.lastVideoTargetObservation == .unavailable)
            sendTarget(nil, to: engine)
            #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == snapshots + 1)
            sendTarget(parameters, to: engine)
            #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == snapshots + 2)
        }
    }

    @Test
    func `estimated cadence only rebuilds public media information when container cadence is unavailable`() {
        let engine = MPVEngine(configuration: .init()) { _ in }
        engine.queue.sync {
            engine.playbackRequestIsActive = true
            engine.lastContainerFramesPerSecond = 24
            for fps in [23.976, 24, 48, 60] {
                sendScalar("estimated-vf-fps", value: fps, to: engine)
            }
            #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == 0)
            #expect(engine.lastContainerFramesPerSecond == 24)

            // A container property change must rebuild and reread its actual
            // availability. No attached client here models an unavailable value.
            sendScalar("container-fps", value: nil, to: engine)
            #expect(engine.lastContainerFramesPerSecond == nil)
            let snapshots = engine.lifecycleDiagnostics.engineActivity.mediaSnapshots
            for (index, fps) in [23.976, 48, 60].enumerated() {
                sendScalar("estimated-vf-fps", value: fps, to: engine)
                #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == snapshots + Int64(index) + 1)
            }
        }
    }

    @Test
    func `new load and accepted playlist start reset observations without stale events resetting them`() async {
        let engine = MPVEngine(configuration: .init()) { _ in }
        let target: [String: MPVNodeValue] = ["gamma": .string("srgb"), "par": .double(.nan)]
        engine.queue.sync {
            engine.playbackRequestIsActive = true
            sendTarget(target, to: engine)
            engine.lastContainerFramesPerSecond = 24
        }
        engine.load(TestPaths.baselineMedia, autoPlay: false, startTime: nil, generation: 1)
        _ = await engine.lifecycleSnapshot()
        engine.queue.sync {
            #expect(engine.lastVideoTargetObservation == nil)
            #expect(engine.lastContainerFramesPerSecond == nil)
            sendTarget(target, to: engine)
            engine.lastContainerFramesPerSecond = 24
            engine.requestedPlaylistEntryID = 2
            var start = mpv_event_start_file()
            start.playlist_entry_id = 1
            withUnsafeMutablePointer(to: &start) { pointer in
                var event = mpv_event()
                event.event_id = MPV_EVENT_START_FILE
                event.data = UnsafeMutableRawPointer(pointer)
                engine.handleEvent(event)
                #expect(engine.lastVideoTargetObservation != nil)
                #expect(engine.lastContainerFramesPerSecond == 24)
                pointer.pointee.playlist_entry_id = 2
                engine.handleEvent(event)
            }
            #expect(engine.lastVideoTargetObservation == nil)
            #expect(engine.lastContainerFramesPerSecond == nil)
            let snapshots = engine.lifecycleDiagnostics.engineActivity.mediaSnapshots
            sendTarget(target, to: engine)
            #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == snapshots + 1)
        }
    }

    private func sendScalar(_ name: String, value: Double?, to engine: MPVEngine) {
        name.withCString { name in
            var property = mpv_event_property()
            property.name = name
            if var value {
                withUnsafeMutablePointer(to: &value) { pointer in
                    property.format = MPV_FORMAT_DOUBLE
                    property.data = UnsafeMutableRawPointer(pointer)
                    send(&property, to: engine)
                }
            } else {
                property.format = MPV_FORMAT_NONE
                send(&property, to: engine)
            }
        }
    }

    private func sendTarget(_ parameters: [String: MPVNodeValue]?, to engine: MPVEngine) {
        "video-target-params".withCString { name in
            var property = mpv_event_property()
            property.name = name
            guard let parameters else {
                property.format = MPV_FORMAT_NONE
                send(&property, to: engine)
                return
            }
            let ordered = parameters.sorted { $0.key < $1.key }
            var keys = ordered.map { strdup($0.key) }
            var values = ordered.map { pair -> mpv_node in
                var node = mpv_node()
                switch pair.value {
                case let .string(value):
                    node.format = MPV_FORMAT_STRING
                    node.u.string = strdup(value)
                case let .double(value):
                    node.format = MPV_FORMAT_DOUBLE
                    node.u.double_ = value
                case let .integer(value):
                    node.format = MPV_FORMAT_INT64
                    node.u.int64 = value
                default:
                    preconditionFailure("Unsupported test parameter")
                }
                return node
            }
            defer {
                keys.forEach { free($0) }
                for node in values where node.format == MPV_FORMAT_STRING {
                    free(node.u.string)
                }
            }
            keys.withUnsafeMutableBufferPointer { keys in
                values.withUnsafeMutableBufferPointer { values in
                    var list = mpv_node_list()
                    list.num = Int32(values.count)
                    list.keys = keys.baseAddress
                    list.values = values.baseAddress
                    withUnsafeMutablePointer(to: &list) { list in
                        var node = mpv_node()
                        node.format = MPV_FORMAT_NODE_MAP
                        node.u.list = list
                        withUnsafeMutablePointer(to: &node) { node in
                            property.format = MPV_FORMAT_NODE
                            property.data = UnsafeMutableRawPointer(node)
                            send(&property, to: engine)
                        }
                    }
                }
            }
        }
    }

    private func send(_ property: inout mpv_event_property, to engine: MPVEngine) {
        withUnsafeMutablePointer(to: &property) { pointer in
            var event = mpv_event()
            event.event_id = MPV_EVENT_PROPERTY_CHANGE
            event.data = UnsafeMutableRawPointer(pointer)
            engine.handleEvent(event)
        }
    }
}
