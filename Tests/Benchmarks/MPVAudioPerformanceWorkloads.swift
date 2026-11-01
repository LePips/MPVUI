#if os(macOS)
import CryptoKit
import Darwin
import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@MainActor
enum MPVAudioPerformanceWorkloads {

    private struct Timing {

        let cpu = clock()
        let wall = DispatchTime.now().uptimeNanoseconds
    }

    private struct Measurement {

        let id: String
        let mediaSHA256: String
        var wall: [Double] = []
        var cpu: [Double] = []
        var outputInitializations: [Double] = []

        var json: [String: Any] {
            var metrics: [String: Any] = [
                "wallSeconds": ["unit": "seconds", "direction": "lower", "samples": wall],
                "cpuSeconds": ["unit": "seconds", "direction": "lower", "samples": cpu],
            ]
            if !outputInitializations.isEmpty {
                metrics["audioOutputInitializations"] = ["unit": "count", "direction": "lower", "samples": outputInitializations]
            }
            return [
                "id": id,
                "parameters": [
                    "fixture": "audio-eac3-5.1.mka",
                    "audioOutput": "avfoundation",
                    "muted": true,
                    "fixtureSHA256": mediaSHA256,
                    "speed": 1.25,
                    "pollSeconds": 0.02,
                    "inputVersion": 1,
                ],
                "metrics": metrics,
                "observations": [],
            ]
        }

        mutating func append(_ start: Timing) {
            wall.append(Double(DispatchTime.now().uptimeNanoseconds - start.wall) / 1e9)
            cpu.append(Double(clock() - start.cpu) / Double(CLOCKS_PER_SEC))
        }
    }

    static func measure(repetitions: Int) async throws -> [[String: Any]] {
        try #require(
            ProcessInfo.processInfo.environment["MPVUI_RUN_NATIVE_AUDIO_TESTS"] == "1",
            "Audio measurements require MPVUI_RUN_NATIVE_AUDIO_TESTS=1 and a real audio output."
        )
        let media = try TestPaths.testMedia("audio-eac3-5.1.mka")
        let hash = try SHA256.hash(data: Data(contentsOf: media)).map { String(format: "%02x", $0) }.joined()
        var startup = Measurement(id: "native_audio_processed_startup", mediaSHA256: hash)
        var transition = Measurement(id: "native_audio_processing_transition", mediaSHA256: hash)

        for _ in 0 ..< repetitions {
            do {
                let audio = try NativeAudioSession(options: ["audio-spdif": "ac3,eac3", "speed": "1.25", "mute": "yes"])
                defer { audio.close() }
                let began = Timing()
                try await audio.load(media, resume: false)
                try await audio.wait("processed audio initializes directly as PCM") {
                    audio.string("current-ao") == "avfoundation"
                        && !audio.string("audio-out-params/format").contains("spdif")
                }
                startup.append(began)
                audio.drainEvents()
                startup.outputInitializations
                    .append(Double(audio.logs.components(separatedBy: "Trying audio driver 'avfoundation'").count - 1))
                try #require(audio.string("ao-mute") == "yes" && audio.string("pause") == "yes")
                try #require(audio.node("avfoundation-audio-spatialization")?.mapValue?["path"] == .string("sample-buffer"))
            }

            do {
                let audio = try NativeAudioSession(options: ["audio-spdif": "ac3,eac3", "mute": "yes"])
                defer { audio.close() }
                try await audio.load(media)
                try await audio.wait("native compressed clock for transition") {
                    audio.nativeClockStarts > 0 && audio.number("time-pos") > 0.4
                }
                let position = audio.number("time-pos")
                let began = Timing()
                try audio.set("speed", "1.25")
                try await audio.wait("PCM resumes from the audible position") {
                    audio.string("current-ao") == "avfoundation"
                        && !audio.string("audio-out-params/format").contains("spdif")
                        && audio.number("time-pos") > position + 0.1
                }
                transition.append(began)
                try #require(abs(audio.number("time-pos") - position) < 2)
                try #require(audio.string("pause") == "no")
            }
        }

        return [startup.json, transition.json]
    }
}
#endif
