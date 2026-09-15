import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration))
@MainActor
struct GeneratedCodecTests {
    struct Clip: Sendable {
        let name: String
        let codec: String
        var fps: Double = 24
    }

    @Test(arguments: [
        Clip(name: "codec-hevc-8bit", codec: "hevc"),
        Clip(name: "codec-hevc-10bit", codec: "hevc"),
        Clip(name: "codec-vp9", codec: "vp9"),
        Clip(name: "codec-av1", codec: "av1"),
        Clip(name: "feature-hdr10", codec: "hevc"),
        Clip(name: "feature-hlg", codec: "hevc"),
        Clip(name: "feature-120fps", codec: "h264", fps: 120),
    ])
    func `generated codecs decode and advance at the encoded frame rate`(clip: Clip) async throws {
        let session = try NativePlaybackSession(options: ["sub-auto": "no"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia(clip.name + ".mkv"))
        #expect(session.property("video-out-params/w")?.integerValue == 320)
        #expect(session.property("video-out-params/h")?.integerValue == 180)
        #expect(abs((session.property("duration")?.doubleValue ?? 0) - 2) < 0.1)
        #expect(abs((session.property("container-fps")?.doubleValue ?? 0) - clip.fps) < 0.01)
        let tracks = try #require(session.property("track-list")?.arrayValue).compactMap(\.mapValue)
        #expect(tracks.first { $0["type"]?.stringValue == "video" }?["codec"]?.stringValue == clip.codec)
        let previous = try #require(session.property("time-pos")?.doubleValue)
        try session.command(["frame-step"])
        try await eventually("next decoded frame from \(clip.name)") {
            (session.property("time-pos")?.doubleValue ?? previous) > previous
        }
        let next = try #require(session.property("time-pos")?.doubleValue)
        #expect(abs(next - previous - 1 / clip.fps) < 0.002)
    }
}
