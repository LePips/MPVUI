import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration))
struct MediaResourceTests {
    @Test(arguments: [
        "01-h264-aac-baseline.mp4", "01-h264-aac-baseline.en.srt", "01-h264-aac-baseline.es.srt",
        "ac3-short.mka", "ac3-stream.mka", "eac3-short.mka", "eac3-stream.mka", "subtitle-formats.mkv",
        "codec-hevc-8bit.mkv", "codec-hevc-10bit.mkv", "codec-vp9.mkv", "codec-av1.mkv",
        "feature-120fps.mkv", "feature-hdr10.mkv", "feature-hlg.mkv",
        "02-h264-multitrack.mkv", "webp-still.webp", "webp-animation.webp",
        "480i-bottom-59.94.mkv", "576i-top-50.mkv", "1080i-top-59.94.mkv",
    ])
    func `bundled generated media resources are present`(name: String) throws {
        let url = try TestPaths.testMedia(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        #expect(values.isRegularFile == true)
        #expect((values.fileSize ?? 0) > 0, "Empty generated media: \(name)")
    }

    @MainActor
    @Test(
        .enabled(if: TestPaths.hasGeneratedMedia, "Import the optional generated library; see TESTING.md."),
        arguments: TestPaths.generatedClips
    )
    func `generated library decodes with embedded and styled subtitles`(_ name: String) async throws {
        let session = try NativePlaybackSession(options: ["sub-auto": "no", "sid": "auto"])
        defer { session.close() }
        try await session.load(TestPaths.media(name + ".mp4"))
        #expect(session.property("video-out-params/w")?.integerValue == 1920)
        #expect(session.property("video-out-params/h")?.integerValue == 1080)
        #expect(abs((session.property("duration")?.doubleValue ?? 0) - 60) < 0.25)
        let frameRate = name == "quality-06-120fps" ? 120.0 : 24.0
        #expect(abs((session.property("container-fps")?.doubleValue ?? 0) - frameRate) < 0.01)

        let tracks = try #require(session.property("track-list")?.arrayValue).compactMap(\.mapValue)
        let embedded = try #require(tracks.first { $0["type"]?.stringValue == "sub" })
        #expect(embedded["codec"]?.stringValue == "mov_text")
        #expect(embedded["lang"]?.stringValue == "eng")
        #expect(embedded["default"]?.boolValue == true)
        #expect(embedded["forced"]?.boolValue == false)
        let audioCodecs = tracks.filter { $0["type"]?.stringValue == "audio" }
            .compactMap { $0["codec"]?.stringValue }
        let expectedAudio = name == "quality-01-sdr" ? ["aac"]
            : name == "quality-02-hdr10" ? ["eac3", "aac"] : []
        #expect(audioCodecs == expectedAudio)

        let sidecar = TestPaths.media(name + ".Styled.en.ass")
        try #require(FileManager.default.fileExists(atPath: sidecar.path))
        try session.command(["sub-add", sidecar.path, "select"])
        try await eventually("styled subtitle selected for \(name)") {
            (session.property("track-list")?.arrayValue ?? []).contains {
                let track = $0.mapValue
                return track?["type"]?.stringValue == "sub" && track?["codec"]?.stringValue == "ass"
                    && track?["external"]?.boolValue == true && track?["selected"]?.boolValue == true
            }
        }

        let previous = try #require(session.property("time-pos")?.doubleValue)
        try session.command(["frame-step"])
        try await eventually("next generated frame") {
            (session.property("time-pos")?.doubleValue ?? previous) > previous
        }
        let next = try #require(session.property("time-pos")?.doubleValue)
        #expect(abs(next - previous - 1 / frameRate) < 0.001)
    }
}
