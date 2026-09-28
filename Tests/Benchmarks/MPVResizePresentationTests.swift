#if os(macOS) && DEBUG
import AppKit
import Foundation
@testable import MPVUI
import Synchronization
import Testing

@Suite(.tags(.benchmark), .serialized)
@MainActor
struct MPVResizePresentationTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["MPVUI_RUN_RESIZE_BENCHMARK"] == "1"),
        arguments: ["window", "large-window", "layout", "pip"]
    )
    func `video continues presenting during resizing`(mode: String) async throws {
        NSApplication.shared.setActivationPolicy(.regular)
        let options = ["ao": "null", "loop-file": "inf"]
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: options,
            autoPlay: true, hardwareDecoding: .disabled, hdrPolicy: .disabled,
            sdrOutput: .compatibility8Bit, videoOutput: .metal
        ))
        defer { fixture.close() }
        fixture.window.styleMask.insert(.resizable)
        fixture.window.setContentSize(CGSize(width: 800, height: 450))
        fixture.surface.layoutSubtreeIfNeeded()
        fixture.window.level = .floating
        fixture.window.center()
        if mode == "large-window" {
            fixture.window.setFrameOrigin(.zero)
        }
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.window.orderFrontRegardless()
        NSApplication.shared.activate()
        let times = Mutex<[Double]>([])
        let layer = try #require(fixture.surface.metalLayer as? MPVMetalLayer)
        layer.observePresentation { time in
            times.withLock { $0.append(time) }
        }
        defer { layer.observePresentation(nil) }
        try fixture.player.load(TestPaths.testMedia("feature-120fps.mkv"))
        try await eventually("playing resize fixture") { fixture.player.state == .playing }
        try await Task.sleep(for: .seconds(2))
        times.withLock { $0.removeAll() }
        try await Task.sleep(for: .seconds(2))
        let baseline = times.withLock { result in
            let values = result
            result.removeAll()
            return values
        }
        try #require(
            baseline.filter { $0 > 0 }.count > 100,
            "An awake, visible test window is required for Metal presentation timestamps; \(fixture.presentationContext)"
        )
        var resizeWindow = fixture.window
        if mode == "pip" {
            try await eventually("system PiP is available") { fixture.player.pictureInPicture.isPossible }
            fixture.player.pictureInPicture.start()
            try await eventually("system PiP owns the surface") {
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
        times.withLock { $0.removeAll() }
        let initialDrawable = layer.drawableSize
        var mediaPositions: Set<Int> = []
        if mode != "layout" {
            fixture.surface.viewWillStartLiveResize()
        }
        for index in 0 ..< 240 {
            let wave = sin(Double(index) * .pi / 90)
            let width = mode == "pip" ? 450 + 90 * wave
                : mode == "large-window" ? 1300 + 350 * wave : 900 + 220 * wave
            let height = mode == "pip" ? width * 9 / 16
                : mode == "large-window" ? 680 + 150 * cos(Double(index) * .pi / 70) : 440 + 120 * cos(Double(index) * .pi / 70)
            resizeWindow.setContentSize(CGSize(
                width: width,
                height: height
            ))
            fixture.surface.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
            mediaPositions.insert(Int(fixture.player.position.seconds * 10))
            if mode != "layout" {
                #expect(layer.drawableSize == initialDrawable, "Interactive geometry must reuse drawable buffers")
            }
        }
        let resizing = times.withLock { result in
            let values = result
            result.removeAll()
            return values
        }
        if mode != "layout" {
            fixture.surface.viewDidEndLiveResize()
        }
        try await Task.sleep(for: .milliseconds(400))
        let settled = times.withLock { $0 }
        let finalSize = MPVRenderSurfaceConfiguration.drawableSize(
            for: fixture.surface.bounds.size, scale: layer.contentsScale
        )
        #expect(layer.drawableSize == finalSize)
        let after = await fixture.player.lifecycleDiagnostics()
        func metrics(_ reported: [Double]) -> [String: Double] {
            let values = reported.filter { $0 > 0 }.sorted()
            let gaps = zip(values.dropFirst(), values).map(-).sorted()
            guard !gaps.isEmpty else { return ["frames": Double(values.count), "callbacks": Double(reported.count)] }
            return [
                "frames": Double(values.count),
                "maxGapMs": gaps.last! * 1000,
                "p95GapMs": gaps[Int(Double(gaps.count - 1) * 0.95)] * 1000,
                "gapsOver50ms": Double(gaps.filter { $0 > 0.05 }.count)
            ]
        }
        let report: [String: Any] = [
            "mode": mode, "baseline": metrics(baseline), "resizing": metrics(resizing),
            "settled": metrics(Array(resizing.suffix(1)) + settled),
            "resizeCommands": after.surfaceResizeCommands - before.surfaceResizeCommands,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let name = ProcessInfo.processInfo.environment["MPVUI_RESIZE_REPORT"] ?? ".build/resize-presentation.json"
        try data.write(to: TestPaths.repositoryRoot.appendingPathComponent(name.replacingOccurrences(of: ".json", with: "-\(mode).json")))
        print(String(decoding: data, as: UTF8.self))
        #expect(resizing.count > 100)
        #expect(mediaPositions.count > 10, "Playback must advance while the viewport changes")
        #expect(metrics(resizing)["gapsOver50ms"] == 0, "Video must not stall during resizing")
        #expect(
            metrics(Array(resizing.suffix(1)) + settled)["gapsOver50ms"] == 0,
            "Restoring full resolution must not introduce a long presentation stall"
        )
        let baselineP95 = try #require(metrics(baseline)["p95GapMs"])
        #expect(try #require(metrics(resizing)["p95GapMs"]) <= baselineP95 * 2.1)
        #expect(fixture.player.lastError == nil)
        #expect(after.handlesCreated == before.handlesCreated)
        #expect(after.loadCommands == before.loadCommands)
        if mode == "pip" {
            fixture.player.pictureInPicture.stop()
            try await eventually("system PiP restores inline playback") {
                !fixture.player.pictureInPicture.isActive && !fixture.player.pictureInPicture.isTransitioning
                    && fixture.surface.window === fixture.window
            }
        }
    }
}
#endif
