#if os(macOS)
import CryptoKit
import Darwin
import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@MainActor
enum MPVSeekPerformanceWorkloads {

    static func measure(repetitions: Int) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        for ext in ["mp4", "mkv", "ts"] {
            let media = try TestPaths.testMedia("video-h264-long-gop.\(ext)")
            let mediaHash = try SHA256.hash(data: Data(contentsOf: media)).map { String(format: "%02x", $0) }.joined()
            var wall: [Double] = []
            var cpu: [Double] = []
            for _ in 0 ..< repetitions {
                let fixture = PlaybackFixture(configuration: .init(
                    additionalOptions: ["ao": "null", "sid": "no"],
                    automaticallyPlays: false,
                    hardwareDecoding: .disabled,
                    hdrPolicy: .disabled,
                    logLevel: .none,
                    sdrOutput: .compatibility8Bit,
                    videoOutput: .metal
                ))
                defer { fixture.close() }
                try await fixture.loadPaused(media, at: .seconds(1))
                let start = DispatchTime.now().uptimeNanoseconds
                let startCPU = clock()
                // A keyframe is at 10s. An unconditional 0.5s offset asks an
                // indexed demuxer for the preceding 0s GOP instead.
                try #require(await fixture.player.seekForPictureInPicture(to: .seconds(10.25)))
                wall.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                cpu.append(Double(clock() - startCPU) / Double(CLOCKS_PER_SEC))
                try #require(fixture.player.isPaused && abs(fixture.player.position.seconds - 10.25) < 0.15)
                try #require(fixture.player.lastError == nil)
            }
            results.append([
                "id": "precise_seek_\(ext)",
                "parameters": [
                    "container": ext,
                    "decoder": "software",
                    "backend": "metal",
                    "fromSeconds": 1,
                    "targetSeconds": 10.25,
                    "keyframeSeconds": 10,
                    "fixture": "video-h264-long-gop",
                    "fixtureSHA256": mediaHash,
                    "inputVersion": 1
                ],
                "metrics": [
                    "completionSeconds": ["unit": "seconds", "direction": "lower", "samples": wall],
                    "cpuSeconds": ["unit": "cpu-seconds", "direction": "lower", "samples": cpu],
                ],
                "observations": [],
            ])
        }
        return results
    }
}
#endif
