#if os(macOS)
import Darwin
import Foundation
import Libmpv
@testable import MPVCore
@testable import MPVUI
import SwiftUI
import Testing

@MainActor
enum MPVOptionalWorkPerformanceWorkloads {

    private struct Timing {

        let cpu = clock()
        let wall = DispatchTime.now().uptimeNanoseconds
    }

    private struct Measurement {

        let id: String
        let iterations: Int
        var wall: [Double] = []
        var cpu: [Double] = []

        var json: [String: Any] {
            [
                "id": id,
                "parameters": ["iterations": iterations, "inputVersion": 1],
                "metrics": [
                    "wallNanosecondsPerOperation": ["unit": "nanoseconds/operation", "direction": "lower", "samples": wall],
                    "cpuNanosecondsPerOperation": ["unit": "cpu-nanoseconds/operation", "direction": "lower", "samples": cpu],
                ],
                "observations": [],
            ]
        }

        mutating func append(_ start: Timing, iterations: Int) {
            wall.append(Double(DispatchTime.now().uptimeNanoseconds - start.wall) / Double(iterations))
            cpu.append(Double(clock() - start.cpu) * 1e9 / Double(CLOCKS_PER_SEC) / Double(iterations))
        }
    }

    static func measure(repetitions: Int) async throws -> [[String: Any]] {
        try await [
            overlayUpdates(repetitions: repetitions),
            ignoredLogs(repetitions: repetitions),
            decoderSnapshots(repetitions: repetitions)
        ]
    }

    private static func overlayUpdates(repetitions: Int) async throws -> [String: Any] {
        let iterations = 2000
        var measurement = Measurement(id: "overlay_update_burst", iterations: iterations)

        for _ in 0 ..< repetitions {
            var submissions = 0
            var lastBitmap: MPVVideoOverlayBitmap?
            let renderer = MPVVideoOverlayRenderer(
                content: AnyView(Color.red),
                submit: { bitmap in
                    submissions += 1
                    lastBitmap = bitmap
                    return bitmap != nil
                },
                availabilityChanged: { _ in }
            )
            defer { renderer.invalidate() }
            renderer.updateSize(CGSize(width: 160, height: 90), displayScale: 1)
            try await eventually("initial benchmark overlay") { submissions > 0 }
            let before = submissions
            let start = Timing()

            for index in 0 ..< iterations {
                renderer.updateContent(AnyView(Color(.sRGB, red: 0, green: 0, blue: Double(index % 2))))
            }

            measurement.append(start, iterations: iterations)
            try await eventually("latest benchmark overlay") {
                submissions > before && lastBitmap?.bytes.first == 255
            }
        }

        return measurement.json
    }

    private static func ignoredLogs(repetitions: Int) -> [String: Any] {
        let iterations = 10000
        var measurement = Measurement(id: "diagnostics_ignored_logs", iterations: iterations)
        let engine = MPVSession(configuration: .init(logLevel: .none, videoOutput: .sampleBuffer)) { _ in }

        engine.queue.sync {
            engine.playbackRequestIsActive = true
            "demuxer".withCString { prefix in
                "info".withCString { level in
                    String(repeating: "ordinary native log payload ", count: 16).withCString { text in
                        var message = mpv_event_log_message()
                        message.prefix = prefix
                        message.level = level
                        message.text = text
                        withUnsafeMutablePointer(to: &message) { pointer in
                            var event = mpv_event()
                            event.event_id = MPV_EVENT_LOG_MESSAGE
                            event.data = UnsafeMutableRawPointer(pointer)

                            for _ in 0 ..< repetitions {
                                let start = Timing()
                                for _ in 0 ..< iterations {
                                    engine.handleLogMessage(event)
                                }
                                measurement.append(start, iterations: iterations)
                            }
                        }
                    }
                }
            }
        }

        return measurement.json
    }

    private static func decoderSnapshots(repetitions: Int) throws -> [String: Any] {
        let iterations = 1000
        var measurement = Measurement(id: "diagnostics_decoder_queries", iterations: iterations)
        let engine = MPVSession(configuration: .init()) { _ in }
        // An uninitialized native client rejects reads consistently without
        // starting playback. This measures bridge/query overhead, not decoding.
        let handle = try #require(mpv_create())
        defer { mpv_destroy(handle) }
        var reads: [Double] = []

        engine.queue.sync {
            engine.handle = handle
            defer { engine.handle = nil }

            for _ in 0 ..< repetitions {
                let before = engine.lifecycleDiagnostics.engineActivity.propertyReads
                let start = Timing()
                for _ in 0 ..< iterations {
                    _ = engine.decoderDiagnostics(hardwareDecoder: nil)
                }
                measurement.append(start, iterations: iterations)
                reads.append(Double(engine.lifecycleDiagnostics.engineActivity.propertyReads - before) / Double(iterations))
            }
        }

        var result = measurement.json
        var metrics = result["metrics"] as! [String: Any]
        metrics["propertyReadsPerOperation"] = ["unit": "reads/operation", "direction": "lower", "samples": reads]
        result["metrics"] = metrics
        return result
    }
}
#endif
