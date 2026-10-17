import Foundation
import Libmpv
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
struct MPVMetadataObservationActivityTests {

    @Test
    @MainActor
    func `estimated cadence updates scalar metadata without native rereads`() async throws {
        var rates: [Double?] = []
        let engine = MPVSession(configuration: .init()) { emission in
            if case let .frameRate(value) = emission.update {
                rates.append(value)
            }
        }
        engine.queue.sync {
            engine.playbackRequestIsActive = true
            engine.lastContainerFramesPerSecond = 24
            for fps in [23.976, 24, 48, 60] {
                sendScalar("estimated-vf-fps", value: fps, to: engine)
            }
            #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == 0)
            #expect(engine.lastContainerFramesPerSecond == 24)
            sendScalar("container-fps", value: nil, to: engine)
            for fps in [23.976, 23.97601, 23.97602, 48, 60] {
                sendScalar("estimated-vf-fps", value: fps, to: engine)
            }
            #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == 0)
            #expect(engine.lifecycleDiagnostics.engineActivity.propertyReads == 0)
        }
        try await eventually("cadence changes delivered") { rates.count == 4 }
        #expect(rates == [60, 23.976, 48, 60])
    }

    @Test
    func `new load and accepted playlist start reset observations without stale events resetting them`() async {
        let engine = MPVSession(configuration: .init(additionalOptions: ["ao": "null"])) { _ in }
        await withCheckedContinuation { continuation in
            engine.queue.async {
                engine.playbackRequestIsActive = true
                engine.lastContainerFramesPerSecond = 24
                engine.load(TestPaths.baselineMedia, autoPlay: false, startTime: nil, generation: 1)
                // Queue the assertions before the headless audio load can
                // schedule native events that repopulate these observations.
                engine.queue.async {
                    #expect(engine.lastContainerFramesPerSecond == nil)
                    engine.activePlaylistEntryID = engine.requestedPlaylistEntryID
                    engine.lastContainerFramesPerSecond = 24
                    engine.requestedPlaylistEntryID = 2
                    var start = mpv_event_start_file()
                    start.playlist_entry_id = 1
                    withUnsafeMutablePointer(to: &start) { pointer in
                        var event = mpv_event()
                        event.event_id = MPV_EVENT_START_FILE
                        event.data = UnsafeMutableRawPointer(pointer)
                        engine.handleEvent(event)

                        #expect(engine.lastContainerFramesPerSecond == 24)
                        pointer.pointee.playlist_entry_id = 2
                        engine.handleEvent(event)
                    }

                    #expect(engine.lastContainerFramesPerSecond == nil)
                    let snapshots = engine.lifecycleDiagnostics.engineActivity.mediaSnapshots
                    sendScalar("video-target-params", value: nil, to: engine)

                    #expect(engine.lifecycleDiagnostics.engineActivity.mediaSnapshots == snapshots + 1)
                    continuation.resume()
                }
            }
        }
    }

    private func sendScalar(_ name: String, value: Double?, to engine: MPVSession) {
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

    private func send(_ property: inout mpv_event_property, to engine: MPVSession) {
        withUnsafeMutablePointer(to: &property) { pointer in
            var event = mpv_event()
            event.event_id = MPV_EVENT_PROPERTY_CHANGE
            event.data = UnsafeMutableRawPointer(pointer)
            engine.handleEvent(event)
        }
    }
}
