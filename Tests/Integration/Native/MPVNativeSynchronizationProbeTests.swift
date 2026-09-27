#if os(iOS) && !targetEnvironment(simulator)
import AVFoundation
import CoreVideo
import CryptoKit
import Darwin
import Foundation
@testable import MPVUI
import Testing
import UIKit

/// Opt-in diagnostics only: this adds direct native property queries and must
/// never run concurrently with performance measurements. It does not change the
/// production polling interval or the benchmark protocol.
@Suite(.tags(.integration, .nativePatch), .serialized)
struct MPVNativeSynchronizationProbeTests {
    private static var configurationURL: URL? {
        Bundle.module.url(forResource: "native-sync-configuration", withExtension: "json")
    }

    private struct Configuration: Decodable {
        let directFilename: String
        let hlsURL: URL
        let directMediaSHA256: String
        let directFileSHA256: String
        let hlsMediaSHA256: String
        let hostVerification: HostVerification

        struct HostVerification: Decodable {
            let hlsIdentity: MediaIdentity
        }

        struct MediaIdentity: Decodable {
            let files: [String: String]
        }
    }

    @MainActor
    @Test(
        .enabled(if: configurationURL != nil, "Opt in with GeneratedMedia/native-sync-configuration.json"),
        arguments: ["direct", "hls"],
        [50, 500]
    )
    func `native synchronization phases with polling controls`(workload: String, intervalMilliseconds: Int) async throws {
        let configurationData = try Data(contentsOf: #require(Self.configurationURL))
        let configurationSHA256 = SHA256.hash(data: configurationData).map { String(format: "%02x", $0) }.joined()
        let config = try JSONDecoder().decode(Configuration.self, from: configurationData)
        try #require(config.directFilename == URL(fileURLWithPath: config.directFilename).lastPathComponent)
        try #require(config.hlsURL.scheme == "http" || config.hlsURL.scheme == "https")
        let source = workload == "direct" ? try TestPaths.testMedia(config.directFilename) : config.hlsURL
        let mediaSHA256 = workload == "direct" ? config.directMediaSHA256 : config.hlsMediaSHA256
        try #require(mediaSHA256.count == 64 && mediaSHA256.allSatisfy(\.isHexDigit))
        let origin = ProcessInfo.processInfo.systemUptime
        var samples: [[String: Any]] = []
        var phases: [[String: Any]] = []
        var frameworkSamples: [[String: Any]] = []
        var networkPreflight: [String: Any] = ["required": workload == "hls"]
        var readinessObservations: [[String: Any]] = []
        var setupStage = "fixtureValidation"
        var setupFailure: [String: Any] = [:]
        var directBytesVerified = false
        var createdFixture: ProbeFixture?
        let audio = AVAudioSession.sharedInstance()
        var audioObservation: [String: Any] = [:]
        var status = "failed"
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("native-sync-\(workload)-\(intervalMilliseconds)ms-\(UUID().uuidString).json")
        defer {
            let report: [String: Any] = [
                "schemaVersion": 1, "status": status, "purpose": "separate diagnostic synchronization probe",
                "workload": workload, "mediaSHA256": mediaSHA256, "queryIntervalMilliseconds": intervalMilliseconds,
                "configurationSHA256": configurationSHA256,
                "directBytesVerifiedOnDevice": directBytesVerified,
                "setupStage": setupStage, "setupFailure": setupFailure,
                "readinessObservations": readinessObservations,
                "hlsIdentityScope": "host manifest verification; HLS responses are not independently hashed on device",
                "audioRoute": audioObservation["route"] ?? NSNull(),
                "audioSampleRate": audioObservation["sampleRate"] ?? NSNull(),
                "audioOutputChannels": audioObservation["outputChannels"] ?? NSNull(),
                "systemOutputVolume": audioObservation["volume"] ?? NSNull(),
                "samples": samples, "phases": phases, "frameworkSamples": frameworkSamples,
                "networkPreflight": networkPreflight,
                "nativeLogs": createdFixture?.logs ?? [],
                "nativeLogsDiscarded": createdFixture?.logsDiscarded ?? 0,
                "events": (createdFixture?.events ?? []).map { ["deliveryElapsedSeconds": $0.0 - origin, "event": $0.1] },
                "limitations": [
                    "Queries are sequential on the engine queue, not an atomic native snapshot.",
                    "Query begin/end bound each read group; engine states and hardware logs are event-derived.",
                    "Unavailable values are null. Seeking may complete between samples; no sample is not zero drift.",
                    "State event timestamps describe main-actor delivery, not the native event instant.",
                    "50/500 ms controls include extra observer work and are not benchmark protocol4 performance runs.",
                    "HLS manifest network preflight and hashing run before all playback phases; playback is not retried after a failure.",
                    "Native warning/error messages are retained with a bounded test-only log buffer; normal info logs are not published to this probe.",
                    "Process CPU includes all test activity; query wall time includes native serialization and waiting.",
                    "Framework metrics/readback bracket the settled window outside the native query loop; their timestamps bound a slightly wider interval.",
                    "Displayed-buffer availability/dimensions and framework counters do not establish full pixel progression or physical panel scanout.",
                    "avsync is mpv audio/video timing, not panel scanout or audible synchronization."
                ]
            ]
            do {
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
                print("Native synchronization report: \(output.lastPathComponent), status=\(status)")
            } catch { Issue.record("Could not save synchronization evidence: \(error)") }
        }

        func recordReadiness(_ boundary: String) {
            let application = UIApplication.shared
            let applicationState: String = switch application.applicationState {
            case .active: "active"
            case .inactive: "inactive"
            case .background: "background"
            @unknown default: "unknown"
            }
            let scenes = application.connectedScenes.map { scene -> [String: Any] in
                let activation: String = switch scene.activationState {
                case .foregroundActive: "foregroundActive"
                case .foregroundInactive: "foregroundInactive"
                case .background: "background"
                case .unattached: "unattached"
                @unknown default: "unknown"
                }
                let windows = (scene as? UIWindowScene)?.windows ?? []
                return [
                    "type": String(describing: type(of: scene)),
                    "activationState": activation,
                    "sessionRole": scene.session.role.rawValue,
                    "windowCount": windows.count,
                    "keyWindowCount": windows.filter(\.isKeyWindow).count
                ]
            }
            readinessObservations.append([
                "boundary": boundary, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - origin,
                "applicationState": applicationState, "protectedDataAvailable": application.isProtectedDataAvailable,
                "sceneCount": scenes.count, "scenes": scenes
            ])
        }
        func requireForeground(_ stage: String) async throws {
            setupStage = stage
            recordReadiness("\(stage):before")
            do {
                try await eventually("the physical test host to enter a foreground-active scene during \(stage)", timeout: .seconds(10)) {
                    UIApplication.shared.connectedScenes.contains {
                        $0 is UIWindowScene && $0.activationState == .foregroundActive
                    }
                }
                recordReadiness("\(stage):ready")
            } catch {
                recordReadiness("\(stage):failed")
                let failure = error as NSError
                setupFailure = [
                    "stage": stage,
                    "errorDomain": failure.domain,
                    "errorCode": failure.code,
                    "description": failure.localizedDescription
                ]
                throw error
            }
        }

        if workload == "direct" {
            // Before the observation window, independently verify bundled bytes.
            let observed = try SHA256.hash(data: Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
            try #require(observed == config.directFileSHA256, "Bundled direct media differs from the verified host fixture")
            directBytesVerified = true
        }
        // Install the report writer before this requirement: launch failures
        // must retain application/scene evidence even without a player or audio.
        try await requireForeground("beforeAudioAndRenderer")
        setupStage = "audioActivation"
        let priorCategory = audio.category, priorMode = audio.mode, priorOptions = audio.categoryOptions
        defer {
            audioObservation = [
                "route": audio.currentRoute.outputs.map(\.portType.rawValue),
                "sampleRate": audio.sampleRate,
                "outputChannels": audio.outputNumberOfChannels,
                "volume": audio.outputVolume
            ]
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            try? audio.setCategory(priorCategory, mode: priorMode, options: priorOptions)
        }
        try audio.setCategory(.playback, mode: .moviePlayback)
        try audio.setActive(true)
        setupStage = "rendererCreation"
        let fixture = try ProbeFixture()
        createdFixture = fixture
        defer { fixture.close() }

        func observe(_ phase: String) async -> NativeSample {
            let requested = ProcessInfo.processInfo.systemUptime
            let sample = await fixture.snapshot()
            samples.append(sample.json(phase: phase, origin: origin, requested: requested))
            return sample
        }
        func collect(
            _ name: String,
            duration: Double? = nil,
            until predicate: ((NativeSample) -> Bool)? = nil
        ) async throws -> NativeSample {
            let begin = ProcessInfo.processInfo.systemUptime, cpuBegin = processCPU()
            var count = 0
            var sample = await observe(name)
            count += 1
            let deadline = begin + (duration ?? 12)
            while duration != nil ? ProcessInfo.processInfo.systemUptime < deadline : predicate?(sample) != true {
                if duration == nil {
                    try #require(ProcessInfo.processInfo.systemUptime < deadline, "Timed out during \(name)")
                }
                try #require(!sample.failed && !sample.fallback, "Native renderer failed during \(name)")
                // Sleep after completion: no catch-up bursts if a query stalls.
                try await Task.sleep(for: .milliseconds(intervalMilliseconds))
                sample = await observe(name)
                count += 1
            }
            try #require(!sample.failed && !sample.fallback, "Native renderer failed during \(name)")
            phases.append([
                "name": name,
                "beginElapsedSeconds": begin - origin,
                "endElapsedSeconds": ProcessInfo.processInfo.systemUptime - origin,
                "processCPUSeconds": nullableDifference(processCPU(), cpuBegin),
                "samples": count
            ])
            return sample
        }

        func observeFramework(_ boundary: String) async throws -> FrameworkSample {
            let renderer = fixture.layer.sampleBufferRenderer
            let begin = ProcessInfo.processInfo.systemUptime
            let value = await renderer.videoPerformanceMetrics
            let metricsEnd = ProcessInfo.processInfo.systemUptime
            let buffer = renderer.displayedPixelBuffer()
            let readbackEnd = ProcessInfo.processInfo.systemUptime
            let width = buffer.map(CVPixelBufferGetWidth), height = buffer.map(CVPixelBufferGetHeight)
            let delay = value?.totalAccumulatedFrameDelay
            func nullable(_ value: (some Any)?) -> Any {
                value.map { $0 as Any } ?? NSNull()
            }
            // Record unavailable evidence before requiring it, so a failed
            // probe retains nulls instead of silently substituting zero drops.
            frameworkSamples.append([
                "boundary": boundary, "queryBeginElapsedSeconds": begin - origin,
                "metricsEndElapsedSeconds": metricsEnd - origin,
                "readbackEndElapsedSeconds": readbackEnd - origin,
                "totalNumberOfFrames": nullable(value?.totalNumberOfFrames),
                "numberOfDroppedFrames": nullable(value?.numberOfDroppedFrames),
                "numberOfCorruptedFrames": nullable(value?.numberOfCorruptedFrames),
                "totalAccumulatedFrameDelaySeconds": nullable(delay.flatMap { $0.isFinite ? $0 : nil }),
                "displayedPixelBufferAvailable": buffer != nil,
                "displayedWidth": nullable(width), "displayedHeight": nullable(height)
            ])
            let metrics = try #require(value, "AVFoundation performance metrics are required on the physical device")
            let displayedWidth = try #require(width), displayedHeight = try #require(height)
            try #require(displayedWidth > 0 && displayedHeight > 0, "Displayed native buffer must have valid dimensions")
            try #require(metrics.totalNumberOfFrames > 0 && metrics.numberOfDroppedFrames >= 0 && metrics.numberOfCorruptedFrames >= 0)
            try #require(metrics.totalAccumulatedFrameDelay.isFinite && metrics.totalAccumulatedFrameDelay >= 0)
            return FrameworkSample(
                frames: metrics.totalNumberOfFrames,
                dropped: metrics.numberOfDroppedFrames,
                corrupted: metrics.numberOfCorruptedFrames,
                delay: metrics.totalAccumulatedFrameDelay,
                width: displayedWidth,
                height: displayedHeight
            )
        }

        if workload == "hls" {
            // A permission dialog or connectivity failure must not be mistaken
            // for an MPV scheduling failure. Wait before measuring playback,
            // independently verify the fetched manifest, and retain failures.
            setupStage = "networkPreflight"
            let begin = ProcessInfo.processInfo.systemUptime
            let settings = URLSessionConfiguration.ephemeral
            settings.waitsForConnectivity = true
            settings.timeoutIntervalForRequest = 15
            settings.timeoutIntervalForResource = 30
            settings.urlCache = nil
            settings.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: settings)
            defer { session.invalidateAndCancel() }
            networkPreflight["beginElapsedSeconds"] = begin - origin
            networkPreflight["waitsForConnectivity"] = true
            networkPreflight["timeoutSeconds"] = 30
            networkPreflight["localNetworkUsageDescriptionPresent"] = Bundle.main
                .object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") is String
            networkPreflight["allowsLocalNetworking"] = (Bundle.main
                .object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])?["NSAllowsLocalNetworking"] as? Bool ?? false
            do {
                let (data, response) = try await session.data(from: source)
                let observed = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                networkPreflight["statusCode"] = (response as? HTTPURLResponse)?.statusCode ?? NSNull()
                networkPreflight["bytes"] = data.count
                networkPreflight["manifestSHA256"] = observed
                networkPreflight["endElapsedSeconds"] = ProcessInfo.processInfo.systemUptime - origin
                let expected = try #require(
                    config.hostVerification.hlsIdentity.files[source.lastPathComponent],
                    "The host-verified HLS manifest hash is required"
                )
                try #require((response as? HTTPURLResponse)?.statusCode == 200, "HLS preflight must return HTTP 200")
                try #require(data.starts(with: Data("#EXTM3U".utf8)), "HLS preflight response must be a playlist")
                try #require(observed == expected, "Fetched HLS manifest differs from the verified fixture")
                networkPreflight["passed"] = true
            } catch {
                let failure = error as NSError
                networkPreflight["passed"] = false
                networkPreflight["endElapsedSeconds"] = ProcessInfo.processInfo.systemUptime - origin
                networkPreflight["errorDomain"] = failure.domain
                networkPreflight["errorCode"] = failure.code
                networkPreflight["errorDescription"] = failure.localizedDescription
                networkPreflight["networkPath"] = failure.userInfo["_NSURLErrorNWPathKey"].map { String(describing: $0) } ?? NSNull()
                if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
                    networkPreflight["underlyingErrorDomain"] = underlying.domain
                    networkPreflight["underlyingErrorCode"] = underlying.code
                    networkPreflight["underlyingErrorDescription"] = underlying.localizedDescription
                }
                throw error
            }
            try await requireForeground("afterNetworkPreflight")
        }

        setupStage = "playback"
        _ = await observe("beforeLoad")
        fixture.mark("loadRequested")
        fixture.engine.load(source, autoPlay: true, startTime: .zero, generation: 1)
        let started = try await collect("startup", until: { $0.playing && ($0.position ?? 0) > 0 })
        try #require((started.duration ?? 0) >= 40, "Synchronization fixtures must be seekable and at least 40 seconds")
        _ = try await collect("startupRecovery", duration: 2)
        // Expensive framework observations stay outside the 50/500 ms native
        // query loop and outside the settled phase CPU interval.
        let frameworkBefore = try await observeFramework("beforeSteady")
        let before = await observe("steadyBoundary")
        let after = try await collect("steady", duration: 3)
        let frameworkAfter = try await observeFramework("afterSteady")
        try #require(frameworkAfter.frames > frameworkBefore.frames, "AVFoundation frame metrics must progress for this workload")
        try #require(frameworkAfter.dropped == frameworkBefore.dropped, "AVFoundation reported a settled frame drop or counter reset")
        try #require(frameworkAfter.corrupted == frameworkBefore.corrupted, "AVFoundation reported settled corruption or a counter reset")
        try #require(frameworkAfter.delay >= frameworkBefore.delay, "AVFoundation cumulative delay must not reset during steady playback")
        try #require(frameworkAfter.width == frameworkBefore.width && frameworkAfter.height == frameworkBefore.height)
        try #require(before.hardware == true && after.hardware == true)
        try #require(["videotoolbox", "videotoolbox-copy"].contains(before.hardwareDecoder ?? "")
            && ["videotoolbox", "videotoolbox-copy"].contains(after.hardwareDecoder ?? ""))
        try #require(before.audioOutput == "avfoundation" && after.audioOutput == "avfoundation")
        try #require(before.decoderDrops != nil && before.outputDrops != nil)
        try #require(before.decoderDrops == after.decoderDrops && before.outputDrops == after.outputDrops)
        let first = try #require(before.position), last = try #require(after.position)
        try #require((0.8 ... 1.2).contains((last - first) / (after.end - before.end)))
        fixture.mark("exactSeekRequested:20")
        fixture.engine.seek(to: .seconds(20))
        _ = try await collect("seek", until: {
            $0.playing && $0.seeking == false && ($0.position ?? -1) >= 19.9 && ($0.position ?? 100) < 22
        })
        let settled = try await collect("seekRecovery", duration: 2)
        try #require(settled.hardware == true && settled.audioOutput == "avfoundation")
        try #require(["videotoolbox", "videotoolbox-copy"].contains(settled.hardwareDecoder ?? ""))
        try #require(samples.contains { $0["phase"] as? String == "steady" && $0["avsyncSeconds"] is Double })
        setupStage = "completed"
        status = "passed"
    }

    private static func processCPU() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func processCPU() -> Double? {
        Self.processCPU()
    }

    private func nullableDifference(_ last: Double?, _ first: Double?) -> Any {
        guard let last, let first else { return NSNull() }
        return last - first
    }

    private struct FrameworkSample {
        let frames: Int, dropped: Int, corrupted: Int
        let delay: Double
        let width: Int, height: Int
    }

    private struct NativeSample: Sendable {
        let begin: Double, end: Double
        let avsync: Double?, correction: Double?, position: Double?, duration: Double?
        let paused: Bool?, seeking: Bool?, cachePaused: Bool?
        let playing: Bool, hardware: Bool?, hardwareDecoder: String?, audioOutput: String?
        let decoderDrops: Int64?, outputDrops: Int64?
        let failed: Bool, fallback: Bool
        func json(phase: String, origin: Double, requested: Double) -> [String: Any] {
            func value(_ x: (some Any)?) -> Any {
                x.map { $0 as Any } ?? NSNull()
            }
            return [
                "phase": phase,
                "requestElapsedSeconds": requested - origin,
                "queryBeginElapsedSeconds": begin - origin,
                "queryEndElapsedSeconds": end - origin,
                "queueWaitSeconds": begin - requested,
                "queryWallSeconds": end - begin,
                "avsyncSeconds": value(avsync),
                "totalAudioVideoCorrectionSeconds": value(correction),
                "positionSeconds": value(position),
                "durationSeconds": value(duration),
                "paused": value(paused),
                "seeking": value(seeking),
                "pausedForCache": value(cachePaused),
                "playing": playing,
                "actualVideoToolboxHardware": value(hardware),
                "hardwareDecoder": value(hardwareDecoder),
                "audioOutput": value(audioOutput),
                "decoderDrops": value(decoderDrops),
                "outputDrops": value(outputDrops),
                "failed": failed,
                "rendererFallback": fallback
            ]
        }
    }

    @MainActor
    private final class ProbeFixture {
        let engine: MPVEngine
        let layer = AVSampleBufferDisplayLayer()
        let window: UIWindow
        private weak var previousKeyWindow: UIWindow?
        private let recorder: EventRecorder
        var events: [(Double, String)] {
            recorder.values
        }

        var logs: [[String: Any]] {
            recorder.logs
        }

        var logsDiscarded: Int {
            recorder.logsDiscarded
        }

        init() throws {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = try #require(
                scenes.first { $0.activationState == .foregroundActive },
                "A foreground physical-device scene is required"
            )
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            let host = UIViewController()
            host.view.backgroundColor = .black
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            layer.frame = host.view.bounds
            host.view.layer.addSublayer(layer)
            recorder = EventRecorder()
            let recorder = recorder
            engine = MPVEngine(configuration: .init(
                additionalOptions: ["sub-auto": "no", "sub-visibility": "no", "osd-level": "0"],
                audio: .init(audioSession: .hostManaged), autoPlay: true,
                hardwareDecoding: .videoToolbox, logLevel: .warning, videoOutput: .sampleBuffer
            )) { emission in
                switch emission.update {
                case let .state(state): recorder.add("state:\(state)")
                case let .error(error, fatal): recorder.add("error:\(error), fatal:\(fatal)")
                case .nativeVideoOutputUnavailable: recorder.add("nativeVideoOutputUnavailable")
                case let .log(log): recorder.addLog(log)
                default: break
                }
            }
            let scale = scene.screen.scale
            engine.attach(to: MPVRenderTarget(
                layerAddress: Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque())), layerOwner: layer,
                drawableWidth: Int(layer.bounds.width * scale), drawableHeight: Int(layer.bounds.height * scale),
                usesExtendedDynamicRange: false, displaySupportsExtendedDynamicRange: false, outputHeadroom: 1
            ))
        }

        func mark(_ label: String) {
            recorder.add(label)
        }

        func close() {
            engine.shutdownSynchronously()
            layer.removeFromSuperlayer()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        func snapshot() async -> NativeSample {
            let engine = engine
            return await withCheckedContinuation { continuation in
                engine.queue.async {
                    let begin = ProcessInfo.processInfo.systemUptime
                    let avsync = engine.getDouble("avsync"), correction = engine.getDouble("total-avsync-change")
                    let position = engine.getDouble("time-pos"), duration = engine.getDouble("duration")
                    let paused = engine.getFlag("pause"), seeking = engine.getFlag("seeking"),
                        cachePaused = engine.getFlag("paused-for-cache")
                    let hwdec = engine.getString("hwdec-current"), ao = engine.getString("current-ao")
                    let decoderDrops = engine.getInt64("decoder-frame-drop-count"), outputDrops = engine.getInt64("frame-drop-count")
                    continuation.resume(returning: NativeSample(
                        begin: begin, end: ProcessInfo.processInfo.systemUptime,
                        avsync: avsync, correction: correction, position: position, duration: duration,
                        paused: paused, seeking: seeking, cachePaused: cachePaused,
                        playing: engine.isFileLoaded && engine.hasPlaybackStarted && !engine.isPaused && !engine.isSeeking && !engine
                            .isPausedForCache,
                        hardware: engine.videoToolboxSessionUsesHardware, hardwareDecoder: hwdec, audioOutput: ao,
                        decoderDrops: decoderDrops, outputDrops: outputDrops,
                        failed: engine.fatalPlaybackError != nil,
                        fallback: engine.didRequestNativeOutputFallback || engine.videoOutput != .sampleBuffer
                    ))
                }
            }
        }
    }

    @MainActor
    private final class EventRecorder {
        var values: [(Double, String)] = []
        var logs: [[String: Any]] = []
        var logsDiscarded = 0
        func add(_ value: String) {
            values.append((ProcessInfo.processInfo.systemUptime, value))
        }

        func addLog(_ value: MPVLogMessage) {
            if logs.count == 32 {
                logs.removeFirst()
                logsDiscarded += 1
            }
            logs.append([
                "deliverySystemUptimeSeconds": ProcessInfo.processInfo.systemUptime,
                "prefix": value.prefix,
                "level": value.level.rawValue,
                "message": String(value.message.prefix(4096)),
                "messageTruncated": value.message.count > 4096
            ])
        }
    }
}
#endif
