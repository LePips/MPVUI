import Foundation
import MPVCore
#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
#endif

/// Manages HLS packaging and its HTTP server for one playback session.
/// Limits how far packaging runs ahead of playback. Seeking outside its window requires a new session.
@MainActor
final class MPVHLSStream {

    private(set) var startTime: Duration
    private(set) var packagingInfo: MPVMediaPackager.Info?
    private(set) var preparationPlan: MPVExternalPlaybackPlan?
    private(set) var failure: String?
    private var requiresForeground = false
    private var usesRenderer = false
    private let packager = MPVMediaPackager()
    private let directory: URL
    private let transcoder = MPVMediaTranscoder()
    private let server: MPVHTTPMediaServer
    private var updatesTask: Task<Void, Never>?
    private var encodedPosition: Double
    private var playbackPosition: Double
    private var isThrottled = false
    private var isFinished = false
    private var isStopped = false
    private var isInactive = false
    private var applicationObservers: [NSObjectProtocol] = []

    var isTranscoding: Bool {
        preparationPlan?.isTranscoding ?? false
    }

    init(startTime: Duration) throws {
        self.startTime = startTime
        encodedPosition = startTime.seconds
        playbackPosition = startTime.seconds

        directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("MPVUI-Stream-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = MPVHTTPMediaServer(directory: directory)
    }

    isolated deinit {
        applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        updatesTask?.cancel()

        let transcoder = transcoder
        let packager = packager
        let server = server
        let directory = directory

        Task {
            await packager.stop()
            await transcoder.stop()
            await server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func start(source: URL, options: [String: String], toneMapHDR: Bool = false, advertisedHost: String? = nil) async throws -> URL {
        try await start(
            source: source,
            packaging: MPVMediaPackagingOptions(mpv: options),
            toneMapHDR: toneMapHDR,
            advertisedHost: advertisedHost
        )
    }

    func start(
        source: URL,
        packaging: MPVMediaPackagingOptions,
        toneMapHDR: Bool = false,
        advertisedHost: String? = nil,
        onPreparation: @escaping @MainActor (MPVExternalPlaybackPlan) -> Void = { _ in }
    ) async throws -> URL {
        usesRenderer = packaging.requiresRenderer

        if usesRenderer {
            let plan = MPVExternalPlaybackPlan(rendering: packaging, toneMapsHDR: toneMapHDR)
            preparationPlan = plan
            requiresForeground = plan.requiresForeground
            onPreparation(plan)
        }

        observeApplicationState()

        let url = try await server.start(advertisedHost: advertisedHost)

        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }

        let playlist = directory.appendingPathComponent(usesRenderer ? "stream.m3u8" : "media.m3u8")

        if usesRenderer {
            let updates = transcoder.updates

            updatesTask = Task { [weak self] in
                for await update in updates {
                    guard let self, !self.isStopped else { return }

                    switch update {
                    case let .progress(position):
                        self.encodedPosition = position
                        self.throttle()

                    case .finished:
                        self.isFinished = true

                    case let .failed(message):
                        self.failure = message
                    }
                }
            }

            transcoder.start(.init(
                source: source,
                playlist: playlist,
                startTime: startTime,
                options: packaging.mpv,
                toneMapHDR: toneMapHDR,
                initiallyPaused: requiresForeground && isInactive
            ))
        } else {
            let updates = packager.updates

            updatesTask = Task { [weak self] in
                for await update in updates {
                    guard let self, !self.isStopped else { return }

                    switch update {
                    case let .prepared(info):
                        self.packagingInfo = info
                        self.startTime = .seconds(info.startTime)
                        self.preparationPlan = info.preparationPlan
                        onPreparation(info.preparationPlan)
                        self.requiresForeground = info.requiresForeground
                        self.packager.setPaused(self.requiresForeground && self.isInactive)

                    case .finished:
                        self.isFinished = true

                    case let .failed(message):
                        self.failure = message
                    }
                }
            }

            packager.start(source: source, playlist: playlist, startTime: startTime, options: packaging)
        }

        var deadline = ContinuousClock.now + .seconds(60)
        var previousCheck = ContinuousClock.now

        while !isStopped {
            try Task.checkCancellation()

            let now = ContinuousClock.now

            if requiresForeground && isInactive {
                deadline += now - previousCheck
            }

            previousCheck = now

            if let failure {
                throw MPVHTTPMediaServer.ServerError(failure)
            }

            if let text = try? String(contentsOf: playlist, encoding: .utf8) {
                let segments = text.components(separatedBy: "\n").filter { $0.hasPrefix("#EXTINF:") }.count

                if segments >= 3 || (isFinished && segments > 0 && text.contains("#EXT-X-ENDLIST")) {
                    if !usesRenderer {
                        try publishMasterPlaylist()
                    }

                    return url
                }
            }

            if isFinished {
                throw MPVHTTPMediaServer.ServerError("Packaging produced no playable HLS segments.")
            }

            guard ContinuousClock.now < deadline else {
                throw MPVHTTPMediaServer.ServerError("Media packaging did not produce playable segments within 60 seconds.")
            }

            try await Task.sleep(for: .milliseconds(100))
        }

        throw CancellationError()
    }

    func updatePlaybackPosition(_ position: Duration) {
        playbackPosition = position.seconds
        packager.updatePlaybackPosition(position)
        throttle()
    }

    func stop() async {
        guard !isStopped else { return }

        isStopped = true
        applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        applicationObservers.removeAll()
        updatesTask?.cancel()
        updatesTask = nil
        await packager.stop()
        await transcoder.stop()
        await server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func throttle() {
        guard usesRenderer, !isFinished, !isStopped else { return }

        let ahead = encodedPosition - playbackPosition
        let paused = (requiresForeground && isInactive) || (isThrottled ? ahead > 12 : ahead > 24)
        guard paused != isThrottled else { return }

        isThrottled = paused
        transcoder.setPaused(paused)
    }

    private func publishMasterPlaylist() throws {
        guard let info = packagingInfo else { throw MPVHTTPMediaServer.ServerError("Missing packaging information.") }

        var text = try String(contentsOf: directory.appendingPathComponent("master.m3u8"), encoding: .utf8)

        if !info.videoCodec.isEmpty || !info.hasVideo {
            let codecs = [info.videoCodec, info.audioCodec].filter { !$0.isEmpty }.joined(separator: ",")

            text = text.replacingOccurrences(of: #",CODECS="[^"]*""#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "#EXT-X-STREAM-INF:", with: "#EXT-X-STREAM-INF:CODECS=\"\(codecs)\",")
        }

        if info.hasAudio {
            let audio = """
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DE\
            FAULT=YES,AUTOSELECT=YES,CHANNELS=\"\(info.audioChannels)\"\
            \n
            """
            text = text.replacingOccurrences(of: "#EXT-X-STREAM-INF:", with: audio + "#EXT-X-STREAM-INF:AUDIO=\"audio\",")
        }

        if info.hasVideo {
            text = text.replacingOccurrences(
                of: "#EXT-X-STREAM-INF:",
                with: "#EXT-X-STREAM-INF:VIDEO-RANGE=\(info.videoRange),FRAME-RATE=\(String(format: "%.3f", info.frameRate)),"
            )
        }

        if info.dolbyVisionProfile != 0 {
            let codec = String(format: "dvh1.%02d.%02d", info.dolbyVisionProfile, info.dolbyVisionLevel)

            if info.dolbyVisionProfile == 5 {
                text = text.replacingOccurrences(of: #"hvc1\.[^,\"]+"#, with: codec, options: .regularExpression)
            } else {
                text = text.replacingOccurrences(
                    of: "#EXT-X-STREAM-INF:",
                    with: "#EXT-X-STREAM-INF:SUPPLEMENTAL-CODECS=\"\(codec)/\(info.videoRange == "HLG" ? "db4h" : "db1p")\","
                )
            }
        }

        // Copied tracks can have missing or underestimated bitrates.
        // Calculate the advertised bandwidth from the completed startup segments.
        let media = try String(contentsOf: directory.appendingPathComponent("media.m3u8"), encoding: .utf8)
        var duration = 0.0
        var peak = 1.0

        for line in media.components(separatedBy: "\n") {
            if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).split(separator: ",")[0]) ?? 0
            } else if line.hasSuffix(".m4s"), duration > 0,
                      let size = try FileManager.default
                          .attributesOfItem(atPath: directory.appendingPathComponent(line).path)[.size] as? Int
            {
                peak = max(peak, Double(size) * 8 / duration)
            }
        }

        text = text.replacingOccurrences(
            of: #"(?<!-)BANDWIDTH=[0-9]+"#,
            with: "BANDWIDTH=\(Int(ceil(peak * 1.1)))",
            options: .regularExpression
        )

        text = text.replacingOccurrences(of: #",AVERAGE-BANDWIDTH=[0-9]+"#, with: "", options: .regularExpression)
        try text.write(to: directory.appendingPathComponent("stream.m3u8"), atomically: true, encoding: .utf8)
    }

    private func observeApplicationState() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        isInactive = UIApplication.shared.applicationState != .active
        isThrottled = requiresForeground && isInactive

        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            applicationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isStopped else { return }

                    self.isInactive = name == UIApplication.willResignActiveNotification
                    self.packager.setPaused(self.packagingInfo == nil || (self.requiresForeground && self.isInactive))

                    if self.requiresForeground && self.isInactive {
                        // Wait for GPU processing to pause before the app becomes inactive.
                        self.isThrottled = true
                        self.transcoder.setPaused(true, synchronously: true)
                    } else {
                        self.throttle()
                    }
                }
            })
        }
        #endif
    }
}
