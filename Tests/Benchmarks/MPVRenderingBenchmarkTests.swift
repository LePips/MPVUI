#if os(macOS)
import AppKit
import CryptoKit
import Darwin
import Foundation
@testable import MPVUI
import Testing

/// Opt-in, reproducible renderer measurements. These measure this machine and
/// fixture, not energy use or a general ordering of quality presets.
@Suite(.tags(.benchmark), .serialized)
@MainActor
struct MPVRenderingBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MPVUI_RUN_RENDERER_BENCHMARK"] == "1"))
    func `measure presets`() async throws {
        let environment = ProcessInfo.processInfo.environment
        let media = environment["MPVUI_BENCHMARK_MEDIA"].map { URL(fileURLWithPath: $0) } ?? TestPaths.baselineMedia
        let duration = min(60, max(2, Double(environment["MPVUI_BENCHMARK_SECONDS"] ?? "5") ?? 5))
        let mediaData = try Data(contentsOf: media, options: .mappedIfSafe)
        let checksum = SHA256.hash(data: mediaData).map { String(format: "%02x", $0) }.joined()
        let repetitions = min(10, max(1, Int(environment["MPVUI_BENCHMARK_REPETITIONS"] ?? "3") ?? 3))
        let presets: [MPVRenderingQuality.Preset] = [.battery, .balanced, .highQuality]
        var measurements: [[String: Any]] = []
        for sampleIndex in 0 ..< repetitions * presets.count {
            let repetition = sampleIndex / presets.count
            let preset = presets[(sampleIndex % presets.count + repetition) % presets.count]
            let player = MPVPlayer(configuration: .init(
                autoPlay: true, hardwareDecoding: .disabled,
                hdrPolicy: .disabled, sdrOutput: .compatibility8Bit,
                renderingQuality: .init(preset: preset)
            ))
            let surface = MPVPlatformVideoPlayer(player: player)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = surface
            window.orderFront(nil)
            surface.layoutSubtreeIfNeeded()
            surface.activateRenderingSurface()
            player.load(media)
            for _ in 0 ..< 100 {
                if player.state == .playing || player.lastError != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(player.state == .playing)
            // Exclude shader compilation, decoder startup and the first statistics interval.
            try await Task.sleep(for: .seconds(1))
            let cpuStart = clock()
            let wallStart = ContinuousClock.now
            try await Task.sleep(for: .seconds(duration))
            let cpuSeconds = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)
            let wallSeconds = wallStart.duration(to: .now).seconds
            let observed = player.playbackDiagnostics
            #expect(observed.renderingQuality.resolvedPreset == preset)
            #expect(!observed.renderingQuality.effectiveOptions.isEmpty)
            #expect(player.renderColorStatus.precision == .unorm8)
            #expect(player.mediaInformation.hdr.output.primaries == "bt.709")
            #expect(player.mediaInformation.hdr.output.transferFunction == .sRGB)
            #expect(player.mediaInformation.hdr.output.pixelFormat?.contains("8") == true)
            var sample: [String: Any] = [
                "preset": preset.rawValue,
                "repetition": repetition + 1,
                "effectiveOptions": observed.renderingQuality.effectiveOptions,
                "cpuSeconds": cpuSeconds,
                "wallSeconds": wallSeconds,
                "drawableWidth": surface.metalLayer.drawableSize.width,
                "drawableHeight": surface.metalLayer.drawableSize.height,
                "pixelFormat": surface.metalLayer.pixelFormat.rawValue,
                "configuredPrecision": player.renderColorStatus.precision.rawValue,
                "rendererOutputPixelFormat": player.mediaInformation.hdr.output.pixelFormat.map { $0 as Any } ?? NSNull(),
                "rendererOutputPrimaries": player.mediaInformation.hdr.output.primaries.map { $0 as Any } ?? NSNull(),
                "rendererOutputTransfer": player.mediaInformation.hdr.output.transferFunction.mpvValue.map { $0 as Any } ?? NSNull(),
                "sourceWidth": player.mediaInformation.dimensions.map { $0.width as Any } ?? NSNull(),
                "sourceHeight": player.mediaInformation.dimensions.map { $0.height as Any } ?? NSNull(),
                "freshPasses": observed.freshRenderPasses?.map { pass in
                    [
                        "name": pass.name,
                        "averageNanoseconds": pass.averageNanoseconds.map { $0 as Any } ?? NSNull(),
                        "peakNanoseconds": pass.peakNanoseconds.map { $0 as Any } ?? NSNull()
                    ] as [String: Any]
                } ?? [],
            ]
            sample["outputDroppedFrames"] = observed.outputDroppedFrames
            sample["decoderDroppedFrames"] = observed.decoderDroppedFrames
            sample["startLatencySeconds"] = observed.startLatencySeconds
            sample["estimatedFilterFramesPerSecond"] = observed.estimatedFilterFramesPerSecond
            measurements.append(sample)
            player.stop()
            surface.detach()
            window.contentView = nil
            window.orderOut(nil)
        }
        let report: [String: Any] = [
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "fixture": media.lastPathComponent,
            "sha256": checksum,
            "decoder": "software",
            "sdrPolicy": "compatibility8Bit",
            "sampleSeconds": duration,
            "repetitions": repetitions,
            "warmupSeconds": 1,
            "order": "Rotated: battery/balanced/highQuality; balanced/highQuality/battery; highQuality/battery/balanced",
            "outputPoints": "1280x720",
            "limitations": "Local process CPU and GPU pass timing. Includes diagnostics polling and test process overhead. No measured energy, calibrated image quality or physical refresh guarantee.",
            "measurements": measurements,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let defaultOutput = TestPaths.repositoryRoot
            .appendingPathComponent(".build/renderer-benchmark.json")
        let output = environment["MPVUI_BENCHMARK_OUTPUT"].map { URL(fileURLWithPath: $0) } ?? defaultOutput
        try data.write(to: output, options: .atomic)
        print("Renderer benchmark: \(output.path)")
    }
}
#endif
