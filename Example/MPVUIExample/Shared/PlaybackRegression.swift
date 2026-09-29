#if os(iOS)
import AVFoundation
import Darwin
import Foundation
import MPVUI
import Observation
import SwiftUI
import UIKit

/// Opt-in functional playback checks on a physical device.
@MainActor
struct PlaybackRegressionView: View {
    @State
    private var regression = PlaybackRegression()
    @Environment(\.scenePhase)
    private var scenePhase

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let player = regression.player {
                MPVVideoPlayer(player: player)
            }
            Text(regression.status)
                .font(.caption.monospaced())
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.7))
                .accessibilityIdentifier("playbackRegressionStatus")
        }
        .ignoresSafeArea()
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                regression.lostForeground = true
            }
        }
        .task { await regression.run() }
    }
}

private struct RegressionFailure: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

private struct RegressionSettings {
    let media: URL
    let output: URL
    let backend: MPVPlayerConfiguration.VideoOutput?
    let requestedBackend: String
    let softwareDecoding: Bool

    init() throws {
        let arguments = ProcessInfo.processInfo.arguments
        var values: [String: String] = [:]
        var software = false
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--regression-software-decoding" {
                software = true
                index += 1
                continue
            }
            guard argument.hasPrefix("--regression-") else { index += 1
                continue
            }
            guard ["--regression-media", "--regression-output", "--regression-backend"].contains(argument),
                  index + 1 < arguments.count
            else {
                throw RegressionFailure(message: "Unknown or incomplete argument: \(argument)")
            }
            values[argument] = arguments[index + 1]
            index += 2
        }
        guard let source = values["--regression-media"], !source.isEmpty else {
            throw RegressionFailure(message: "--regression-media URL or Documents-relative path is required")
        }
        if let url = URL(string: source), let scheme = url.scheme {
            guard ["file", "http", "https"].contains(scheme.lowercased()) else {
                throw RegressionFailure(message: "Media must be a file, HTTP, or HTTPS URL")
            }
            media = url
        } else {
            media = source.hasPrefix("/") ? URL(fileURLWithPath: source) : Self.documents.appendingPathComponent(source)
        }
        if media.isFileURL, !FileManager.default.fileExists(atPath: media.path) {
            throw RegressionFailure(message: "Media file does not exist: \(media.lastPathComponent)")
        }
        requestedBackend = values["--regression-backend"] ?? "default"
        guard ["default", "sampleBuffer", "metal"].contains(requestedBackend) else {
            throw RegressionFailure(message: "Backend must be default, sampleBuffer or metal")
        }
        backend = MPVPlayerConfiguration.VideoOutput(rawValue: requestedBackend)
        softwareDecoding = software
        output = try Self.outputURL(values["--regression-output"] ?? "playback-regression.json")
    }

    var configuration: MPVPlayerConfiguration {
        .init(
            audio: .init(audioSession: .hostManaged),
            autoPlay: true,
            hardwareDecoding: softwareDecoding ? .disabled : .automatic,
            logLevel: .none,
            videoOutput: backend ?? .sampleBuffer
        )
    }

    var json: [String: Any] {
        var components = URLComponents(url: media, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return [
            "media": components?.string ?? media.lastPathComponent,
            "backend": requestedBackend,
            "resolvedBackend": configuration.videoOutput.rawValue,
            "softwareDecoding": softwareDecoding,
            "cycles": 3,
            "purpose": "functional playback regression; not a performance measurement"
        ]
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func outputURL(_ filename: String) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\") else {
            throw RegressionFailure(message: "--regression-output must be a filename")
        }
        return documents.appendingPathComponent("Benchmarks", isDirectory: true).appendingPathComponent(filename)
    }

    static var failureOutput: URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--regression-output"), index + 1 < arguments.count,
           let url = try? outputURL(arguments[index + 1])
        {
            return url
        }
        return documents.appendingPathComponent("Benchmarks/playback-regression-error-\(UUID().uuidString).json")
    }
}

@MainActor
@Observable
private final class PlaybackRegression {
    var player: MPVPlayer?
    var status = "Preparing playback regression"
    @ObservationIgnored
    var lostForeground = false
    @ObservationIgnored
    private weak var releasedPlayer: MPVPlayer?
    @ObservationIgnored
    private var hasRun = false
    @ObservationIgnored
    private var startUptime = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored
    private var lastSampleUptime = -Double.infinity
    @ObservationIgnored
    private var checkpoints: [[String: Any]] = []
    @ObservationIgnored
    private var samples: [[String: Any]] = []
    @ObservationIgnored
    private var checks: [[String: Any]] = []
    @ObservationIgnored
    private var stage = "preparing"
    @ObservationIgnored
    private var expectedBackend: MPVPlayerConfiguration.VideoOutput?
    @ObservationIgnored
    private var expectsSoftwareDecoding = false

    func run() async {
        guard !hasRun else { return }
        hasRun = true
        startUptime = ProcessInfo.processInfo.systemUptime
        let oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var settings: RegressionSettings?
        var failure: String?
        defer {
            release()
            _ = ExampleAudioSession.deactivate()
            UIApplication.shared.isIdleTimerDisabled = oldIdleTimer
        }
        do {
            let parsed = try RegressionSettings()
            settings = parsed
            guard !FileManager.default.fileExists(atPath: parsed.output.path) else {
                throw RegressionFailure(message: "Report already exists; choose another --regression-output")
            }
            if let error = ExampleAudioSession.activate() {
                throw RegressionFailure(message: error)
            }
            let configuration = parsed.configuration
            expectedBackend = configuration.videoOutput
            expectsSoftwareDecoding = parsed.softwareDecoding
            player = MPVPlayer(configuration: configuration)
            releasedPlayer = player
            player?.load(parsed.media)
            for cycle in 1 ... 3 {
                setStage("cycle-\(cycle)-start")
                try await wait(timeout: 30) {
                    self.player?.state == .playing && self.position > 0.15
                        && self.player?.mediaInformation.dimensions != nil
                }
                try require(duration.isFinite && duration >= 30, "Use seekable VOD at least 30 seconds long for rate-change checks")
                try require(player?.isSeekable == true, "Media is not seekable")
                try await advancingPlayback(seconds: 3)
                checkpoint()

                setStage("cycle-\(cycle)-pause")
                player?.pause()
                try await wait(timeout: 5) { self.player?.isPaused == true && self.player?.state == .paused }
                try await observe(seconds: 0.5)
                let pausePosition = position
                try await observe(seconds: 1.5)
                let pausedMovement = abs(position - pausePosition)
                try require(player?.isPaused == true && pausedMovement < 0.15, "Paused playback position moved")
                checks.append(["stage": stage, "positionDeltaSeconds": pausedMovement])
                checkpoint()

                setStage("cycle-\(cycle)-seek")
                let target = min(max(2, duration * 0.35), duration - 5)
                let previousSampleCount = player?.playbackDiagnostics.nativeOutputStatistics?.sampleBuildCount
                player?.seek(to: .seconds(target))
                try await wait(timeout: 15) {
                    self.player?.isPaused == true && self.player?.state == .paused && abs(self.position - target) < 0.15
                }
                if player?.videoOutput == .sampleBuffer {
                    guard let previousSampleCount, previousSampleCount > 1 else {
                        throw RegressionFailure(message: "\(stage): native pre-seek sample baseline is unavailable")
                    }
                    // VOCTRL_RESET zeros the native counter on exact seek. A
                    // positive smaller value in a fresh snapshot establishes
                    // a new generation; timing/copy changes alone cannot pass.
                    let previousSnapshot = player?.playbackDiagnostics.engineActivity.diagnosticsSnapshots ?? 0
                    try await wait(timeout: 5) {
                        guard let current = self.player?.playbackDiagnostics,
                              current.engineActivity.diagnosticsSnapshots > previousSnapshot,
                              let count = current.nativeOutputStatistics?.sampleBuildCount else { return false }
                        return count > 0 && count < previousSampleCount
                    }
                }
                checks.append([
                    "stage": stage,
                    "targetSeconds": target,
                    "observedPositionSeconds": position,
                    "nativeSampleResetObserved": player?.videoOutput == .sampleBuffer,
                    "nativePreSeekSampleBuildCount": regressionNullable(previousSampleCount),
                    "nativeResetBaseline": player?.videoOutput == .sampleBuffer ? 0 as Any : NSNull(),
                    "nativePostSeekSampleBuildCount": regressionNullable(player?.playbackDiagnostics.nativeOutputStatistics?
                        .sampleBuildCount)
                ])
                checkpoint()

                setStage("cycle-\(cycle)-resume")
                let resumedPosition = position
                player?.play()
                try await wait(timeout: 15) { self.player?.state == .playing && self.position > resumedPosition + 0.15 }
                try await advancingPlayback(seconds: 3)
                checkpoint()

                setStage("cycle-\(cycle)-stop-retained")
                player?.stop()
                try await wait(timeout: 10) { self.player?.state == .stopped && self.player?.isPaused == true }
                // Let any already-published final diagnostics settle. Public
                // diagnostics are cached; unchanged values cannot prove that
                // an unreported native handle was never recreated.
                try await observe(seconds: 0.5)
                let stoppedPosition = position
                let activity = player?.playbackDiagnostics.engineActivity
                let nativeSamples = player?.playbackDiagnostics.nativeOutputStatistics
                try await observe(seconds: 3) {
                    try self.require(
                        self.player?.state == .stopped && self.player?.isPaused == true,
                        "Retained stopped player restarted without a request"
                    )
                    try self.require(abs(self.position - stoppedPosition) < 0.15, "Stopped clock advanced")
                }
                try require(
                    player?.playbackDiagnostics.engineActivity == activity,
                    "Stopped player published new native engine activity"
                )
                try require(
                    player?.playbackDiagnostics.nativeOutputStatistics == nativeSamples,
                    "Stopped player published new native video samples"
                )
                checks.append([
                    "stage": stage,
                    "stateRemainedStopped": true,
                    "publishedActivityUnchanged": true,
                    "publishedNativeSamplesUnchanged": true,
                    "nativeHandleLifecycleAvailable": false
                ])
                checkpoint()

                setStage("cycle-\(cycle)-replay")
                player?.play()
                try await wait(timeout: 30) {
                    self.player?.state == .playing && self.position > 0.15 && self.position < 1.5
                }
                checks.append(["stage": stage, "replayInitialPositionSeconds": position])
                try await advancingPlayback(seconds: 3)
                checkpoint()
            }

            setStage("stop-before-typed-load")
            player?.stop()
            try await wait(timeout: 10) { self.player?.state == .stopped && self.player?.isPaused == true }
            checkpoint()
            setStage("typed-load-while-stopped")
            player?.load(parsed.media, autoPlay: false, startTime: .seconds(1))
            try await wait(timeout: 30) {
                self.player?.state == .paused && self.player?.isPaused == true && abs(self.position - 1) < 0.15
                    && self.player?.mediaInformation.dimensions != nil
            }
            checkpoint()
            setStage("typed-load-resume")
            player?.play()
            try await wait(timeout: 15) { self.player?.state == .playing && self.position > 1.15 }
            try await advancingPlayback(seconds: 3)
            checkpoint()
            for (name, rate) in [("slow", 0.5), ("fast", 1.5), ("normal", 1.0)] {
                setStage("rate-\(name)")
                player?.setPlaybackRate(rate)
                try await wait(timeout: 5) { self.player?.playbackRate == rate }
                try await advancingPlayback(seconds: 3, expectedRate: rate)
                checkpoint()
            }
            setStage("release")
            release()
            try await wait(timeout: 5) { self.releasedPlayer == nil }
            checks.append(["stage": stage, "playerDeallocated": releasedPlayer == nil])
            checkpoint()
        } catch {
            failure = error is CancellationError ? "Regression cancelled" : error.localizedDescription
            checkpoint()
            release()
        }
        let report: [String: Any] = [
            "schemaVersion": 2, "status": failure == nil ? "passed" : "failed",
            "error": regressionNullable(failure), "createdAt": ISO8601DateFormatter().string(from: Date()),
            "configuration": settings?.json ?? [:], "checks": checks, "checkpoints": checkpoints, "samples": samples,
            "environment": [
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "deviceModel": UIDevice.current.model,
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                "audioRoute": AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
            ],
            "limitations": [
                "This is a functional scenario, not a CPU, memory, energy, or physical smoothness benchmark.",
                "Native sample counters establish sample-build attempts, not successful enqueue or correctly presented pixels. No display pixel readback is performed.",
                "Native exact seek resets the counter to zero. A fresh smaller positive count establishes post-reset attempts; subsequent playback must strictly increase from its fresh baseline.",
                "Decoder/output drop counters must be available and unchanged during settled observation segments. Startup and seek transitions are excluded; zero reported drops does not prove every physical refresh was displayed.",
                "A/V drift is sampled within settled observation segments; it is not an audible lip-sync or calibrated physical-display assessment.",
                "Engine and native counters are cached published snapshots. Unchanged stopped snapshots cannot prove absent native handle recreation; internal lifecycle tests provide that assertion.",
                "Metal has no public submitted-frame counter in this harness; its progression check uses playback time plus native decoder/output diagnostics.",
                "Footprint snapshots are context only and include the app and this scenario's report allocations.",
            ],
        ]
        let output = settings?.output ?? RegressionSettings.failureOutput
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output, options: .withoutOverwriting)
            status = failure.map { "FAILED: \($0)\n\(output.lastPathComponent)" } ?? "PASSED: \(output.lastPathComponent)"
            print("PLAYBACK_REGRESSION_RESULT \(output.path) \(failure == nil ? "passed" : "failed")")
        } catch {
            status = "FAILED saving regression report: \(error.localizedDescription)"
            print("PLAYBACK_REGRESSION_ERROR \(status)")
        }
    }

    private var position: Double {
        player.map { regressionSeconds($0.position) } ?? 0
    }

    private var duration: Double {
        player.map { regressionSeconds($0.duration) } ?? 0
    }

    private func release() {
        player?.stop()
        player = nil
    }

    private func setStage(_ name: String) {
        stage = name
        status = "Playback regression: \(name)"
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw RegressionFailure(message: "\(stage): \(message)")
        }
    }

    private func checkFailure() throws {
        try Task.checkCancellation()
        try require(!lostForeground, "App left the foreground")
        if let error = player?.lastError {
            throw RegressionFailure(message: "\(stage): \(error)")
        }
        if let player, let expectedBackend {
            try require(player.videoOutput == expectedBackend, "Playback changed the expected video backend")
            try require(player.lastError == nil, "Unexpected playback error")
        }
    }

    private func wait(timeout: Double, until: () -> Bool) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        repeat {
            try checkFailure()
            sample()
            if until() {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime - start < timeout
        throw RegressionFailure(message: "Timed out during \(stage)")
    }

    private func observe(seconds interval: Double, check: (() throws -> Void)? = nil) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        repeat {
            try checkFailure()
            try check?()
            sample()
            try await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime - start < interval
    }

    private func advancingPlayback(seconds interval: Double, expectedRate: Double = 1) async throws {
        // Exclude load/resume/seek settling and take a new diagnostic snapshot
        // after the current playing generation has resolved. Old cached
        // counters from a retired handle cannot become this segment's baseline.
        try await observe(seconds: 1)
        let previousSnapshot = player?.playbackDiagnostics.engineActivity.diagnosticsSnapshots ?? 0
        try await wait(timeout: 5) {
            (self.player?.playbackDiagnostics.engineActivity.diagnosticsSnapshots ?? 0) > previousSnapshot
                && self.decoderMatchesExpectation
        }
        if player?.videoOutput == .sampleBuffer {
            try await wait(timeout: 5) { (self.player?.playbackDiagnostics.nativeOutputStatistics?.sampleBuildCount ?? 0) > 0 }
        }
        let before = player?.playbackDiagnostics
        let beforePosition = position
        let segmentStart = ProcessInfo.processInfo.systemUptime
        var driftSamples: [[String: Any]] = []
        var lastDriftSnapshot: Int64?
        func collectDrift() {
            guard let diagnostics = player?.playbackDiagnostics,
                  lastDriftSnapshot != diagnostics.engineActivity.diagnosticsSnapshots else { return }
            lastDriftSnapshot = diagnostics.engineActivity.diagnosticsSnapshots
            driftSamples.append([
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - segmentStart,
                "seconds": regressionFinite(diagnostics.audioVideoDriftSeconds)
            ])
        }
        collectDrift()
        try await observe(seconds: interval) {
            try self.require(self.player?.isPaused == false, "Playback unexpectedly paused")
            try self.require(self.player?.state != .ended, "Playback ended during the progression check")
            try self.require(self.decoderMatchesExpectation, "Decoder changed during settled playback")
            collectDrift()
        }
        let finalSnapshot = player?.playbackDiagnostics.engineActivity.diagnosticsSnapshots ?? 0
        try await wait(timeout: 2) {
            (self.player?.playbackDiagnostics.engineActivity.diagnosticsSnapshots ?? 0) > finalSnapshot
        }
        collectDrift()
        let after = player?.playbackDiagnostics
        let progress = position - beforePosition
        let elapsed = ProcessInfo.processInfo.systemUptime - segmentStart
        let finiteDrift = driftSamples.compactMap { $0["seconds"] as? Double }
        var check: [String: Any] = [
            "stage": stage, "playbackProgressSeconds": progress, "observationSeconds": elapsed,
            "expectedPlaybackRate": expectedRate, "observedPlaybackRate": player?.playbackRate as Any? ?? NSNull(),
            "settlingSecondsExcluded": 1, "maximumAllowedDroppedFrames": 0,
            "decoderDroppedFramesDelta": regressionDelta(before?.decoderDroppedFrames, after?.decoderDroppedFrames),
            "outputDroppedFramesDelta": regressionDelta(before?.outputDroppedFrames, after?.outputDroppedFrames),
            "audioVideoDriftSamples": driftSamples,
            "audioVideoDriftMinSeconds": regressionFinite(finiteDrift.min()),
            "audioVideoDriftMaxSeconds": regressionFinite(finiteDrift.max()),
            "audioVideoDriftMaxAbsoluteSeconds": regressionFinite(finiteDrift.map { abs($0) }.max()),
        ]
        if player?.videoOutput == .sampleBuffer {
            check["nativeSampleBuildCountStart"] = regressionNullable(before?.nativeOutputStatistics?.sampleBuildCount)
            check["nativeSampleBuildCountEnd"] = regressionNullable(after?.nativeOutputStatistics?.sampleBuildCount)
            check["nativeSampleBuildCountDelta"] = regressionDelta(
                before?.nativeOutputStatistics?.sampleBuildCount,
                after?.nativeOutputStatistics?.sampleBuildCount
            )
        }
        checks.append(check)
        try require(
            player?.playbackRate == expectedRate && (0.8 ... 1.2).contains(progress / elapsed / expectedRate),
            "Playback failed to advance at the requested rate through the observation interval"
        )
        try require(decoderMatchesExpectation, "Decoder changed during settled playback")
        guard let firstDecoder = before?.decoderDroppedFrames, let lastDecoder = after?.decoderDroppedFrames,
              let firstOutput = before?.outputDroppedFrames, let lastOutput = after?.outputDroppedFrames
        else {
            throw RegressionFailure(message: "\(stage): decoder/output drop counters are unavailable")
        }
        try require(
            lastDecoder >= firstDecoder && lastOutput >= firstOutput,
            "Drop counters reset during settled playback"
        )
        try require(
            lastDecoder == firstDecoder && lastOutput == firstOutput,
            "Decoder/output frames dropped during settled playback"
        )
        if player?.videoOutput == .sampleBuffer {
            guard let first = before?.nativeOutputStatistics?.sampleBuildCount,
                  let last = after?.nativeOutputStatistics?.sampleBuildCount
            else {
                throw RegressionFailure(message: "\(stage): native sample counters are unavailable")
            }
            try require(last > first, "Native sample-build attempts did not advance with the playback clock")
        }
    }

    private var decoderMatchesExpectation: Bool {
        guard let diagnostics = player?.playbackDiagnostics, diagnostics.fallbackReasons.isEmpty else { return false }
        let decoder = diagnostics.decoder
        if expectsSoftwareDecoding {
            let selected = decoder.selectedDecoder?.lowercased()
            guard let pixelFormat = decoder.decodedPixelFormat?.lowercased(), !pixelFormat.isEmpty else { return false }
            return decoder.session == .software && decoder.videoToolboxSessionUsesHardware != true
                && (selected == nil || selected == "" || selected == "no")
                && !pixelFormat.contains("videotoolbox") && decoder.fallbackReason == nil
        }
        guard case .hardware = decoder.session else { return false }
        return decoder.videoToolboxSessionUsesHardware == true && decoder.fallbackReason == nil
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSampleUptime >= 0.5, samples.count < 480 else { return }
        lastSampleUptime = now
        let d = player?.playbackDiagnostics
        samples.append([
            "elapsedSeconds": now - startUptime, "stage": stage, "state": player.map { String(describing: $0.state) } ?? "released",
            "positionSeconds": regressionFinite(position), "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "physicalFootprintBytes": regressionNullable(regressionFootprint()),
            "decoderDroppedFrames": regressionNullable(d?.decoderDroppedFrames),
            "outputDroppedFrames": regressionNullable(d?.outputDroppedFrames),
            "audioVideoDriftSeconds": regressionFinite(d?.audioVideoDriftSeconds),
            "nativeSampleBuildCount": regressionNullable(d?.nativeOutputStatistics?.sampleBuildCount),
        ])
    }

    private func checkpoint() {
        let d = player?.playbackDiagnostics
        let session: String = switch d?.decoder.session {
        case .software: "software"
        case let .hardware(value): value
        default: "unknown"
        }
        checkpoints.append([
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - startUptime, "stage": stage,
            "state": player.map { String(describing: $0.state) } ?? "released",
            "positionSeconds": regressionFinite(position), "durationSeconds": regressionFinite(duration),
            "effectiveBackend": regressionNullable(player?.videoOutput.rawValue), "decoderSession": session,
            "expectedBackend": regressionNullable(expectedBackend?.rawValue),
            "selectedDecoder": regressionNullable(d?.decoder.selectedDecoder),
            "decodedPixelFormat": regressionNullable(d?.decoder.decodedPixelFormat),
            "videoToolboxSessionUsesHardware": regressionNullable(d?.decoder.videoToolboxSessionUsesHardware),
            "videoCodec": regressionNullable(player?.mediaInformation.videoCodec),
            "audioCodec": regressionNullable(player?.mediaInformation.audioCodec),
            "audioSourceChannels": regressionNullable(d?.audio.sourceChannels),
            "audioOutputChannels": regressionNullable(d?.audio.outputChannels),
            "audioOutput": regressionNullable(d?.audio.output),
            "sourceWidth": regressionNullable(player?.mediaInformation.dimensions?.width),
            "sourceHeight": regressionNullable(player?.mediaInformation.dimensions?.height),
            "outputDroppedFrames": regressionNullable(d?.outputDroppedFrames),
            "decoderDroppedFrames": regressionNullable(d?.decoderDroppedFrames),
            "audioVideoDriftSeconds": regressionFinite(d?.audioVideoDriftSeconds),
            "nativeSampleBuildCount": regressionNullable(d?.nativeOutputStatistics?.sampleBuildCount),
            "nativePixelBufferCopies": regressionNullable(d?.nativeOutputStatistics?.pixelBufferCopies),
            "cacheTotalBytes": regressionNullable(player?.bufferStatus.totalBytes),
            "cacheBytesAhead": regressionNullable(player?.bufferStatus.bytesAhead),
            "fallbackReasons": d?.fallbackReasons ?? [],
            "error": player?.lastError.map { String(describing: $0) } as Any? ?? NSNull(),
            "nativeHandleLifecycleAvailable": false,
            "engineActivity": [
                "nativeWakeups": regressionNullable(d?.engineActivity.nativeWakeups),
                "eventDrainPasses": regressionNullable(d?.engineActivity.eventDrainPasses),
                "nativeEvents": regressionNullable(d?.engineActivity.nativeEvents),
                "publishedUpdates": regressionNullable(d?.engineActivity.publishedUpdates),
                "propertyReads": regressionNullable(d?.engineActivity.propertyReads)
            ],
        ])
    }
}

private func regressionSeconds(_ value: Duration) -> Double {
    Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
}

private func regressionNullable(_ value: (some Any)?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}

private func regressionFinite(_ value: Double?) -> Any {
    value.flatMap { $0.isFinite ? $0 : nil }.map { $0 as Any } ?? NSNull()
}

private func regressionDelta(_ first: Int64?, _ last: Int64?) -> Any {
    guard let first, let last, last >= first else { return NSNull() }
    return last - first
}

private func regressionFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : nil
}
#endif
