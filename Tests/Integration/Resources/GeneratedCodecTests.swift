import AVFoundation
import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.integration))
@MainActor
struct GeneratedCodecTests {

    struct Clip: Sendable {

        let filename: String
        let codec: String
        var fps: Double = 24
        var duration: Double = 2
    }

    @Test(arguments: [1, 2])
    func `DTS tracks decode to their encoded tones`(track: Int) async throws {
        // Decode a window beyond the reported dropout on both tracks.
        try await expectDecodedTone(
            "audio-dts-multitrack.mkv",
            track: track,
            start: 36,
            channels: track == 1 ? 6 : 2,
            crossings: [track == 1 ? 44 : 66]
        )
    }

    @Test(arguments: [
        "audio-flac.flac",
        "audio-alac.m4a",
        "audio-mp3.mp3",
        "audio-vorbis.ogg",
        "audio-opus.ogg",
        "audio-pcm.wav",
        "audio-adts.aac",
    ])
    func `standalone audio decodes both channels after seeking`(filename: String) async throws {
        try await expectDecodedTone(filename, track: 1, start: 1, channels: 2, crossings: [22, 33])
    }

    @Test(arguments: [
        Clip(filename: "video-mp42.asf", codec: "msmpeg4v2", fps: 25),
        Clip(filename: "video-hevc-8bit.mkv", codec: "hevc"),
        Clip(filename: "video-vp9.mkv", codec: "vp9"),
        Clip(filename: "video-av1-10bit.mkv", codec: "av1"),
        Clip(filename: "color-hdr10.mkv", codec: "hevc", duration: 10),
        Clip(filename: "color-hlg.mkv", codec: "hevc", duration: 10),
        Clip(filename: "video-h264-120fps.mkv", codec: "h264", fps: 120),
    ])

    func `generated codecs decode and advance at the encoded frame rate`(clip: Clip) async throws {
        let session = try NativePlaybackSession(options: ["sub-auto": "no"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia(clip.filename))

        #expect(session.property("video-out-params/w")?.integerValue == 320)
        #expect(session.property("video-out-params/h")?.integerValue == 180)
        #expect(abs((session.property("duration")?.doubleValue ?? 0) - clip.duration) < 0.1)
        #expect(abs((session.property("container-fps")?.doubleValue ?? 0) - clip.fps) < 0.01)

        let tracks = try #require(session.property("track-list")?.arrayValue).compactMap(\.mapValue)
        #expect(tracks.first { $0["type"]?.stringValue == "video" }?["codec"]?.stringValue == clip.codec)

        let previous = try #require(session.property("time-pos")?.doubleValue)

        try session.command(["frame-step"])

        try await eventually("next decoded frame from \(clip.filename)") {
            (session.property("time-pos")?.doubleValue ?? previous) > previous
        }

        let next = try #require(session.property("time-pos")?.doubleValue)
        #expect(abs(next - previous - 1 / clip.fps) < 0.002)
    }

    private func expectDecodedTone(
        _ filename: String,
        track: Int,
        start: Int,
        channels: AVAudioChannelCount,
        crossings: [Int]
    ) async throws {
        let url = try TestPaths.testMedia(filename)
        let wave = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: wave) }

        do {
            let session = try NativePlaybackSession(options: [
                "audio": String(track),
                "vid": "no",
                "ao": "pcm",
                "ao-pcm-file": wave.path,
                "start": String(start),
                "length": "1",
                "pause": "no",
            ])
            defer { session.close() }
            try session.command(["loadfile", url.path])
            try await eventually("\(filename) track \(track) reaches the end of the requested window") {
                session.property("eof-reached")?.boolValue == true
            }
        }

        let file = try AVAudioFile(forReading: wave)
        let format = file.processingFormat
        try #require(format.channelCount == channels)
        #expect(format.sampleRate == 48000)
        #expect(abs(Double(file.length) / format.sampleRate - 1) < 0.05)

        // Count positive zero crossings in 100 ms of decoded PCM.
        file.framePosition = file.length / 2
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        try file.read(into: buffer, frameCount: buffer.frameCapacity)
        try #require(buffer.frameLength == buffer.frameCapacity)
        let data = try #require(buffer.floatChannelData)
        for (index, expected) in crossings.enumerated() {
            let samples = UnsafeBufferPointer(start: data[index], count: Int(buffer.frameLength))
            #expect(samples.contains { $0 > 0.01 })
            let actual = zip(samples, samples.dropFirst()).count { $0.0 <= 0 && $0.1 > 0 }
            #expect(abs(actual - expected) <= 1, "\(filename) channel \(index)")
        }
    }
}
