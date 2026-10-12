import AVFoundation
import CoreMedia
import Foundation
@testable import MPVUI
import Synchronization
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVPassthroughAudioSinkTests {
    @Test
    func `PCM audio bypasses the passthrough sink and plays through the next output`() async throws {
        let sink = RecordingSink()
        let player = try MPVPlayer(
            url: TestPaths.testMedia("audio-pcm-stereo.mka"),
            configuration: .init(
                // The spatial output comes first, as with a sink set, so mpv sets its gain before it
                // opens, then refuses PCM for the next output.
                additionalOptions: ["ao": "spatial,null"],
                audio: .init(passthroughSink: sink),
                autoPlay: true
            )
        )
        defer { player.stop() }
        try await eventually("PCM plays through the next output") {
            player.state == .playing && player.position > .seconds(0.5)
        }
        #expect(sink.calls.withLock { $0 }.isEmpty)
        #expect(player.lastError == nil)
    }
}

/// Records every call mpv makes, without rendering anything.
private final class RecordingSink: MPVPassthroughAudioSink {
    let calls = Mutex<[String]>([])

    var isReady: Bool {
        record("isReady")
        return true
    }

    func open(
        codec: MPVPassthroughAudioCodec,
        synchronizer: AVSampleBufferRenderSynchronizer,
        fallback: @escaping @Sendable () -> Void
    ) -> Bool {
        record("open")
        return false
    }

    func begin(at time: CMTime) {
        record("begin")
    }

    func write(_ bursts: UnsafeRawBufferPointer) {
        record("write")
    }

    func end() {
        record("end")
    }

    func close() {
        record("close")
    }

    func setVolume(_ volume: Float) {
        record("setVolume")
    }

    private func record(_ call: String) {
        calls.withLock { $0.append(call) }
    }
}
