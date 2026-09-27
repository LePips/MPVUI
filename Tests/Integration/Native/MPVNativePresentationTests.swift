#if os(iOS) && !targetEnvironment(simulator)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import MPVUI
import Testing

/// Foreground physical-device checks. AVFoundation metrics and displayed-buffer
/// readback strengthen clock-only evidence; neither measures panel scanout or
/// audible synchronization. Keep these calls out of performance measurements.
@Suite(.tags(.integration, .nativePatch), .serialized)
struct MPVNativePresentationTests {
    @MainActor
    @Test(arguments: [0.5, 1.0, 1.5])
    func `framework frame metrics and displayed pixels follow transport`(rate: Double) async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null", "sub-auto": "no", "sub-visibility": "no", "osd-level": "0"],
            autoPlay: false, hardwareDecoding: .videoToolbox, videoOutput: .sampleBuffer
        ))
        defer { fixture.close() }
        let player = fixture.player
        let layer = player.sampleBufferDisplayLayer
        let renderer = layer.sampleBufferRenderer
        // The generated fixture is a moving 15 fps testsrc2 chart. Exact integer
        // seconds align to its frame boundaries; subtitles/OSD stay disabled.
        try await fixture.loadPaused(at: .seconds(1))
        try await eventually("initial native pixels at exactly one second") {
            guard let clock = layer.controlTimebase else { return false }
            return layer.isReadyForDisplay && renderer.displayedPixelBuffer() != nil
                && CMTimebaseGetRate(clock) == 0
                && abs(CMTimebaseGetTime(clock).seconds - 1) < 0.1
        }
        let clock = try #require(layer.controlTimebase)
        let reference = try displayedLuma(renderer)
        player.setPlaybackRate(rate)
        #expect(CMTimebaseGetRate(clock) == 0)
        player.play()
        try await eventually("native playback timebase at requested rate") {
            player.state == .playing && abs(CMTimebaseGetRate(clock) - rate) < 0.01
        }
        // Exclude startup transition from steady drop assertions. Fetch a fresh
        // framework snapshot for this segment; seek may reset its generation.
        try await Task.sleep(for: .milliseconds(600))
        let before = try await metrics(renderer)
        let startPosition = player.position.seconds
        let start = ProcessInfo.processInfo.systemUptime
        var previous = try displayedLuma(renderer)
        var changedFrames = 0
        for _ in 0 ..< 12 {
            try await Task.sleep(for: .milliseconds(100))
            let current = try displayedLuma(renderer)
            if current != previous {
                changedFrames += 1
            }
            previous = current
            try #require(player.state == .playing && !player.isPaused)
            try #require(player.videoOutput == .sampleBuffer && player.videoOutputFallbackReason == nil)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let progress = player.position.seconds - startPosition
        let after = try await metrics(renderer)
        #expect((0.8 ... 1.2).contains(progress / elapsed / rate))
        #expect(changedFrames >= 3, "Moving chart must yield multiple distinct displayed-buffer readbacks")
        #expect(after.frames > before.frames, "AVFoundation frame metrics must advance with the clock and pixels")
        #expect(after.dropped == before.dropped, "AVFoundation reported a settled display-deadline drop")
        #expect(after.corrupted == before.corrupted)
        #expect(after.delay >= before.delay)
        print("Native presentation rate=\(rate), wall=\(elapsed), mediaProgress=\(progress), "
            + "changedReadbacks=\(changedFrames), frames=\(after.frames - before.frames), "
            + "drops=\(after.dropped - before.dropped), frameDelay=\(after.delay - before.delay)")

        player.pause()
        try await eventually("native clock paused") { player.isPaused && CMTimebaseGetRate(clock) == 0 }
        try await Task.sleep(for: .milliseconds(300))
        let pausedPosition = player.position.seconds
        let paused = try displayedLuma(renderer)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try displayedLuma(renderer) == paused)
        #expect(abs(player.position.seconds - pausedPosition) < 0.1)

        // The return to an exact earlier timestamp must reproduce that decoded
        // image, not merely update public time-pos or increase a build counter.
        for target in [4.0, 1.0] {
            let prior = try displayedLuma(renderer)
            #expect(await player.seekForPictureInPicture(to: .seconds(target)))
            try await eventually("exact paused seek renders the destination image") {
                guard let current = try? displayedLuma(renderer) else { return false }
                return player.isPaused && CMTimebaseGetRate(clock) == 0
                    && abs(player.position.seconds - target) < 0.1
                    && abs(CMTimebaseGetTime(clock).seconds - target) < 0.1
                    && current != prior && (target != 1 || current == reference)
            }
        }
        #expect(player.playbackDiagnostics.decoder.videoToolboxSessionUsesHardware == true)
        #expect(player.playbackDiagnostics.fallbackReasons.isEmpty)
        #expect(renderer.status != .failed)
        #expect(player.lastError == nil)
    }

    private struct Metrics {
        let frames: Int
        let dropped: Int
        let corrupted: Int
        let delay: Double
    }

    @MainActor
    private func metrics(_ renderer: AVSampleBufferVideoRenderer) async throws -> Metrics {
        for _ in 0 ..< 30 {
            if let value = await renderer.videoPerformanceMetrics, value.totalNumberOfFrames > 0 {
                return Metrics(
                    frames: value.totalNumberOfFrames,
                    dropped: value.numberOfDroppedFrames,
                    corrupted: value.numberOfCorruptedFrames,
                    delay: value.totalAccumulatedFrameDelay
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Physical metrics are mandatory for this test. Missing data must never
        // become zero drops or a silently passing progression assertion.
        Issue.record("AVFoundation video performance metrics unavailable on the physical device")
        throw PresentationEvidenceUnavailable.metrics
    }

    private enum PresentationEvidenceUnavailable: Error { case pixels, metrics }

    @MainActor
    private func displayedLuma(_ renderer: AVSampleBufferVideoRenderer) throws -> Data {
        guard let buffer = renderer.displayedPixelBuffer() else { throw PresentationEvidenceUnavailable.pixels }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        try #require(format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        try #require(CVPixelBufferGetPlaneCount(buffer) == 2)
        try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        var bytes = Data(capacity: width * height)
        for row in 0 ..< height {
            bytes.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width)
        }
        return bytes
    }
}
#endif
