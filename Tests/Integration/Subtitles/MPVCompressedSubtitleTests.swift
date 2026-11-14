import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.integration, .nativePatch), .serialized)
@MainActor
struct MPVCompressedSubtitleTests {

    @Test(arguments: ["mkv", "lavf"], ["subtitles-none.mkv", "subtitles-zlib.mkv"])
    func `Matroska text cues decode through both demuxers`(demuxer: String, file: String) async throws {
        let session = try NativePlaybackSession(options: ["demuxer": demuxer, "sid": "1"])
        defer { session.close() }
        try await session.load(TestPaths.testMedia(file))
        try #require(session.property("demuxer")?.stringValue == demuxer)
        try session.command(["seek", "1", "absolute+exact"])
        try await eventually("decoded subtitle from \(file) using \(demuxer)") {
            session.property("sub-text")?.stringValue == "Styled subtitle sample"
        }
        try session.command(["seek", "11", "absolute+exact"])
        try await eventually("subtitle clears at the end of its cue") {
            (session.property("time-pos")?.doubleValue ?? 0) > 10
                && (session.property("sub-text")?.stringValue ?? "").isEmpty
        }
    }
}
