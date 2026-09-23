#if os(macOS)
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import Libmpv
@testable import MPVUI
import QuartzCore
import Testing

/// Run through `Build/benchmark`; deliberately absent from ordinary tests.
/// Measurements describe this process, fixture and display, not energy use.
@Suite(.tags(.benchmark), .serialized)
@MainActor
struct MPVPerformanceBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MPVUI_RUN_PERFORMANCE_BENCHMARKS"] == "1"))
    func `measure local runtime workloads`() async throws {
        let settings = try BenchmarkSettings()
        var workloads: [[String: Any]] = []
        if settings.suites.contains("micro") {
            workloads += try chapterWorkloads(repetitions: settings.repetitions)
            try workloads.append(resizeWorkload(repetitions: settings.repetitions))
        }
        if settings.suites.contains("playback") {
            workloads += try await playbackWorkloads(settings)
        }
        var runtime: [String: Any] = [
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "processorCount": ProcessInfo.processInfo.processorCount,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "mpvClientAPIVersion": mpv_client_api_version(),
            "diagnosticsRefreshSeconds": 0.5,
            "limitations": [
                "CPU includes all test-process threads and diagnostics polling; one CPU second per wall second means one core.",
                "RSS is sampled every 100 ms within each playback interval; it is not lifetime peak RSS or memory owned only by this player.",
                "Playback position is accumulated across observed loop wraps. Counter deltas are unavailable across loops or observed resets, and omitted for fixtures shorter than warmup + sample + 2 seconds.",
                "Counter deltas subtract cached diagnostics polled every 500 ms with 100 ms timer leeway; their endpoints do not exactly match the measured CPU/wall interval.",
                "Native subtitles can fall back internally from YUV composition to Core Image. The paused readback pixel format is an observation; it does not measure the fraction of interval frames using either route.",
                "Optional native readback records unavailable pixels explicitly. Media dimensions and native readiness/clock checks do not validate rendered pixels or actual output dimensions.",
                "GPU pass timings are mpv rolling observations at interval end, not a whole-interval GPU or energy measurement.",
                "Startup latency runs from engine load submission to playback-restart. Paused exact-seek latency runs from the caller request to the engine's seek/restart completion; neither measures physical display latency.",
            ],
        ]
        runtime.merge(loadedMPVImage()) { _, value in value }
        let report: [String: Any] = [
            "workloads": workloads,
            "runtime": runtime,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: settings.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settings.output, options: .atomic)
        print("Performance benchmark: \(settings.output.path)")
    }

    private func chapterWorkloads(repetitions: Int) throws -> [[String: Any]] {
        try [(64, 500), (4096, 30)].map { count, iterations in
            let node = MPVNodeValue.array((0 ..< count).map { index in
                .map(["title": .string("Chapter \(index + 1)"), "time": .double(Double(index) * 30)])
            })
            var measurement = BenchmarkMeasurement(
                id: "parse_chapters_\(count)",
                parameters: ["chapterCount": count, "iterations": iterations, "warmupIterations": 5, "inputVersion": 1]
            )
            for _ in 0 ..< 5 {
                _ = parseChapterChecksum(node)
            }
            let expected = parseChapterChecksum(node) * iterations
            for repetition in 1 ... repetitions {
                let start = ProcessTiming()
                var checksum = 0
                for _ in 0 ..< iterations {
                    checksum &+= parseChapterChecksum(node)
                }
                let elapsed = start.elapsed()
                try #require(checksum == expected)
                measurement.addTiming(elapsed, operations: iterations)
                measurement.observations.append(["repetition": repetition, "checksum": checksum])
            }
            return measurement.json
        }
    }

    /// Consuming observable parser output prevents a benchmark of discarded work.
    @inline(never)
    private func parseChapterChecksum(_ node: MPVNodeValue) -> Int {
        let chapters = MPVEngine.parseChapters(node)
        return chapters.count + (chapters.last?.id ?? 0) + Int(chapters.first?.endTime?.seconds ?? 0)
    }

    private func resizeWorkload(repetitions: Int) throws -> [String: Any] {
        let layer = CAMetalLayer()
        let size = CGSize(width: 1280, height: 720)
        var commits = 0
        let coordinator = MPVRenderSurfaceResizeCoordinator(
            commit: { _ in commits += 1
                return true
            },
            // The production diagnostic consumer does this when logging is off.
            emitDiagnostic: { _ in }
        )
        coordinator.activate(
            layer: layer, layerAddress: MPVRenderSurfaceResizeCoordinator.layerAddress(of: layer),
            contentsScale: 1, committedSize: size
        )
        defer { coordinator.deactivate() }
        let iterations = 100_000
        var measurement = BenchmarkMeasurement(
            id: "resize_diagnostics_disabled",
            parameters: [
                "iterations": iterations,
                "warmupIterations": 1000,
                "width": 1280,
                "height": 720,
                "contentsScale": 1,
                "requestKind": "discrete",
                "geometry": "alreadyCommitted",
                "diagnostics": "disabled"
            ]
        )
        for _ in 0 ..< 1000 {
            coordinator.requestResize(to: size, contentsScale: 1, kind: .discrete)
        }
        for repetition in 1 ... repetitions {
            let start = ProcessTiming()
            var accepted = 0
            for _ in 0 ..< iterations {
                if coordinator.requestResize(to: size, contentsScale: 1, kind: .discrete) {
                    accepted += 1
                }
            }
            let elapsed = start.elapsed()
            try #require(accepted == 0 && commits == 0)
            measurement.addTiming(elapsed, operations: iterations)
            measurement.observations.append(["repetition": repetition, "acceptedRequests": accepted])
        }
        return measurement.json
    }

    private func playbackWorkloads(_ settings: BenchmarkSettings) async throws -> [[String: Any]] {
        let fixtureHash = try sha256(settings.media)
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MPVUI-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let subtitle = temporaryDirectory.appendingPathComponent("benchmark-overlay.ass")
        try benchmarkSubtitle.write(to: subtitle, atomically: true, encoding: .utf8)
        let subtitleHash = try sha256(subtitle)
        let backends: [MPVPlayerConfiguration.VideoOutput] = [.metal, .sampleBuffer]
        var collected: [MPVPlayerConfiguration.VideoOutput: BenchmarkMeasurement] = [:]
        // Alternate which backend runs first to reduce systematic thermal/order bias.
        for repetition in 1 ... settings.repetitions {
            for offset in backends.indices {
                let backend = backends[(offset + repetition - 1) % backends.count]
                let sample = try await playbackSample(settings, backend: backend, subtitle: subtitle, repetition: repetition)
                if collected[backend] == nil {
                    var parameters: [String: Any] = [
                        "fixtureSHA256": fixtureHash, "sampleSeconds": settings.sampleSeconds,
                        "warmupSeconds": settings.warmupSeconds, "samplePollSeconds": 0.1,
                        "decoder": "software", "backend": backend.rawValue, "hdrPolicy": "disabled",
                        "sdrOutput": "compatibility8Bit", "audioOutput": "null", "loopFile": "inf",
                        "renderingPreset": "balanced", "logLevel": "none",
                        "windowWidthPoints": 1280, "windowHeightPoints": 720,
                        "videoZoom": backend == .sampleBuffer ? 0.25 : 0,
                        "subtitleSHA256": backend == .sampleBuffer ? subtitleHash : "none",
                    ]
                    parameters.merge(sample.parameters) { _, new in new }
                    collected[backend] = BenchmarkMeasurement(
                        id: backend == .metal ? "playback_metal_balanced_software" : "playback_sample_buffer_software",
                        parameters: parameters
                    )
                } else {
                    for (key, value) in sample.parameters {
                        let previous = try #require(collected[backend]!.parameters[key])
                        let previousData = try JSONSerialization.data(withJSONObject: [previous], options: .sortedKeys)
                        let currentData = try JSONSerialization.data(withJSONObject: [value], options: .sortedKeys)
                        try #require(previousData == currentData, "Playback output changed between repetitions: \(key)")
                    }
                }
                for (name, value) in sample.metrics {
                    collected[backend]!.add(name, value: value.value, unit: value.unit, direction: value.direction)
                }
                collected[backend]!.observations.append(sample.observation)
            }
        }
        return backends.compactMap { collected[$0]?.json }
    }

    private func playbackSample(
        _ settings: BenchmarkSettings, backend: MPVPlayerConfiguration.VideoOutput, subtitle: URL, repetition: Int
    ) async throws -> PlaybackSample {
        var options = ["ao": "null", "loop-file": "inf", "osd-level": "0"]
        if backend == .sampleBuffer {
            options["video-zoom"] = "0.25"
            options["sub-visibility"] = "yes"
        } else {
            options["sid"] = "no"
        }
        let player = MPVPlayer(configuration: .init(
            additionalOptions: options,
            autoPlay: true,
            hardwareDecoding: .disabled,
            hdrPolicy: .disabled,
            logLevel: .none,
            loop: true,
            renderingQuality: .init(preset: .balanced),
            sdrOutput: .compatibility8Bit,
            videoOutput: backend
        ))
        let surface = MPVPlatformVideoPlayer(player: player)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        defer {
            player.stop()
            surface.detach()
            window.contentView = nil
            window.orderOut(nil)
        }
        window.contentView = surface
        window.orderFront(nil)
        surface.layoutSubtreeIfNeeded()
        surface.activateRenderingSurface()
        player.load(settings.media)
        if backend == .sampleBuffer {
            player.loadExternalTrack(subtitle, type: .subtitle, select: true)
        }
        try await waitForPlayback(player, backend: backend)
        try await Task.sleep(for: .seconds(settings.warmupSeconds))
        try validatePlayback(player, backend: backend)
        let screen = try #require(window.screen, "Playback benchmarking requires an attached display.")
        let dimensions = try #require(player.mediaInformation.dimensions)
        try #require(dimensions.width > 0 && dimensions.height > 0, "Media dimensions must be positive.")
        let duration = player.duration.seconds
        // A fixture shorter than two polls cannot be measured reliably across wraps.
        try #require(duration.isFinite && duration >= 0.5, "Use a local video fixture at least 0.5 seconds long.")
        let before = player.playbackDiagnostics
        var position = player.position.seconds
        let initialPosition = position
        var progress = 0.0
        var wraps = 0
        var residentSamples: [Double] = []
        var observations: [[String: Any]] = []
        var previousCounters = diagnosticCounters(before)
        var resetCount = 0
        if let resident = residentMemoryBytes() {
            residentSamples.append(resident)
        }
        let start = ProcessTiming()
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            try validatePlayback(player, backend: backend)
            let currentPosition = player.position.seconds
            if currentPosition < position - 0.25 {
                wraps += 1
                progress += max(0, duration - position + currentPosition)
            } else {
                progress += max(0, currentPosition - position)
            }
            position = currentPosition
            let counters = diagnosticCounters(player.playbackDiagnostics)
            for (name, value) in counters {
                if let previous = previousCounters[name], value < previous {
                    resetCount += 1
                }
            }
            previousCounters = counters
            var point: [String: Any] = [
                "elapsedSeconds": start.wallSeconds,
                "positionSeconds": currentPosition,
                "state": String(describing: player.state),
                "counters": counters
            ]
            if let resident = residentMemoryBytes() {
                residentSamples.append(resident)
                point["residentBytes"] = resident
            }
            observations.append(point)
        } while start.wallSeconds < settings.sampleSeconds
        let elapsed = start.elapsed()
        let after = player.playbackDiagnostics
        try #require(progress > 0, "Playback did not advance during the measurement interval.")
        var sample = PlaybackSample(parameters: [
            "sourceWidth": dimensions.width, "sourceHeight": dimensions.height, "sourceDurationSeconds": duration,
            "surfaceWidthPoints": surface.bounds.width, "surfaceHeightPoints": surface.bounds.height,
            "backingScaleFactor": window.backingScaleFactor,
            "effectiveBackend": player.videoOutput.rawValue,
            "decodedPixelFormat": after.decoder.decodedPixelFormat ?? "unknown",
        ], observation: [
            "repetition": repetition, "positionStartSeconds": initialPosition, "positionEndSeconds": position,
            "loopWraps": wraps, "counterResets": resetCount, "countersStart": diagnosticCounters(before),
            "countersEnd": diagnosticCounters(after), "intervalSamples": observations,
            "startLatencySeconds": after.startLatencySeconds.map { $0 as Any } ?? NSNull(),
        ])
        try #require(window.screen === screen, "Playback display changed during the measurement interval.")
        sample.parameters["displayID"] = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .intValue ?? -1
        sample.parameters["screenFramePoints"] = [
            "x": screen.frame.origin.x, "y": screen.frame.origin.y,
            "width": screen.frame.width, "height": screen.frame.height,
        ]
        sample.parameters["maximumFramesPerSecond"] = screen.maximumFramesPerSecond
        sample.add("cpuSeconds", elapsed.cpuSeconds, unit: "seconds", direction: "lower")
        let startLatency = try #require(after.startLatencySeconds, "Playback startup latency is unavailable.")
        try #require(startLatency.isFinite && startLatency >= 0)
        sample.add("startLatencySeconds", startLatency, unit: "seconds", direction: "lower")
        sample.add("wallSeconds", elapsed.wallSeconds, unit: "seconds", direction: "neutral")
        sample
            .add(
                "cpuSecondsPerWallSecond",
                elapsed.cpuSeconds / elapsed.wallSeconds,
                unit: "cpu-seconds/wall-second",
                direction: "lower"
            )
        sample.add("playbackProgressSeconds", progress, unit: "seconds", direction: "neutral")
        sample.add(
            "playbackSecondsPerWallSecond",
            progress / elapsed.wallSeconds,
            unit: "playback-seconds/wall-second",
            direction: "neutral"
        )
        if let peak = residentSamples.max() {
            sample.add("residentPeakBytes", peak, unit: "bytes", direction: "lower")
            sample.add("residentMeanBytes", residentSamples.reduce(0, +) / Double(residentSamples.count), unit: "bytes", direction: "lower")
        }
        // Diagnostics are polled by the engine at 500 ms. A wrap can hide the
        // exact reset; never invent a full-interval delta for a looping fixture.
        // Keep optional metric sets stable for the bundled short looping fixture,
        // even if scheduling happens to produce a particular interval with no wrap.
        let counterDeltasEligible = duration > settings.warmupSeconds + settings.sampleSeconds + 2
        sample.parameters["intervalCounterDeltasEligible"] = counterDeltasEligible
        if counterDeltasEligible && wraps == 0 && resetCount == 0 {
            let firstCounters = diagnosticCounters(before)
            var deltas: [String: Int64] = [:]
            for (name, end) in diagnosticCounters(after) {
                if let begin = firstCounters[name], end >= begin {
                    deltas[name] = end - begin
                    let direction = ["nativeSampleBuildCount", "nativePixelBufferCopies", "nativeSampleBuildNanoseconds"]
                        .contains(name) ? "neutral" : "lower"
                    sample.add(
                        name + "Delta",
                        Double(end - begin),
                        unit: name.hasSuffix("Nanoseconds") ? "nanoseconds" : "count",
                        direction: direction
                    )
                }
            }
            if let count = deltas["nativeSampleBuildCount"], count > 0 {
                if let nanoseconds = deltas["nativeSampleBuildNanoseconds"] {
                    sample.add(
                        "nativeSampleBuildNanosecondsPerSample",
                        Double(nanoseconds) / Double(count),
                        unit: "nanoseconds/sample",
                        direction: "lower"
                    )
                }
                if let copies = deltas["nativePixelBufferCopies"] {
                    sample.add(
                        "nativePixelBufferCopiesPerSample",
                        Double(copies) / Double(count),
                        unit: "copies/sample",
                        direction: "lower"
                    )
                }
            }
        }
        if backend == .metal {
            sample.parameters["drawableWidth"] = surface.metalLayer.drawableSize.width
            sample.parameters["drawableHeight"] = surface.metalLayer.drawableSize.height
            sample.parameters["pixelFormat"] = surface.metalLayer.pixelFormat.rawValue
            sample.parameters["configuredPrecision"] = player.renderColorStatus.precision.rawValue
            sample.parameters["effectiveOptions"] = after.renderingQuality.effectiveOptions
            sample.parameters["outputPrimaries"] = player.mediaInformation.hdr.output.primaries ?? "unknown"
            sample.parameters["outputPixelFormat"] = player.mediaInformation.hdr.output.pixelFormat ?? "unknown"
            sample.parameters["outputTransfer"] = player.mediaInformation.hdr.output.transferFunction.mpvValue ?? "unknown"
            let passes = after.freshRenderPasses ?? []
            sample.observation["freshRenderPasses"] = passes.map { pass in
                [
                    "name": pass.name,
                    "averageNanoseconds": pass.averageNanoseconds.map { $0 as Any } ?? NSNull(),
                    "peakNanoseconds": pass.peakNanoseconds.map { $0 as Any } ?? NSNull()
                ] as [String: Any]
            }
            let averages = passes.compactMap(\.averageNanoseconds)
            if averages.count == passes.count && !averages.isEmpty {
                sample.add(
                    "gpuPassAverageTotalNanoseconds",
                    averages.reduce(0) { $0 + Double($1) },
                    unit: "nanoseconds",
                    direction: "lower"
                )
            }
        } else {
            let outputInput = player.mediaInformation.hdr.videoOutputInput
            sample.parameters["videoOutputInputPixelFormat"] = try #require(
                outputInput.pixelFormat,
                "Native video output input format is unavailable."
            )
            sample.parameters["videoOutputInputPrimaries"] = outputInput.primaries ?? "unknown"
            sample.parameters["videoOutputInputTransfer"] = outputInput.transferFunction.mpvValue ?? "unknown"
            sample.parameters["videoOutputInputMatrix"] = outputInput.matrix ?? "unknown"
            sample.parameters["videoOutputInputRange"] = outputInput.range ?? "unknown"
            let renderer = player.sampleBufferDisplayLayer.sampleBufferRenderer
            try #require(renderer.status != .failed)
        }
        // Keep seeking and readback outside the steady-playback CPU/GPU/counter
        // interval. An exact paused seek submits a destination frame; merely
        // stopping the clock can leave AVFoundation's displayedPixelBuffer nil
        // even when the layer is ready and has no rendering error.
        let seekTarget = duration * 0.75
        sample.parameters["postIntervalSeek"] = "paused-absolute-exact"
        sample.parameters["postIntervalSeekTargetFraction"] = 0.75
        sample.parameters["postIntervalSeekTimeoutSeconds"] = 8
        let seekSeconds = try await pausedExactSeek(player, target: seekTarget)
        sample.add("pausedExactSeekCompletionSeconds", seekSeconds, unit: "seconds", direction: "lower")
        sample.observation["postIntervalSeekTargetSeconds"] = seekTarget
        sample.observation["postIntervalSeekPositionSeconds"] = player.position.seconds
        if backend == .sampleBuffer {
            sample.parameters["nativeReadbackPolicy"] = settings.nativeReadbackPolicy
            let buffer: CVPixelBuffer?
            do {
                buffer = try await pausedNativeBuffer(player)
            } catch let BenchmarkReadbackError.noPausedNativeFrame(details) {
                guard settings.nativeReadbackPolicy == "optional" else {
                    throw BenchmarkReadbackError.noPausedNativeFrame(details)
                }
                buffer = nil
                sample.observation["readbackTimeoutDiagnostics"] = details
            }
            sample.observation["readbackAvailable"] = buffer != nil
            let layer = player.sampleBufferDisplayLayer
            try #require(player.isPaused && layer.isReadyForDisplay)
            try #require(layer.sampleBufferRenderer.status != .failed && player.lastError == nil)
            let timebase = try #require(layer.controlTimebase)
            try #require(CMTimebaseGetRate(timebase) == 0)
            try #require(
                abs(CMTimebaseGetTime(timebase).seconds - seekTarget) < 0.15,
                "Native readback clock did not reach the exact seek destination."
            )
            try #require(
                player.mediaInformation.dimensions == dimensions,
                "Media dimensions changed during the native playback workload."
            )
            if let buffer {
                let width = CVPixelBufferGetWidth(buffer)
                let height = CVPixelBufferGetHeight(buffer)
                try #require(width > 0 && height > 0)
                if settings.nativeReadbackPolicy == "required" {
                    sample.parameters["outputWidth"] = width
                    sample.parameters["outputHeight"] = height
                } else {
                    sample.observation["outputWidth"] = width
                    sample.observation["outputHeight"] = height
                }
                // Internal native routes may differ; observed output format is
                // never a control or proof of the route used throughout timing.
                sample.observation["pausedReadbackPixelFormat"] = CVPixelBufferGetPixelFormatType(buffer)
            }
        }
        return sample
    }

    private func pausedExactSeek(_ player: MPVPlayer, target: Double) async throws -> Double {
        player.pause()
        for _ in 0 ..< 250 {
            try #require(player.lastError == nil)
            if player.isPaused {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(player.isPaused, "Playback did not pause before the exact-seek measurement.")
        let start = ProcessTiming()
        // This existing API drains stale events, requests absolute+exact, and
        // completes only after the matching seek/restart (or its 8 s timeout).
        let completed = await player.seekForPictureInPicture(to: .seconds(target))
        let seconds = start.wallSeconds
        try #require(completed, "The paused exact seek did not complete.")
        // Main-actor published state can follow engine completion. Validate it
        // after timing instead of adding polling granularity to seek latency.
        for _ in 0 ..< 250 {
            try #require(player.lastError == nil)
            if player.isPaused && abs(player.position.seconds - target) < 0.15 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(
            player.isPaused && abs(player.position.seconds - target) < 0.15,
            "Paused exact-seek position did not reach its target: \(player.position.seconds), target=\(target)."
        )
        return seconds
    }

    private func pausedNativeBuffer(_ player: MPVPlayer) async throws -> CVPixelBuffer {
        let layer = player.sampleBufferDisplayLayer
        for _ in 0 ..< 250 {
            try #require(player.lastError == nil, "Native output failed while preparing pixel readback.")
            try #require(layer.sampleBufferRenderer.status != .failed)
            if player.isPaused, layer.isReadyForDisplay,
               let timebase = layer.controlTimebase, CMTimebaseGetRate(timebase) == 0,
               let buffer = layer.sampleBufferRenderer.displayedPixelBuffer()
            {
                return buffer
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let timebase = layer.controlTimebase
        let details = "state=\(player.state), isPaused=\(player.isPaused), "
            + "isReadyForDisplay=\(layer.isReadyForDisplay), "
            + "timebaseRate=\(timebase.map { String(CMTimebaseGetRate($0)) } ?? "nil"), "
            + "timebaseTime=\(timebase.map { String(CMTimebaseGetTime($0).seconds) } ?? "nil"), "
            + "position=\(player.position.seconds), rendererStatus=\(layer.sampleBufferRenderer.status.rawValue), "
            + "rendererError=\(String(describing: layer.sampleBufferRenderer.error)), "
            + "playerError=\(String(describing: player.lastError))"
        print("Native paused readback timed out: \(details)")
        throw BenchmarkReadbackError.noPausedNativeFrame(details)
    }

    private func waitForPlayback(_ player: MPVPlayer, backend: MPVPlayerConfiguration.VideoOutput) async throws {
        for _ in 0 ..< 200 {
            if player.lastError != nil {
                break
            }
            if player.state == .playing, player.position.seconds > 0,
               player.playbackDiagnostics.decoder.session == .software,
               backend == .metal ||
               (player.sampleBufferDisplayLayer.isReadyForDisplay && player.subtitleTracks.contains(where: \.isSelected))
            {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(Bool(false), "Benchmark playback failed to start: \(player.state), \(String(describing: player.lastError))")
    }

    private func validatePlayback(_ player: MPVPlayer, backend: MPVPlayerConfiguration.VideoOutput) throws {
        try #require(player.lastError == nil, "Playback error: \(String(describing: player.lastError))")
        // A loop emits seeking/restart events while remaining in active playback.
        try #require(player.state == .playing || player.state == .seeking, "Playback stopped during benchmark: \(player.state)")
        try #require(player.videoOutput == backend && player.videoOutputFallbackReason == nil, "Benchmark output fell back.")
        try #require(player.playbackDiagnostics.decoder.session == .software)
        try #require(player.playbackDiagnostics.fallbackReasons.isEmpty)
        if backend == .metal {
            try #require(player.playbackDiagnostics.renderingQuality.resolvedPreset == .balanced)
            try #require(!player.playbackDiagnostics.renderingQuality.effectiveOptions.isEmpty)
            try #require(player.renderColorStatus.precision == .unorm8)
        } else {
            try #require(player.sampleBufferDisplayLayer.sampleBufferRenderer.status != .failed)
            try #require(player.subtitleTracks.contains { $0.isSelected && ["ass", "ssa"].contains($0.codec ?? "") })
            try #require(player.playbackDiagnostics.nativeOutputStatistics?.sampleBuildCount != nil)
        }
    }
}

private enum BenchmarkReadbackError: Error {
    case noPausedNativeFrame(String)
}

private struct BenchmarkSettings {
    let repetitions: Int
    let sampleSeconds: Double
    let warmupSeconds: Double
    let suites: Set<String>
    let output: URL
    let media: URL
    let nativeReadbackPolicy: String

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        repetitions = Int(environment["MPVUI_PERF_REPETITIONS"] ?? "3") ?? 0
        sampleSeconds = Double(environment["MPVUI_PERF_SAMPLE_SECONDS"] ?? "3") ?? .nan
        warmupSeconds = Double(environment["MPVUI_PERF_WARMUP_SECONDS"] ?? "1") ?? .nan
        suites = Set((environment["MPVUI_PERF_SUITES"] ?? "micro,playback").split(separator: ",").map(String.init))
        nativeReadbackPolicy = environment["MPVUI_PERF_NATIVE_READBACK"] ?? "required"
        try #require((1 ... 20).contains(repetitions))
        try #require(sampleSeconds.isFinite && (0.5 ... 60).contains(sampleSeconds))
        try #require(warmupSeconds.isFinite && (0.5 ... 30).contains(warmupSeconds))
        try #require(!suites.isEmpty && suites.isSubset(of: ["micro", "playback"]))
        try #require(
            ["required", "optional"].contains(nativeReadbackPolicy),
            "MPVUI_PERF_NATIVE_READBACK must be required or optional."
        )
        let root = TestPaths.repositoryRoot
        output = environment["MPVUI_PERF_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(".build/benchmarks/runtime.json")
        media = environment["MPVUI_PERF_MEDIA"].map { URL(fileURLWithPath: $0) } ?? TestPaths.baselineMedia
    }
}

private struct BenchmarkMetric {
    let unit: String
    let direction: String
    var samples: [Double] = []
    var json: [String: Any] {
        ["unit": unit, "direction": direction, "samples": samples]
    }
}

private struct BenchmarkMeasurement {
    let id: String
    var parameters: [String: Any]
    var metrics: [String: BenchmarkMetric] = [:]
    var observations: [[String: Any]] = []

    mutating func add(_ name: String, value: Double, unit: String, direction: String) {
        guard value.isFinite else { return }
        if metrics[name] == nil {
            metrics[name] = .init(unit: unit, direction: direction)
        }
        metrics[name]!.samples.append(value)
    }

    mutating func addTiming(_ elapsed: ProcessElapsed, operations: Int) {
        add(
            "wallNanosecondsPerOperation",
            value: elapsed.wallSeconds * 1e9 / Double(operations),
            unit: "nanoseconds/operation",
            direction: "lower"
        )
        add(
            "cpuNanosecondsPerOperation",
            value: elapsed.cpuSeconds * 1e9 / Double(operations),
            unit: "cpu-nanoseconds/operation",
            direction: "lower"
        )
        add(
            "cpuSecondsPerWallSecond",
            value: elapsed.cpuSeconds / elapsed.wallSeconds,
            unit: "cpu-seconds/wall-second",
            direction: "neutral"
        )
    }

    var json: [String: Any] {
        ["id": id, "parameters": parameters, "metrics": metrics.mapValues(\.json), "observations": observations]
    }
}

private struct PlaybackSample {
    struct Value { let value: Double
        let unit: String
        let direction: String
    }

    var parameters: [String: Any]
    var observation: [String: Any]
    var metrics: [String: Value] = [:]

    mutating func add(_ name: String, _ value: Double, unit: String, direction: String) {
        if value.isFinite {
            metrics[name] = Value(value: value, unit: unit, direction: direction)
        }
    }
}

private struct ProcessElapsed { let cpuSeconds: Double
    let wallSeconds: Double
}

private struct ProcessTiming {
    private let cpu = clock()
    private let wall = DispatchTime.now().uptimeNanoseconds
    var wallSeconds: Double {
        Double(DispatchTime.now().uptimeNanoseconds - wall) / 1e9
    }

    func elapsed() -> ProcessElapsed {
        ProcessElapsed(cpuSeconds: Double(clock() - cpu) / Double(CLOCKS_PER_SEC), wallSeconds: wallSeconds)
    }
}

private func residentMemoryBytes() -> Double? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) : nil
}

private func diagnosticCounters(_ diagnostics: MPVPlaybackDiagnostics) -> [String: Int64] {
    let values: [String: Int64?] = [
        "outputDroppedFrames": diagnostics.outputDroppedFrames,
        "decoderDroppedFrames": diagnostics.decoderDroppedFrames,
        "mistimedFrames": diagnostics.mistimedFrames,
        "delayedFrames": diagnostics.delayedFrames,
        "nativePixelBufferCopies": diagnostics.nativeOutputStatistics?.pixelBufferCopies,
        "nativeSampleBuildCount": diagnostics.nativeOutputStatistics?.sampleBuildCount,
        "nativeSampleBuildNanoseconds": diagnostics.nativeOutputStatistics?.totalSampleBuildNanoseconds,
    ]
    return values.compactMapValues { $0 }
}

private func sha256(_ file: URL) throws -> String {
    try SHA256.hash(data: Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
}

private func loadedMPVImage() -> [String: Any] {
    let function: @convention(c) () -> UInt = mpv_client_api_version
    let pointer = unsafeBitCast(function, to: UnsafeRawPointer.self)
    var info = Dl_info()
    guard dladdr(pointer, &info) != 0, let filename = info.dli_fname else { return ["libraryKind": "unresolved"] }
    let file = URL(fileURLWithPath: String(cString: filename)).resolvingSymlinksInPath()
    let lower = file.lastPathComponent.lowercased()
    return [
        "libraryPath": file.path,
        "librarySHA256": (try? sha256(file)).map { $0 as Any } ?? NSNull(),
        "libraryKind": lower
            .contains("mpv") && (lower.contains("dylib") || file.path.contains(".framework/")) ? "dynamic-library" : "static-host-image",
    ]
}

private let benchmarkSubtitle = """
[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
ScaledBorderAndShadow: yes
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Helvetica,44,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,40,40,40,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,9:59:59.00,Default,,0,0,0,,Local performance benchmark — persistent subtitle overlay
"""
#endif
