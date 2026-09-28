#if os(macOS) && DEBUG
import AppKit
import AVFoundation
import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.benchmark), .serialized)
@MainActor
struct MPVSampleBufferResizePresentationTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["MPVUI_RUN_RESIZE_BENCHMARK"] == "1"),
        arguments: ["window", "large-window", "layout", "pip"]
    )
    func `sample buffers keep presenting through window and PiP resizing`(mode: String) async throws {
        NSApplication.shared.setActivationPolicy(.regular)
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"],
            autoPlay: true, hardwareDecoding: .automatic, hdrPolicy: .automatic,
            sdrOutput: .compatibility8Bit, videoOutput: .sampleBuffer
        ))
        defer { fixture.close() }
        fixture.window.styleMask.insert(.resizable)
        fixture.window.setContentSize(CGSize(width: 800, height: 450))
        fixture.window.level = .floating
        fixture.window.center()
        if mode == "large-window" {
            fixture.window.setFrameOrigin(.zero)
        }
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.window.orderFrontRegardless()
        NSApplication.shared.activate()
        fixture.surface.layoutSubtreeIfNeeded()
        // Loop boundaries flush AVFoundation and reset its metrics. Use a clip
        // long enough to cover the entire measurement without a seek or reload.
        let media = ProcessInfo.processInfo.environment["MPVUI_RESIZE_NATIVE_MEDIA"]
            .map { URL(fileURLWithPath: $0) } ?? TestPaths.baselineMedia
        try #require(FileManager.default.fileExists(atPath: media.path), "Missing resize media: \(media.path)")
        fixture.player.load(media)
        let video = fixture.player.sampleBufferDisplayLayer
        try await eventually("sample-buffer playback is ready") {
            fixture.player.state == .playing && video.isReadyForDisplay
        }
        try #require(fixture.player.videoOutput == .sampleBuffer)
        try await Task.sleep(for: .seconds(1))
        let baselineStart = try #require(await video.sampleBufferRenderer.videoPerformanceMetrics)
        try await Task.sleep(for: .seconds(2))
        let baselineEnd = try #require(await video.sampleBufferRenderer.videoPerformanceMetrics)
        let baseline = metrics(from: baselineStart, to: baselineEnd)
        try #require(baseline.frames > 20, "An awake, visible window must present sample-buffer frames")

        var resizeWindow = fixture.window
        if mode == "pip" {
            try await eventually("sample-buffer system PiP is available") { fixture.player.pictureInPicture.isPossible }
            fixture.player.pictureInPicture.start()
            try await eventually("system PiP owns the sample-buffer surface") {
                fixture.player.pictureInPicture.isActive
                    && fixture.surface.window != nil && fixture.surface.window !== fixture.window
            }
            resizeWindow = try #require(fixture.surface.window)
            try await Task.sleep(for: .milliseconds(500))
        }
        defer {
            if mode == "pip" {
                fixture.player.pictureInPicture.stop()
            }
        }
        let before = await fixture.player.lifecycleDiagnostics()
        let start = try #require(await video.sampleBufferRenderer.videoPerformanceMetrics)
        var widths: Set<Int> = []
        if mode != "layout" {
            fixture.surface.viewWillStartLiveResize()
        }
        for index in 0 ..< 240 {
            let wave = sin(Double(index) * .pi / 90)
            let width = mode == "pip" ? 450 + 90 * wave
                : mode == "large-window" ? 1300 + 350 * wave : 900 + 220 * wave
            let height = mode == "pip" ? width * 9 / 16
                : mode == "large-window" ? 680 + 150 * cos(Double(index) * .pi / 70)
                : 440 + 120 * cos(Double(index) * .pi / 70)
            resizeWindow.setContentSize(CGSize(width: width, height: height))
            fixture.surface.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
            let host = fixture.surface.metalLayer
            let hostSize = try #require(host.presentation()).bounds.size
            let videoSize = try #require(video.presentation()).bounds.size
            #expect(abs(hostSize.width - videoSize.width) < 1)
            #expect(abs(hostSize.height - videoSize.height) < 1)
            #expect(video.superlayer === host)
            #expect(video.isReadyForDisplay)
            #expect(video.sampleBufferRenderer.status != .failed)
            #expect(fixture.player.videoOutput == .sampleBuffer)
            widths.insert(Int(videoSize.width))
        }
        if mode != "layout" {
            fixture.surface.viewDidEndLiveResize()
        }
        try await Task.sleep(for: .milliseconds(400))
        let end = try #require(await video.sampleBufferRenderer.videoPerformanceMetrics)
        let resizing = metrics(from: start, to: end)
        #expect(widths.count > 50, "Native video must follow intermediate window sizes")
        #expect(video.frame == fixture.surface.metalLayer.bounds)
        #expect(resizing.frames > baseline.frames * 3 / 2)
        #expect(resizing.corrupted == 0)
        #expect(resizing.dropFraction <= baseline.dropFraction + 0.02)
        #expect(resizing.averageDelay <= baseline.averageDelay + 0.01)
        let after = await fixture.player.lifecycleDiagnostics()
        #expect(after.handlesCreated == before.handlesCreated)
        #expect(after.loadCommands == before.loadCommands)
        #expect(fixture.player.lastError == nil)
        let report: [String: Any] = [
            "mode": mode, "output": "sampleBuffer", "media": media.lastPathComponent,
            "intermediateWidths": widths.count,
            "baseline": baseline.report, "resizingAndSettling": resizing.report,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: TestPaths.repositoryRoot.appendingPathComponent(".build/resize-sample-buffer-\(mode).json"))
        print(String(decoding: data, as: UTF8.self))
        if mode == "pip" {
            fixture.player.pictureInPicture.stop()
            try await eventually("sample-buffer playback returns inline") {
                !fixture.player.pictureInPicture.isActive && !fixture.player.pictureInPicture.isTransitioning
                    && fixture.surface.window === fixture.window
            }
            #expect(fixture.player.videoOutput == .sampleBuffer)
            #expect(video.superlayer === fixture.surface.metalLayer)
        }
    }

    private func metrics(from start: AVVideoPerformanceMetrics, to end: AVVideoPerformanceMetrics) -> Metrics {
        Metrics(
            frames: end.totalNumberOfFrames - start.totalNumberOfFrames,
            dropped: end.numberOfDroppedFrames - start.numberOfDroppedFrames,
            corrupted: end.numberOfCorruptedFrames - start.numberOfCorruptedFrames,
            delay: end.totalAccumulatedFrameDelay - start.totalAccumulatedFrameDelay
        )
    }

    private struct Metrics {
        let frames: Int
        let dropped: Int
        let corrupted: Int
        let delay: Double
        var dropFraction: Double {
            Double(dropped) / Double(max(1, frames))
        }

        var averageDelay: Double {
            delay / Double(max(1, frames - dropped))
        }

        var report: [String: Any] {
            [
                "frames": frames,
                "dropped": dropped,
                "corrupted": corrupted,
                "dropFraction": dropFraction,
                "averageDelayMs": averageDelay * 1000
            ]
        }
    }
}
#endif
