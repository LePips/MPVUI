#if os(macOS)
import AppKit
import CryptoKit
import Darwin
import Foundation
import Metal
@testable import MPVCore
@testable import MPVUI
import Testing

/// One configuration per process avoids attributing retained driver/compiler
/// resources from an earlier player to a later measurement.
@Suite(.tags(.benchmark), .serialized)
@MainActor
struct MPVMetalResourceBenchmarkTests {

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MPVUI_RUN_METAL_RESOURCE_BENCHMARK"] == "1"))
    func `measure Metal resources`() async throws {
        let environment = ProcessInfo.processInfo.environment

        let options = try JSONDecoder().decode(
            [String: String].self,
            from: Data((environment["MPVUI_METAL_OPTIONS"] ?? "{}").utf8)
        )

        let seconds = Double(environment["MPVUI_BENCHMARK_SECONDS"] ?? "5") ?? 5
        try #require(seconds.isFinite && (2 ... 60).contains(seconds))

        let media = environment["MPVUI_BENCHMARK_MEDIA"].map { URL(fileURLWithPath: $0) } ?? TestPaths.baselineMedia

        let checksum = try SHA256.hash(data: Data(contentsOf: media, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }
            .joined()

        let device = try #require(MTLCreateSystemDefaultDevice())
        let baseline = try resources(device)

        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null", "sid": "no"].merging(options) { _, new in new },
            automaticallyPlays: true,
            logLevel: .info,
            isLoopingEnabled: true,
            renderingQuality: .init(preset: .balanced),
            videoOutput: .metal
        ))
        defer { fixture.close() }
        fixture.window.setContentSize(NSSize(width: 1280, height: 720))
        fixture.surface.layoutSubtreeIfNeeded()

        let player = fixture.player
        player.setDiagnosticsEnabled(true)

        var log: [String] = []
        player.logHandler = { log.append("\($0.prefix): \($0.message)") }
        player.load(media)

        try await eventually("Metal benchmark playback", timeout: .seconds(20)) {
            player.state == .playing && player.position > .zero
                && player.playbackDiagnostics.freshRenderPasses?.isEmpty == false
        }

        try await Task.sleep(for: .seconds(2))

        let cpuStart = clock()
        let wallStart = ContinuousClock.now
        var samples: [[String: UInt64]] = []

        while wallStart.duration(to: .now).seconds < seconds {
            try samples.append(resources(device))
            try await Task.sleep(for: .milliseconds(100))
        }

        let cpuSeconds = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)
        let wallSeconds = wallStart.duration(to: .now).seconds
        let diagnostics = player.playbackDiagnostics
        let hardwareDecoder = player.mediaInformation.hardwareDecoder
        let drawableSize = fixture.surface.metalLayer.drawableSize
        let pixelFormat = fixture.surface.metalLayer.pixelFormat.rawValue

        try #require(player.lastError == nil)
        try #require(player.state == .playing || player.state == .seeking)
        player.pause()
        try await eventually("benchmark pause") { player.isPaused }
        try await Task.sleep(for: .seconds(1))

        let paused = try resources(device)

        player.stop()

        try await eventually("benchmark renderer retirement") {
            let lifecycle = await player.lifecycleDiagnostics()
            return lifecycle.handlesCreated == lifecycle.handlesDestroyed
        }

        try await Task.sleep(for: .seconds(1))

        let stopped = try resources(device)

        let report: [String: Any] = [
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "device": device.name,
            "media": media.path,
            "sha256": checksum,
            "options": options,
            "effectiveRenderingOptions": diagnostics.renderingQuality.effectiveOptions,
            "hardwareDecoder": hardwareDecoder.map { $0 as Any } ?? NSNull(),
            "cpuSecondsPerWallSecond": cpuSeconds / wallSeconds,
            "wallSeconds": wallSeconds,
            "drawableWidth": drawableSize.width,
            "drawableHeight": drawableSize.height,
            "pixelFormat": pixelFormat,
            "baseline": baseline,
            "steady": samples,
            "paused": paused,
            "stopped": stopped,
            "outputDroppedFrames": diagnostics.outputDroppedFrames.map { $0 as Any } ?? NSNull(),
            "decoderDroppedFrames": diagnostics.decoderDroppedFrames.map { $0 as Any } ?? NSNull(),
            "renderPasses": diagnostics.freshRenderPasses?.map(\.name) ?? [],
            "log": log,
            "limitations": """
            Local test-process CPU and sampled memory, including diagnostics. Metal allocations include other users of the device in \
            this process. This is not a physical iOS device or energy benchmark.
            """,
        ]

        let output = environment["MPVUI_BENCHMARK_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? TestPaths.repositoryRoot.appendingPathComponent(".build/metal-resources.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Metal resources: \(output.path)")
    }

    private func resources(_ device: any MTLDevice) throws -> [String: UInt64] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)

        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        try #require(status == KERN_SUCCESS)

        return [
            "footprintBytes": info.phys_footprint,
            "residentBytes": info.resident_size,
            "metalAllocatedBytes": UInt64(device.currentAllocatedSize),
        ]
    }
}
#endif
