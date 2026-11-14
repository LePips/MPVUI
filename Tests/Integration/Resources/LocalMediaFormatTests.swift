import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Libmpv
import MPVCore
import Security
import Testing
import VideoToolbox

@Suite(.tags(.integration), .serialized)
@MainActor
struct LocalMediaFormatTests {

    struct Clip: Decodable, Sendable, CustomTestStringConvertible {

        let file: String
        let format: String
        let codec: String
        let decoder: String
        let androidOnly: Bool
        let width: Int
        let height: Int
        let mpvOptions: [String: String]
        let pixelFormat: String?
        let mpvPixelFormat: String?
        let brightOnLeft: Bool?

        var testDescription: String {
            "\(file) (\(decoder))"
        }
    }

    struct Stream: Decodable, Sendable, CustomTestStringConvertible {

        let file: String
        let format: String
        let parts: [String]

        var testDescription: String {
            file
        }
    }

    struct LiveStream: Decodable, Sendable {

        let file: String
        let update: String
        let parts: [String]
    }

    struct DASHRollovers: Decodable, Sendable {

        let manifests: [String]
        let video: [String]
        let audio: [String]
    }

    struct Pair: Decodable, Sendable, CustomTestStringConvertible {

        let file: String
        let format: String
        let videoCodec: String
        let videoDecoder: String
        let audioCodec: String
        let audioDecoder: String

        var testDescription: String {
            file
        }

        var decoderOptions: [String: String] {
            ["vd": "\(videoDecoder),-", "ad": "\(audioDecoder),-", "audio": "auto"]
        }
    }

    struct LosslessAudio: Decodable, Sendable {

        let file: String
        let sampleRate: Int
        let channels: Int
        let frames: Int
        let sha256: String
        let seekStartFrame: Int
        let seekSha256: String
        let seekEarlySha256: String?
    }

    struct AudioRateCase: Decodable, Sendable, CustomTestStringConvertible {

        let codec: String
        let format: String
        let pcm: LosslessAudio

        var testDescription: String {
            pcm.file
        }
    }

    struct ReferenceClip: Decodable, Sendable, CustomTestStringConvertible {

        struct PCMWindow: Decodable, Sendable {

            let startFrame: Int
            let frameCount: Int
            let rms: Double
        }

        static var directory: URL? {
            ProcessInfo.processInfo.environment["MPVUI_REFERENCE_TEST_MEDIA"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        }

        let file: String
        let kind: String
        let format: String
        let codec: String
        let decoder: String
        let track: Int
        let androidOnly: Bool
        let mpvOptions: [String: String]
        let width: Int?
        let height: Int?
        let frameSteps: Int?
        let pcmFrames: Int?
        let pcmFrameTolerance: Int?
        let pcmWindows: [PCMWindow]?

        var testDescription: String {
            file
        }

        static func load(kind: String) throws -> [Self] {
            guard let directory else { return [] }

            let data = try Data(contentsOf: directory.appendingPathComponent("reference-media.json"))
            return try JSONDecoder().decode([Self].self, from: data).filter {
                $0.kind == kind && !$0.androidOnly
            }
        }

        func source() throws -> URL {
            try #require(Self.directory).appendingPathComponent(file)
        }
    }

    struct TextSubtitles: Decodable, Sendable {

        struct Sidecar: Decodable, Sendable, CustomTestStringConvertible {

            let file: String
            let codec: String
            let androidOnly: Bool

            var testDescription: String {
                file
            }
        }

        let cases: [Sidecar]
        let first: String
        let second: String

        static func load() throws -> Self {
            let url = try TestPaths.testMedia("text-subtitles.json")
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }
    }

    struct Catalog: Decodable, Sendable {

        let video: [Clip]
        let audio: [Clip]
        let images: [Clip]
        let mfImages: [Clip]
        let highEfficiencyAAC: [Clip]
        let paired: [Pair]
        let mappedVideo: [Clip]
        let mappedColorVideo: [Clip]
        let mappedAudio: [Clip]
        let vc1: [Clip]
        let wmv3: [Clip]
        let colorVideo: [Clip]
        let avs3Video: [Clip]
        let proresRAWVideo: [Clip]
        let apv: [Clip]
        let chromaVideo: [Clip]
        let segmented: [Stream]
        let networkStreams: [Stream]
        let segmentedVideo: [SegmentedClip]
        let segmentedAudio: [SegmentedClip]
        let rtpAudio: [RTPAudioFixture]
        let rtpVideo: [RTPRecordingFixture]
        let rtpPacketizedAudio: [RTPRecordingFixture]
        let srtpAudio: [RTPRecordingFixture]
        let srtpTransport: RTPRecordingFixture
        let liveStream: LiveStream
        let liveDash: LiveStream
        let liveDashSliding: LiveStream
        let dashRollovers: DASHRollovers
        let hlsRenditions: Stream
        let hlsDiscontinuities: Stream
        let hlsTimestampResets: Stream
        let dashRenditions: Stream
        let dashAdaptationSets: Stream
        let dashAudioAdaptationSets: Stream
        let surround: LosslessAudio
        let audioRates: [AudioRateCase]
        let monkeysAudio: LosslessAudio

        static func load() throws -> Self {
            let url = try TestPaths.testMedia("codecs.json")
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }
    }

    struct SegmentedClip: Decodable, CustomTestStringConvertible, Sendable {

        let file: String
        let format: String
        let codec: String
        let decoder: String
        let parts: [String]

        var testDescription: String {
            file
        }
    }

    private struct Frame {

        let width: Int
        let height: Int
        let stride: Int
        let pixels: Data

        func rgb(x: Int, y: Int) -> [UInt8] {
            let offset = y * stride + x * 4
            return Array(pixels[offset ..< offset + 3])
        }

        func alpha(x: Int, y: Int) -> UInt8 {
            pixels[y * stride + x * 4 + 3]
        }

        func isPrimaryColor(_ channel: Int, x: Int, y: Int) -> Bool {
            let components = rgb(x: x, y: y)
            return components[channel] > 180
                && components.enumerated().allSatisfy { $0.offset == channel || $0.element < 70 }
        }

        func sampledColors() -> [UInt8] {
            var samples: [UInt8] = []
            for row in 1 ... 8 {
                for column in 1 ... 8 {
                    samples.append(contentsOf: rgb(x: column * width / 9, y: row * height / 9))
                }
            }
            return samples
        }
    }

    private nonisolated static let hardwareVideoInputs:
        [(file: String, decoder: String, codec: CMVideoCodecType, width: Int, height: Int)] =
        [
            ("codecs-h264.h264", "h264", kCMVideoCodecType_H264, 176, 144),
            ("codecs-hevc.hevc", "hevc", kCMVideoCodecType_HEVC, 176, 144),
            ("codecs-hevc-main10.hevc", "hevc", kCMVideoCodecType_HEVC, 176, 144),
            ("codecs-vp9.webm", "vp9", kCMVideoCodecType_VP9, 176, 144),
            ("codecs-vp9-profile2.webm", "vp9", kCMVideoCodecType_VP9, 176, 144),
            ("codecs-av1.mkv", "av1", kCMVideoCodecType_AV1, 176, 144),
            ("video-av1-10bit.mkv", "av1", kCMVideoCodecType_AV1, 320, 180),
        ]

    private var transportOptions: [String: String] {
        [
            "vd": "h264,-",
            "ad": "aac,-",
            "audio": "auto",
            "cache": "no",
            "demuxer-lavf-probesize": "32768",
            "demuxer-lavf-analyzeduration": "0.25",
        ]
    }

    private var rtpRecordingOptions: [String: String] {
        [
            "cache": "no",
            "rtsp-transport": "tcp",
            "demuxer-lavf-o": "protocol_whitelist=[file,udp,rtp,tcp]",
            "demuxer-lavf-probesize": "32768",
            "demuxer-lavf-analyzeduration": "0.8",
        ]
    }

    private var rtmpOptions: [String: String] {
        transportOptions.merging([
            "network-timeout": "4",
            "stream-lavf-o": "rtmp_live=live",
            "tls-verify": "yes",
        ]) { _, new in new }
    }

    @Test(arguments: try Catalog.load().video.filter { !$0.androidOnly })
    func `video decoder produces pixels and advances to the next frame`(clip: Clip) async throws {
        try await expectDecodedVideo(clip)
    }

    @Test(arguments: try Catalog.load().mappedVideo.filter { !$0.androidOnly })
    func `remuxed video keeps its codec and decoded frames`(clip: Clip) async throws {
        try await expectDecodedVideo(clip)
    }

    @Test(arguments: try Catalog.load().mappedColorVideo.filter { !$0.androidOnly })
    func `remuxed video preserves both authored colors`(clip: Clip) async throws {
        try await expectAuthoredColors(clip)
    }

    @Test(arguments: try Catalog.load().audio.filter { !$0.androidOnly })
    func `audio decoder produces the encoded tone`(clip: Clip) async throws {
        try await expectDecodedTone(clip, decoder: clip.decoder)
    }

    @Test(arguments: [
        ("mpeg-layer1.mp1", "mp1float"),
        ("mp2.mp2", "mp2float"),
        ("mpeg-audio-in-mp4.mp4", "mp3on4float"),
    ])
    func `MPEG audio floating point decoders preserve the tone`(file: String, decoder: String)
        async throws
    {
        let clip = try #require(try Catalog.load().audio.first { $0.file == "codecs-\(file)" })
        try await expectDecodedTone(clip, decoder: decoder)
    }

    @Test(arguments: try Catalog.load().highEfficiencyAAC, ["aac", "aac_fixed"])
    func `HE-AAC restores high-band audio in M4A and ADTS`(clip: Clip, decoder: String) async throws {
        try await expectHighEfficiencyAAC(clip, decoder: decoder)
    }

    #if os(macOS)
    @Test(arguments: try Catalog.load().highEfficiencyAAC)
    func `AudioToolbox restores HE-AAC high-band audio`(clip: Clip) async throws {
        try await expectHighEfficiencyAAC(clip, decoder: "aac_at")
    }
    #endif

    @Test
    func `VBR MP3 trims encoder delay and end padding`() async throws {
        try await withDecodedPCM(TestPaths.testMedia("codecs-mp3-vbr.mp3"), options: ["ad": "mp3,-"]) {
            session in
            expectFormat("mp3", session)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == "mp3")
        } checkPCM: { file, _ in
            try #require(file.length == 60000)
            try expectMonoTone(file, at: 0, frequency: 440)
            try expectMonoTone(file, at: 1.15, frequency: 440)
        }
    }

    @Test(arguments: [("codecs-opus.ogg", "ogg", 1), ("codecs-mapping-matroska-opus.mkv", "mkv", 48)])
    func `Opus trims padding and seeks within the container timestamp precision`(
        name: String,
        format: String,
        seekTolerance: Int
    ) async throws {
        let source = try TestPaths.testMedia(name)
        for (startFrame, frames) in [(0, 60000), (30000, 30000)] {
            let start = Double(startFrame) / 48000
            let options = ["ad": "opus,-", "vid": "no", "start": String(start), "hr-seek": "yes"]
            try await withDecodedPCM(source, options: options) { session in
                expectFormat(format, session)
                #expect(session.property("current-tracks/audio/decoder")?.stringValue == "opus")
                #expect(session.property("seekable")?.boolValue == true)
            } checkPCM: { file, seconds in
                // The Matroska fixture uses millisecond timecodes. Ogg may round one sample at an exact seek.
                let tolerance = startFrame == 0 ? 0 : seekTolerance
                try #require(
                    abs(Int(file.length) - frames) <= tolerance,
                    "\(name) starting at sample \(startFrame)"
                )
                try expectMonoTone(file, at: 0, frequency: 440)
                try expectMonoTone(file, at: seconds - 0.1, frequency: 440)
            }
        }
    }

    @Test
    func `FLAC playlist advances without dropping or repeating any stereo samples`() async throws {
        let playlist = try TestPaths.testMedia("audio-flac-gapless.m3u")
        let options = [
            "ad": "flac,-",
            "gapless-audio": "yes",
            "audio-channels": "stereo",
            "audio-format": "s16",
            "ao-pcm-waveheader": "no",
        ]
        try await withPCMOutput(playlist, options: options) { session in
            expectFormat("flac", session)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == "flac")
            #expect(session.property("playlist-count")?.integerValue == 2)
            #expect(session.property("playlist-pos")?.integerValue == 1)
        } checkFile: { raw in
            let samples = try Data(contentsOf: raw)
            #expect(samples.count == 60000 * 4)
            let digest = SHA256.hash(data: samples).map { String(format: "%02x", $0) }.joined()
            #expect(digest == "2371763cb855fedcefa9b7c7b99e49fe475c8084e80da91b975fade392349899")
        }
    }

    @Test(
        .enabled(
            if: FileManager.default
                .fileExists(
                    atPath: TestPaths.generatedMediaDirectory
                        .appendingPathComponent(
                            "audio-joc-reference.mka"
                        )
                        .path
                ),
            "Stage the optional audio-joc-reference.mka sample in the test media directory."
        )
    )
    func `reference E-AC-3 JOC decodes to six channels of PCM`() async throws {
        let source = try TestPaths.testMedia("audio-joc-reference.mka")
        let options = [
            "ad": "eac3,-",
            "vid": "no",
            "audio-channels": "5.1(side)",
            "audio-format": "s16",
        ]
        try await withPCMOutput(source, options: options) { session in
            expectFormat("mkv", session)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == "eac3")
        } checkFile: { wave in
            let file = try AVAudioFile(forReading: wave)
            let format = file.processingFormat
            try #require(format.sampleRate == 48000 && format.channelCount == 6)
            try #require(
                (431_616 ... 433_152).contains(Int(file.length)),
                "PCM duration within one 1536-sample E-AC-3 packet"
            )
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12000))
            for start in [12000, 204_000, 396_000] {
                file.framePosition = AVAudioFramePosition(start)
                try file.read(into: buffer)
                try #require(buffer.frameLength == buffer.frameCapacity)
                let channels = try #require(buffer.floatChannelData)
                for index in 0 ..< Int(format.channelCount) {
                    let pcm = UnsafeBufferPointer(start: channels[index], count: Int(buffer.frameLength))
                    let meanSquare = pcm.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(pcm.count)
                    #expect(meanSquare.squareRoot() > 0.005, "Channel \(index + 1) at sample \(start)")
                }
            }
        }
    }

    @Test
    func `M4A preserves chapters artwork and sample-exact AAC duration`() async throws {
        let source = try TestPaths.testMedia("codecs-album.m4a")
        let session = try NativePlaybackSession(options: [
            "audio": "auto",
            "audio-display": "embedded-first",
            "ad": "aac,-",
            "vd": "mjpeg,-",
        ])
        defer { session.close() }
        try await session.load(source)

        expectFormat("mov", session)
        #expect(session.property("metadata/by-key/title")?.stringValue == "Three tone album")
        #expect(session.property("metadata/by-key/artist")?.stringValue == "Test ensemble")
        #expect(session.property("current-tracks/video/albumart")?.boolValue == true)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "mjpeg")
        let chapters = try #require(session.property("chapter-list")?.arrayValue)
        #expect(
            chapters.compactMap { $0.mapValue?["title"]?.stringValue } == ["Opening", "Middle", "Ending"]
        )
        #expect(chapters.compactMap { $0.mapValue?["time"]?.doubleValue } == [0, 1.024, 2.048])
        for (step, index, time) in [(1, 1, 1.024), (1, 2, 2.048), (-1, 1, 1.024)] {
            try session.command(["add", "chapter", String(step)])
            try await eventually("M4A chapter \(index) is selected") {
                session.property("chapter")?.integerValue == Int64(index)
                    && abs((session.property("time-pos")?.doubleValue ?? -1) - time) < 0.05
            }
            try await expectPrimaryColor(2, session)
        }

        try await withDecodedPCM(source, options: ["ad": "aac,-", "audio-display": "no"]) { audio in
            expectFormat("mov", audio)
            #expect(audio.property("current-tracks/audio/decoder")?.stringValue == "aac")
        } checkPCM: { file, _ in
            try #require(file.length == 147_456)
            try expectMonoTone(file, at: 0, frequency: 440)
            try expectMonoTone(file, at: 1.12, frequency: 660)
            try expectMonoTone(file, at: 2.972, frequency: 880)
        }
    }

    @Test(arguments: [("dts", "dca", "hdmv-dts-core"), ("truehd", "truehd", "hdmv-truehd")])
    func `MPEG-TS private audio tags select the decoder with HDMV registration`(
        codec: String,
        decoder: String,
        registered: String
    ) async throws {
        let unregistered = try TestPaths.testMedia("codecs-mapping-mpegts-\(codec).ts")
        let source = try TestPaths.testMedia("codecs-\(registered).ts")
        let session = try NativePlaybackSession(options: [
            "ad": "\(decoder),-",
            "audio": "auto",
            "vid": "no",
            "pause": "no",
        ])
        defer { session.close() }

        try session.command(["loadfile", unregistered.path])
        try await eventually("unregistered MPEG-TS \(codec) ends with a load error") {
            (session.consumeEndFileStatus() ?? 0) < 0
        }
        #expect(session.property("current-tracks/audio/decoder") == nil)

        try session.command(["loadfile", source.path])
        try await eventually("HDMV registration selects the \(decoder) decoder") {
            session.property("current-tracks/audio/decoder")?.stringValue == decoder
                && (session.property("time-pos")?.doubleValue ?? 0) > 0.25
        }
        expectFormat("mpegts", session)
        #expect(session.property("current-tracks/audio/codec")?.stringValue == codec)
        try await eventually("registered MPEG-TS \(codec) reaches EOF") {
            session.property("eof-reached")?.boolValue == true
        }
    }

    @Test(arguments: try Catalog.load().mappedAudio.filter { !$0.androidOnly })
    func `remuxed audio keeps its codec and decoded tone`(clip: Clip) async throws {
        try await expectDecodedTone(clip, decoder: clip.decoder)
    }

    @Test(arguments: try Catalog.load().vc1.filter { !$0.androidOnly })
    func `VC-1 advanced profile presents both authored colors`(clip: Clip) async throws {
        try await expectAuthoredColors(clip)
    }

    @Test(arguments: try Catalog.load().wmv3.filter { !$0.androidOnly })
    func `VC-1 main profile presents both authored colors`(clip: Clip) async throws {
        try await expectAuthoredColors(clip)
    }

    @Test(arguments: try Catalog.load().colorVideo.filter { !$0.androidOnly })
    func `legacy video decoders present both authored colors`(clip: Clip) async throws {
        try await expectAuthoredColors(clip)
    }

    @Test(arguments: try Catalog.load().avs3Video)
    func `AVS3 presents both authored colors through each container reader`(clip: Clip) async throws {
        try await expectAuthoredColors(clip)
    }

    @Test(arguments: try Catalog.load().proresRAWVideo)
    func `ProRes RAW profiles preserve the Bayer depth and grayscale levels`(clip: Clip) async throws {
        try await expectAuthoredColors(clip, grayLevels: (106, 150))
    }

    @Test(arguments: try Catalog.load().apv.filter { !$0.androidOnly })
    func `APV profiles present both authored frames`(clip: Clip) async throws {
        try await expectAuthoredColors(clip)
    }

    @Test(arguments: try Catalog.load().chromaVideo)
    func `AVC HEVC and VP9 preserve the decoded chroma and bit depth`(clip: Clip) async throws {
        try await expectAuthoredColors(clip)
    }

    @Test
    func `WebP still reader preserves the opening pattern`() async throws {
        let clip = try #require(Catalog.load().images.first { $0.file == "codecs-pipe.webp" })
        try await expectOpeningImage(
            clip,
            options: ["demuxer": "lavf", "demuxer-lavf-format": "webp_pipe"]
        )
    }

    @Test(arguments: try Catalog.load().mfImages.filter { !$0.androidOnly })
    func `mpv image file reader presents the authored patterns`(clip: Clip) async throws {
        try await expectOpeningImage(clip, options: clip.mpvOptions)
    }

    @Test(
        .enabled(
            if: ReferenceClip.directory != nil,
            "Set MPVUI_REFERENCE_TEST_MEDIA to a staged local FATE directory"
        ),
        arguments: try ReferenceClip.load(kind: "video")
    )
    func `reference video decoders present the expected frames`(clip: ReferenceClip) async throws {
        var options = clip.mpvOptions
        options["vd"] = "\(clip.decoder),-"
        options["vid"] = String(clip.track)
        let session = try NativePlaybackSession(options: options)
        defer { session.close() }
        try await session.load(clip.source())

        expectFormat(clip.format, session)
        #expect(session.property("current-tracks/video/codec")?.stringValue == clip.codec)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == clip.decoder)
        #expect(session.property("video-dec-params/w")?.integerValue == clip.width.map { Int64($0) })
        #expect(session.property("video-dec-params/h")?.integerValue == clip.height.map { Int64($0) })

        let first = try screenshot(session).sampledColors()
        var latest = first
        let visibleAtStart = first.contains { $0 > 32 }
        let steps = try #require(clip.frameSteps)
        for _ in 0 ..< steps {
            let previous = try #require(session.property("time-pos")?.doubleValue)
            try session.command(["frame-step"])
            try await eventually("next frame in \(clip.file)") {
                (session.property("time-pos")?.doubleValue ?? previous) > previous
            }
            latest = try screenshot(session).sampledColors()
            if visibleAtStart || latest.contains(where: { $0 > 32 }),
               zip(first, latest).contains(where: { abs(Int($0.0) - Int($0.1)) > 12 })
            {
                break
            }
        }
        #expect(visibleAtStart || latest.contains { $0 > 32 })
        if steps > 0 {
            #expect(zip(first, latest).contains { abs(Int($0.0) - Int($0.1)) > 12 })
        }
    }

    @Test(
        .enabled(
            if: ReferenceClip.directory != nil,
            "Set MPVUI_REFERENCE_TEST_MEDIA to a staged local FATE directory"
        ),
        arguments: try ReferenceClip.load(kind: "audio")
    )
    func `reference audio decoders preserve the PCM envelope`(clip: ReferenceClip) async throws {
        var options = clip.mpvOptions
        options["vid"] = "no"
        options["ad"] = "\(clip.decoder),-"
        options["audio"] = String(clip.track)
        options["length"] = options["length"] ?? "2.5"
        try await withDecodedPCM(clip.source(), options: options) { session in
            expectFormat(clip.format, session)
            #expect(session.property("current-tracks/audio/codec")?.stringValue == clip.codec)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == clip.decoder)
        } checkPCM: { file, _ in
            let frames = try #require(clip.pcmFrames)
            let tolerance = clip.pcmFrameTolerance ?? 5760
            try #require(
                abs(Int(file.length) - frames) <= tolerance,
                "\(clip.file) decoded \(file.length) PCM frames, expected \(frames)"
            )
            for window in try #require(clip.pcmWindows) {
                let count = AVAudioFrameCount(window.frameCount)
                let buffer = try #require(
                    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)
                )
                file.framePosition = AVAudioFramePosition(window.startFrame)
                try file.read(into: buffer)
                try #require(buffer.frameLength == count)
                let samples = try UnsafeBufferPointer(
                    start: #require(buffer.floatChannelData)[0],
                    count: window.frameCount
                )
                let meanSquare =
                    samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(window.frameCount)
                #expect(
                    abs(meanSquare.squareRoot() - window.rms) <= window.rms * 0.4 + 0.005,
                    "PCM level of \(clip.file) at \(window.startFrame)"
                )
            }
        }
    }

    @Test
    func `anamorphic AVC presents each variable frame timestamp`() async throws {
        let session = try NativePlaybackSession(options: ["vd": "h264,-"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("codecs-avc-vfr-anamorphic.mp4"))

        expectFormat("mov", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        #expect(session.property("video-params/w")?.integerValue == 192)
        #expect(session.property("video-params/h")?.integerValue == 108)
        #expect(session.property("video-params/par")?.doubleValue == 1.5)
        let initial = try screenshot(session)
        #expect(initial.width == 288)
        #expect(initial.height == 108)

        for (index, time) in [0.0, 0.25, 0.75, 1.0, 1.125, 1.75, 2.0, 2.25, 2.75].enumerated() {
            if index > 0 {
                try session.command(["frame-step"])
            }
            try await eventually("AVC frame \(index) at \(time) seconds") {
                abs((session.property("time-pos")?.doubleValue ?? -1) - time) < 0.002
            }
            try await expectPrimaryColor(index / 3, session)
        }
    }

    @Test
    func `AVC honors the MP4 rotation matrix`() async throws {
        let session = try NativePlaybackSession(options: ["vd": "h264,-"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("codecs-avc-display-rotation.mp4"))

        expectFormat("mov", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        #expect(session.property("video-params/rotate")?.integerValue == 270)
        let frame = try screenshot(session)
        #expect(frame.width == 108)
        #expect(frame.height == 192)
        #expect(frame.isPrimaryColor(2, x: frame.width / 2, y: frame.height / 4))
        #expect(frame.isPrimaryColor(0, x: frame.width / 2, y: frame.height * 3 / 4))
    }

    @Test(arguments: [false, true])
    func `AVC SPS cropping follows the decoder alignment option`(allowUnaligned: Bool) async throws {
        var options = ["vd": "h264,-"]
        if allowUnaligned {
            options["vd-lavc-o"] = "flags=+unaligned"
        }
        let session = try NativePlaybackSession(options: options)
        defer { session.close() }
        try await session.load(TestPaths.testMedia("codecs-avc-explicit-crop.mp4"))
        expectFormat("mov", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        let frame = try screenshot(session)
        #expect(frame.width == (allowUnaligned ? 160 : 176) && frame.height == 128)
        for y in [4, frame.height - 5] {
            #expect(frame.isPrimaryColor(0, x: 24, y: y))
            #expect(frame.isPrimaryColor(2, x: frame.width - 5, y: y))
            if allowUnaligned {
                #expect(frame.isPrimaryColor(0, x: 4, y: y))
            } else {
                #expect(frame.rgb(x: 4, y: y).allSatisfy { $0 < 24 })
            }
        }
    }

    @Test
    func `UHD HEVC Main 10 with B frames seeks in software`() async throws {
        let session = try NativePlaybackSession(options: ["vd": "hevc,-", "vd-lavc-threads": "4"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("codecs-hevc-main10-uhd.mp4"))
        expectFormat("mov", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "hevc")
        #expect((session.property("hwdec-current")?.stringValue ?? "no") == "no")
        #expect(session.property("video-dec-params/w")?.integerValue == 3840)
        #expect(session.property("video-dec-params/h")?.integerValue == 2160)
        #expect(session.property("video-dec-params/pixelformat")?.stringValue == "yuv420p10")
        for (time, color) in [(1.167, 2), (0.25, 0), (0.667, 1)] {
            try await seek(session, to: time)
            try await expectPrimaryColor(color, session)
        }
    }

    @Test
    func `10-bit AV1 film grain changes the pixels after forward and backward seeks`() async throws {
        let source = try TestPaths.testMedia("codecs-av1-main10-film-grain.mkv")
        var samplesByMode: [[[Int]]] = []
        for grain in ["0", "1"] {
            let session = try NativePlaybackSession(options: [
                "vd": "libdav1d,-",
                "vd-lavc-film-grain": "cpu",
                "vd-lavc-o": "filmgrain=\(grain)",
            ])
            defer { session.close() }
            try await session.load(source)
            expectFormat("mkv", session)
            #expect(session.property("current-tracks/video/decoder")?.stringValue == "libdav1d")
            #expect(session.property("video-dec-params/pixelformat")?.stringValue == "yuv420p10")

            var samples: [[Int]] = []
            for time in [0.25, 1.25, 0.5] {
                try await seek(session, to: time)
                let frame = try screenshot(session)
                try #require(frame.width == 160 && frame.height == 96)
                samples.append((30 ..< 66).flatMap { y in
                    (40 ..< 120).map { x in Int(frame.rgb(x: x, y: y)[0]) }
                })
            }
            samplesByMode.append(samples)
        }
        for (off, on) in zip(samplesByMode[0], samplesByMode[1]) {
            let count = Double(off.count)
            let difference = zip(off, on).reduce(0) { $0 + abs($1.0 - $1.1) }
            #expect(Double(difference) / count > 1.5)
            #expect(Double(abs(off.reduce(0, +) - on.reduce(0, +))) / count < 3)
        }
    }

    @Test
    func `HDR10 plus scene statistics follow seek order and clear on SDR replacement`() async throws {
        let session = try NativePlaybackSession(options: ["vd": "hevc,h264,-", "aid": "no"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("color-hdr10plus-scenes.mkv"))
        expectFormat("mkv", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "hevc")
        let properties = ["scene-max-r", "scene-max-g", "scene-max-b", "scene-avg"]
        for (time, levels) in [
            (0.5, [400.0, 300, 200, 130]),
            (2.5, [600, 500, 400, 170]),
            (1.5, [900, 700, 500, 280]),
            (0.5, [400, 300, 200, 130])
        ] {
            try await seek(session, to: time)
            try await eventually("HDR10+ metadata at \(time) seconds") {
                zip(properties, levels).allSatisfy { property, expected in
                    let actual = session.property("video-params/\(property)")?.doubleValue ?? -1
                    return abs(actual - expected) < 1
                }
            }
            #expect(session.property("video-params/gamma")?.stringValue == "pq")
        }

        try await session.load(TestPaths.testMedia("baseline.mp4"))
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        #expect(session.property("video-params/gamma")?.stringValue != "pq")
        #expect(properties.allSatisfy { session.property("video-params/\($0)") == nil })
    }

    @Test(arguments: ["top", "bottom"], [false, true])
    func `MBAFF AVC presents the expected frame or field cadence`(order: String, deinterlace: Bool)
        async throws
    {
        let session = try NativePlaybackSession(options: [
            "vd": "h264,-",
            "deinterlace": deinterlace ? "yes" : "no",
        ])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("codecs-avc-mbaff-\(order).mp4"))

        expectFormat("mov", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        let first = try screenshot(session)
        #expect(first.width == 192)
        #expect(first.height == 128)

        let rate = deinterlace ? 48.0 : 24.0
        for index in 1 ... 6 {
            let time = Double(index) / rate
            try session.command(["frame-step"])
            try await eventually("\(order)-first AVC presentation at \(time) seconds") {
                abs((session.property("time-pos")?.doubleValue ?? -1) - time) < 0.002
            }
        }
        #expect(try screenshot(session).pixels != first.pixels)
    }

    @Test
    func `MPEG-2 telecine preserves field order across a dominance change`() async throws {
        let levels = [35, 98, 165, 229, 58, 122, 186, 247]
        let cycle = levels.enumerated().flatMap { index, level in
            Array(repeating: level, count: index.isMultiple(of: 2) ? 2 : 3)
        }
        try await expectMPEG2Fields("codecs-mpeg2-telecine.mkv", cadence: 60, levels: cycle + cycle)
    }

    @Test(arguments: [
        ("interlaced-480i-bottom.mkv", 60000.0 / 1001),
        ("interlaced-576i-top.mkv", 50.0),
        ("interlaced-1080i-top.mkv", 60000.0 / 1001),
    ])
    func `interlaced MPEG-2 preserves authored field order and cadence`(name: String, cadence: Double)
        async throws
    {
        let levels = Array(repeating: [45, 100, 165, 220], count: 3).flatMap(\.self)
        try await expectMPEG2Fields(name, cadence: cadence, levels: levels)
    }

    @Test(arguments: [false, true])
    func `24-bit FLAC preserves each surround channel and exact samples`(seek: Bool) async throws {
        try await expectLosslessAudio(
            Catalog.load().surround,
            decoder: "flac",
            format: "flac",
            layout: "5.1",
            sampleFormat: "s32",
            bytesPerSample: 4,
            seek: seek
        )
    }

    @Test(arguments: try Catalog.load().audioRates)
    func `24-bit ALAC and WAV preserve the source rate and exact stereo samples`(clip: AudioRateCase)
        async throws
    {
        for seek in [false, true] {
            try await expectLosslessAudio(
                clip.pcm,
                decoder: clip.codec,
                format: clip.format,
                layout: "stereo",
                sampleFormat: "s32",
                bytesPerSample: 4,
                seek: seek
            )
        }
    }

    @Test(arguments: [false, true])
    func `APE preserves every sample through the last compressed frame`(seek: Bool) async throws {
        try await expectLosslessAudio(
            Catalog.load().monkeysAudio,
            decoder: "ape",
            format: "ape",
            layout: "mono",
            sampleFormat: "s16",
            bytesPerSample: 2,
            seek: seek
        )
    }

    @Test(arguments: ["fixed", "xiph", "ebml", "flac-xiph", "flac-ebml"], ["mkv", "lavf"])
    func `Matroska lacing preserves PCM through native and FFmpeg readers`(
        mode: String,
        demuxer: String
    ) async throws {
        let url = try TestPaths.testMedia("matroska-lacing.json")
        let clips = try JSONDecoder().decode([String: LosslessAudio].self, from: Data(contentsOf: url))
        let clip = try #require(clips[mode])
        for seek in [false, true] {
            try await expectLosslessAudio(
                clip,
                decoder: mode.hasPrefix("flac-") ? "flac" : "pcm_s16le",
                format: demuxer == "mkv" ? "mkv" : "matroska",
                demuxer: demuxer,
                layout: "mono",
                sampleFormat: "s16",
                bytesPerSample: 2,
                seek: seek
            )
        }
    }

    @Test(arguments: [false, true])
    func `ordered Matroska chapters link another segment and return`(seek: Bool) async throws {
        let url = try TestPaths.testMedia("matroska-ordered.json")
        let clip = try JSONDecoder().decode(LosslessAudio.self, from: Data(contentsOf: url))
        try await expectLosslessAudio(
            clip,
            decoder: "pcm_s16le",
            format: "mkv_oc/mkv",
            demuxer: "mkv",
            layout: "mono",
            sampleFormat: "s16",
            bytesPerSample: 2,
            seek: seek
        ) { session in
            let chapters = session.property("chapter-list")?.arrayValue ?? []
            #expect(
                chapters.compactMap { $0.mapValue?["title"]?.stringValue } == [
                    "Opening",
                    "Linked",
                    "Return",
                ]
            )
            #expect(chapters.compactMap { $0.mapValue?["time"]?.doubleValue } == [0, 0.36, 0.72])
        }
    }

    @Test
    func `ordered Matroska omits the missing chapter and restores it once the segment is present`()
        async throws
    {
        struct OrderedChapters: Decodable {

            let withoutLinked: LosslessAudio
        }

        let catalog = try Data(contentsOf: TestPaths.testMedia("matroska-ordered.json"))
        let complete = try JSONDecoder().decode(LosslessAudio.self, from: catalog)
        let incomplete = try JSONDecoder().decode(OrderedChapters.self, from: catalog).withoutLinked
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = directory.appendingPathComponent(complete.file)
        try FileManager.default.copyItem(at: TestPaths.testMedia(complete.file), to: main)

        func check(_ fixture: LosslessAudio, titles: [String], times: [Double]) async throws {
            for seek in [false, true] {
                try await expectLosslessAudio(
                    fixture,
                    decoder: "pcm_s16le",
                    format: "mkv_oc/mkv",
                    demuxer: "mkv",
                    layout: "mono",
                    sampleFormat: "s16",
                    bytesPerSample: 2,
                    seek: seek,
                    source: main
                ) { session in
                    let chapters = session.property("chapter-list")?.arrayValue ?? []
                    #expect(chapters.compactMap { $0.mapValue?["title"]?.stringValue } == titles)
                    #expect(chapters.compactMap { $0.mapValue?["time"]?.doubleValue } == times)
                }
            }
        }

        try await check(incomplete, titles: ["Opening", "Return"], times: [0, 0.36])
        let linked = try TestPaths.testMedia("matroska-ordered-linked.mka")
        try FileManager.default.copyItem(at: linked, to: directory.appendingPathComponent(linked.lastPathComponent))
        try await check(complete, titles: ["Opening", "Linked", "Return"], times: [0, 0.36, 0.72])
    }

    @Test(arguments: ["directory", "bd", "br", "bluray"])
    func `clear Blu-ray opens both play items and follows chapter marks`(input: String) async throws {
        let disc = try TestPaths.testMedia("bluray/BDMV/MovieObject.bdmv")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let options = [
            "vd": "h264,-",
            "ad": "pcm_bluray,-",
            "bluray-device": disc.path,
            "audio": "auto",
        ]
        let session = try NativePlaybackSession(options: options)
        defer { session.close() }
        let source = input == "directory" ? disc.path : "\(input)://0"
        try await session.load(argument: source, named: "authored Blu-ray title")
        expectFormat("disc", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        #expect(session.property("current-tracks/audio/decoder")?.stringValue == "pcm_bluray")
        #expect(session.property("seekable")?.boolValue == true)
        #expect(session.property("duration")?.doubleValue == 4)
        let chapters = try #require(session.property("chapter-list")?.arrayValue)
        #expect(chapters.compactMap { $0.mapValue?["time"]?.doubleValue } == [0, 2])
        try await expectPrimaryColor(0, session)

        for (chapter, channel) in [(1, 2), (0, 0)] {
            try session.command(["set", "chapter", String(chapter)])
            try await eventually("Blu-ray chapter \(chapter)") {
                session.property("chapter")?.integerValue == Int64(chapter)
                    && abs((session.property("time-pos")?.doubleValue ?? -1) - Double(chapter * 2)) < 0.1
            }
            try await expectPrimaryColor(channel, session)
        }

        try await withDecodedPCM(
            disc,
            argument: source,
            options: options.merging(["vid": "no"]) { first, _ in first }
        ) { audio in
            expectFormat("disc", audio)
            #expect(audio.property("current-tracks/audio/decoder")?.stringValue == "pcm_bluray")
        } checkPCM: { file, duration in
            #expect(abs(duration - 4) < 0.1)
            try expectMonoTone(file, at: 0.5, frequency: 440)
            try expectMonoTone(file, at: 2.5, frequency: 880)
        }
    }

    @Test
    func `Blu-ray selects alternate LPCM and PGS across a chapter boundary`() async throws {
        let disc = try TestPaths.testMedia("bluray/BDMV/MovieObject.bdmv")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let options = ["vd": "h264,-", "ad": "pcm_bluray,-", "audio": "auto", "sid": "1", "aid": "1"]
        let session = try NativePlaybackSession(options: options)
        defer { session.close() }
        try await session.load(disc)
        expectFormat("disc", session)
        #expect(session.property("current-tracks/audio/lang")?.stringValue == "eng")
        #expect(session.property("current-tracks/sub/codec")?.stringValue == "hdmv_pgs_subtitle")

        try await seek(session, to: 0.5)
        try await eventually("the first Blu-ray chapter displays its PGS cue") {
            try brightPixelSamples(in: screenshot(session, mode: "subtitles")) > 4
        }
        try session.command(["set", "chapter", "1"])
        try session.command(["set", "aid", "2"])
        try await seek(session, to: 2.5)
        try await expectPrimaryColor(2, session)
        #expect(session.property("chapter")?.integerValue == 1)
        #expect(session.property("current-tracks/audio/lang")?.stringValue == "spa")
        #expect(session.property("current-tracks/audio/decoder")?.stringValue == "pcm_bluray")
        try await eventually("the second Blu-ray chapter displays its own PGS cue") {
            try brightPixelSamples(in: screenshot(session, mode: "subtitles")) > 4
        }
        try await seek(session, to: 3.25)
        try await eventually("the second Blu-ray chapter clears its PGS cue") {
            try brightPixelSamples(in: screenshot(session, mode: "subtitles")) == 0
        }

        try await withDecodedPCM(disc, options: ["vid": "no", "ad": "pcm_bluray,-", "audio": "2"]) { audio in
            expectFormat("disc", audio)
            #expect(audio.property("current-tracks/audio/lang")?.stringValue == "spa")
        } checkPCM: { file, duration in
            #expect(abs(duration - 4) < 0.1)
            try expectMonoTone(file, at: 0.5, frequency: 660)
            try expectMonoTone(file, at: 2.5, frequency: 1100)
        }
    }

    @Test
    func `standalone Blu-ray transport clips preserve both authored pictures and tones`() async throws {
        let options = ["vd": "h264,-", "ad": "pcm_bluray,-", "audio": "auto"]
        for (number, channel, frequency) in [("00001", 0, 440), ("00002", 2, 880)] {
            let source = try TestPaths.testMedia("bluray/BDMV/STREAM/\(number).m2ts")
            let session = try NativePlaybackSession(options: options)
            defer { session.close() }
            try await session.load(source)
            expectFormat("mpegts", session)
            #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == "pcm_bluray")
            try await expectPrimaryColor(channel, session)

            try await withDecodedPCM(
                source,
                options: options.merging(["vid": "no"]) { first, _ in first }
            ) { audio in
                expectFormat("mpegts", audio)
                #expect(audio.property("current-tracks/audio/decoder")?.stringValue == "pcm_bluray")
            } checkPCM: { file, duration in
                #expect(abs(duration - 2) < 0.1)
                try expectMonoTone(file, at: 0.5, frequency: frequency)
            }
        }
    }

    @Test
    func `CUE opens its relative FLAC and navigates authored chapters`() async throws {
        let source = try TestPaths.testMedia("codecs-album.cue")
        let session = try NativePlaybackSession(options: ["audio": "auto", "ad": "flac,-"])
        defer { session.close() }
        try session.command(["loadfile", source.path])
        try await eventually("CUE album opens at its first track") {
            session.property("current-tracks/audio/decoder")?.stringValue == "flac"
                && session.property("chapter")?.integerValue == 0
        }
        expectFormat("cue/flac", session)
        #expect(session.property("seekable")?.boolValue == true)
        let chapters = try #require(session.property("chapter-list")?.arrayValue)
        #expect(
            chapters.compactMap { $0.mapValue?["title"]?.stringValue } == ["Opening", "Middle", "Ending"]
        )
        #expect(chapters.compactMap { $0.mapValue?["time"]?.doubleValue } == [0, 1, 2])

        for (step, index) in [(1, 1), (1, 2), (-1, 1)] {
            try session.command(["add", "chapter", String(step)])
            try await eventually("CUE chapter \(index) is selected") {
                session.property("chapter")?.integerValue == Int64(index)
                    && session.property("seeking")?.boolValue == false
                    && abs((session.property("time-pos")?.doubleValue ?? -1) - Double(index)) < 0.05
            }
        }

        try await withDecodedPCM(source, options: ["ad": "flac,-"]) { session in
            expectFormat("cue/flac", session)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == "flac")
        } checkPCM: { file, duration in
            #expect(abs(duration - 3) < 0.01)
            for (start, tone) in [(0.25, 440), (1.25, 660), (2.25, 880)] {
                try expectMonoTone(file, at: start, frequency: tone)
            }
        }
    }

    @Test(arguments: ["m3u", "pls"])
    func `local playlists advance past an unavailable relative entry`(suffix: String) async throws {
        let source = try TestPaths.testMedia("codecs-playlist.\(suffix)")
        let session = try NativePlaybackSession()
        defer { session.close() }

        try await session.load(source)
        #expect(session.property("playlist-count")?.integerValue == 3)
        #expect(session.property("playlist-playing-pos")?.integerValue == 0)
        expectFormat("mpegts", session)
        try await expectPrimaryColor(0, session)

        try session.command(["set", "pause", "no"])
        try await eventually("last playlist entry starts after an unavailable entry") {
            session.property("playlist-playing-pos")?.integerValue == 2
                && session.property("video-out-params/w")?.integerValue != nil
                && session.property("time-pos")?.doubleValue != nil
        }
        try await expectPrimaryColor(2, session)

        try session.command(["set", "pause", "yes"])
        try session.command(["playlist-play-index", "0"])
        try await eventually("first playlist entry opens again") {
            session.property("playlist-playing-pos")?.integerValue == 0
                && session.property("video-out-params/w")?.integerValue != nil
                && session.property("time-pos")?.doubleValue != nil
        }
        try await expectPrimaryColor(0, session)
    }

    @Test
    func `recursive directories play visible media in natural filename order`() async throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let subdirectory = directory.appendingPathComponent("Nested", isDirectory: true)
        try files.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }

        let paths = ["Clip 10.ts", "Nested/Clip 1.ts", "Clip 2.ts", ".Hidden.ts"]
        for (path, color) in zip(paths, [2, 1, 0, 1]) {
            try files.copyItem(
                at: TestPaths.testMedia("codecs-http-hls-0\(color).ts"),
                to: directory.appendingPathComponent(path)
            )
        }
        try Data("Ignored by the video filter".utf8).write(
            to: directory.appendingPathComponent("Clip 1.txt")
        )

        let session = try NativePlaybackSession(options: [
            "directory-mode": "recursive",
            "directory-filter-types": "video",
        ])
        defer { session.close() }
        try await session.load(directory)

        let playlist = try #require(session.property("playlist")?.arrayValue)
        let orderedFiles = playlist.compactMap { $0.mapValue?["filename"]?.stringValue }
        #expect(
            orderedFiles
                == ["Clip 2.ts", "Clip 10.ts", "Nested/Clip 1.ts"].map {
                    directory.appendingPathComponent($0).path
                }
        )
        for (index, color) in [0, 2, 1].enumerated() {
            if index > 0 {
                try session.command(["playlist-play-index", String(index)])
            }
            try await eventually("directory plays entry \(index)") {
                session.property("playlist-playing-pos")?.integerValue == Int64(index)
                    && session.property("file-format")?.stringValue == "mpegts"
                    && session.property("video-out-params/w")?.integerValue == 176
            }
            try await expectPrimaryColor(color, session)
        }
    }

    @Test(arguments: ["ini", "url", "txt"])
    func `native reference shortcut and plaintext playlists open their relative media`(reader: String)
        async throws
    {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }

        let opening = "Opening clip.ts"
        let ending = "Ending clip.ts"
        try files.copyItem(
            at: TestPaths.testMedia("codecs-http-hls-00.ts"),
            to: directory.appendingPathComponent(opening)
        )
        try files.copyItem(
            at: TestPaths.testMedia("codecs-http-hls-02.ts"),
            to: directory.appendingPathComponent(ending)
        )
        let text =
            switch reader {
            case "ini": "[Reference]\nRef1=\(opening)\nRef2=\(ending)\n"
            case "url": "[InternetShortcut]\nURL=\"\(opening)\"\n"
            default: "\n\(opening)\n\n\(ending)\n"
            }
        let source = directory.appendingPathComponent("Playback.\(reader)")
        try Data(text.utf8).write(to: source)

        let session = try NativePlaybackSession()
        defer { session.close() }
        if reader == "txt" {
            try session.command(["loadlist", source.path, "replace"])
            try await eventually("the plaintext playlist opens its first picture") {
                session.property("video-out-params/w")?.integerValue != nil
            }
        } else {
            try await session.load(source)
        }

        let expected = reader == "url" ? [opening] : [opening, ending]
        let entries = try #require(session.property("playlist")?.arrayValue)
        #expect(
            entries.compactMap { $0.mapValue?["filename"]?.stringValue }
                == expected.map { directory.appendingPathComponent($0).path }
        )
        expectFormat("mpegts", session)
        try await expectPrimaryColor(0, session)
        if expected.count == 2 {
            try session.command(["playlist-play-index", "1"])
            try await expectPrimaryColor(2, session)
        }
    }

    @Test(arguments: [
        ("codecs-raw-frames.mjpg", "mjpeg", "2048"),
        ("codecs-raw-frames.h263p", "h263p", "1024"),
    ])
    func `native raw video uses the configured packet size and frame rate`(
        file: String,
        decoder: String,
        packetSize: String
    ) async throws {
        let session = try NativePlaybackSession(options: [
            "vd": "\(decoder),-",
            "demuxer": "rawvideo",
            "demuxer-rawvideo-codec": decoder,
            "demuxer-rawvideo-size": packetSize,
            "demuxer-rawvideo-w": "96",
            "demuxer-rawvideo-h": "64",
            "demuxer-rawvideo-fps": "8",
        ])
        defer { session.close() }
        try await session.load(TestPaths.testMedia(file))

        expectFormat("rawvideo", session)
        #expect(session.property("current-tracks/video/codec")?.stringValue == decoder)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == decoder)
        #expect(session.property("video-out-params/w")?.integerValue == 96)
        #expect(session.property("video-out-params/h")?.integerValue == 64)
        #expect(session.property("container-fps")?.doubleValue == 8)
        #expect(session.property("duration")?.doubleValue == 3)
        try await expectPrimaryColor(0, session)

        for (time, channel) in [(2.125, 2), (1.125, 1)] {
            try await seek(session, to: time)
            try await expectPrimaryColor(channel, session)
        }
    }

    @Test
    func `multi-file CUE follows INDEX 01 when changing sources`() async throws {
        let source = try TestPaths.testMedia("codecs-album-multi.cue")
        try await withDecodedPCM(source, options: ["ad": "flac,-"]) { session in
            expectFormat("cue/flac", session)
            let chapters = session.property("chapter-list")?.arrayValue ?? []
            #expect(
                chapters.compactMap { $0.mapValue?["title"]?.stringValue } == ["First file", "Second file"]
            )
            #expect(chapters.compactMap { $0.mapValue?["time"]?.doubleValue } == [0, 1])
        } checkPCM: { file, duration in
            #expect(abs(duration - 2) < 0.025)
            for (start, tone) in [(0.25, 440), (1.05, 880), (1.85, 880)] {
                try expectMonoTone(file, at: start, frequency: tone)
            }
        }
    }

    #if os(macOS)
    @Test(arguments: [
        ("aac-fixed.aac", "aac_at"),
        ("amr-nb.amr", "amr_nb_at"),
        ("ac3.ac3", "ac3_at"),
        ("eac3.eac3", "eac3_at"),
        ("alac.caf", "alac_at"),
        ("mpeg-layer1.mp1", "mp1_at"),
        ("mp2.mp2", "mp2_at"),
        ("mp3-fixed.mp3", "mp3_at"),
        ("alaw.wav", "pcm_alaw_at"),
        ("mulaw.wav", "pcm_mulaw_at"),
        ("ima-qt.mov", "adpcm_ima_qt_at"),
    ])
    func `AudioToolbox decoder produces the encoded tone`(file: String, decoder: String)
        async throws
    {
        let clip = try #require(try Catalog.load().audio.first { $0.file == "codecs-\(file)" })
        try await expectDecodedTone(clip, decoder: decoder)
    }
    #endif

    @Test(arguments: try Catalog.load().segmented)
    func `segmented playback seeks forward and backward across files`(stream: Stream) async throws {
        let session = try NativePlaybackSession()
        defer { session.close() }
        try await session.load(TestPaths.testMedia(stream.file))

        expectFormat(stream.format, session)
        #expect(session.property("current-tracks/video/codec")?.stringValue == "h264")
        for (time, channel) in [(2.25, 2), (0.25, 0), (1.25, 1)] {
            try await seek(session, to: time)
            try await expectPrimaryColor(channel, session)
        }
    }

    @Test(arguments: try Catalog.load().segmentedVideo)
    func `segmented video presents each authored picture`(clip: SegmentedClip) async throws {
        try await withSegmentedSource(clip) { source in
            let session = try NativePlaybackSession(options: ["vd": "\(clip.decoder),-", "audio": "no"])
            defer { session.close() }
            try await session.load(source)
            expectFormat(clip.format, session)
            #expect(session.property("current-tracks/video/codec")?.stringValue == clip.codec)
            #expect(session.property("current-tracks/video/decoder")?.stringValue == clip.decoder)
            #expect(session.property("video-dec-params/w")?.integerValue == 176)
            #expect(session.property("video-dec-params/h")?.integerValue == 144)
            for (time, color) in [(2.25, 2), (0.25, 0), (1.25, 1)] {
                try await seek(session, to: time)
                try await expectPrimaryColor(color, session)
            }
        }
    }

    @Test(arguments: try Catalog.load().segmentedAudio)
    func `segmented audio presents each authored tone`(clip: SegmentedClip) async throws {
        let duration = clip.file.contains("-packed-") ? 3.0 : 2.8
        try await withSegmentedSource(clip) { source in
            try await withDecodedPCM(source, options: ["ad": "\(clip.decoder),-", "vid": "no"]) {
                session in
                expectFormat(clip.format, session)
                #expect(session.property("current-tracks/audio/codec")?.stringValue == clip.codec)
                #expect(session.property("current-tracks/audio/decoder")?.stringValue == clip.decoder)
            } checkPCM: { file, decoded in
                try #require(abs(duration - decoded) < 0.15)
                for (time, tone) in [(0.25, 440), (1.25, 660), (2.25, 880)] {
                    try expectMonoTone(file, at: time, frequency: tone)
                }
            }
        }
    }

    @Test(arguments: try Catalog.load().networkStreams)
    func `HTTP streams seek across picture and audio segment boundaries`(stream: Stream) async throws {
        try await verifyNetworkStream(stream, secure: false)
    }

    @Test(arguments: try Catalog.load().networkStreams)
    func `HTTPS streams seek across picture and audio segment boundaries`(stream: Stream) async throws {
        try await verifyNetworkStream(stream, secure: true)
    }

    @Test
    func `HTTP progressive MP4 preserves decoded frames and audio across range reads`() async throws {
        let name = "baseline.mp4"
        let server = try LoopbackMediaServer(resources: httpResources([name]))
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent(name)
        let options = ["vd": "h264,-", "ad": "aac,-", "audio": "auto", "cache": "no"]
        let session = try NativePlaybackSession(options: options)
        defer { session.close() }
        try await session.load(url)
        expectFormat("mov", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        #expect(session.property("seekable")?.boolValue == true)
        let first = try screenshot(session)
        #expect(first.width == 360 && first.height == 640)

        try await seek(session, to: 10.0)
        try await eventually("different picture after the HTTP range seek") {
            try screenshot(session).sampledColors() != first.sampledColors()
        }
        try await seek(session, to: 0.0)
        try await eventually("opening picture after the HTTP range seek back") {
            try screenshot(session).sampledColors() == first.sampledColors()
        }
        #expect(server.requestedNonzeroRange(name))

        try await withDecodedPCM(url, options: options.merging(["vid": "no"]) { first, _ in first }) {
            audio in
            expectFormat("mov", audio)
            #expect(audio.property("current-tracks/audio/decoder")?.stringValue == "aac")
        } checkPCM: { file, duration in
            #expect(abs(duration - 12) < 0.1)
            for time in [0.5, 6.0, 11.5] {
                try expectMonoTone(file, at: time, frequency: 440)
            }
        }
    }

    @Test(arguments: ["hex", "data"])
    func `inline hex and data sources decode and seek like a file`(scheme: String) async throws {
        let bytes = try Data(contentsOf: TestPaths.testMedia("codecs-part-00.mp4"))
        let source =
            scheme == "hex"
                ? "hex://" + bytes.map { String(format: "%02x", $0) }.joined()
                : "data://video/mp4;base64," + bytes.base64EncodedString()
        let session = try NativePlaybackSession(options: ["vd": "h264,-", "cache": "no"])
        defer { session.close() }
        try await expectRedMP4ThroughSeek(#require(URL(string: source)), session)
    }

    @Test
    func `memory subtitle source preserves cue text and clear times`() async throws {
        let session = try NativePlaybackSession(options: ["vd": "h264,-", "sub-auto": "no"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("codecs-part-00.mp4"))
        let srt = "1\n00:00:00,250 --> 00:00:00,750\nInline cue\n"
        try session.command(["sub-add", "memory://" + srt, "select"])
        #expect(session.property("current-tracks/sub/codec")?.stringValue == "subrip")
        for (time, text) in [(0.5, "Inline cue"), (0.833333, "")] {
            try await seek(session, to: time)
            try await eventually("inline subtitle text at \(time) seconds") {
                (session.property("sub-text")?.stringValue ?? "") == text
            }
        }
    }

    @Test(arguments: [false, true])
    func `descriptor sources support seeks and respect ownership`(takeOwnership: Bool) async throws {
        let url = try TestPaths.testMedia("codecs-part-00.mp4")
        let file = try FileHandle(forReadingFrom: url)
        let fd = fcntl(file.fileDescriptor, F_DUPFD_CLOEXEC, 128)
        try #require(fd >= 0)
        defer {
            if fcntl(fd, F_GETFD) >= 0 {
                _ = Darwin.close(fd)
            }
            try? file.close()
        }

        do {
            let session = try NativePlaybackSession(options: ["vd": "h264,-", "cache": "no"])
            defer { session.close() }
            let scheme = takeOwnership ? "fdclose" : "fd"
            try await expectRedMP4ThroughSeek(#require(URL(string: "\(scheme)://\(fd)")), session)
        }
        #expect((fcntl(fd, F_GETFD) < 0) == takeOwnership)
    }

    @Test
    func `FFmpeg pipe preserves the authored AAC tone`() async throws {
        let bytes = try Data(contentsOf: TestPaths.testMedia("codecs-aac-lc.aac"))
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        let writer = pipe.fileHandleForWriting
        try #require(fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0)
        let transfer = Task.detached {
            defer { try? writer.close() }
            try writer.write(contentsOf: bytes)
        }
        defer {
            try? reader.close()
            transfer.cancel()
        }

        let url = try #require(URL(string: "ffmpeg://pipe:\(reader.fileDescriptor)"))
        try await withDecodedPCM(url, options: ["ad": "aac,-", "cache": "no"]) { session in
            expectFormat("aac", session)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == "aac")
            #expect(session.property("seekable")?.boolValue == false)
        } checkPCM: { file, duration in
            try #require(abs(duration - 1.25) < 0.1)
            for time in [0.05, 0.6, 1.05] {
                try expectMonoTone(file, at: time, frequency: 440)
            }
        }
        try await transfer.value
    }

    @Test(arguments: ["file", "lavf", "ffmpeg", "cache", "async"])
    func `file URL and input wrappers retain exact video seeks`(scheme: String) async throws {
        let clip = try TestPaths.testMedia("tls-ranges.mp4")
        let argument =
            switch scheme {
            case "file": clip.absoluteString
            case "lavf", "ffmpeg": "\(scheme)://file:\(clip.path)"
            default: "ffmpeg://\(scheme):file:\(clip.path)"
            }
        try await expectThreeColorMP4ThroughSeeks(argument, label: scheme)
    }

    @Test
    func `mpv URL resolves the nested HTTP video`() async throws {
        let name = "tls-ranges.mp4"
        let server = try LoopbackMediaServer(resources: httpResources([name]))
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent(name)
        let encoded = try #require(
            url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        try await expectThreeColorMP4ThroughSeeks("mpv://\(encoded)", label: "mpv URL")
        #expect(server.requested(name))
    }

    @Test(arguments: ["ipfs", "ipns"])
    func `IPFS gateway schemes request the named video and seek by range`(scheme: String) async throws {
        let clip = try Data(contentsOf: TestPaths.testMedia("tls-ranges.mp4"))
        let name = "fixture/video.mp4"
        let route = "\(scheme)/\(name)"
        let server = try LoopbackMediaServer(resources: [route: clip])
        defer { server.stop() }
        let gateway = try await server.start()

        try await expectThreeColorMP4ThroughSeeks(
            "\(scheme)://\(name)",
            label: scheme,
            options: [
                "stream-lavf-o": "gateway=\(gateway.absoluteString)"
            ]
        )
        #expect(server.requested(route))
        #expect(server.requestedNonzeroRange(route))
    }

    @Test
    func `FTP input authenticates and restarts at media offsets`() async throws {
        let media = try Data(contentsOf: TestPaths.testMedia("tls-ranges.mp4"))
        let server = try LoopbackFTPServer(media: media)
        defer { server.stop() }
        try await expectThreeColorMP4ThroughSeeks(server.start(), label: "FTP")
        #expect(server.restartedAtNonzeroOffset)
    }

    #if os(macOS)
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["MPVUI_TEST_SMB_SHARE"] != nil,
            "A loopback SMB fixture share is available"
        )
    )
    func `SMB authenticates and seeks through a Unicode path`() async throws {
        // The fixture share publishes tls-ranges.mp4 as Playback Ω.mp4 and requires fixture:loopback.
        let share = try #require(ProcessInfo.processInfo.environment["MPVUI_TEST_SMB_SHARE"])
        try #require(!share.isEmpty && !share.contains("/"))
        var components = URLComponents()
        components.scheme = "smb"
        components.host = "127.0.0.1"
        if let value = ProcessInfo.processInfo.environment["MPVUI_TEST_SMB_PORT"] {
            let port = try #require(UInt16(value))
            try #require(port > 0)
            components.port = Int(port)
        }
        components.user = "fixture"
        components.path = "/\(share)/Playback Ω.mp4"
        let options = ["network-timeout": "4"]

        do {
            components.password = "wrong"
            let session = try NativePlaybackSession(options: options)
            defer { session.close() }
            let invalid = try #require(components.url)
            try session.command(["loadfile", invalid.absoluteString])
            try await eventually("SMB rejects the wrong fixture password") {
                (session.consumeEndFileStatus() ?? 0) < 0
            }
        }

        components.password = "loopback"
        let url = try #require(components.url)
        try await expectThreeColorMP4ThroughSeeks(url.absoluteString, label: "SMB", options: options)
    }
    #endif

    @Test
    func `crypto input decrypts and seeks to authored frames`() async throws {
        let clip = try TestPaths.testMedia("tls-ranges.mp4.enc")
        let key = "000102030405060708090a0b0c0d0e0f"
        let iv = "101112131415161718191a1b1c1d1e1f"
        try await expectThreeColorMP4ThroughSeeks(
            "ffmpeg://crypto:file:\(clip.path)",
            label: "AES-128 CBC",
            options: [
                "stream-lavf-o": "key=\(key),iv=\(iv)"
            ]
        )
    }

    @Test
    func `FFmpeg shared cache retains exact video seeks`() async throws {
        let clip = try TestPaths.testMedia("tls-ranges.mp4")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shared-av-io-\(UUID())"
        )
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: cache) }

        try await expectThreeColorMP4ThroughSeeks(
            "ffmpeg://shared:file:\(clip.path)",
            label: "shared cache",
            options: [
                "stream-lavf-o": "cache_dir=\(cache.path)"
            ]
        )
        let entries = try FileManager.default.contentsOfDirectory(
            at: cache,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        let expectedExtensions: Set<String> = ["cache", "spacemap"]
        #expect(expectedExtensions.isSubset(of: Set(entries.map(\.pathExtension))))
        for entry in entries where expectedExtensions.contains(entry.pathExtension) {
            #expect(try (entry.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
        }
    }

    @Test
    func `growing PCM file decodes the appended tone`() async throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(
            "growing-\(UUID()).pcm"
        )
        let sampleRate = 48000
        func tone(_ frequency: Double) -> Data {
            let samples = (0 ..< sampleRate).map { frame in
                Int16(4096 * sin(2 * .pi * frequency * Double(frame) / Double(sampleRate))).littleEndian
            }
            return samples.withUnsafeBytes { Data($0) }
        }

        try tone(440).write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }

        let options = [
            "cache": "no",
            "demuxer": "rawaudio",
            "demuxer-rawaudio-channels": "mono",
            "demuxer-rawaudio-rate": String(sampleRate),
            "demuxer-rawaudio-format": "s16le",
            "ad": "pcm_s16le,-",
        ]
        try await withDecodedPCM(target, argument: "appending://\(target.path)", options: options) {
            session in
            expectFormat("rawaudio", session)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == "pcm_s16le")
        } duringPlayback: { session in
            try await eventually("the first PCM tone starts playing") {
                session.property("current-ao")?.stringValue == "pcm"
                    && session.property("time-pos")?.doubleValue != nil
            }
            let writer = try FileHandle(forWritingTo: target)
            defer { try? writer.close() }
            try writer.seekToEnd()
            try writer.write(contentsOf: tone(880))
        } checkPCM: { file, _ in
            #expect(file.length == 96000)
            try expectMonoTone(file, at: 0.4, frequency: 440)
            try expectMonoTone(file, at: 1.4, frequency: 880)
        }
    }

    @Test(arguments: ["absolute slice", "relative slice", "subfile"])
    func `bounded input preserves PCM without decoding trailing bytes`(kind: String) async throws {
        let source = try TestPaths.testMedia("codecs-aac-lc.aac")
        let clip = try Data(contentsOf: source)
        let start = 32 * 1024
        let end = start + clip.count
        let envelope = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: envelope) }
        try (Data(count: start) + clip + clip).write(to: envelope)
        let argument =
            switch kind {
            case "absolute slice": "slice://\(start)-\(end)@\(envelope.path)"
            case "relative slice": "slice://\(start)-+\(clip.count)@\(envelope.path)"
            default: "ffmpeg://subfile,,start,\(start),end,\(end),,:file:\(envelope.path)"
            }

        let baseline = try await withPCMOutput(source, options: ["ad": "aac,-", "audio-format": "s16"]) { session in
            expectFormat("aac", session)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == "aac")
        } checkFile: { url in
            let file = try AVAudioFile(forReading: url)
            try #require(abs(Double(file.length) / 48000 - 1.25) < 0.15)
            for time in [0.05, 0.55, 1.05] {
                try expectMonoTone(file, at: time, frequency: 440)
            }
            return try Data(contentsOf: url)
        }
        let bounded = try await withPCMOutput(
            envelope,
            argument: argument,
            options: ["ad": "aac,-", "audio-format": "s16"]
        ) { session in
            expectFormat("aac", session)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == "aac")
        } checkFile: {
            try Data(contentsOf: $0)
        }
        #expect(bounded == baseline, "\(kind) decodes exactly one copy of the source")
    }

    @Test(arguments: ["concat", "concatf", "edl"])
    func `concatenated inputs seek across the clip boundary`(scheme: String) async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let argument: String
        let format: String
        let secondTime: Double
        if scheme == "edl" {
            let paths = try ["codecs-part-00.mp4", "codecs-part-02.mp4"].map {
                try TestPaths.testMedia($0).path
            }
            argument = "edl://" + paths.map { "%\($0.utf8.count)%\($0),0,1" }.joined(separator: ";")
            format = "edl/mov"
            secondTime = 1.25
        } else {
            // One part holds the MOV index. The other holds the indexed media.
            let bytes = try Data(contentsOf: TestPaths.testMedia("tls-ranges.mp4"))
            let middle = bytes.count / 2
            let paths = try [bytes.prefix(middle), bytes.suffix(from: middle)].enumerated().map {
                index, part in
                let url = directory.appendingPathComponent("part-\(index).bin")
                try part.write(to: url)
                return "file:" + url.path
            }
            if scheme == "concatf" {
                let list = directory.appendingPathComponent("parts.txt")
                try Data((paths.joined(separator: "\n") + "\n").utf8).write(to: list)
                argument = "ffmpeg://concatf:file:\(list.path)"
            } else {
                argument = "ffmpeg://concat:" + paths.joined(separator: "|")
            }
            format = "mov"
            secondTime = 2.25
        }

        let session = try NativePlaybackSession(options: ["vd": "h264,-", "cache": "no"])
        defer { session.close() }
        try await session.load(argument: argument, named: scheme)
        expectFormat(format, session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        #expect(session.property("seekable")?.boolValue == true)
        for (time, channel) in [(secondTime, 2), (0.25, 0)] {
            try await seek(session, to: time)
            try await expectPrimaryColor(channel, session)
        }
    }

    @Test
    func `HTTPS playback verifies trust and credentials and seeks with byte ranges`() async throws {
        let name = "tls-ranges.mp4"
        let authorization = "Basic " + Data("fixture:loopback".utf8).base64EncodedString()
        let server = try LoopbackMediaServer(
            resources: httpResources([name]),
            identity: loopbackTLSIdentity(),
            authorization: authorization
        )
        defer { server.stop() }
        let base = try await server.start()
        let session = try NativePlaybackSession(options: [
            "vd": "h264,-",
            "tls-verify": "yes",
            "network-timeout": "4",
            "cache": "no",
        ])
        defer { session.close() }

        func authenticated(_ filename: String, password: String = "loopback") throws -> URL {
            var components = try #require(
                URLComponents(url: base.appendingPathComponent(filename), resolvingAgainstBaseURL: false)
            )
            components.user = "fixture"
            components.password = password
            return try #require(components.url)
        }

        func expectRejected(_ url: URL, cause: String) async throws {
            try session.command(["loadfile", url.absoluteString])
            var status: Int32?
            try await eventually("HTTPS load fails for \(cause)") {
                status = session.consumeEndFileStatus()
                return status != nil
            }
            #expect((status ?? 0) < 0)
        }

        let source = try authenticated(name)
        try await expectRejected(source, cause: "untrusted certificate")
        #expect(!server.requested(name))

        try session.command(["set", "tls-ca-file", TestPaths.testMedia("tls-loopback.pem").path])
        var wrongHost = try #require(URLComponents(url: source, resolvingAgainstBaseURL: false))
        wrongHost.host = "localhost"
        try await expectRejected(#require(wrongHost.url), cause: "certificate hostname mismatch")
        #expect(!server.requested(name))
        try await expectRejected(authenticated(name, password: "wrong"), cause: "invalid credentials")
        #expect(server.respondedWithError(401))
        try await expectRejected(authenticated("tls-missing.mp4"), cause: "missing file")
        #expect(server.respondedWithError(404))

        try await session.load(source)
        expectFormat("mov", session)
        #expect(session.property("seekable")?.boolValue == true)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        try await expectPrimaryColor(0, session)
        try await seek(session, to: 2.25)
        try await expectPrimaryColor(2, session)
        #expect(server.requestedNonzeroRange(name))
    }

    @Test
    func `HTTPS follows a redirect and seeks in the final resource`() async throws {
        let name = "tls-ranges.mp4"
        let redirect = "tls-redirect.mp4"
        let server = try LoopbackMediaServer(
            resources: httpResources([name]),
            identity: loopbackTLSIdentity(),
            redirects: [redirect: name]
        )
        let session = try NativePlaybackSession(options: [
            "vd": "h264,-",
            "tls-verify": "yes",
            "tls-ca-file": TestPaths.testMedia("tls-loopback.pem").path,
            "cache": "no",
            "network-timeout": "4",
        ])
        defer {
            session.close()
            server.stop()
        }

        try await session.load(server.start().appendingPathComponent(redirect))
        expectFormat("mov", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        try await expectPrimaryColor(0, session)
        try await seek(session, to: 2.25)
        try await expectPrimaryColor(2, session)
        #expect(server.requested(redirect))
        #expect(server.requestedNonzeroRange(name))
    }

    @Test
    func `HTTPS redirect chains recover after a loop and interrupted response`() async throws {
        let name = "tls-ranges.mp4"
        let destination = "tls-chain-final.mp4"
        let interrupted = "tls-interrupted.mp4"
        let entry = "tls-chain-start.mp4"
        let next = "tls-chain-next.mp4"
        let loop = "tls-loop.mp4"
        let loopNext = "tls-loop-next.mp4"
        let bytes = try Data(contentsOf: TestPaths.testMedia(name))
        let server = try LoopbackMediaServer(
            resources: [name: bytes, interrupted: bytes, destination: bytes],
            identity: loopbackTLSIdentity(),
            redirects: [entry: next, next: destination, loop: loopNext, loopNext: loop],
            cutoffs: [interrupted: .init(offset: 24, resume: false)]
        )
        let session = try NativePlaybackSession(options: [
            "vd": "h264,-",
            "tls-verify": "yes",
            "tls-ca-file": TestPaths.testMedia("tls-loopback.pem").path,
            "cache": "no",
            "network-timeout": "4",
            "stream-lavf-o": "reconnect_delay_max=0,reconnect_max_retries=1",
        ])
        defer {
            session.close()
            server.stop()
        }

        let base = try await server.start()
        try await session.load(base.appendingPathComponent(name))
        try await seek(session, to: 2.25)
        try await expectPrimaryColor(2, session)

        for path in [loop, interrupted] {
            try session.command(["loadfile", base.appendingPathComponent(path).absoluteString])
            try await eventually("HTTPS rejects \(path)", timeout: .seconds(10)) {
                (session.consumeEndFileStatus() ?? 0) < 0
            }
            #expect(server.requested(path))
        }
        #expect(server.requested(loopNext))
        #expect(server.requestedNonzeroRange(interrupted))
        #expect(!server.respondedWithError(404))

        try await session.load(base.appendingPathComponent(entry))
        expectFormat("mov", session)
        #expect(session.property("seekable")?.boolValue == true)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        try await expectPrimaryColor(0, session)
        try await seek(session, to: 1.25)
        try await expectPrimaryColor(1, session)
        try session.command(["set", "pause", "no"])
        try await eventually("the redirected resource reaches EOF") {
            session.property("eof-reached")?.boolValue == true
        }
        #expect(server.requested(entry))
        #expect(server.requested(next))
        #expect(server.requestedNonzeroRange(destination))
    }

    @Test
    func `HTTPS resumes a partial video response at the exact byte and reaches EOF`() async throws {
        let name = "tls-ranges.mp4"
        let bytes = try Data(contentsOf: TestPaths.testMedia(name))
        // The fixture reserves four MiB for its index. Cut inside the media data.
        let cutoff = (4 << 20) + 900
        try #require(bytes.count > cutoff)
        let server = try LoopbackMediaServer(
            resources: [name: bytes],
            identity: loopbackTLSIdentity(),
            cutoffs: [name: .init(offset: cutoff, resume: true)]
        )
        let session = try NativePlaybackSession(options: [
            "vd": "h264,-",
            "tls-verify": "yes",
            "tls-ca-file": TestPaths.testMedia("tls-loopback.pem").path,
            "cache": "no",
            "network-timeout": "4",
            "stream-lavf-o": "reconnect=1,reconnect_delay_max=0,reconnect_max_retries=2",
        ])
        defer {
            session.close()
            server.stop()
        }

        try await session.load(server.start().appendingPathComponent(name))
        expectFormat("mov", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        try await expectPrimaryColor(0, session)
        try session.command(["set", "pause", "no"])
        try await expectPrimaryColor(1, session)
        try await expectPrimaryColor(2, session)
        #expect(server.requestedRange(name, startingAt: cutoff))
        try await eventually("the resumed HTTPS item reaches EOF") {
            session.property("eof-reached")?.boolValue == true
        }
    }

    @Test(arguments: ["dav", "webdav", "davs", "webdavs"])
    func `WebDAV aliases preserve authenticated seekable playback`(scheme: String) async throws {
        let name = "tls-ranges.mp4"
        let secure = scheme.hasSuffix("s")
        let authorization = "Basic " + Data("fixture:loopback".utf8).base64EncodedString()
        let server = try LoopbackMediaServer(
            resources: httpResources([name]),
            identity: secure ? loopbackTLSIdentity() : nil,
            authorization: authorization
        )
        defer { server.stop() }
        let base = try await server.start()
        var components = try #require(
            URLComponents(url: base.appendingPathComponent(name), resolvingAgainstBaseURL: false)
        )
        components.scheme = scheme
        components.user = "fixture"
        components.password = "loopback"
        let source = try #require(components.url)
        let session = try NativePlaybackSession(options: [
            "vd": "h264,-",
            "tls-verify": "yes",
            "tls-ca-file": TestPaths.testMedia("tls-loopback.pem").path,
            "cache": "no",
            "network-timeout": "4",
        ])
        defer { session.close() }

        try await session.load(source)
        expectFormat("mov", session)
        #expect(session.property("seekable")?.boolValue == true)
        try await expectPrimaryColor(0, session)
        try await seek(session, to: 2.25)
        try await expectPrimaryColor(2, session)
        #expect(server.requestedNonzeroRange(name))
    }

    @Test
    func `live HLS recovers when its next segment is delayed`() async throws {
        try await verifyLiveHLS(secure: false)
    }

    @Test
    func `live HLS recovers across an HTTPS segment stall`() async throws {
        try await verifyLiveHLS(secure: true)
    }

    @Test
    func `seekable HLS preserves video and audio across two discontinuity markers`() async throws {
        try await verifyNetworkStream(
            Catalog.load().hlsDiscontinuities,
            secure: true,
            cycles: 3,
            seekPoints: [(2.75, 2), (3.25, 0), (4.25, 1), (5.75, 2), (6.25, 0), (8.25, 2), (0.25, 0)]
        )
    }

    @Test
    func `HLS reports early EOF when seeking past reset timestamps and recovers on reload`()
        async throws
    {
        let catalog = try Catalog.load()
        let stream = catalog.hlsTimestampResets
        let standard = catalog.hlsDiscontinuities
        let server = try LoopbackMediaServer(
            resources: httpResources([stream.file, standard.file] + stream.parts + standard.parts)
        )
        let session = try NativePlaybackSession(options: [
            "vd": "h264,-",
            "ad": "aac,-",
            "audio": "auto",
        ])
        defer {
            session.close()
            server.stop()
        }

        let base = try await server.start()
        try await session.load(base.appendingPathComponent(stream.file))
        expectFormat("hls", session)
        #expect(abs((session.property("duration")?.doubleValue ?? 0) - 9) < 0.1)
        try await seek(session, to: 2.75)
        try await expectPrimaryColor(2, session)

        // The current reader cannot map seeks into a segment whose clock restarted.
        try session.command(["seek", "3.25", "absolute+exact"])
        try await eventually("the reset timeline ends at the first discontinuity") {
            session.property("eof-reached")?.boolValue == true
        }
        let position = try #require(session.property("time-pos")?.doubleValue)
        #expect((2.75 ... 3.01).contains(position))

        try session.command(["stop"])
        try await eventually("the reset HLS item releases its frame") {
            session.property("video-out-params/w") == nil
        }
        try await session.load(base.appendingPathComponent(standard.file))
        try await seek(session, to: 4.25)
        try await expectPrimaryColor(1, session)
    }

    @Test
    func `live DASH reloads its manifest and presents the newly listed segment`() async throws {
        try await verifyLiveDASH(Catalog.load().liveDash)
    }

    @Test
    func `live DASH advances across a sliding segment window`() async throws {
        try await verifyLiveDASH(Catalog.load().liveDashSliding)
    }

    @Test
    func `live DASH advances across an HTTPS window rollover`() async throws {
        try await verifyLiveDASH(Catalog.load().liveDashSliding, secure: true)
    }

    @Test
    func `live DASH keeps video and audio advancing through two HTTPS window rollovers`() async throws {
        let stream = try Catalog.load().dashRollovers
        try #require(stream.manifests.count == 3 && stream.video.count == 7 && stream.audio.count == 7)
        let name = stream.manifests[0]
        let fragments = stream.video + stream.audio
        var updates = try stream.manifests.dropFirst().enumerated().map { index, filename in
            let preceding = 2 * (index + 1)
            return try LoopbackMediaServer.ResourceVersion(
                afterRequests: [stream.video[preceding], stream.audio[preceding]],
                bytes: Data(contentsOf: TestPaths.testMedia(filename))
            )
        }
        updates.append(
            LoopbackMediaServer.ResourceVersion(
                afterRequests: [stream.video[6], stream.audio[6]],
                bytes: nil
            )
        )
        let server = try LoopbackMediaServer(
            resources: httpResources([name] + fragments),
            identity: loopbackTLSIdentity(),
            versions: [name: updates]
        )
        defer { server.stop() }
        let source = try await server.start().appendingPathComponent(name)
        let options = try liveStreamingOptions(
            [
                "vd": "h264,-",
                "ad": "aac,-",
                "cache-pause": "no",
                "network-timeout": "4",
                "demuxer-lavf-o": "max_reload=8",
            ],
            secure: true
        )
        let tones = [440, 660, 880, 440, 660, 880]
        try await withDecodedPCM(source, options: options) { session in
            expectFormat("dash", session)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == "aac")
        } duringPlayback: { session in
            for index in tones.indices {
                let start = Double(index)
                try await eventually("live DASH frame in window \(index / 2 + 1) at \(start) seconds") {
                    let position = session.property("time-pos")?.doubleValue ?? -1
                    guard (start + 0.15 ..< start + 0.95).contains(position),
                          session.property("video-out-params/w")?.integerValue == 176
                    else { return false }

                    let frame = try screenshot(session)
                    return frame.isPrimaryColor(index % 3, x: frame.width / 2, y: frame.height / 2)
                }
                #expect(session.property("seekable")?.boolValue == false)
                #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
            }
        } checkPCM: { file, duration in
            try #require(abs(duration - 6.0) < 0.15)
            for (index, frequency) in tones.enumerated() {
                try expectMonoTone(file, at: Double(index) + 0.25, frequency: frequency)
            }
        }
        for fragment in fragments {
            #expect(server.requested(fragment), "mpv retrieved \(fragment)")
        }
        #expect(server.respondedWithError(410))
    }

    @Test(arguments: [("udp", "mpegts"), ("rtp", "rtp"), ("sdp", "sdp")])
    func `transport stream decodes over UDP, RTP and SDP`(scheme: String, reader: String) async throws {
        let transport = try Data(contentsOf: TestPaths.testMedia("codecs-datagrams.ts"))
        let port = try LoopbackTransport.availablePort()
        let description = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sdp")
        defer { try? FileManager.default.removeItem(at: description) }
        let source: URL
        if scheme == "sdp" {
            try LoopbackTransport.sessionDescription(port: port).write(
                to: description,
                atomically: true,
                encoding: .utf8
            )
            source = description
        } else {
            source = try #require(URL(string: "\(scheme)://127.0.0.1:\(port)"))
        }
        var options = transportOptions
        options["demuxer-lavf-o"] = "protocol_whitelist=[file,udp,rtp]"
        let session = try NativePlaybackSession(options: options)
        let sender = Task.detached {
            try await LoopbackTransport.send(transport, to: port, usesRTP: scheme != "udp")
        }
        defer {
            sender.cancel()
            session.close()
        }

        try await expectTransportPlayback(source, reader: reader, session: session)
    }

    @Test(.enabled(if: LoopbackTransport.supportsUDPLite, "The kernel supports UDP-Lite sockets"))
    func `UDP Lite delivers the transport stream`() async throws {
        let transport = try Data(contentsOf: TestPaths.testMedia("codecs-datagrams.ts"))
        let protocolNumber = LoopbackTransport.udpLiteProtocol
        let port = try LoopbackTransport.availablePort(ipProtocol: protocolNumber)
        let source = try #require(URL(string: "udplite://127.0.0.1:\(port)"))
        let options = transportOptions.merging(["network-timeout": "4"]) { _, new in new }
        let session = try NativePlaybackSession(options: options)
        let sender = Task.detached {
            try await LoopbackTransport.send(
                transport,
                to: port,
                usesRTP: false,
                ipProtocol: protocolNumber
            )
        }
        defer {
            sender.cancel()
            session.close()
        }

        try await expectTransportPlayback(source, reader: "mpegts", session: session)
    }

    #if os(macOS)
    @Test
    func `DTLS delivers the authenticated transport stream`() async throws {
        let transport = try Data(contentsOf: TestPaths.testMedia("codecs-datagrams.ts"))
        let options = try transportOptions.merging([
            "network-timeout": "4",
            "tls-verify": "yes",
            "tls-ca-file": TestPaths.testMedia("tls-loopback.pem").path,
        ]) { _, new in new }
        let server = LoopbackDTLSServer()
        let session = try NativePlaybackSession(options: options)
        defer {
            session.close()
            server.stop()
        }

        try await expectTransportPlayback(
            server.start(transport: transport),
            reader: "mpegts",
            session: session
        )
    }
    #endif

    @Test(arguments: [false, true])
    func `transport stream decodes over TCP and TLS`(secure: Bool) async throws {
        let transport = try Data(contentsOf: TestPaths.testMedia("codecs-datagrams.ts"))
        let server = try LoopbackMediaServer(
            identity: secure ? loopbackTLSIdentity() : nil,
            rawStream: transport
        )
        let options = transportOptions.merging([
            "network-timeout": "4",
            "tls-verify": "yes",
        ]) { _, new in new }
        let session = try NativePlaybackSession(options: options)
        defer {
            session.close()
            server.stop()
        }

        try await expectTransportPlayback(
            server.start(),
            reader: "mpegts",
            session: session,
            verifyTrust: secure
        )
    }

    @Test(arguments: [false, true])
    func `Gopher and Gophers selectors deliver a decoded transport stream`(secure: Bool) async throws {
        let name = "codecs-datagrams.ts"
        let transport = try Data(contentsOf: TestPaths.testMedia(name))
        let server = try LoopbackMediaServer(
            identity: secure ? loopbackTLSIdentity() : nil,
            rawStream: transport,
            gopherSelector: name
        )
        let options = transportOptions.merging([
            "network-timeout": "4",
            "tls-verify": "yes",
        ]) { _, new in new }
        let session = try NativePlaybackSession(options: options)
        defer {
            session.close()
            server.stop()
        }
        let source = try await server.start().appendingPathComponent("9").appendingPathComponent(name)

        try await expectTransportPlayback(
            source,
            reader: "mpegts",
            session: session,
            verifyTrust: secure
        )
        #expect(server.requested(name))
    }

    @Test(arguments: [false, true])
    func `RTMP and RTMPS deliver the authored FLV`(secure: Bool) async throws {
        try await expectRTMP(secure: secure, tunneled: false)
    }

    @Test(arguments: [false, true])
    func `RTMPT and RTMPTS deliver the authored FLV`(secure: Bool) async throws {
        try await expectRTMP(secure: secure, tunneled: true)
    }

    #if os(macOS)
    @Test(arguments: [false, true])
    func `RTMPE and RTMPTE negotiate encrypted playback`(tunneled: Bool) async throws {
        let server = LoopbackEncryptedRTMPServer()
        let session = try NativePlaybackSession(options: rtmpOptions)
        defer {
            session.close()
            server.stop()
        }

        try await expectTransportPlayback(
            server.start(tunneled: tunneled),
            reader: "flv",
            session: session,
            seekable: true
        )
    }
    #endif

    @Test(arguments: ["mmsh", "mms", "mmshttp"])
    func `Windows Media HTTP schemes select both ASF tracks`(scheme: String) async throws {
        let name = "codecs-windows-media.wmsp"
        let server = try LoopbackMediaServer(resources: httpResources([name]))
        let session = try NativePlaybackSession(options: transportOptions)
        defer {
            session.close()
            server.stop()
        }
        let base = try await server.start()
        var components = try #require(
            URLComponents(url: base.appendingPathComponent(name), resolvingAgainstBaseURL: false)
        )
        components.scheme = scheme
        let source = try #require(components.url)

        try await expectTransportPlayback(source, reader: "asf", session: session, seekable: true)
        let pragmas = server.pragmas(for: name)
        #expect(pragmas.contains { $0.contains("request-context=1") })
        #expect(pragmas.contains("xPlayStrm=1"))
        #expect(pragmas.contains("stream-switch-count=2"))
    }

    @Test
    func `Windows Media TCP selects both ASF tracks`() async throws {
        let wmsp = try Data(contentsOf: TestPaths.testMedia("codecs-windows-media.wmsp"))
        let server = try LoopbackMMSTServer(wmsp: wmsp)
        let options = transportOptions.merging(["keep-open": "no"]) { _, new in new }
        let session = try NativePlaybackSession(options: options)
        defer {
            session.close()
            server.stop()
        }

        try await expectTransportPlayback(server.start(), reader: "asf", session: session)
        var status: Int32?
        try await eventually("Windows Media TCP reports EOF after the last packet") {
            status = session.consumeEndFileStatus()
            return status != nil
        }
        #expect(status == 0)
    }

    @Test
    func `Unix domain socket delivers the transport stream`() async throws {
        #if targetEnvironment(simulator)
        // CoreSimulator's absolute app-container path alone can exceed sockaddr_un.sun_path.
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        #else
        let directory = FileManager.default.temporaryDirectory
        #endif
        let socket = directory.appendingPathComponent("mpv-\(UUID().uuidString.prefix(12))")
        let transport = try Data(contentsOf: TestPaths.testMedia("codecs-datagrams.ts"))
        let server = try LoopbackMediaServer(rawStream: transport, socketPath: socket.path)
        let session = try NativePlaybackSession(options: transportOptions)
        defer {
            session.close()
            server.stop()
            try? FileManager.default.removeItem(at: socket)
        }

        try await expectTransportPlayback(server.start(), reader: "mpegts", session: session)
    }

    @Test
    func `HTTP CONNECT tunnel delivers the transport stream`() async throws {
        let authority = "fixture.invalid:80"
        let transport = try Data(contentsOf: TestPaths.testMedia("codecs-datagrams.ts"))
        let server = try LoopbackMediaServer(resources: [authority: transport])
        let session = try NativePlaybackSession(options: transportOptions)
        defer {
            session.close()
            server.stop()
        }
        let base = try await server.start().appendingPathComponent(authority)
        var components = try #require(URLComponents(url: base, resolvingAgainstBaseURL: false))
        components.scheme = "httpproxy"
        try await expectTransportPlayback(#require(components.url), reader: "mpegts", session: session)
        #expect(server.requested(authority))
    }

    @Test(arguments: ["mp3adu", "mp3adufloat"])
    func `MPEG audio ADU decoders preserve the RTP tone`(decoder: String) async throws {
        let encoded = try Data(contentsOf: TestPaths.testMedia("codecs-reservoir-free.mp3"))
        let port = try LoopbackTransport.availablePort()
        let description = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sdp")
        defer { try? FileManager.default.removeItem(at: description) }
        try LoopbackTransport.mpegAudioADUSessionDescription(port: port).write(
            to: description,
            atomically: true,
            encoding: .utf8
        )

        let options = [
            "ad": "\(decoder),-",
            "vid": "no",
            "cache": "no",
            "end": "1.2",
            "demuxer-lavf-o": "protocol_whitelist=[file,udp,rtp]",
            "demuxer-lavf-probesize": "4096",
            "demuxer-lavf-analyzeduration": "0.2",
        ]
        let sender = Task.detached { try await LoopbackTransport.sendMPEGAudioADU(encoded, to: port) }
        defer { sender.cancel() }
        try await withDecodedPCM(description, options: options) { session in
            expectFormat("sdp", session)
            #expect(session.property("current-tracks/audio/codec")?.stringValue == "mp3adu")
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == decoder)
            #expect(session.property("seekable")?.boolValue == false)
        } checkPCM: { file, duration in
            try #require(abs(duration - 1.2) < 0.1)
            for start in [0.05, duration / 2, duration - 0.15] {
                try expectMonoTone(file, at: start, frequency: 440)
            }
        }
    }

    @Test
    func `RTSP negotiates interleaved transport and decodes it`() async throws {
        let transport = try Data(contentsOf: TestPaths.testMedia("codecs-datagrams.ts"))
        let server = try LoopbackRTSPServer(transport: transport)
        let session = try NativePlaybackSession(
            options: transportOptions.merging(["rtsp-transport": "tcp"]) { _, new in new }
        )
        defer {
            server.stop()
            session.close()
        }

        try await expectTransportPlayback(server.start(), reader: "rtsp", session: session)
    }

    @Test
    func `RTSPS negotiates interleaved transport over trusted TLS`() async throws {
        let transport = try Data(contentsOf: TestPaths.testMedia("codecs-datagrams.ts"))
        let server = try LoopbackRTSPServer(transport: transport, identity: loopbackTLSIdentity())
        let options = try transportOptions.merging([
            "rtsp-transport": "tcp",
            "tls-verify": "yes",
            "tls-ca-file": TestPaths.testMedia("tls-loopback.pem").path,
        ]) { _, new in new }
        let session = try NativePlaybackSession(options: options)
        defer {
            session.close()
            server.stop()
        }

        try await expectTransportPlayback(server.start(), reader: "rtsp", session: session)
    }

    @Test(arguments: [false, true])
    func `interleaved RTSP reconnects after the server drops a session`(secure: Bool) async throws {
        let transport = try Data(contentsOf: TestPaths.testMedia("codecs-datagrams.ts"))
        let server = try LoopbackRTSPServer(
            transport: transport,
            identity: secure ? loopbackTLSIdentity() : nil
        )
        let options = try liveStreamingOptions(
            transportOptions.merging([
                "rtsp-transport": "tcp",
                "network-timeout": "2",
            ]) { _, new in new },
            secure: secure
        )
        let session = try NativePlaybackSession(options: options)
        defer {
            session.close()
            server.stop()
        }

        let source = try await server.start()
        try await expectTransportPlayback(source, reader: "rtsp", session: session)
        #expect(server.playRequests == 1)
        server.disconnect()
        try await eventually("the dropped RTSP connection ends playback") {
            session.property("eof-reached")?.boolValue == true || session.consumeEndFileStatus() != nil
        }
        try session.command(["stop"])
        try await eventually("the old RTSP frame is released") {
            session.property("video-out-params/w") == nil
        }
        try session.command(["set", "pause", "yes"])
        try await expectTransportPlayback(source, reader: "rtsp", session: session)
        #expect(server.playRequests == 2)
    }

    @Test(arguments: try Catalog.load().rtpAudio.filter { !$0.androidOnly }, ["rtp", "sdp", "rtsp"])
    func `elementary RTP audio decodes through each reader`(clip: RTPAudioFixture, reader: String)
        async throws
    {
        let encoded = try Data(contentsOf: TestPaths.testMedia(clip.file))
        let options = [
            "ad": "\(clip.decoder),-",
            "vid": "no",
            "cache": "no",
            "end": "1.2",
            "rtsp-transport": "tcp",
            "demuxer-lavf-o": "protocol_whitelist=[file,udp,rtp,tcp]",
            "demuxer-lavf-probesize": "4096",
            "demuxer-lavf-analyzeduration": "0.2",
        ]

        func check(_ source: URL) async throws {
            try await withDecodedPCM(source, options: options) { session in
                expectFormat(reader, session)
                #expect(session.property("current-tracks/audio/codec")?.stringValue == clip.codec)
                #expect(session.property("current-tracks/audio/decoder")?.stringValue == clip.decoder)
                #expect(session.property("seekable")?.boolValue == false)
            } checkPCM: { samples, duration in
                try #require(abs(duration - 1.2) < 0.12)
                for start in [0.08, 0.5, 0.95] {
                    try expectMonoTone(samples, at: start, frequency: 440)
                }
            }
        }

        if reader == "rtsp" {
            let server = try LoopbackRTSPServer(audio: clip, encoded: encoded)
            defer { server.stop() }
            try await check(server.start())
        } else {
            let port = try LoopbackTransport.availablePort()
            let sender = Task.detached { try await LoopbackTransport.send(encoded, as: clip, to: port) }
            defer { sender.cancel() }
            if reader == "sdp" {
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sdp")
                defer { try? FileManager.default.removeItem(at: path) }
                let description = LoopbackTransport.sessionDescription(
                    port: port,
                    media: "audio",
                    payload: clip.payloadType,
                    encoding: clip.encoding
                )
                try description.write(to: path, atomically: true, encoding: .utf8)
                try await check(path)
            } else {
                try await check(#require(URL(string: "rtp://127.0.0.1:\(port)")))
            }
        }
    }

    @Test(
        arguments: try Catalog.load().rtpVideo.filter { !$0.androidOnly }.flatMap { clip in
            clip.readers.map { (clip, $0) }
        }
    )
    func `packetized RTP video presents both authored pictures`(
        clip: RTPRecordingFixture,
        reader: String
    ) async throws {
        try await withRTPRecording(clip, reader: reader) { source in
            var options = rtpRecordingOptions
            options["vd"] = "\(clip.decoder),-"
            let session = try NativePlaybackSession(options: options)
            defer { session.close() }
            try await session.load(source)
            expectFormat(reader, session)
            #expect(session.property("current-tracks/video/codec")?.stringValue == clip.codec)
            #expect(session.property("current-tracks/video/decoder")?.stringValue == clip.decoder)
            #expect(session.property("seekable")?.boolValue == false)
            let width = try #require(clip.width)
            let height = try #require(clip.height)
            #expect(session.property("video-out-params/w")?.integerValue == Int64(width))
            #expect(session.property("video-out-params/h")?.integerValue == Int64(height))

            try session.command(["set", "pause", "no"])
            try await expectPrimaryColor(0, session)
            let red = try #require(session.property("time-pos")?.doubleValue)
            try await eventually("\(clip.file) through \(reader) reaches the blue half") {
                guard (session.property("time-pos")?.doubleValue ?? red) > red else { return false }

                let frame = try screenshot(session)
                return frame.isPrimaryColor(2, x: frame.width / 2, y: frame.height / 2)
            }
        }
    }

    @Test(
        arguments: try Catalog.load().rtpPacketizedAudio.filter { !$0.androidOnly }.flatMap { clip in
            clip.readers.map { (clip, $0) }
        }
    )
    func `packetized RTP audio produces the authored tone`(clip: RTPRecordingFixture, reader: String)
        async throws
    {
        try await expectPacketizedAudio(clip, reader: reader)
    }

    @Test(arguments: try Catalog.load().srtpAudio)
    func `SDP authenticates encrypted RTP and decodes its tone`(clip: RTPRecordingFixture)
        async throws
    {
        try await expectPacketizedAudio(clip, reader: "sdp")
    }

    @Test
    func `SRTP opens authenticated MPEG transport directly`() async throws {
        let clip = try Catalog.load().srtpTransport
        let recording = try Data(contentsOf: TestPaths.testMedia(clip.file))
        let port = try LoopbackTransport.availablePort()
        let sender = Task.detached { try await LoopbackTransport.send(recording, as: clip, to: port) }
        defer { sender.cancel() }
        let options = try transportOptions.merging([
            "stream-lavf-o": #require(clip.inputOptions),
            "demuxer-lavf-format": "mpegts",
            "network-timeout": "4",
        ]) { _, new in new }
        let session = try NativePlaybackSession(options: options)
        defer { session.close() }

        try await expectTransportPlayback(
            #require(URL(string: "srtp://127.0.0.1:\(port)")),
            reader: "mpegts",
            session: session
        )
    }

    @Test(arguments: [("p5", 5), ("p81", 8)])
    func `Dolby Vision through fragmented HLS matches the direct mpv control`(
        profile: String,
        profileID: Int
    ) async throws {
        let name = "dolby-vision-\(profile)-hls"
        let playlist = "\(name).m3u8"
        let files = [playlist, "\(name)-init.mp4"] + (0 ... 3).map { "\(name)-0\($0).m4s" }
        let server = try LoopbackMediaServer(resources: httpResources(files))
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent(playlist)
        let session = try NativePlaybackSession(options: ["vd": "hevc,-"])
        defer { session.close() }
        let times = [0.75, 3.25, 5.75, 8.25]

        func frameDifference(_ first: [UInt8], _ second: [UInt8]) -> Double {
            let total = zip(first, second).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            return Double(total) / Double(first.count)
        }

        try await session.load(TestPaths.testMedia("\(name).mp4"))
        expectFormat("mov", session)
        try await eventually("initial MP4 frame is ready") { session.consumePlaybackRestart() }
        var direct: [[UInt8]] = []
        for time in times {
            let previous = try screenshot(session).sampledColors()
            // The edit list trims two pictures that the HLS muxer restores.
            try await seek(session, to: time - 2 * 1001.0 / 24000)
            // The playback clock can reach the seek target before screenshot-raw sees the new frame.
            try await eventually("MP4 displays the reference frame for \(time) seconds") {
                try frameDifference(previous, screenshot(session).sampledColors()) > 1
            }
            try direct.append(screenshot(session).sampledColors())
        }

        try await session.load(url)
        expectFormat("hls", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "hevc")
        #expect(session.property("current-tracks/video/dolby-vision-profile")?.integerValue == Int64(profileID))
        for index in [0, 2, 1, 3, 0, 3] {
            try await seek(session, to: times[index])
            try await eventually("Dolby Vision picture matches paired MP4 control in fragment \(index)") {
                try frameDifference(screenshot(session).sampledColors(), direct[index]) < 2
            }
        }
        try session.command(["set", "pause", "no"])
        try await eventually("Dolby Vision HLS reaches EOF") {
            session.property("eof-reached")?.boolValue == true
        }
        #expect((session.property("time-pos")?.doubleValue ?? 0) > 9.75)
        for file in files {
            #expect(server.requested(file))
        }
    }

    @Test
    func `HTTP HLS starts at the requested bitrate and switches video rendition`() async throws {
        let stream = try Catalog.load().hlsRenditions
        let server = try LoopbackMediaServer(resources: httpResources([stream.file] + stream.parts))
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent(stream.file)
        let session = try NativePlaybackSession(options: [
            "vd": "h264,-",
            "ad": "aac,-",
            "audio": "auto",
            "hls-bitrate": "min",
        ])
        defer { session.close() }

        try await session.load(url)
        expectFormat(stream.format, session)
        let low = try #require(session.property("current-tracks/video/id")?.integerValue)
        #expect(session.property("current-tracks/video/hls-bitrate")?.integerValue == 150_000)
        #expect(session.property("video-out-params/w")?.integerValue == 176)
        try await expectPrimaryColor(0, session)

        let tracks = try #require(session.property("track-list")?.arrayValue)
        let highTrack = try #require(
            tracks.compactMap(\.mapValue).first {
                $0["type"]?.stringValue == "video" && $0["hls-bitrate"]?.integerValue == 500_000
            }
        )
        let high = try #require(highTrack["id"]?.integerValue)
        let switches: [(Int64, Int64, Double, Int)] = [(high, 352, 2.25, 2), (low, 176, 1.25, 1)]
        for (id, width, time, color) in switches {
            try session.command(["set", "vid", String(id)])
            try await seek(session, to: time)
            try await eventually("selected HLS rendition presents its coded width") {
                session.property("current-tracks/video/id")?.integerValue == id
                    && session.property("video-out-params/w")?.integerValue == width
            }
            try await expectPrimaryColor(color, session)
        }
        #expect(session.property("current-tracks/audio/decoder")?.stringValue == "aac")
        for playlist in stream.parts where playlist.hasSuffix(".m3u8") {
            #expect(server.requested(playlist))
        }
        let highTail = try #require(stream.parts.last)
        #expect(server.requested(highTail))
    }

    @Test
    func `HTTP DASH switches representations within the same adaptation set`() async throws {
        try await verifyDASHVideoSelection(Catalog.load().dashRenditions)
    }

    @Test
    func `HTTP DASH switches video across adaptation sets`() async throws {
        try await verifyDASHVideoSelection(Catalog.load().dashAdaptationSets)
    }

    @Test
    func `HTTP DASH switches audio across adaptation sets`() async throws {
        let stream = try Catalog.load().dashAudioAdaptationSets
        let server = try LoopbackMediaServer(resources: httpResources([stream.file] + stream.parts))
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent(stream.file)
        let options = ["vd": "h264,-", "ad": "aac,-", "audio": "1"]

        do {
            let session = try NativePlaybackSession(options: options)
            defer { session.close() }
            try await session.load(url)
            expectFormat("dash", session)
            let video = try #require(session.property("current-tracks/video/id")?.integerValue)
            let tracks = try #require(session.property("track-list")?.arrayValue)
            let audio = tracks.compactMap(\.mapValue).filter { $0["type"]?.stringValue == "audio" }
            #expect(audio.compactMap { $0["id"]?.integerValue } == [1, 2])
            for (id, color) in [(1, 0), (2, 2), (1, 1)] {
                try session.command(["set", "aid", String(id)])
                try await seek(session, to: Double(color) + 0.25)
                try await eventually("DASH selects audio track \(id)") {
                    session.property("current-tracks/audio/id")?.integerValue == Int64(id)
                        && session.property("current-tracks/audio/decoder")?.stringValue == "aac"
                }
                #expect(session.property("current-tracks/video/id")?.integerValue == video)
                try await expectPrimaryColor(color, session)
            }
        }

        for (id, tones) in [(1, [440, 660, 880]), (2, [990, 990, 990])] {
            try await withDecodedPCM(url, options: ["vid": "no", "audio": String(id), "ad": "aac,-"]) {
                session in
                expectFormat("dash", session)
                #expect(session.property("current-tracks/audio/id")?.integerValue == Int64(id))
                #expect(session.property("current-tracks/audio/decoder")?.stringValue == "aac")
            } checkPCM: { pcm, duration in
                try #require(abs(duration - 3.0) < 0.15)
                for (segment, tone) in tones.enumerated() {
                    try expectMonoTone(pcm, at: Double(segment) + 0.25, frequency: tone)
                }
            }
        }
        #expect(server.requested("codecs-http-dash-1-02.m4s"))
        #expect(server.requested("codecs-dash-audio-alt-03.m4s"))
    }

    @Test(arguments: Self.hardwareVideoInputs)
    func `VideoToolbox requests present successive authored frames`(
        file: String,
        decoder: String,
        codec: CMVideoCodecType,
        width: Int,
        height: Int
    ) async throws {
        let advertised = VTIsHardwareDecodeSupported(codec)
        let preferred = decoder == "av1" && !advertised ? "libdav1d" : decoder
        var options = [
            "hwdec": "videotoolbox-copy",
            "hwdec-codecs": decoder,
        ]
        if preferred == decoder {
            options["vd"] = "\(decoder),-"
        }
        let session = try NativePlaybackSession(options: options)
        defer { session.close() }
        try await session.load(TestPaths.testMedia(file))

        let route = try #require(session.property("hwdec-current")?.stringValue)
        #expect(route == "videotoolbox-copy" || route == "no")
        if advertised {
            #expect(route == "videotoolbox-copy")
        }
        #expect(session.property("current-tracks/video/codec")?.stringValue == decoder)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == preferred)
        let first = try screenshot(session)
        #expect(first.width == width && first.height == height)
        let initial = try #require(session.property("time-pos")?.doubleValue)
        try session.command(["frame-step"])
        try await eventually("\(file) displays a later frame") {
            (session.property("time-pos")?.doubleValue ?? initial) > initial
        }
        let next = try screenshot(session)
        #expect(first.pixels != next.pixels)
        #expect(session.property("hwdec-current")?.stringValue == route)
        print(
            "Decode route for \(file) = \(route), decoder = \(preferred), hardware advertised = \(advertised)"
        )
    }

    @Test
    func `MPEG transport stream switches between two authored programs`() async throws {
        let source = try TestPaths.testMedia("codecs-two-programs.ts")
        do {
            let session = try NativePlaybackSession(options: [
                "audio": "auto",
                "ad": "aac,mp2float,-",
                "vd": "h264,mpeg2video,-",
                "hr-seek-demuxer-offset": "0.65",
            ])
            defer { session.close() }
            try await session.load(source)

            expectFormat("mpegts", session)
            #expect(session.property("seekable")?.boolValue == true)
            #expect(session.property("track-list/count")?.integerValue == 4)
            #expect(session.property("current-tracks/video/program-id")?.integerValue == 101)
            #expect(session.property("current-tracks/audio/program-id")?.integerValue == 101)

            for (id, program, time, color, width) in [(2, 202, 2.25, 2, 352), (1, 101, 1.25, 0, 176)] {
                try session.command(["set", "vid", String(id)])
                try session.command(["set", "aid", String(id)])
                try await seek(session, to: time)
                #expect(session.property("current-tracks/video/program-id")?.integerValue == Int64(program))
                #expect(session.property("current-tracks/audio/program-id")?.integerValue == Int64(program))
                #expect(
                    session.property("current-tracks/video/decoder")?.stringValue
                        == (id == 1 ? "h264" : "mpeg2video")
                )
                #expect(
                    session.property("current-tracks/audio/decoder")?.stringValue
                        == (id == 1 ? "aac" : "mp2float")
                )
                #expect(session.property("video-out-params/w")?.integerValue == Int64(width))
                try await expectPrimaryColor(color, session)
            }
        }

        for (id, program, decoder, frequency) in [(1, 101, "aac", 440), (2, 202, "mp2float", 880)] {
            try await withDecodedPCM(
                source,
                options: ["vid": "no", "audio": String(id), "ad": "\(decoder),-"]
            ) { audio in
                expectFormat("mpegts", audio)
                #expect(audio.property("current-tracks/audio/program-id")?.integerValue == Int64(program))
                #expect(audio.property("current-tracks/audio/decoder")?.stringValue == decoder)
            } checkPCM: { pcm, duration in
                #expect(abs(duration - 3) < 0.1)
                for time in [0.15, 1.25, 2.75] {
                    try expectMonoTone(pcm, at: time, frequency: frequency)
                }
            }
        }
    }

    @Test
    func `MPEG transport stream keeps the primary program across PAT updates`() async throws {
        let source = try TestPaths.testMedia("codecs-changing-programs.ts")
        let session = try NativePlaybackSession(options: [
            "ad": "aac,-",
            "vd": "h264,-",
            "audio": "auto",
            "cache": "no",
            "demuxer-lavf-probesize": "32768",
            "demuxer-lavf-analyzeduration": "0.2",
        ])
        defer { session.close() }
        try await session.load(source)
        expectFormat("mpegts", session)
        #expect(session.property("track-list/count")?.integerValue == 2)
        try await expectPrimaryColor(0, session)

        try session.command(["set", "pause", "no"])
        try await eventually("MPEG-TS discovers the late program") {
            session.property("track-list/count")?.integerValue == 4
        }
        try await expectPrimaryColor(1, session)
        try await expectPrimaryColor(2, session)
        #expect(session.property("current-tracks/video/program-id")?.integerValue == 101)
        #expect(session.property("current-tracks/audio/program-id")?.integerValue == 101)
        try await eventually("MPEG-TS finishes after the late program leaves") {
            session.property("eof-reached")?.boolValue == true
        }
        #expect((session.property("time-pos")?.doubleValue ?? 0) > 8.8)

        try await withDecodedPCM(source, options: ["vid": "no", "audio": "1", "ad": "aac,-"]) { audio in
            expectFormat("mpegts", audio)
            #expect(audio.property("current-tracks/audio/program-id")?.integerValue == 101)
        } checkPCM: { pcm, duration in
            #expect(abs(duration - 9) < 0.15)
            for (time, frequency) in [(0.25, 440), (2.75, 440), (3.25, 550), (5.75, 550), (6.25, 660), (8.75, 660)] {
                try expectMonoTone(pcm, at: time, frequency: frequency)
            }
        }
    }

    @Test
    func `MPEG transport stream keeps its timeline across a 33-bit PTS wrap`() async throws {
        let source = try TestPaths.testMedia("codecs-pts-wrap.ts")
        let session = try NativePlaybackSession(options: [
            "audio": "auto",
            "ad": "aac,-",
            "vd": "h264,-",
            "hr-seek-demuxer-offset": "0.65",
        ])
        defer { session.close() }
        try await session.load(source)

        expectFormat("mpegts", session)
        #expect(session.property("seekable")?.boolValue == true)
        #expect(abs((session.property("duration")?.doubleValue ?? 0) - 3) < 0.1)
        for (time, color) in [(0.25, 0), (2.25, 2), (0.75, 0)] {
            try await seek(session, to: time)
            try await expectPrimaryColor(color, session)
        }
        try session.command(["set", "pause", "no"])
        try await expectPrimaryColor(2, session)
        try await eventually("MPEG-TS reaches EOF after PTS wraps") {
            session.property("eof-reached")?.boolValue == true
        }

        try await withDecodedPCM(source, options: ["vid": "no", "ad": "aac,-"]) { audio in
            expectFormat("mpegts", audio)
            #expect(audio.property("current-tracks/audio/decoder")?.stringValue == "aac")
        } checkPCM: { pcm, duration in
            #expect(abs(duration - 3) < 0.1)
            for time in [0.2, 0.95, 1.05, 2.75] {
                try expectMonoTone(pcm, at: time, frequency: 440)
            }
        }
    }

    @Test(arguments: try Catalog.load().paired)
    func `paired streams decode on either side of the same boundary`(pair: Pair) async throws {
        let media = try TestPaths.testMedia(pair.file)
        let session = try NativePlaybackSession(options: pair.decoderOptions)
        defer { session.close() }
        try await session.load(media)

        expectFormat(pair.format, session)
        #expect(session.property("current-tracks/video/codec")?.stringValue == pair.videoCodec)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == pair.videoDecoder)
        #expect(session.property("current-tracks/audio/codec")?.stringValue == pair.audioCodec)
        #expect(session.property("current-tracks/audio/decoder")?.stringValue == pair.audioDecoder)

        for (time, color) in [(0.25, 0), (1.25, 1), (0.75, 0), (1.75, 1)] {
            try await seek(session, to: time)
            try await expectPrimaryColor(color, session)
        }

        try await checkPairedPCM(pair, options: pair.decoderOptions, expectVideo: true)
    }

    @Test
    func `unavailable video decoder leaves paired AVI audio playable`() async throws {
        let pair = try #require(try Catalog.load().paired.first { $0.format == "avi" })
        var options = pair.decoderOptions
        options["vd"] = "vp9,-"
        try await checkPairedPCM(pair, options: options, expectVideo: false)
    }

    @Test(arguments: ["data", "mpegtsraw", "webm_dash_manifest"])
    func `data readers reject nonplayable tracks and the session recovers`(format: String)
        async throws
    {
        let usesWebM = format == "webm_dash_manifest"
        let playable = try TestPaths.testMedia(
            usesWebM ? "codecs-webm-dash-index.webm" : "codecs-hls-00.ts"
        )
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: raw) }
        if format == "data" {
            try Data(0 ... 255).write(to: raw)
        }

        let session = try NativePlaybackSession(options: [
            "demuxer": "lavf",
            "demuxer-lavf-format": format,
            "keep-open": "no",
        ])
        defer { session.close() }
        try session.command(["loadfile", (format == "data" ? raw : playable).path])
        var status: Int32?
        try await eventually("\(format) completes with a load error") {
            status = session.consumeEndFileStatus()
            return status != nil
        }
        let expected = format == "mpegtsraw" ? MPV_ERROR_UNKNOWN_FORMAT : MPV_ERROR_NOTHING_TO_PLAY
        #expect(status == expected.rawValue)

        try session.command(["set", "demuxer-lavf-format", ""])
        try await session.load(playable)
        expectFormat(usesWebM ? "matroska" : "mpegts", session)
        try await expectPrimaryColor(0, session)
    }

    @Test
    func `truncated MOV cannot reuse a frame and the full file recovers`() async throws {
        let complete = try TestPaths.testMedia("tls-ranges.mp4")
        let prefix = try FileHandle(forReadingFrom: complete)
        defer { try? prefix.close() }
        let truncated = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: truncated) }
        let header = try #require(try prefix.read(upToCount: 48))
        try #require(header.count == 48 && header[36 ..< 40] == Data("moov".utf8))
        try header.write(to: truncated)

        let session = try NativePlaybackSession(options: ["vd": "h264,-", "keep-open": "no"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("codecs-hls-01.ts"))
        try await expectPrimaryColor(1, session)
        try session.command(["loadfile", truncated.path])
        try await eventually("truncated MOV reports a load error") {
            (session.consumeEndFileStatus() ?? 0) < 0
        }
        #expect(session.property("current-tracks/video/codec") == nil)
        #expect(session.property("video-out-params/w") == nil)

        try await session.load(complete)
        expectFormat("mov", session)
        try await expectPrimaryColor(0, session)
        try await seek(session, to: 2.25)
        try await expectPrimaryColor(2, session)
    }

    @Test(arguments: [("mkv", "mkv"), ("lavf", "matroska")])
    func `truncated WebM clears both tracks and recovers through either reader`(
        reader: String,
        format: String
    ) async throws {
        let complete = try TestPaths.testMedia("codecs-paired-vp9-opus.webm")
        let prefix = try FileHandle(forReadingFrom: complete)
        defer { try? prefix.close() }
        let truncated = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).webm")
        defer { try? FileManager.default.removeItem(at: truncated) }
        let header = try #require(try prefix.read(upToCount: 8))
        try #require(header.count == 8 && header.prefix(4) == Data([0x1A, 0x45, 0xDF, 0xA3]))
        try header.write(to: truncated)

        let session = try NativePlaybackSession(options: [
            "demuxer": reader,
            "vd": "vp9,-",
            "ad": "opus,-",
            "audio": "auto",
            "keep-open": "no",
        ])
        defer { session.close() }
        try await session.load(complete)
        expectFormat(format, session)
        try await seek(session, to: 1.25)
        try await expectPrimaryColor(1, session)
        #expect(session.property("current-tracks/audio/codec")?.stringValue == "opus")

        try session.command(["loadfile", truncated.path])
        try await eventually("truncated WebM reports a load error through \(reader)") {
            (session.consumeEndFileStatus() ?? 0) < 0
        }
        #expect(session.property("current-tracks/video/codec") == nil)
        #expect(session.property("current-tracks/audio/codec") == nil)
        #expect(session.property("video-out-params/w") == nil)

        try await session.load(complete)
        expectFormat(format, session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "vp9")
        #expect(session.property("current-tracks/audio/decoder")?.stringValue == "opus")
        try await expectPrimaryColor(0, session)
        try await seek(session, to: 1.25)
        try await expectPrimaryColor(1, session)
    }

    @Test(arguments: [("mkv", "mkv"), ("lavf", "matroska")])
    func `WebM truncated after a complete cluster reaches early EOF and the full file recovers`(
        reader: String,
        format: String
    ) async throws {
        let session = try NativePlaybackSession(options: [
            "demuxer": reader,
            "vd": "vp9,-",
            "ad": "opus,-",
            "audio": "auto",
        ])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("codecs-webm-truncated-cluster.webm"))
        expectFormat(format, session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "vp9")
        #expect(session.property("current-tracks/audio/decoder")?.stringValue == "opus")
        try await seek(session, to: 0.7)
        try await expectPrimaryColor(0, session)
        try session.command(["set", "pause", "no"])
        try await eventually("\(reader) reaches EOF at the truncated cluster") {
            session.property("eof-reached")?.boolValue == true
        }
        #expect((0.9 ... 1.05).contains(session.property("time-pos")?.doubleValue ?? -1))

        try session.command(["set", "pause", "yes"])
        try await session.load(TestPaths.testMedia("codecs-paired-vp9-opus.webm"))
        try await seek(session, to: 1.25)
        try await expectPrimaryColor(1, session)
        #expect(session.property("eof-reached")?.boolValue == false)
    }

    @Test(arguments: [
        ("codecs-alpha-prores.mov", "mov", "prores", true),
        ("codecs-alpha-vp8.webm", "mkv", "vp8", false),
        ("codecs-alpha-vp9.webm", "mkv", "vp9", false),
    ])
    func `transparent ProRes preserves alpha and bundled VP8 and VP9 produce opaque frames`(
        name: String,
        format: String,
        decoder: String,
        supportsAlpha: Bool
    ) async throws {
        let session = try NativePlaybackSession(options: ["vd": "\(decoder),-"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia(name))
        expectFormat(format, session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == decoder)
        #expect(session.property("video-dec-params/pixelformat")?.stringValue == (supportsAlpha ? "yuva444p12" : "yuv420p"))
        #expect(session.property("video-dec-params/alpha")?.stringValue == (supportsAlpha ? "straight" : "none"))

        for (time, color) in [(0.25, 0), (1.25, 2), (0.25, 0)] {
            try await seek(session, to: time)
            try await expectPrimaryColor(color, session)
            let frame = try screenshot(session)
            try #require(frame.width == 96 && frame.height == 64)
            let columns = [16, 48, 80]
            #expect(columns.allSatisfy { frame.isPrimaryColor(color, x: $0, y: 32) })
            let alpha = columns.map { frame.alpha(x: $0, y: 32) }
            #expect(alpha[0] == (supportsAlpha ? 0 : 255))
            #expect(abs(Int(alpha[1]) - (supportsAlpha ? 128 : 255)) <= 2)
            #expect(alpha[2] == 255)
        }
    }

    @Test
    func `mpv image sequence decodes each DPX frame in order`() async throws {
        let directory = try TestPaths.testMedia("codecs-still-00.dpx").deletingLastPathComponent()
        let session = try NativePlaybackSession(options: ["mf-fps": "1"])
        defer { session.close() }
        try session.command(["loadfile", "mf://\(directory.path)/codecs-still-%02d.dpx"])
        try await eventually("first image in mpv sequence") {
            session.property("video-out-params/w")?.integerValue == 32
        }

        expectFormat("mf", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "dpx")
        try await expectPrimaryColor(0, session)

        for channel in 1 ... 2 {
            try session.command(["frame-step"])
            try await eventually("image \(channel) in mpv sequence") {
                (session.property("time-pos")?.doubleValue ?? -1) == Double(channel)
            }
            try await expectPrimaryColor(channel, session)
        }
    }

    @Test(arguments: ["mov_text", "webvtt"])
    func `timed text displays and clears cues after seeking`(codec: String) async throws {
        let session = try NativePlaybackSession(options: ["sid": "1", "sub-auto": "no"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("codecs-mov-text.mp4"))
        if codec == "webvtt" {
            try session.command(["sub-add", TestPaths.testMedia("codecs-cues.vtt").path, "select"])
        }

        expectFormat("mov", session)
        #expect(session.property("current-tracks/sub/codec")?.stringValue == codec)
        let cues =
            codec == "webvtt"
                ? [(1.25, "WebVTT first cue"), (2.25, ""), (2.75, "WebVTT second cue")]
                : [(1.25, "First cue"), (2.25, ""), (2.75, "Second cue")]
        for (time, expected) in cues {
            try await seek(session, to: time)
            try await eventually("timed text at \(time) seconds") {
                (session.property("sub-text")?.stringValue ?? "") == expected
            }
        }
    }

    @Test(arguments: try TextSubtitles.load().cases.filter { !$0.androidOnly })
    func `local text sidecars preserve cues and clear times`(sidecar: TextSubtitles.Sidecar)
        async throws
    {
        let catalog = try TextSubtitles.load()
        let session = try NativePlaybackSession(options: ["vd": "h264,-", "sub-auto": "no"])
        defer { session.close() }
        try await session.load(TestPaths.baselineMedia)
        try session.command(["sub-add", TestPaths.testMedia(sidecar.file).path, "select"])
        #expect(session.property("current-tracks/sub/codec")?.stringValue == sidecar.codec)

        for (time, text) in [(3.25, catalog.second), (2.25, ""), (1.25, catalog.first), (4.25, "")] {
            try await seek(session, to: time)
            try await eventually("\(sidecar.file) text at \(time) seconds") {
                session.property("sub-text")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "" == text
            }
        }
    }

    @Test
    func `bilingual SRT sidecars switch subtitle roles and clear when deselected`() async throws {
        let session = try NativePlaybackSession(options: ["vd": "h264,-", "sub-auto": "no"])
        defer { session.close() }
        try await session.load(TestPaths.baselineMedia)
        try session.command(["sub-add", TestPaths.testMedia("baseline.en.srt").path, "select"])
        let english = try #require(session.property("current-tracks/sub/id")?.integerValue)
        #expect(session.property("current-tracks/sub/codec")?.stringValue == "subrip")
        try session.command(["sub-add", TestPaths.testMedia("baseline.es.srt").path, "select"])
        let spanish = try #require(session.property("current-tracks/sub/id")?.integerValue)
        #expect(session.property("current-tracks/sub/codec")?.stringValue == "subrip")
        #expect(english != spanish)

        func expectCues(at time: Double, primary: String, secondary: String) async throws {
            try await seek(session, to: time)
            try await eventually("primary and secondary SRT text at \(time) seconds") {
                (session.property("sub-text")?.stringValue ?? "") == primary
                    && (session.property("secondary-sub-text")?.stringValue ?? "") == secondary
            }
        }

        try session.command(["set", "sid", String(english)])
        try session.command(["set", "secondary-sid", String(spanish)])
        try await expectCues(
            at: 1.0,
            primary: "Welcome to the subtitle demo.",
            secondary: "Bienvenidos a la demostración de subtítulos."
        )
        try await expectCues(
            at: 5.0,
            primary: "Two languages can appear at the same time.",
            secondary: "Dos idiomas pueden aparecer al mismo tiempo."
        )
        try session.command(["set", "sid", "no"])
        try session.command(["set", "secondary-sid", String(english)])
        try session.command(["set", "sid", String(spanish)])
        try await expectCues(
            at: 9.0,
            primary: "Elige cada idioma en el menú de pistas.",
            secondary: "Choose each language in the Tracks menu."
        )
        try session.command(["set", "sid", "no"])
        try session.command(["set", "secondary-sid", "no"])
        try await expectCues(at: 1.0, primary: "", secondary: "")
    }

    @Test(arguments: [("codecs-cea608.ts", "mpegts"), ("codecs-cea608.mov", "mov")])
    func `CEA-608 cues render and clear in MPEG-TS and QuickTime`(file: String, format: String)
        async throws
    {
        let session = try NativePlaybackSession(options: [
            "vd": "h264,-",
            "sid": "1",
            "sub-auto": "no",
            "sub-create-cc-track": format == "mpegts" ? "yes" : "no",
        ])
        defer { session.close() }
        try await session.load(TestPaths.testMedia(file))
        expectFormat(format, session)
        #expect(session.property("current-tracks/sub/codec")?.stringValue == "eia_608")
        let initialFrame = try screenshot(session, mode: "subtitles")
        #expect(brightPixelSamples(in: initialFrame, interval: 2) == 0)

        let captions = [
            (1.268, 2.336, "FIRST CAPTION", true),
            (3.270, 4.338, "SECOND CAPTION", false),
        ]
        for replay in [false, true] {
            let pass = replay ? "replay after rewind" : "initial playback"
            if replay {
                try session.command(["set", "pause", "yes"])
                try await seek(session, to: 0)
                let text = session.property("sub-text")?.stringValue ?? ""
                #expect(text.isEmpty)
            }

            try session.command(["set", "pause", "no"])
            for (start, stop, label, lowerHalf) in captions {
                try await eventually("\(label) appears once at its encoded time during \(pass)") {
                    let time = session.property("time-pos")?.doubleValue ?? -1
                    return (start - 0.1 ... start + 0.4).contains(time)
                        && session.property("sub-text")?.stringValue?.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ) == label
                }
                try await expectCaptionHalf(label, lowerHalf: lowerHalf, session: session)
                try await eventually("\(label) clears at its encoded time during \(pass)") {
                    let time = session.property("time-pos")?.doubleValue ?? -1
                    return (stop - 0.1 ... stop + 0.4).contains(time)
                        && (session.property("sub-text")?.stringValue ?? "").isEmpty
                }
                try await eventually("glyphs clear for \(label)") {
                    try brightPixelSamples(in: screenshot(session, mode: "subtitles"), interval: 2) == 0
                }
            }
        }
    }

    @Test(
        arguments: ["codecs-webvtt.webm", "codecs-webvtt.mkv"],
        [("mkv", "mkv", "webvtt-webm"), ("lavf", "matroska", "webvtt")]
    )
    func `embedded WebVTT follows primary and secondary selection after seeking`(
        file: String,
        route: (demuxer: String, format: String, codec: String)
    ) async throws {
        let (demuxer, format, codec) = route
        let session = try NativePlaybackSession(options: [
            "demuxer": demuxer,
            "sid": "1",
            "secondary-sid": "2",
            "sub-auto": "no",
        ])
        defer { session.close() }
        try await session.load(TestPaths.testMedia(file))
        expectFormat(format, session)
        #expect(session.property("current-tracks/sub/codec")?.stringValue == codec)

        let rtlCue = "כתוביות בעברית"
        let placements: [String: WebVTTPlacement] = [
            "WebVTT first cue": .init(
                horizontalPosition: 0.25,
                verticalPosition: 0.8,
                horizontalAnchor: .left,
                verticalAnchor: .bottom,
                maximumWidth: 0.4,
                textAlignment: .left
            ),
            rtlCue: .init(
                horizontalPosition: 0.75,
                verticalPosition: 0.2,
                horizontalAnchor: .right,
                verticalAnchor: .top,
                maximumWidth: 0.3,
                textAlignment: .right
            ),
        ]
        let defaultPlacement = WebVTTPlacement(horizontalPosition: 0.5, verticalPosition: 0.96)

        func checkCues(at time: Double? = nil, primary: String, secondary: String) async throws {
            if let time {
                try await seek(session, to: time)
            }
            try await eventually(
                "primary cue '\(primary)' and secondary cue '\(secondary)' through \(demuxer)"
            ) {
                let regions = MPVTextSubtitleParser.snapshot(from: session.property("sub-text-snapshot")).regions
                return regions.filter { $0.role == .primary }.map(\.text).joined(separator: "\n") == primary
                    && regions.filter { $0.role == .secondary }.map(\.text).joined(separator: "\n") == secondary
                    && regions.allSatisfy { $0.placement == .webVTT(placements[$0.text] ?? defaultPlacement) }
                    && (session.property("sub-text")?.stringValue ?? "") == primary
                    && (session.property("secondary-sub-text")?.stringValue ?? "") == secondary
            }
        }

        try await checkCues(at: 1.25, primary: "WebVTT first cue", secondary: rtlCue)
        try await checkCues(at: 2.25, primary: "", secondary: "")
        try await checkCues(at: 2.75, primary: "WebVTT second cue", secondary: "Captions second cue")
        try session.command(["set", "sid", "no"])
        try session.command(["set", "secondary-sid", "1"])
        try session.command(["set", "sid", "2"])
        try await checkCues(at: 1.25, primary: rtlCue, secondary: "WebVTT first cue")
        try session.command(["set", "secondary-sid", "no"])
        try await checkCues(primary: rtlCue, secondary: "")
        try session.command(["set", "sid", "no"])
        try await checkCues(primary: "", secondary: "")
        try await checkCues(at: 2.75, primary: "", secondary: "")
        try session.command(["set", "sid", "1"])
        try session.command(["set", "secondary-sid", "2"])
        try await checkCues(at: 2.75, primary: "WebVTT second cue", secondary: "Captions second cue")
        try await checkCues(at: 3.75, primary: "", secondary: "")
        try await checkCues(at: 1.25, primary: "WebVTT first cue", secondary: rtlCue)
    }

    @Test
    func `AVI XSUB renders and clears the bitmap cue`() async throws {
        let session = try NativePlaybackSession(options: ["sid": "1", "sub-auto": "no"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("subtitles-xsub.avi"))

        expectFormat("avi", session)
        #expect(session.property("current-tracks/sub/codec")?.stringValue == "xsub")
        try await seek(session, to: 1.5)
        try await eventually("XSUB presents the bitmap cue") {
            try screenshot(session, mode: "subtitles").rgb(x: 180, y: 570).allSatisfy { $0 > 180 }
        }

        try await seek(session, to: 5.0)
        try await eventually("XSUB clears the bitmap cue") {
            try screenshot(session, mode: "subtitles").rgb(x: 180, y: 570).allSatisfy { $0 < 100 }
        }
    }

    @Test(arguments: [("dvd_subtitle", "3"), ("dvb_subtitle", "4")], ["mkv", "lavf"])
    func `DVD and DVB bitmap cues render and clear through both Matroska readers`(
        track: (codec: String, id: String),
        demuxer: String
    ) async throws {
        let options = ["demuxer": demuxer, "sid": track.id, "sub-auto": "no"]
        try await expectBitmapCue(
            "subtitles.mkv",
            format: demuxer == "mkv" ? "mkv" : "matroska",
            codec: track.codec,
            options: options
        )
    }

    @Test
    func `MP4 DVD bitmap cues render and clear`() async throws {
        try await expectBitmapCue(
            "subtitles-dvd.mp4",
            format: "mov",
            codec: "dvd_subtitle",
            options: ["sid": "1", "sub-auto": "no"],
        )
    }

    @Test(arguments: [("mkv", "mkv"), ("lavf", "matroska")])
    func `PGS palette preserves color order and clears at the authored boundary`(
        reader: String,
        format: String
    ) async throws {
        let session = try NativePlaybackSession(options: [
            "demuxer": reader,
            "sid": "5",
            "sub-auto": "no",
        ])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("subtitles.mkv"))
        expectFormat(format, session)
        #expect(session.property("current-tracks/sub/codec")?.stringValue == "hdmv_pgs_subtitle")
        #expect(session.property("current-tracks/sub/title")?.stringValue == "Color channel order")

        func matchesPalette(visible: Bool) throws -> Bool {
            let frame = try screenshot(session, mode: "subtitles")
            try #require(frame.width == 360 && frame.height == 640)
            let white = frame.rgb(x: 128, y: 576)
            let outside = frame.rgb(x: 80, y: 576)
            if visible {
                return white.allSatisfy { $0 > 192 } && frame.isPrimaryColor(0, x: 185, y: 576)
                    && frame.isPrimaryColor(2, x: 232, y: 576) && outside.allSatisfy { $0 < 100 }
            }
            return [128, 185, 232].allSatisfy { frame.rgb(x: $0, y: 576) == outside }
        }

        try session.command(["set", "pause", "no"])
        for (window, visible) in [(3.75 ..< 4.0, true), (4.03 ..< 4.27, false)] {
            try await eventually("PGS palette through \(reader) in \(window)") {
                guard window.contains(session.property("time-pos")?.doubleValue ?? -1) else { return false }

                return try matchesPalette(visible: visible)
            }
        }
        try session.command(["set", "pause", "yes"])
        try await seek(session, to: 0.25)
        try await eventually("PGS returns after seeking back through \(reader)") {
            try matchesPalette(visible: true)
        }
    }

    @Test(arguments: [("mkv", "mkv"), ("lavf", "matroska")])
    func `PGS overlays preserve object order and both levels of transparency`(
        reader: String,
        format: String
    ) async throws {
        let session = try NativePlaybackSession(options: ["demuxer": reader, "sid": "2", "sub-auto": "no"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("subtitles-positioned.mkv"))
        expectFormat(format, session)
        #expect(session.property("current-tracks/sub/codec")?.stringValue == "hdmv_pgs_subtitle")

        func matchesOverlay() throws -> Bool {
            let frame = try screenshot(session, mode: "subtitles")
            try #require(frame.width == 360 && frame.height == 640)
            let background = frame.rgb(x: 80, y: 540)
            let white = frame.rgb(x: 125, y: 540)
            let alpha = frame.rgb(x: 230, y: 540)
            let solid = frame.rgb(x: 255, y: 540)
            return white.allSatisfy { $0 > 192 } && frame.rgb(x: 175, y: 540).allSatisfy { $0 > 192 }
                && frame.isPrimaryColor(0, x: 205, y: 540) && frame.isPrimaryColor(0, x: 255, y: 540)
                && Int(alpha[0]) > Int(background[0]) + 30 && Int(alpha[0]) < Int(solid[0]) - 20
        }

        try session.command(["set", "pause", "no"])
        try await eventually("both overlapping PGS objects through \(reader)") {
            guard (0.3 ..< 2.8).contains(session.property("time-pos")?.doubleValue ?? -1) else { return false }

            return try matchesOverlay()
        }
        try await eventually("PGS clears both objects") {
            guard (3.1 ..< 4.8).contains(session.property("time-pos")?.doubleValue ?? -1) else { return false }

            let frame = try screenshot(session, mode: "subtitles")
            let background = frame.rgb(x: 80, y: 540)
            return [125, 175, 205, 230, 255].allSatisfy { x in
                zip(frame.rgb(x: x, y: 540), background).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
            }
        }
        try session.command(["set", "pause", "yes"])
        try await seek(session, to: 0.2)
        try await eventually("PGS object order and transparency restore after seeking") {
            try matchesOverlay()
        }
    }

    @Test(arguments: [("mkv", "mkv"), ("lavf", "matroska")])
    func `embedded ASS retains authored color and placement in overlapping cues`(
        reader: String,
        format: String
    ) async throws {
        let session = try NativePlaybackSession(options: ["demuxer": reader, "sid": "1", "sub-auto": "no"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("subtitles-positioned.mkv"))
        expectFormat(format, session)
        #expect(session.property("current-tracks/sub/codec")?.stringValue == "ass")

        for (time, expected) in [
            (0.85, ["Upper cue"]),
            (1.9, ["Upper cue", "Lower cue"]),
            (2.9, ["Lower cue"]),
            (4.0, []),
            (0.85, ["Upper cue"])
        ] {
            try await seek(session, to: time)
            try await eventually("ASS colors and cue placement at \(time) through \(reader)") {
                let text = session.property("sub-text")?.stringValue ?? ""
                guard Set(text.split(separator: "\n").map(String.init)) == Set(expected) else { return false }

                let frame = try screenshot(session, mode: "subtitles")
                var green = 0
                var yellow = 0
                for y in stride(from: 0, to: frame.height, by: 2) {
                    for x in stride(from: 0, to: frame.width, by: 2) {
                        let rgb = frame.rgb(x: x, y: y)
                        if rgb[1] > 175, rgb[2] < 90 {
                            if rgb[0] < 90 {
                                guard x < 190, (55 ..< 100).contains(y) else { return false }

                                green += 1
                            } else if rgb[0] > 175 {
                                guard x > 165, (520 ..< 565).contains(y) else { return false }

                                yellow += 1
                            }
                        }
                    }
                }
                return (expected.contains("Upper cue") ? green > 15 : green == 0)
                    && (expected.contains("Lower cue") ? yellow > 15 : yellow == 0)
            }
        }
    }

    @Test(arguments: [
        ("subtitles-dvb.ts", "dvb_subtitle"),
        ("subtitles-pgs.m2ts", "hdmv_pgs_subtitle"),
    ])
    func `DVB and PGS bitmap cues render and clear in transport streams`(file: String, codec: String)
        async throws
    {
        let session = try NativePlaybackSession(options: ["sid": "1", "sub-auto": "no", "speed": "2"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia(file))

        expectFormat("mpegts", session)
        #expect(session.property("current-tracks/sub/codec")?.stringValue == codec)

        // Play from the beginning so both readers receive the bitmap display set before its clear event.
        try session.command(["set", "pause", "no"])
        try await eventually("authored bitmap is visible in \(file)") {
            let time = session.property("time-pos")?.doubleValue ?? -1
            guard (1 ..< 3).contains(time) else { return false }

            return try brightPixelSamples(in: screenshot(session, mode: "subtitles")) > 4
        }
        try await eventually("authored bitmap clears in \(file)") {
            guard let time = session.property("time-pos")?.doubleValue, time >= 5 else { return false }

            return try brightPixelSamples(in: screenshot(session, mode: "subtitles")) == 0
        }
    }

    @Test(arguments: [("mono", 1), ("stereo", 2), ("5.1", 6), ("7.1", 8)])
    func `Matroska PCM preserves the authored channel order`(layout: String, channels: Int)
        async throws
    {
        try await expectMatroskaChannelTones(
            "audio-pcm-\(layout).mka",
            decoder: "pcm_s16le",
            layout: layout,
            duration: 6,
            frequencies: (0 ..< channels).map { 220 + $0 * 110 }
        )
    }

    @Test(arguments: [
        "audio-ac3-stereo.mka",
        "audio-ac3-5.1.mka",
        "audio-eac3-stereo.mka",
        "audio-eac3-5.1.mka",
        "audio-eac3-256k-5.1.mka",
        "audio-eac3-768k-5.1.mka",
    ])
    func `Matroska Dolby audio preserves the authored channel order`(name: String) async throws {
        let decoder = name.hasPrefix("audio-eac3") ? "eac3" : "ac3"
        let stereo = name.contains("stereo")
        try await expectMatroskaChannelTones(
            name,
            decoder: decoder,
            layout: stereo ? "stereo" : "5.1",
            duration: name == "audio-\(decoder)-5.1.mka" ? 24 : 6,
            frequencies: stereo ? [220, 330] : [220, 330, 440, nil, 660, 770]
        )
    }

    @Test
    func `DTS audio and video clocks continue after a track and speed change`() async throws {
        let session = try NativePlaybackSession(options: [
            "vd": "h264,-",
            "ad": "dca,-",
            "audio": "auto",
            "audio-channels": "auto",
            "audio-pitch-correction": "no",
            "aid": "1",
            "speed": "4",
        ])
        defer { session.close() }
        try await session.load(TestPaths.testMedia("audio-dts-multitrack.mkv"))
        expectFormat("mkv", session)
        #expect(session.property("current-ao")?.stringValue == "null")
        #expect(session.property("current-tracks/audio/decoder")?.stringValue == "dca")
        try session.command(["set", "pause", "no"])
        try await eventually("DTS 5.1 stays in sync after 30 seconds", timeout: .seconds(14)) {
            (session.property("time-pos")?.doubleValue ?? 0) >= 30
                && session.property("audio-out-params/channel-count")?.integerValue == 6
                && abs(session.property("avsync")?.doubleValue ?? .infinity) < 0.25
        }
        try session.command(["set", "pause", "yes"])
        let position = try #require(session.property("time-pos")?.doubleValue)
        try session.command(["set", "aid", "2"])
        try session.command(["set", "speed", "3"])
        try session.command(["set", "pause", "no"])
        try await eventually("DTS stereo resumes near the switch with synchronized video") {
            guard let time = session.property("time-pos")?.doubleValue else { return false }

            return (position + 1 ... position + 5).contains(time)
                && session.property("current-tracks/audio/id")?.integerValue == 2
                && session.property("audio-out-params/channel-count")?.integerValue == 2
                && abs(session.property("avsync")?.doubleValue ?? .infinity) < 0.25
        }
        try await eventually("DTS stereo continues to EOF", timeout: .seconds(20)) {
            session.property("eof-reached")?.boolValue == true
        }
        #expect((session.property("time-pos")?.doubleValue ?? 0) >= 71.5)
    }

    @Test(arguments: [0, 24000])
    func `cached PCM stream callbacks preserve both channels and an exact seek`(start: Int) async throws {
        var samples: [Int16] = []
        for frame in 0 ..< 60000 {
            samples.append(Int16((frame * 257) % 65521 - 32760).littleEndian)
            samples.append(Int16((frame * 541) % 65479 - 32739).littleEndian)
        }
        let bytes = samples.withUnsafeBytes { Data($0) }
        let stream = SyntheticCacheStream(contents: bytes)
        defer { withExtendedLifetime(stream) {} }

        let source = try #require(URL(string: "cachefixture://pcm"))
        let options = [
            "ad": "pcm_s16le,-",
            "ao-pcm-waveheader": "no",
            "demuxer": "rawaudio",
            "demuxer-rawaudio-channels": "stereo",
            "demuxer-rawaudio-format": "s16le",
            "demuxer-rawaudio-rate": "48000",
            "audio-channels": "stereo",
            "audio-format": "s16",
            "cache": "yes",
            "hr-seek": "yes",
            "start": String(Double(start) / 48000),
        ]
        try await withPCMOutput(source, options: options, configureSession: { session in
            try session.registerStream(
                protocol: "cachefixture",
                userData: Unmanaged.passUnretained(stream).toOpaque(),
                open: SyntheticCacheStream.open
            )
        }) { session in
            expectFormat("rawaudio", session)
            #expect(session.property("seekable")?.boolValue == true)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == "pcm_s16le")
        } checkFile: { file in
            let actual = try Data(contentsOf: file)
            let expected = bytes.dropFirst(start * 2 * MemoryLayout<Int16>.size)
            #expect(actual == expected)
        }
    }

    private func verifyLiveHLS(secure: Bool) async throws {
        let stream = try Catalog.load().liveStream
        let last = try #require(stream.parts.last)
        let server = try LoopbackMediaServer(
            resources: httpResources([stream.file] + stream.parts),
            hold: last,
            identity: secure ? loopbackTLSIdentity() : nil
        )
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent(stream.file)
        let session = try NativePlaybackSession(
            options: liveStreamingOptions(
                [
                    "vd": "h264,-",
                    "ad": "aac,-",
                    "audio": "auto",
                    "demuxer-lavf-o": "live_start_index=0",
                    "cache": "yes",
                    "cache-pause": "yes",
                    "cache-pause-wait": "0.25",
                ],
                secure: secure
            )
        )
        defer {
            server.releaseHeldResponse()
            session.close()
        }

        try await session.load(url)
        expectFormat("hls", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        #expect(session.property("current-tracks/audio/decoder")?.stringValue == "aac")
        try await expectPrimaryColor(0, session)
        #expect(session.property("eof-reached")?.boolValue == false)

        try server.replace(stream.file, with: Data(contentsOf: TestPaths.testMedia(stream.update)))
        try session.command(["set", "pause", "no"])
        try await eventually("HLS buffers while the final segment is withheld", timeout: .seconds(10)) {
            server.requested(last) && session.property("paused-for-cache")?.boolValue == true
        }
        #expect((session.property("time-pos")?.doubleValue ?? 3) < 2.1)
        #expect(session.property("eof-reached")?.boolValue == false)

        server.releaseHeldResponse()
        try await expectPrimaryColor(2, session)
        try await eventually("HLS ends after consuming the delayed segment") {
            session.property("eof-reached")?.boolValue == true
                && session.property("paused-for-cache")?.boolValue == false
        }
    }

    private func expectRTMP(secure: Bool, tunneled: Bool) async throws {
        let recording = try Data(contentsOf: TestPaths.testMedia("codecs-rtmp-replies.bin"))
        let server = try LoopbackRTMPServer(
            recording: recording,
            identity: secure ? loopbackTLSIdentity() : nil,
            tunneled: tunneled
        )
        let session = try NativePlaybackSession(options: rtmpOptions)
        defer {
            session.close()
            server.stop()
        }

        try await expectTransportPlayback(
            server.start(),
            reader: "flv",
            session: session,
            verifyTrust: secure,
            seekable: true
        )
    }

    private func expectPacketizedAudio(_ clip: RTPRecordingFixture, reader: String) async throws {
        try await withRTPRecording(clip, reader: reader) { source in
            var options = rtpRecordingOptions
            options["ad"] = "\(clip.decoder),-"
            options["end"] = "1.2"
            try await withDecodedPCM(source, options: options) { session in
                expectFormat(reader, session)
                #expect(session.property("current-tracks/audio/codec")?.stringValue == clip.codec)
                #expect(session.property("current-tracks/audio/decoder")?.stringValue == clip.decoder)
                #expect(session.property("seekable")?.boolValue == false)
            } checkPCM: { samples, duration in
                try #require(abs(duration - 1.2) < 0.13)
                for start in [0.08, 0.5, 0.95] {
                    try expectMonoTone(samples, at: start, frequency: 440)
                }
            }
        }
    }

    private func verifyNetworkStream(
        _ stream: Stream,
        secure: Bool,
        cycles: Int = 1,
        seekPoints: [(Double, Int)] = [(2.25, 2), (0.25, 0), (1.25, 1)]
    ) async throws {
        let filenames = [stream.file] + stream.parts
        let server = try LoopbackMediaServer(
            resources: httpResources(filenames),
            identity: secure ? loopbackTLSIdentity() : nil
        )
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent(stream.file)
        var options = ["vd": "h264,-", "ad": "aac,-", "audio": "auto"]
        if secure {
            options["tls-verify"] = "yes"
            options["tls-ca-file"] = try TestPaths.testMedia("tls-loopback.pem").path
        }

        do {
            let session = try NativePlaybackSession(options: options)
            defer { session.close() }
            try await session.load(url)
            expectFormat(stream.format, session)
            #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
            #expect(session.property("seekable")?.boolValue == true)
            for (time, channel) in seekPoints {
                try await seek(session, to: time)
                try await expectPrimaryColor(channel, session)
            }
        }

        options["vid"] = "no"
        try await withDecodedPCM(url, options: options) { session in
            expectFormat(stream.format, session)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == "aac")
        } checkPCM: { file, duration in
            let pattern = [440, 660, 880]
            let segmentCount = cycles * pattern.count
            try #require(abs(duration - Double(segmentCount)) < 0.15)
            for segment in 0 ..< segmentCount {
                try expectMonoTone(
                    file,
                    at: Double(segment) + 0.25,
                    frequency: pattern[segment % pattern.count]
                )
            }
        }
        for filename in filenames {
            #expect(server.requested(filename), "mpv retrieved \(filename) over \(url.scheme ?? "HTTP")")
        }
    }

    private func verifyLiveDASH(_ stream: LiveStream, secure: Bool = false) async throws {
        let first = stream.parts[1]
        let last = try #require(stream.parts.last)
        let server = try LoopbackMediaServer(
            resources: httpResources([stream.file] + stream.parts),
            identity: secure ? loopbackTLSIdentity() : nil
        )
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent(stream.file)
        let session = try NativePlaybackSession(
            options: liveStreamingOptions(
                [
                    "vd": "h264,-",
                    "cache-pause": "no",
                    "network-timeout": "4",
                    "demuxer-lavf-o": "max_reload=32",
                ],
                secure: secure
            )
        )
        defer { session.close() }

        try session.command(["loadfile", url.absoluteString])
        try await eventually("DASH requests the first advertised segment") { server.requested(first) }
        #expect(!server.requested(last))
        try server.replace(stream.file, with: Data(contentsOf: TestPaths.testMedia(stream.update)))

        try await eventually("DASH opens a live video frame") {
            session.property("video-out-params/w")?.integerValue == 176
        }
        expectFormat("dash", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        #expect(session.property("seekable")?.boolValue == false)
        try await expectPrimaryColor(0, session)

        try session.command(["set", "pause", "no"])
        try await expectPrimaryColor(1, session)
        try await expectPrimaryColor(2, session)
        #expect((session.property("time-pos")?.doubleValue ?? 0) >= 2)
        #expect(server.requested(last))
    }

    private func liveStreamingOptions(_ options: [String: String], secure: Bool) throws -> [String:
        String]
    {
        if !secure {
            return options
        }

        return try options.merging([
            "tls-verify": "yes",
            "tls-ca-file": TestPaths.testMedia("tls-loopback.pem").path,
        ]) { _, new in new }
    }

    private func verifyDASHVideoSelection(_ stream: Stream) async throws {
        let server = try LoopbackMediaServer(resources: httpResources([stream.file] + stream.parts))
        defer { server.stop() }
        let url = try await server.start().appendingPathComponent(stream.file)
        let session = try NativePlaybackSession(options: [
            "vid": "1",
            "vd": "h264,-",
            "ad": "aac,-",
            "audio": "auto",
        ])
        defer { session.close() }
        try await session.load(url)

        expectFormat("dash", session)
        let tracks = try #require(session.property("track-list")?.arrayValue)
        let video = tracks.compactMap(\.mapValue).filter { $0["type"]?.stringValue == "video" }
        let audio = try #require(session.property("current-tracks/audio/id")?.integerValue)
        #expect(video.compactMap { $0["id"]?.integerValue } == [1, 2])

        let steps: [(Int64, Int64, Double, Int)] = [
            (1, 176, 0.25, 0),
            (2, 352, 2.25, 2),
            (1, 176, 1.25, 1),
        ]
        for (id, width, time, color) in steps {
            try session.command(["set", "vid", String(id)])
            try await eventually("DASH representation \(id) is selected") {
                session.property("current-tracks/video/id")?.integerValue == id
            }
            try await seek(session, to: time)
            try await eventually("DASH representation \(id) presents width \(width)") {
                session.property("video-out-params/w")?.integerValue == width
            }
            try await expectPrimaryColor(color, session)
            #expect(session.property("current-tracks/audio/id")?.integerValue == audio)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == "aac")
        }
        #expect(server.requested("codecs-dash-renditions-1-03.m4s"))
        #expect(server.requested("codecs-dash-renditions-0-02.m4s"))
    }

    private func expectMPEG2Fields(_ name: String, cadence: Double, levels: [Int]) async throws {
        let session = try NativePlaybackSession(options: [
            "vd": "mpeg2video,-",
            "vf": "lavfi=[bwdif=mode=send_field:parity=auto:deint=interlaced]",
        ])
        defer { session.close() }
        try await session.load(TestPaths.testMedia(name))
        expectFormat("mkv", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "mpeg2video")

        for (field, level) in levels.enumerated() {
            let time = Double(field) / cadence
            if field > 0 {
                try session.command(["frame-step"])
            }
            try await eventually("\(name) field \(field) at \(time) seconds") {
                abs((session.property("time-pos")?.doubleValue ?? -1) - time) < 0.002
            }
            try await expectGrayLevel(level, session)
        }
    }

    private func expectThreeColorMP4ThroughSeeks(
        _ argument: String,
        label: String,
        options: [String: String] = [:]
    ) async throws {
        let session = try NativePlaybackSession(
            options: ["vd": "h264,-", "cache": "no"].merging(options) { _, new in new }
        )
        defer { session.close() }

        try await session.load(argument: argument, named: label)
        expectFormat("mov", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        #expect(session.property("seekable")?.boolValue == true)
        for (time, channel) in [(2.25, 2), (0.25, 0)] {
            try await seek(session, to: time)
            try await expectPrimaryColor(channel, session)
        }
    }

    private func expectDecodedVideo(_ clip: Clip) async throws {
        var options = clip.mpvOptions
        options["vd"] = "\(clip.decoder),-"
        let session = try NativePlaybackSession(options: options)
        defer { session.close() }
        try await session.load(TestPaths.testMedia(clip.file))

        expectFormat(clip.format, session)
        #expect(session.property("current-tracks/video/codec")?.stringValue == clip.codec)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == clip.decoder)
        #expect(session.property("video-out-params/w")?.integerValue == Int64(clip.width))
        #expect(session.property("video-out-params/h")?.integerValue == Int64(clip.height))
        let initialTime = try #require(session.property("time-pos")?.doubleValue)

        try session.command(["frame-step"])
        try await eventually("second decoded frame from \(clip.file)") {
            (session.property("time-pos")?.doubleValue ?? initialTime) > initialTime
        }

        let frame = try screenshot(session)
        let samples = stride(from: 8, to: frame.width, by: 16).map {
            frame.rgb(x: $0, y: frame.height / 2)
        }
        #expect(
            samples.contains { rgb in
                Int(rgb.max() ?? 0) - Int(rgb.min() ?? 0) > 80
            },
            "Decoded image contains the source's colored bars"
        )
    }

    private func expectOpeningImage(_ clip: Clip, options: [String: String]) async throws {
        guard let brightOnLeft = clip.brightOnLeft else {
            Issue.record("The authored pattern is missing for \(clip.file)")
            return
        }

        var selected = options
        selected["vd"] = "\(clip.decoder),-"
        let session = try NativePlaybackSession(options: selected)
        defer { session.close() }
        try await session.load(TestPaths.testMedia(clip.file))
        expectFormat(clip.format, session)
        #expect(session.property("current-tracks/video/codec")?.stringValue == clip.codec)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == clip.decoder)
        try await eventually("\(clip.file) presents its bright and dark halves") {
            let image = try screenshot(session)
            guard image.width == clip.width, image.height == clip.height else { return false }

            let left = image.rgb(x: image.width / 4, y: image.height / 2)
            let right = image.rgb(x: image.width * 3 / 4, y: image.height / 2)
            let (bright, dark) = brightOnLeft ? (left, right) : (right, left)
            return bright.allSatisfy { $0 > 180 } && dark.allSatisfy { $0 < 50 }
        }
    }

    private func expectAuthoredColors(_ clip: Clip, grayLevels: (first: Int, second: Int)? = nil)
        async throws
    {
        var options = clip.mpvOptions
        options["vd"] = "\(clip.decoder),-"
        let session = try NativePlaybackSession(options: options)
        defer { session.close() }
        try await session.load(TestPaths.testMedia(clip.file))

        expectFormat(clip.format, session)
        #expect(session.property("current-tracks/video/codec")?.stringValue == clip.codec)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == clip.decoder)
        if let pixelFormat = clip.mpvPixelFormat {
            #expect(session.property("video-dec-params/pixelformat")?.stringValue == pixelFormat)
        }
        #expect(session.property("video-out-params/w")?.integerValue == Int64(clip.width))
        #expect(session.property("video-out-params/h")?.integerValue == Int64(clip.height))
        let levels = grayLevels ?? (clip.pixelFormat?.hasPrefix("gray") == true ? (72, 180) : nil)
        if let levels {
            try await expectGrayLevel(levels.first, session)
        } else {
            try await expectPrimaryColor(0, session)
        }

        let firstTime = try #require(session.property("time-pos")?.doubleValue)
        try session.command(["set", "pause", "no"])
        if let levels {
            try await expectGrayLevel(levels.second, session)
        } else {
            try await expectPrimaryColor(2, session)
        }
        #expect((session.property("time-pos")?.doubleValue ?? firstTime) > firstTime + 0.25)
    }

    private func withSegmentedSource(_ clip: SegmentedClip, check: (URL) async throws -> Void)
        async throws
    {
        let parts = [clip.file] + clip.parts
        let server = try LoopbackMediaServer(resources: httpResources(parts))
        defer { server.stop() }
        try await check(server.start().appendingPathComponent(clip.file))
        for part in parts {
            #expect(server.requested(part), "The reader requests \(part)")
        }
    }

    private func withRTPRecording(
        _ clip: RTPRecordingFixture,
        reader: String,
        check: (URL) async throws -> Void,
    ) async throws {
        let recording = try Data(contentsOf: TestPaths.testMedia(clip.file))
        if reader == "rtsp" {
            let server = try LoopbackRTSPServer(fixture: clip, recording: recording)
            defer { server.stop() }
            try await check(server.start())
            return
        }
        let port = try LoopbackTransport.availablePort()
        let sender = Task.detached { try await LoopbackTransport.send(recording, as: clip, to: port) }
        defer { sender.cancel() }
        if reader == "rtp" {
            try await check(#require(URL(string: "rtp://127.0.0.1:\(port)")))
        } else {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sdp")
            defer { try? FileManager.default.removeItem(at: path) }
            let description = LoopbackTransport.sessionDescription(
                port: port,
                media: clip.media,
                payload: clip.payloadType,
                attributes: clip.sdpAttributes,
            )
            try description.write(to: path, atomically: true, encoding: .utf8)
            try await check(path)
        }
    }

    private func expectBitmapCue(
        _ file: String,
        format: String,
        codec: String,
        options: [String: String]
    ) async throws {
        let session = try NativePlaybackSession(options: options)
        defer { session.close() }
        try await session.load(TestPaths.testMedia(file))

        expectFormat(format, session)
        #expect(session.property("current-tracks/sub/codec")?.stringValue == codec)

        for (time, visible) in [(1.0, true), (5.0, false), (1.0, true)] {
            try await seek(session, to: time)
            try await eventually("\(codec) cue visibility through \(format) at \(time)s") {
                let bright = try brightPixelSamples(in: screenshot(session, mode: "subtitles"))
                return visible ? bright > 4 : bright == 0
            }
        }
    }

    private func expectLosslessAudio(
        _ fixture: LosslessAudio,
        decoder: String,
        format: String,
        demuxer: String? = nil,
        layout: String,
        sampleFormat: String,
        bytesPerSample: Int,
        seek: Bool,
        source: URL? = nil,
        checkTimeline: ((NativePlaybackSession) -> Void)? = nil
    ) async throws {
        let firstFrame = seek ? fixture.seekStartFrame : 0
        var options = [
            "ad": "\(decoder),-",
            "audio-channels": layout,
            "audio-samplerate": String(fixture.sampleRate),
            "audio-format": sampleFormat,
            "ao-pcm-waveheader": "no",
            "start": String(Double(firstFrame) / Double(fixture.sampleRate)),
            "hr-seek": "yes",
        ]
        options["demuxer"] = demuxer
        let input = try source ?? TestPaths.testMedia(fixture.file)
        try await withPCMOutput(input, options: options) { session in
            expectFormat(format, session)
            #expect(session.property("current-tracks/audio/codec")?.stringValue == decoder)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == decoder)
            #expect(session.property("seekable")?.boolValue == true)
            #expect(
                session.property("audio-out-params/channel-count")?.integerValue == Int64(fixture.channels)
            )
            #expect(
                session.property("audio-out-params/samplerate")?.integerValue == Int64(fixture.sampleRate)
            )
            checkTimeline?(session)
        } checkFile: { output in
            let bytes = try Data(contentsOf: output)
            let frameSize = fixture.channels * bytesPerSample
            let expectedBytes = (fixture.frames - firstFrame) * frameSize
            // mpv truncates the fractional sample offset during an exact seek.
            let oneSampleEarly =
                seek && bytes.count == expectedBytes + frameSize && fixture.seekEarlySha256 != nil
            #expect(bytes.count == expectedBytes || oneSampleEarly)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let expected =
                oneSampleEarly ? fixture.seekEarlySha256 : (seek ? fixture.seekSha256 : fixture.sha256)
            #expect(digest == expected)
        }
    }

    private func expectTransportPlayback(
        _ source: URL,
        reader: String,
        session: NativePlaybackSession,
        verifyTrust: Bool = false,
        seekable: Bool = false,
    ) async throws {
        if verifyTrust {
            try session.command(["loadfile", source.absoluteString])
            var status: Int32?
            try await eventually("\(source.scheme ?? "file") rejects the untrusted loopback certificate") {
                status = session.consumeEndFileStatus()
                return status != nil
            }
            #expect((status ?? 0) < 0)
            try session.command(["set", "tls-ca-file", TestPaths.testMedia("tls-loopback.pem").path])
        }
        try await session.load(source)
        expectFormat(reader, session)
        #expect(session.property("seekable")?.boolValue == seekable)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        #expect(session.property("current-tracks/audio/decoder")?.stringValue == "aac")
        let frame = try screenshot(session)
        let rgb = frame.rgb(x: frame.width / 2, y: frame.height / 2).sorted()
        #expect(rgb[1] < 70 && rgb[2] > 180)

        let firstTime = try #require(session.property("time-pos")?.doubleValue)
        try session.command(["set", "pause", "no"])
        try await eventually(
            "\(source.scheme ?? "file") through \(reader) advances past its first decoded frame"
        ) {
            (session.property("time-pos")?.doubleValue ?? firstTime) > firstTime + 0.25
        }
    }

    private func expectCaptionHalf(_ label: String, lowerHalf: Bool, session: NativePlaybackSession)
        async throws
    {
        try await eventually("rendered glyphs for \(label) are in the authored half") {
            let frame = try screenshot(session, mode: "subtitles")
            let middle = frame.height / 2
            let upper = brightPixelSamples(in: frame, interval: 2, rows: 0 ..< middle)
            let lower = brightPixelSamples(in: frame, interval: 2, rows: middle ..< frame.height)
            return lowerHalf ? lower > 0 && upper == 0 : upper > 0 && lower == 0
        }
    }

    private func brightPixelSamples(in frame: Frame, interval: Int = 8, rows: Range<Int>? = nil)
        -> Int
    {
        let rows = rows ?? 0 ..< frame.height
        var bright = 0
        for y in stride(from: rows.lowerBound + interval / 2, to: rows.upperBound, by: interval) {
            for x in stride(from: interval / 2, to: frame.width, by: interval)
                where frame.rgb(x: x, y: y).allSatisfy({ $0 > 200 })
            {
                bright += 1
            }
        }
        return bright
    }

    private func expectDecodedTone(_ clip: Clip, decoder: String) async throws {
        var options = clip.mpvOptions
        options["ad"] = "\(decoder),-"
        try await withDecodedPCM(TestPaths.testMedia(clip.file), options: options) { session in
            expectFormat(clip.format, session)
            #expect(session.property("current-tracks/audio/codec")?.stringValue == clip.codec)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == decoder)
            if options["vid"] == "no" {
                #expect(session.property("current-tracks/video/decoder")?.stringValue == nil)
            }
        } checkPCM: { file, duration in
            try #require(abs(duration - 1.25) < 0.15)
            for start in [0.05, duration / 2, duration - 0.15] {
                try expectMonoTone(file, at: start, frequency: 440)
            }
        }
    }

    private func expectHighEfficiencyAAC(_ clip: Clip, decoder: String) async throws {
        try await withDecodedPCM(TestPaths.testMedia(clip.file), options: ["ad": "\(decoder),-"]) {
            session in
            expectFormat(clip.format, session)
            #expect(session.property("current-tracks/audio/codec")?.stringValue == "aac")
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == decoder)
        } checkPCM: { file, duration in
            try #require((1.15 ... 1.34).contains(duration))
            try expectMonoTone(file, at: 0.2, frequency: 440)
            #expect(try highBandAmplitude(file, at: 0.2) < 0.01)
            #expect(
                try highBandAmplitude(file, at: 0.9) > 0.035,
                "Decoded AAC reproduces the authored high band"
            )
        }
    }

    private func highBandAmplitude(_ file: AVAudioFile, at start: Double) throws -> Double {
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)
        )
        file.framePosition = AVAudioFramePosition(start * file.processingFormat.sampleRate)
        try file.read(into: buffer)
        try #require(buffer.frameLength == buffer.frameCapacity)
        let samples = try #require(buffer.floatChannelData)[0]
        // A second difference largely cancels the continuous 440 Hz tone and preserves the new high band.
        let indices = 1 ..< (Int(buffer.frameLength) - 1)
        let total = indices.reduce(0.0) { sum, i in
            sum + Double(abs(samples[i - 1] - 2 * samples[i] + samples[i + 1]))
        }
        return total / Double(indices.count)
    }

    private func httpResources(_ filenames: [String]) throws -> [String: Data] {
        try Dictionary(
            uniqueKeysWithValues: filenames.map { name in
                try (name, Data(contentsOf: TestPaths.testMedia(name)))
            }
        )
    }

    private func loopbackTLSIdentity() throws -> sec_identity_t {
        let data = try Data(contentsOf: TestPaths.testMedia("tls-loopback.p12"))
        var options: [String: Any] = [kSecImportExportPassphrase as String: "loopback-only"]
        #if os(macOS)
        options[kSecImportToMemoryOnly as String] = true
        #endif
        var imported: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &imported)
        try #require(status == errSecSuccess)
        let items = try #require(imported as? [[String: Any]])
        let item = try #require(items.first?[kSecImportItemIdentity as String])
        try #require(CFGetTypeID(item as CFTypeRef) == SecIdentityGetTypeID())
        return try #require(sec_identity_create(item as! SecIdentity))
    }

    private func checkPairedPCM(_ pair: Pair, options: [String: String], expectVideo: Bool)
        async throws
    {
        try await withDecodedPCM(TestPaths.testMedia(pair.file), options: options) { session in
            expectFormat(pair.format, session)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == pair.audioDecoder)
            let videoDecoder = session.property("current-tracks/video/decoder")?.stringValue
            #expect(videoDecoder == (expectVideo ? pair.videoDecoder : nil))
        } checkPCM: { file, duration in
            try #require(abs(duration - 2.0) < 0.15)
            for (start, frequency) in [(0.25, 440), (0.75, 440), (1.25, 660), (1.75, 660)] {
                try expectMonoTone(file, at: start, frequency: frequency)
            }
        }
    }

    private func withDecodedPCM(
        _ source: URL,
        argument: String? = nil,
        options: [String: String],
        checkSession: (NativePlaybackSession) -> Void,
        duringPlayback: ((NativePlaybackSession) async throws -> Void)? = nil,
        checkPCM: (AVAudioFile, Double) throws -> Void
    ) async throws {
        try await withPCMOutput(
            source,
            argument: argument,
            options: options,
            checkSession: checkSession,
            duringPlayback: duringPlayback
        ) { wave in
            let file = try AVAudioFile(forReading: wave)
            let format = file.processingFormat
            try #require(format.channelCount == 1 && format.sampleRate == 48000)
            try checkPCM(file, Double(file.length) / format.sampleRate)
        }
    }

    private func withPCMOutput<Output>(
        _ source: URL,
        argument: String? = nil,
        options: [String: String],
        configureSession: ((NativePlaybackSession) throws -> Void)? = nil,
        checkSession: (NativePlaybackSession) -> Void,
        duringPlayback: ((NativePlaybackSession) async throws -> Void)? = nil,
        checkFile: (URL) throws -> Output
    ) async throws -> Output {
        let wave = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: wave) }

        do {
            let defaults = [
                "audio": "auto",
                "ao": "pcm",
                "ao-pcm-file": wave.path,
                "audio-samplerate": "48000",
                "audio-channels": "mono",
                "gapless-audio": "no",
                "pause": "no",
            ]
            let session = try NativePlaybackSession(
                options: defaults.merging(options) { _, option in option }
            )
            defer { session.close() }
            try configureSession?(session)
            try session.command([
                "loadfile",
                argument ?? (source.isFileURL ? source.path : source.absoluteString),
            ])
            try await duringPlayback?(session)
            let track = options["audio"].map { " (audio track \($0))" } ?? ""
            try await eventually("audio finished decoding from \(source.lastPathComponent)\(track)") {
                if let status = session.consumeEndFileStatus() {
                    try #require(
                        status >= 0,
                        "Audio playback of \(source.lastPathComponent)\(track) failed with mpv error \(status)"
                    )
                }
                return session.property("eof-reached")?.boolValue == true
            }

            #expect(session.property("current-ao")?.stringValue == "pcm")
            checkSession(session)
        }

        return try checkFile(wave)
    }

    private func expectMatroskaChannelTones(
        _ name: String,
        decoder: String,
        layout: String,
        duration: Double,
        frequencies: [Int?]
    ) async throws {
        let source = try TestPaths.testMedia(name)
        try await withPCMOutput(source, options: ["ad": "\(decoder),-", "audio-channels": layout]) {
            session in
            expectFormat("mkv", session)
            #expect(session.property("current-tracks/audio/decoder")?.stringValue == decoder)
        } checkFile: { output in
            let file = try AVAudioFile(forReading: output)
            let format = file.processingFormat
            try #require(format.channelCount == frequencies.count && format.sampleRate == 48000)
            #expect(abs(Double(file.length) / format.sampleRate - duration) < 0.15)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            let tones = frequencies.compactMap(\.self)
            for start in [0.25, duration - 0.45] {
                file.framePosition = AVAudioFramePosition(start * format.sampleRate)
                try file.read(into: buffer, frameCount: buffer.frameCapacity)
                try #require(buffer.frameLength == buffer.frameCapacity)
                let samples = try #require(buffer.floatChannelData)
                for (channel, sourceTone) in frequencies.enumerated() {
                    guard let frequency = sourceTone else { continue }

                    func level(_ hz: Int) -> Double {
                        let step = 2 * Double.pi * Double(hz) / format.sampleRate
                        let frames = Int(buffer.frameLength)
                        var real = 0.0
                        var imaginary = 0.0
                        for frame in 0 ..< frames {
                            let sample = Double(samples[channel][frame])
                            real += sample * cos(step * Double(frame))
                            imaginary += sample * sin(step * Double(frame))
                        }
                        return 2 * hypot(real, imaginary) / Double(frames)
                    }

                    let expected = level(frequency)
                    #expect(expected > 0.015, "\(name) channel \(channel) has \(frequency) Hz at \(start)s")
                    for other in tones where other != frequency {
                        #expect(level(other) < expected / 3, "\(name) channel \(channel) at \(start)s")
                    }
                }
            }
        }
    }

    private func expectMonoTone(_ file: AVAudioFile, at start: Double, frequency: Int) throws {
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)
        )
        file.framePosition = AVAudioFramePosition(start * file.processingFormat.sampleRate)
        try file.read(into: buffer)
        try #require(buffer.frameLength == buffer.frameCapacity)
        let samples = try UnsafeBufferPointer(
            start: #require(buffer.floatChannelData)[0],
            count: Int(buffer.frameLength)
        )
        #expect(samples.contains { $0 > 0.025 }, "Decoded PCM contains an audible signal at \(start)s")
        let crossings = zip(samples, samples.dropFirst()).count { $0.0 <= 0 && $0.1 > 0 }
        #expect(abs(crossings - frequency / 10) <= 2, "Decoded the \(frequency) Hz tone at \(start)s")
    }

    private func expectFormat(_ format: String, _ session: NativePlaybackSession) {
        let names = session.property("file-format")?.stringValue?.split(separator: ",").map(String.init)
        #expect(names?.contains(format) == true, "Expected \(format) among \(names ?? [])")
    }

    private func seek(_ session: NativePlaybackSession, to time: Double) async throws {
        try session.command(["seek", String(time), "absolute+exact"])
        try await eventually("decoded frame at \(time) seconds") {
            session.property("seeking")?.boolValue == false
                && abs((session.property("time-pos")?.doubleValue ?? -1) - time) < 0.1
        }
    }

    private func expectRedMP4ThroughSeek(_ url: URL, _ session: NativePlaybackSession) async throws {
        try await session.load(url)
        expectFormat("mov", session)
        #expect(session.property("current-tracks/video/decoder")?.stringValue == "h264")
        #expect(session.property("seekable")?.boolValue == true)
        try await seek(session, to: 0.5)
        try await expectPrimaryColor(0, session)
    }

    private func expectPrimaryColor(_ channel: Int, _ session: NativePlaybackSession) async throws {
        try await eventually("decoded frame with color component \(channel)") {
            let frame = try screenshot(session)
            return frame.isPrimaryColor(channel, x: frame.width / 2, y: frame.height / 2)
        }
    }

    private func expectGrayLevel(_ level: Int, _ session: NativePlaybackSession) async throws {
        try await eventually("decoded gray level \(level)") {
            let frame = try screenshot(session)
            let rgb = frame.rgb(x: frame.width / 2, y: frame.height / 2).map(Int.init)
            return rgb.allSatisfy { abs($0 - level) < 25 } && (rgb.max() ?? 0) - (rgb.min() ?? 0) < 5
        }
    }

    private func screenshot(_ session: NativePlaybackSession, mode: String = "video") throws -> Frame {
        let frame = try #require(try session.command(["screenshot-raw", mode, "rgba"])?.mapValue)
        let width = try Int(#require(frame["w"]?.integerValue))
        let height = try Int(#require(frame["h"]?.integerValue))
        let stride = try Int(#require(frame["stride"]?.integerValue))
        guard case let .data(pixels) = frame["data"] else { throw CocoaError(.fileReadCorruptFile) }

        try #require(width > 0 && height > 0 && stride >= width * 4 && pixels.count >= stride * height)
        return Frame(width: width, height: height, stride: stride, pixels: pixels)
    }
}
