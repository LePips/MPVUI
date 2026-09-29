#if os(iOS)
import AVFoundation
import Darwin
import Foundation
import Metal
import MPVUI
import Observation
import SwiftUI
import UIKit

/// Opt-in, on-device measurements. Each launch runs one player and one source.
@MainActor
struct PlaybackBenchmarkView: View {
    @State
    private var benchmark = PlaybackBenchmark()
    @Environment(\.scenePhase)
    private var scenePhase

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let player = benchmark.mpv {
                MPVVideoPlayer(player: player)
            } else if let player = benchmark.av {
                BenchmarkAVSurface(player: player)
            }
            Text(benchmark.status)
                .font(.caption.monospaced())
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.7))
                .accessibilityIdentifier("playbackBenchmarkStatus")
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { benchmark.surfaceSize = $0 }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                benchmark.lostForeground = true
            }
        }
        .task { await benchmark.run() }
    }
}

private struct BenchmarkAVSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> BenchmarkAVView {
        let view = BenchmarkAVView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: BenchmarkAVView, context: Context) {
        view.playerLayer.player = player
    }

    static func dismantleUIView(_ view: BenchmarkAVView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

private final class BenchmarkAVView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

private struct BenchmarkFailure: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

private struct PlaybackBenchmarkSettings {
    let player: String
    let media: URL
    let output: URL
    let seconds: Double
    let warmup: Double
    let requestedBackend: String
    let backend: MPVPlayerConfiguration.VideoOutput?
    let sdrOutput: MPVSDROutputPolicy
    let softwareDecoding: Bool
    let options: [String: String]

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var options: [String: String] = [:]
        var software = false
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            if key == "--playback-benchmark" {
                index += 1
                continue
            }
            if key == "--benchmark-software-decoding" {
                software = true
                index += 1
                continue
            }
            guard key.hasPrefix("--benchmark-") else { index += 1
                continue
            }
            guard index + 1 < arguments.count else { throw BenchmarkFailure(message: "Missing value for \(key)") }
            let value = arguments[index + 1]
            if key == "--benchmark-option" {
                let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty else {
                    throw BenchmarkFailure(message: "Use --benchmark-option key=value")
                }
                options[String(parts[0])] = String(parts[1])
            } else {
                guard [
                    "--benchmark-player",
                    "--benchmark-media",
                    "--benchmark-output",
                    "--benchmark-seconds",
                    "--benchmark-warmup",
                    "--benchmark-backend",
                    "--benchmark-sdr-output"
                ].contains(key) else {
                    throw BenchmarkFailure(message: "Unknown benchmark argument \(key)")
                }
                values[key] = value
            }
            index += 2
        }
        player = values["--benchmark-player"] ?? "mpv"
        guard ["mpv", "avplayer"].contains(player) else { throw BenchmarkFailure(message: "Player must be mpv or avplayer") }
        guard let source = values["--benchmark-media"], !source.isEmpty else {
            throw BenchmarkFailure(message: "--benchmark-media is required")
        }
        let documents = Self.documents
        if let url = URL(string: source), let scheme = url.scheme {
            guard ["file", "http", "https"].contains(scheme.lowercased()) else {
                throw BenchmarkFailure(message: "Media must be a file, HTTP, or HTTPS URL")
            }
            media = url
        } else if source.hasPrefix("/") {
            media = URL(fileURLWithPath: source)
        } else {
            media = documents.appendingPathComponent(source)
        }
        if media.isFileURL, !FileManager.default.fileExists(atPath: media.path) {
            throw BenchmarkFailure(message: "Media file does not exist: \(media.lastPathComponent)")
        }
        output = try Self.outputURL(filename: values["--benchmark-output"] ?? "playback-benchmark.json")
        seconds = Double(values["--benchmark-seconds"] ?? "30") ?? .nan
        warmup = Double(values["--benchmark-warmup"] ?? "5") ?? .nan
        guard seconds.isFinite, (2 ... 300).contains(seconds), warmup.isFinite, (0 ... 60).contains(warmup) else {
            throw BenchmarkFailure(message: "Sample must be 2–300 seconds and warmup 0–60 seconds")
        }
        requestedBackend = values["--benchmark-backend"] ?? "default"
        guard ["default", "sampleBuffer", "metal"].contains(requestedBackend) else {
            throw BenchmarkFailure(message: "Backend must be default, sampleBuffer or metal")
        }
        backend = MPVPlayerConfiguration.VideoOutput(rawValue: requestedBackend)
        let sdrName = values["--benchmark-sdr-output"] ?? "automatic"
        guard ["automatic", "compatibility8Bit"].contains(sdrName),
              let sdr = MPVSDROutputPolicy(rawValue: sdrName)
        else {
            throw BenchmarkFailure(message: "SDR output must be automatic or compatibility8Bit")
        }
        sdrOutput = sdr
        softwareDecoding = software
        self.options = options
        if player == "avplayer", software || !options.isEmpty || backend == .metal || sdrOutput != .automatic {
            throw BenchmarkFailure(message: "MPV options, software decoding, SDR policy and Metal backend selection apply only to mpv")
        }
    }

    /// Omitting videoOutput deliberately exercises the complete library resolver,
    /// including its treatment of additional options and output policies.
    var mpvConfiguration: MPVPlayerConfiguration {
        .init(
            additionalOptions: options, audio: .init(audioSession: .hostManaged),
            autoPlay: true, hardwareDecoding: softwareDecoding ? .disabled : .automatic,
            logLevel: .none, sdrOutput: sdrOutput, videoOutput: backend ?? .sampleBuffer, volume: 100
        )
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func outputURL(filename: String) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\") else {
            throw BenchmarkFailure(message: "--benchmark-output must be a filename")
        }
        return documents.appendingPathComponent("Benchmarks", isDirectory: true).appendingPathComponent(filename)
    }

    static var failureOutput: URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--benchmark-output"), index + 1 < arguments.count,
           let output = try? outputURL(filename: arguments[index + 1])
        {
            return output
        }
        return documents.appendingPathComponent("Benchmarks/playback-benchmark-error-\(UUID().uuidString).json")
    }

    var json: [String: Any] {
        // Avoid persisting credentials or authorization queries from Jellyfin URLs.
        var components = URLComponents(url: media, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return [
            "player": player,
            "media": components?.string ?? media.lastPathComponent,
            "backend": player == "mpv" ? requestedBackend : "AVPlayerLayer",
            "resolvedBackend": player == "mpv" ? mpvConfiguration.videoOutput.rawValue : "AVPlayerLayer",
            "sdrOutput": sdrOutput.rawValue,
            "softwareDecoding": softwareDecoding,
            "options": options,
            "sampleSeconds": seconds,
            "warmupSeconds": warmup,
            "samplePollSeconds": 0.1,
            "audioVolume": 1.0,
            "loop": false,
            "logLevel": "none"
        ]
    }
}

@MainActor
@Observable
private final class PlaybackBenchmark {
    var mpv: MPVPlayer?
    var av: AVPlayer?
    var status = "Preparing playback benchmark"
    @ObservationIgnored
    var surfaceSize = CGSize.zero
    @ObservationIgnored
    var lostForeground = false
    @ObservationIgnored
    private weak var releasedMPV: MPVPlayer?
    @ObservationIgnored
    private weak var releasedAV: AVPlayer?
    @ObservationIgnored
    private var hasRun = false
    @ObservationIgnored
    private var phases: [String: Any] = [:]
    @ObservationIgnored
    private var timeline: [[String: Any]] = []
    @ObservationIgnored
    private var validation: [String: Any] = [:]
    @ObservationIgnored
    private var diagnostics: [String: Any] = [:]
    @ObservationIgnored
    private var maximumFootprint: UInt64 = 0
    @ObservationIgnored
    private var maximumResident: UInt64 = 0
    @ObservationIgnored
    private var maximumMetalAllocated: UInt64?
    @ObservationIgnored
    private var metalDevice: (any MTLDevice)?
    @ObservationIgnored
    private var maximumCacheBytes: Int64 = 0
    @ObservationIgnored
    private var maximumTotalCacheBytes: Int64?
    @ObservationIgnored
    private var maximumAbsoluteAVDrift = 0.0
    @ObservationIgnored
    private var observedAVDrift = false
    @ObservationIgnored
    private var memoryReadFailed = false
    @ObservationIgnored
    private var beginUptime = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored
    private var lastTimelineUptime = -Double.infinity

    func run() async {
        guard !hasRun else { return }
        hasRun = true
        beginUptime = ProcessInfo.processInfo.systemUptime
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        var settings: PlaybackBenchmarkSettings?
        var failure: String?
        var environment: [String: Any] = [:]
        defer {
            releasePlayers()
            _ = ExampleAudioSession.deactivate()
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
        }
        do {
            let parsed = try PlaybackBenchmarkSettings(arguments: ProcessInfo.processInfo.arguments)
            settings = parsed
            guard !FileManager.default.fileExists(atPath: parsed.output.path) else {
                throw BenchmarkFailure(message: "Report already exists; choose a new --benchmark-output")
            }
            if let audioError = ExampleAudioSession.activate() {
                throw BenchmarkFailure(message: audioError)
            }
            // Create this once for both players before baseline sampling. Device
            // creation and framework setup must not be mistaken for playback cost.
            metalDevice = MTLCreateSystemDefaultDevice()
            try await measure("baseline", seconds: 1)
            environment = environmentSnapshot()
            // The first startup memory sample precedes engine, decoder and renderer allocation.
            try await measure("startup", timeout: 30, action: { self.createPlayer(parsed) }, until: {
                self.isPlaying && self.position > 0.2
            })
            guard duration.isFinite, duration > parsed.warmup + parsed.seconds + 8 else {
                throw BenchmarkFailure(message: "Use seekable VOD at least warmup + sample + 8 seconds long; observed duration \(duration)")
            }
            validation["sourceDurationSeconds"] = duration
            diagnostics["started"] = diagnosticSnapshot()
            try await measure("warmup", seconds: parsed.warmup, requiresPlayback: true)
            diagnostics["steadyStart"] = diagnosticSnapshot()
            let steadyStartPosition = position
            try await measure("steady", seconds: parsed.seconds, requiresPlayback: true)
            let steadyProgress = position - steadyStartPosition
            guard let steadyPhase = phases["steady"] as? [String: Any],
                  let steadyWallSeconds = steadyPhase["wallSeconds"] as? Double,
                  steadyWallSeconds.isFinite, steadyWallSeconds > 0
            else {
                throw BenchmarkFailure(message: "Steady phase wall time is unavailable")
            }
            validation["steadyProgressSeconds"] = steadyProgress
            validation["steadyProgressPerWallSecond"] = steadyProgress / steadyWallSeconds
            guard (0.85 ... 1.15).contains(steadyProgress / steadyWallSeconds) else {
                throw BenchmarkFailure(message: "Playback did not advance smoothly through the steady interval: \(steadyProgress) seconds")
            }
            diagnostics["steadyEnd"] = diagnosticSnapshot()
            try await measure("pausing", timeout: 5, action: { self.pause() }, until: { self.isPaused })
            // Allow the last published mpv position and hardware audio clock to settle.
            try await measure("pauseSettling", seconds: 0.5)
            let pausedPosition = position
            try await measure("pause", seconds: 3)
            let pauseMovement = abs(position - pausedPosition)
            validation["pausePositionDeltaSeconds"] = pauseMovement
            guard isPaused, pauseMovement < 0.15 else { throw BenchmarkFailure(message: "Playback advanced while paused") }
            let target = duration * 0.25
            validation["seekTargetSeconds"] = target
            try await measure("seek", timeout: 10, action: { self.seek(to: target) }, until: {
                self.isPaused && abs(self.position - target) < 0.15
            })
            validation["seekPositionSeconds"] = position
            diagnostics["seekCompleted"] = diagnosticSnapshot()
            let resumedPosition = position
            try await measure("resuming", timeout: 10, action: { self.play() }, until: {
                self.isPlaying && self.position > resumedPosition + 0.2
            })
            let resumeStart = position
            try await measure("resume", seconds: 3, requiresPlayback: true)
            validation["resumeProgressSeconds"] = position - resumeStart
            guard position - resumeStart > 2.4
            else { throw BenchmarkFailure(message: "Playback failed to advance after seeking and resuming") }
            diagnostics["beforeStop"] = diagnosticSnapshot()
            try await measure("stopping", timeout: 5, action: { self.stop() }, until: { self.isStopped })
            try await measure("stopped", seconds: 5)
            releasePlayers()
            try await measure("released", seconds: 5)
            validation["playerDeallocated"] = releasedMPV == nil && releasedAV == nil
            guard releasedMPV == nil && releasedAV == nil else {
                throw BenchmarkFailure(message: "Player is still retained five seconds after its surface was removed")
            }
            let after = environmentSnapshot()
            let stableKeys = [
                "surfaceWidthPoints",
                "surfaceHeightPoints",
                "screenScale",
                "maximumFramesPerSecond",
                "lowPowerMode",
                "audioRoute",
                "systemOutputVolume"
            ]
            let changed = stableKeys.filter { key in
                let first = try? JSONSerialization.data(withJSONObject: [nullable(environment[key])], options: .sortedKeys)
                let last = try? JSONSerialization.data(withJSONObject: [nullable(after[key])], options: .sortedKeys)
                return first != last
            }
            validation["environmentChangedKeys"] = changed
            guard changed.isEmpty else {
                throw BenchmarkFailure(message: "Measurement conditions changed: \(changed.joined(separator: ", "))")
            }
        } catch {
            failure = error is CancellationError ? "Benchmark cancelled" : error.localizedDescription
            releasePlayers()
        }
        environment["after"] = environmentSnapshot()
        var metrics: [String: Any] = [
            "lifetimeSampledPeakFootprintBytes": maximumFootprint,
            "lifetimeSampledPeakResidentBytes": maximumResident,
            "lifetimeSampledPeakMetalAllocatedBytes": nullable(maximumMetalAllocated),
            "maximumDemuxerCacheBytes": maximumCacheBytes,
            "maximumTotalDemuxerCacheBytes": nullable(maximumTotalCacheBytes),
            "maximumAbsoluteAudioVideoDriftSeconds": observedAVDrift ? maximumAbsoluteAVDrift as Any : NSNull(),
        ]
        for (phase, prefix) in [
            ("baseline", "baseline"),
            ("startup", "startup"),
            ("steady", "steady"),
            ("pause", "pause"),
            ("stopped", "stopped"),
            ("released", "afterRelease")
        ] {
            if let values = phases[phase] as? [String: Any] {
                for key in [
                    "cpuSecondsPerWallSecond",
                    "peakFootprintBytes",
                    "meanFootprintBytes",
                    "lastFootprintBytes",
                    "peakResidentBytes",
                    "peakMetalAllocatedBytes",
                    "lastMetalAllocatedBytes"
                ] {
                    metrics[prefix + key.prefix(1).uppercased() + key.dropFirst()] = values[key]
                }
            }
        }
        for (name, value) in phases {
            guard let phase = value as? [String: Any] else { continue }
            metrics[name + "MaximumAbsoluteAudioVideoDriftSeconds"] = phase["audioVideoDriftMaxAbsoluteSeconds"]
            metrics[name + "MeanAbsoluteAudioVideoDriftSeconds"] = phase["audioVideoDriftMeanAbsoluteSeconds"]
        }
        metrics["startupObservedLatencySeconds"] = (phases["startup"] as? [String: Any])?["wallSeconds"]
        metrics["seekObservedLatencySeconds"] = (phases["seek"] as? [String: Any])?["wallSeconds"]
        metrics["startRestartLatencySeconds"] = (diagnostics["beforeStop"] as? [String: Any])?["startLatencySeconds"]
        metrics["seekRestartLatencySeconds"] = (diagnostics["beforeStop"] as? [String: Any])?["seekLatencySeconds"]
        let report: [String: Any] = [
            "schemaVersion": 4,
            "status": failure == nil ? "passed" : "failed",
            "error": failure.map { $0 as Any } ?? NSNull(),
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "configuration": settings?.json ?? [:], "environment": environment,
            "phases": phases, "metrics": metrics, "diagnostics": diagnostics,
            "validation": validation, "timeline": timeline,
            "limitations": [
                "CPU is process user + system getrusage time; 1 CPU second per wall second equals one core, not device percent.",
                "Physical footprint and resident bytes are sampled every 100 ms; transient allocations can occur between samples or while the main actor is blocked.",
                "OS resident high-water includes the entire app lifetime. Footprint peaks are sampled, not OS lifetime peak footprint.",
                "Metal allocated bytes are MTLDevice.currentAllocatedSize on one retained default device. They describe its resource allocations, may overlap physical footprint, and exclude unreported system or compositor allocations; do not add them to footprint.",
                "System decoder/compositor service memory, GPU energy and physical display smoothness are outside these process metrics.",
                "Phase diagnostics observe newly published public snapshot revisions without extra native polling. Values can predate publication and are not independent 100 ms measurements; counter endpoints do not align exactly with CPU phase boundaries.",
                "A phase excludes its pre-existing diagnostic revision. Short transitions may have no new drift observation; unavailable phase drift remains null. Seek and subsequent resuming/resume phases are reported separately.",
                "Only published decoder/fallback transitions can be observed. A transient state between native snapshots may be missed; no polling harness establishes physical lip-sync.",
                "Native copy counters exclude decoder, Core Image, GPU and system compositor internal copies.",
                "Startup and seek completion use observed media-clock progress; they do not prove the destination pixels reached the display.",
                "AVPlayer does not expose decoder hardware-session evidence or A/V drift through this harness. Missing values remain unavailable.",
            ],
        ]
        let output = settings?.output ?? PlaybackBenchmarkSettings.failureOutput
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output, options: .withoutOverwriting)
            status = failure.map { "FAILED: \($0)\n\(output.lastPathComponent)" } ?? "PASSED: \(output.lastPathComponent)"
            print("PLAYBACK_BENCHMARK_RESULT \(output.path) \(failure == nil ? "passed" : "failed")")
        } catch {
            status = "FAILED saving report: \(error.localizedDescription)\n\(failure ?? "")"
            print("PLAYBACK_BENCHMARK_ERROR \(status)")
        }
    }

    private func createPlayer(_ settings: PlaybackBenchmarkSettings) {
        if settings.player == "mpv" {
            mpv = MPVPlayer(configuration: settings.mpvConfiguration)
            releasedMPV = mpv
            mpv?.load(settings.media)
        } else {
            av = AVPlayer(url: settings.media)
            releasedAV = av
            av?.volume = 1
            av?.play()
        }
    }

    private func pause() {
        mpv?.pause()
        av?.pause()
    }

    private func play() {
        mpv?.play()
        av?.play()
    }

    private func seek(to target: Double) {
        mpv?.seek(to: .seconds(target))
        av?.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func stop() {
        mpv?.stop()
        av?.pause()
        av?.replaceCurrentItem(with: nil)
    }

    private func releasePlayers() {
        stop()
        mpv = nil
        av = nil
    }

    private var position: Double {
        mpv.map { seconds($0.position) } ?? av?.currentTime().seconds ?? 0
    }

    private var duration: Double {
        mpv.map { seconds($0.duration) } ?? av?.currentItem?.duration.seconds ?? 0
    }

    private var isPlaying: Bool {
        mpv.map { $0.state == .playing } ?? (av?.timeControlStatus == .playing)
    }

    private var isPaused: Bool {
        mpv?.isPaused ?? (av?.timeControlStatus == .paused)
    }

    private var isStopped: Bool {
        mpv.map { $0.state == .stopped } ?? (av?.currentItem == nil)
    }

    private func checkFailure() throws {
        try Task.checkCancellation()
        if lostForeground {
            throw BenchmarkFailure(message: "App left the foreground; rerun without interruption")
        }
        if memoryReadFailed {
            throw BenchmarkFailure(message: "task_info memory measurements are unavailable")
        }
        if let error = mpv?.lastError {
            throw BenchmarkFailure(message: String(describing: error))
        }
        if let error = av?.error ?? av?.currentItem?.error {
            throw error
        }
    }

    private func measure(
        _ name: String, seconds interval: Double? = nil, timeout: Double = 30,
        requiresPlayback: Bool = false, action: (() -> Void)? = nil, until: (() -> Bool)? = nil
    ) async throws {
        status = "Playback benchmark: \(name)"
        var accumulator = BenchmarkPhase()
        accumulator.beginDiagnostics(revision: mpv?.playbackDiagnostics.engineActivity.diagnosticsSnapshots)
        defer { phases[name] = accumulator.json }
        recordMemory(into: &accumulator, phase: name)
        action?()
        let limit = interval ?? timeout
        repeat {
            try checkFailure()
            if requiresPlayback, mpv?.state == .ended || av?.currentItem?.status == .failed {
                throw BenchmarkFailure(message: "Playback ended or failed during \(name)")
            }
            recordMemory(into: &accumulator, phase: name)
            if let until, until() {
                return
            }
            if accumulator.elapsed >= limit {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        } while true
        if until != nil {
            throw BenchmarkFailure(message: "Timed out during \(name)")
        }
    }

    private func recordMemory(into phase: inout BenchmarkPhase, phase name: String) {
        let memory = BenchmarkMemory.read(metalAllocatedBytes: metalDevice.map { UInt64($0.currentAllocatedSize) })
        if memory == nil {
            memoryReadFailed = true
        }
        phase.record(memory)
        maximumFootprint = max(maximumFootprint, memory?.footprint ?? 0)
        maximumResident = max(maximumResident, memory?.resident ?? 0)
        if let metal = memory?.metalAllocatedBytes {
            maximumMetalAllocated = max(maximumMetalAllocated ?? 0, metal)
        }
        maximumCacheBytes = max(maximumCacheBytes, mpv?.bufferStatus.bytesAhead ?? 0)
        if let total = mpv?.bufferStatus.totalBytes {
            maximumTotalCacheBytes = max(maximumTotalCacheBytes ?? 0, total)
        }
        if let drift = mpv?.playbackDiagnostics.audioVideoDriftSeconds, drift.isFinite {
            maximumAbsoluteAVDrift = max(maximumAbsoluteAVDrift, abs(drift))
            observedAVDrift = true
        }
        if let player = mpv {
            phase.recordDiagnostics(
                player.playbackDiagnostics,
                backend: player.videoOutput.rawValue
            )
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastTimelineUptime >= 1, timeline.count < 480 {
            lastTimelineUptime = uptime
            timeline.append([
                "elapsedSeconds": uptime - beginUptime, "phase": name,
                "positionSeconds": finite(position), "footprintBytes": memory?.footprint as Any? ?? NSNull(),
                "residentBytes": memory?.resident as Any? ?? NSNull(),
                "metalAllocatedBytes": nullable(memory?.metalAllocatedBytes),
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                "cacheBytes": mpv?.bufferStatus.bytesAhead as Any? ?? NSNull(),
                "totalCacheBytes": nullable(mpv?.bufferStatus.totalBytes),
                "diagnosticsRevision": nullable(mpv?.playbackDiagnostics.engineActivity.diagnosticsSnapshots),
                "audioVideoDriftSeconds": finite(mpv?.playbackDiagnostics.audioVideoDriftSeconds),
            ])
        }
    }

    private func diagnosticSnapshot() -> [String: Any] {
        if let player = mpv {
            let d = player.playbackDiagnostics
            let session: String = switch d.decoder.session {
            case .unknown: "unknown"
            case .software: "software"
            case let .hardware(name): name
            }
            return [
                "effectiveBackend": player.videoOutput.rawValue,
                "fallbackReasons": d.fallbackReasons, "decoderSession": session,
                "selectedDecoder": nullable(d.decoder.selectedDecoder),
                "videoToolboxSessionUsesHardware": nullable(d.decoder.videoToolboxSessionUsesHardware),
                "videoToolboxSupportsCodec": nullable(d.decoder.videoToolboxSupportsCodec),
                "decoderInterop": nullable(d.decoder.interop), "decodedPixelFormat": nullable(d.decoder.decodedPixelFormat),
                "decoderFallbackReason": nullable(d.decoder.fallbackReason),
                "decoderDroppedFrames": nullable(d.decoderDroppedFrames), "outputDroppedFrames": nullable(d.outputDroppedFrames),
                "mistimedFrames": nullable(d.mistimedFrames), "delayedFrames": nullable(d.delayedFrames),
                "audioVideoDriftSeconds": finite(d.audioVideoDriftSeconds),
                "totalAudioVideoCorrectionSeconds": finite(d.totalAudioVideoCorrectionSeconds),
                "nativePixelBufferCopies": nullable(d.nativeOutputStatistics?.pixelBufferCopies),
                "nativeSampleBuildCount": nullable(d.nativeOutputStatistics?.sampleBuildCount),
                "nativeSampleBuildNanoseconds": nullable(d.nativeOutputStatistics?.totalSampleBuildNanoseconds),
                "startLatencySeconds": finite(d.startLatencySeconds), "seekLatencySeconds": finite(d.seekLatencySeconds),
                "videoCodec": nullable(player.mediaInformation.videoCodec), "audioCodec": nullable(player.mediaInformation.audioCodec),
                "sourceWidth": nullable(player.mediaInformation.dimensions?.width),
                "sourceHeight": nullable(player.mediaInformation.dimensions?.height),
                "containerFramesPerSecond": finite(d.containerFramesPerSecond),
                "audioOutput": nullable(d.audio.output), "audioNativePath": nullable(d.audio.nativePath),
                "audioSourceChannels": nullable(d.audio.sourceChannels), "audioOutputChannels": nullable(d.audio.outputChannels),
                "audioOutputFormat": nullable(d.audio.outputFormat),
                "cacheBytesAhead": player.bufferStatus.bytesAhead,
                "cacheTotalBytes": nullable(player.bufferStatus.totalBytes),
                "cacheSecondsAhead": seconds(player.bufferStatus.secondsBufferedAhead),
                "buffering": player.bufferStatus.isBuffering,
                "engineActivity": [
                    "nativeWakeups": d.engineActivity.nativeWakeups,
                    "eventDrainPasses": d.engineActivity.eventDrainPasses,
                    "nativeEvents": d.engineActivity.nativeEvents,
                    "publishedUpdates": d.engineActivity.publishedUpdates,
                    "propertyReads": d.engineActivity.propertyReads,
                    "mediaSnapshots": d.engineActivity.mediaSnapshots,
                    "bufferSnapshots": d.engineActivity.bufferSnapshots,
                    "diagnosticsSnapshots": d.engineActivity.diagnosticsSnapshots,
                    "propertyChangeEvents": d.engineActivity.propertyChangeEvents,
                ],
            ]
        }
        guard let item = av?.currentItem else { return [:] }
        let event = item.accessLog()?.events.last
        return [
            "effectiveBackend": "AVPlayerLayer", "decoderSession": "unavailable",
            "videoToolboxSessionUsesHardware": NSNull(),
            "sourceWidth": item.presentationSize.width, "sourceHeight": item.presentationSize.height,
            "droppedVideoFrames": nullable(event?.numberOfDroppedVideoFrames),
            "stalls": nullable(event?.numberOfStalls), "observedBitrate": finite(event?.observedBitrate),
            "indicatedBitrate": finite(event?.indicatedBitrate),
            "loadedTimeRanges": item.loadedTimeRanges.map {
                ["start": finite($0.timeRangeValue.start.seconds), "duration": finite($0.timeRangeValue.duration.seconds)]
            },
            "audioVideoDriftSeconds": NSNull(), "nativePixelBufferCopies": NSNull(),
        ]
    }

    private func environmentSnapshot() -> [String: Any] {
        let process = ProcessInfo.processInfo
        let session = AVAudioSession.sharedInstance()
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.screen
        return [
            "deviceModel": UIDevice.current.model, "hardwareModel": hardwareModel(),
            "operatingSystem": process.operatingSystemVersionString,
            "processorCount": process.processorCount, "physicalMemoryBytes": process.physicalMemory,
            "thermalState": process.thermalState.rawValue, "lowPowerMode": process.isLowPowerModeEnabled,
            "batteryState": UIDevice.current.batteryState.rawValue, "batteryLevel": UIDevice.current.batteryLevel,
            "surfaceWidthPoints": surfaceSize.width, "surfaceHeightPoints": surfaceSize.height,
            "screenScale": nullable(screen?.scale), "maximumFramesPerSecond": nullable(screen?.maximumFramesPerSecond),
            "metalDevice": nullable(metalDevice?.name),
            "audioSampleRate": session.sampleRate, "audioOutputChannels": session.outputNumberOfChannels,
            "audioIOBufferSeconds": session.ioBufferDuration, "systemOutputVolume": session.outputVolume,
            "audioRoute": session.currentRoute.outputs.map(\.portType.rawValue),
            "isSimulator": isSimulator,
        ]
    }

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
}

private struct BenchmarkMemory {
    let footprint: UInt64
    let resident: UInt64
    let residentHighWater: UInt64
    let metalAllocatedBytes: UInt64?

    static func read(metalAllocatedBytes: UInt64?) -> Self? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return Self(
            footprint: info.phys_footprint,
            resident: info.resident_size,
            residentHighWater: info.resident_size_peak,
            metalAllocatedBytes: metalAllocatedBytes
        )
    }
}

private struct BenchmarkPhase {
    private let start = ProcessInfo.processInfo.systemUptime
    private let cpuStart = benchmarkCPUSeconds()
    private var count = 0
    private var first: BenchmarkMemory?
    private var last: BenchmarkMemory?
    private var footprintSum = 0.0
    private var residentSum = 0.0
    private var footprintPeak: UInt64 = 0
    private var residentPeak: UInt64 = 0
    private var metalCount = 0
    private var metalSum = 0.0
    private var metalPeak: UInt64 = 0
    private var lastDiagnosticsRevision: Int64?
    private var diagnosticSamples: [[String: Any]] = []
    private var driftValues: [Double] = []
    var elapsed: Double {
        ProcessInfo.processInfo.systemUptime - start
    }

    mutating func beginDiagnostics(revision: Int64?) {
        lastDiagnosticsRevision = revision
    }

    mutating func recordDiagnostics(_ value: MPVPlaybackDiagnostics, backend: String) {
        let revision = value.engineActivity.diagnosticsSnapshots
        guard revision != lastDiagnosticsRevision else { return }
        lastDiagnosticsRevision = revision
        let session: String = switch value.decoder.session {
        case .unknown: "unknown"
        case .software: "software"
        case let .hardware(name): name
        }
        if let drift = value.audioVideoDriftSeconds, drift.isFinite {
            driftValues.append(drift)
        }
        diagnosticSamples.append([
            "observedElapsedSeconds": elapsed, "diagnosticsRevision": revision,
            "audioVideoDriftSeconds": finite(value.audioVideoDriftSeconds),
            "effectiveBackend": backend,
            "decoderSession": session, "selectedDecoder": nullable(value.decoder.selectedDecoder),
            "decodedPixelFormat": nullable(value.decoder.decodedPixelFormat),
            "videoToolboxSessionUsesHardware": nullable(value.decoder.videoToolboxSessionUsesHardware),
            "decoderFallbackReason": nullable(value.decoder.fallbackReason), "fallbackReasons": value.fallbackReasons,
            "decoderDroppedFrames": nullable(value.decoderDroppedFrames),
            "outputDroppedFrames": nullable(value.outputDroppedFrames),
            "nativeSampleBuildCount": nullable(value.nativeOutputStatistics?.sampleBuildCount),
        ])
    }

    mutating func record(_ value: BenchmarkMemory?) {
        guard let value else { return }
        if first == nil {
            first = value
        }
        last = value
        count += 1
        footprintSum += Double(value.footprint)
        residentSum += Double(value.resident)
        footprintPeak = max(footprintPeak, value.footprint)
        residentPeak = max(residentPeak, value.resident)
        if let metal = value.metalAllocatedBytes {
            metalCount += 1
            metalSum += Double(metal)
            metalPeak = max(metalPeak, metal)
        }
    }

    var json: [String: Any] {
        let wall = elapsed
        let cpu = benchmarkCPUSeconds() - cpuStart
        return [
            "wallSeconds": wall, "cpuSeconds": cpu, "cpuSecondsPerWallSecond": cpu / max(wall, 0.000_001),
            "memorySamples": count, "firstFootprintBytes": nullable(first?.footprint), "lastFootprintBytes": nullable(last?.footprint),
            "peakFootprintBytes": count > 0 ? footprintPeak as Any : NSNull(),
            "meanFootprintBytes": count > 0 ? footprintSum / Double(count) as Any : NSNull(),
            "firstResidentBytes": nullable(first?.resident), "lastResidentBytes": nullable(last?.resident),
            "peakResidentBytes": count > 0 ? residentPeak as Any : NSNull(),
            "meanResidentBytes": count > 0 ? residentSum / Double(count) as Any : NSNull(),
            "processResidentHighWaterBytes": nullable(last?.residentHighWater),
            "firstMetalAllocatedBytes": nullable(first?.metalAllocatedBytes),
            "lastMetalAllocatedBytes": nullable(last?.metalAllocatedBytes),
            "peakMetalAllocatedBytes": metalCount > 0 ? metalPeak as Any : NSNull(),
            "meanMetalAllocatedBytes": metalCount > 0 ? metalSum / Double(metalCount) as Any : NSNull(),
            "diagnosticSamples": diagnosticSamples, "audioVideoDriftSampleCount": driftValues.count,
            "audioVideoDriftMinSeconds": finite(driftValues.min()), "audioVideoDriftMaxSeconds": finite(driftValues.max()),
            "audioVideoDriftMaxAbsoluteSeconds": finite(driftValues.map { abs($0) }.max()),
            "audioVideoDriftMeanAbsoluteSeconds": driftValues.isEmpty ? NSNull() : driftValues
                .reduce(0) { $0 + abs($1) } / Double(driftValues.count) as Any,
        ]
    }
}

private func benchmarkCPUSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func nullable(_ value: (some Any)?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}

private func finite(_ value: Double?) -> Any {
    value.flatMap { $0.isFinite ? $0 : nil }.map { $0 as Any } ?? NSNull()
}

private func hardwareModel() -> String {
    var info = utsname()
    uname(&info)
    let capacity = MemoryLayout.size(ofValue: info.machine)
    return withUnsafePointer(to: &info.machine) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
            String(cString: $0)
        }
    }
}
#endif
