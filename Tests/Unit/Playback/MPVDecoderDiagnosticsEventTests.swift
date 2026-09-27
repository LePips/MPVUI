import Foundation
import Libmpv
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
struct MPVDecoderDiagnosticsEventTests {
    @Test
    func `new media never inherits prior decoder session evidence`() {
        let engine = MPVEngine(configuration: .init()) { _ in }
        engine.queue.sync {
            engine.videoToolboxSessionUsesHardware = true
            engine.resetMediaObservations()
            #expect(engine.videoToolboxSessionUsesHardware == nil)
        }
    }

    @Test @MainActor
    func `delivered session changes remain visible between timer snapshots`() async throws {
        var sessions: [MPVPlaybackDiagnostics.Decoder.Session] = []
        let engine = MPVEngine(configuration: .init()) { emission in
            if case let .diagnostics(value) = emission.update {
                sessions.append(value.decoder.session)
            }
        }
        let handle = try #require(mpv_create())
        defer { mpv_destroy(handle) }
        engine.queue.sync {
            engine.handle = handle
            defer { engine.handle = nil }
            for session in [MPVPlaybackDiagnosticsParser.VideoToolboxSessionResult.hardware, .software, .hardware, .unknown] {
                engine.updateVideoToolboxSession(session, hardwareDecoder: "videotoolbox")
            }
        }
        try await eventually("all decoder transitions delivered") { sessions.count == 4 }
        #expect(sessions == [.hardware("videotoolbox"), .software, .hardware("videotoolbox"), .unknown])
    }

    @Test @MainActor
    func `copied selected decoder events preserve transient software fallback`() async throws {
        var decoders: [MPVPlaybackDiagnostics.Decoder] = []
        let engine = MPVEngine(configuration: .init()) { emission in
            if case let .diagnostics(value) = emission.update {
                decoders.append(value.decoder)
            }
        }
        let handle = try #require(mpv_create())
        defer { mpv_destroy(handle) }
        engine.queue.sync {
            engine.handle = handle
            defer { engine.handle = nil }
            engine.playbackRequestIsActive = true
            engine.updateVideoToolboxSession(.hardware, hardwareDecoder: "videotoolbox")
            for decoder in ["videotoolbox", "no", "videotoolbox"] {
                "hwdec-current".withCString { name in
                    decoder.withCString { value in
                        var storage: UnsafePointer<CChar>? = value
                        withUnsafeMutablePointer(to: &storage) { pointer in
                            var property = mpv_event_property()
                            property.name = name
                            property.format = MPV_FORMAT_STRING
                            property.data = UnsafeMutableRawPointer(pointer)
                            withUnsafeMutablePointer(to: &property) { eventData in
                                var event = mpv_event()
                                event.event_id = MPV_EVENT_PROPERTY_CHANGE
                                event.data = UnsafeMutableRawPointer(eventData)
                                engine.handleEvent(event)
                            }
                        }
                    }
                }
            }
            // Property-first delivery stays unknown until new session evidence.
            engine.updateVideoToolboxSession(.hardware, hardwareDecoder: "videotoolbox")
            #expect(engine.lifecycleDiagnostics.engineActivity.diagnosticsSnapshots == 0)
        }
        try await eventually("all selected decoder events delivered") { decoders.count == 4 }
        #expect(decoders.map(\.selectedDecoder) == ["videotoolbox", "no", "videotoolbox", "videotoolbox"])
        #expect(decoders.map(\.session) == [.hardware("videotoolbox"), .software, .unknown, .hardware("videotoolbox")])
        #expect(decoders[1].fallbackReason != nil)
    }
}
