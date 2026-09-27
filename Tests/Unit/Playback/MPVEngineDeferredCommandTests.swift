import Foundation
import Libmpv
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
struct MPVEngineDeferredCommandTests {
    @Test
    func `fallback command waits for playback restart and executes exactly once`() async throws {
        let engine = MPVEngine(configuration: .init()) { _ in }
        defer { engine.shutdownSynchronously() }
        try installClient(on: engine)
        engine.queue.sync {
            engine.currentGeneration = 7
            engine.playbackRequestIsActive = true
            engine.isLoading = true
        }
        engine.performCommand("add", arguments: ["volume", "5"], deferUntilPlaybackRestart: true, generation: 7)
        _ = await engine.lifecycleSnapshot()
        engine.queue.sync {
            #expect(engine.getDouble("volume") == 20)
            engine.isLoading = false
            engine.isFileLoaded = true
            var event = mpv_event()
            event.event_id = MPV_EVENT_PLAYBACK_RESTART
            engine.handleEvent(event)
            #expect(engine.getDouble("volume") == 25)
            engine.handleEvent(event)
            #expect(engine.getDouble("volume") == 25)
        }
    }

    @Test
    func `deferred commands preserve order and a ready renderer executes immediately`() async throws {
        let engine = MPVEngine(configuration: .init()) { _ in }
        defer { engine.shutdownSynchronously() }
        try installClient(on: engine)
        engine.queue.sync {
            engine.currentGeneration = 1
            engine.playbackRequestIsActive = true
            engine.isLoading = true
        }
        engine.performCommand("set", arguments: ["volume", "30"], deferUntilPlaybackRestart: true, generation: 1)
        engine.performCommand("add", arguments: ["volume", "5"], deferUntilPlaybackRestart: true, generation: 1)
        _ = await engine.lifecycleSnapshot()
        engine.queue.sync {
            engine.isLoading = false
            engine.isFileLoaded = true
            var event = mpv_event()
            event.event_id = MPV_EVENT_PLAYBACK_RESTART
            engine.handleEvent(event)
            #expect(engine.getDouble("volume") == 35)
        }
        engine.performCommand("add", arguments: ["volume", "5"], deferUntilPlaybackRestart: true, generation: 1)
        _ = await engine.lifecycleSnapshot()
        #expect(engine.queue.sync { engine.getDouble("volume") } == 40)
    }

    @Test
    func `stale generation and stopped ownership cannot replay deferred commands`() async throws {
        let engine = MPVEngine(configuration: .init()) { _ in }
        defer { engine.shutdownSynchronously() }
        try installClient(on: engine)
        engine.queue.sync {
            engine.currentGeneration = 2
            engine.playbackRequestIsActive = true
            engine.isLoading = true
        }
        engine.performCommand("set", arguments: ["volume", "70"], deferUntilPlaybackRestart: true, generation: 1)
        engine.performCommand("set", arguments: ["volume", "80"], deferUntilPlaybackRestart: true, generation: 2)
        engine.stop(generation: 3)
        _ = await engine.lifecycleSnapshot()
        #expect(engine.queue.sync { engine.handle == nil })
        try installClient(on: engine)
        engine.queue.sync {
            engine.currentGeneration = 3
            engine.playbackRequestIsActive = true
            engine.isLoading = false
            engine.isFileLoaded = true
            var event = mpv_event()
            event.event_id = MPV_EVENT_PLAYBACK_RESTART
            engine.handleEvent(event)
            #expect(engine.getDouble("volume") == 20)
        }
    }

    @Test
    func `terminal load failure cancels commands waiting for a replacement renderer`() async throws {
        let engine = MPVEngine(configuration: .init()) { _ in }
        defer { engine.shutdownSynchronously() }
        try installClient(on: engine)
        engine.queue.sync {
            engine.currentGeneration = 5
            engine.playbackRequestIsActive = true
            engine.isLoading = true
        }
        engine.performCommand("set", arguments: ["volume", "80"], deferUntilPlaybackRestart: true, generation: 5)
        _ = await engine.lifecycleSnapshot()
        engine.queue.sync {
            engine.publishFatalError(.loadFailed(code: -13, message: "fixture load failed"))
            engine.fatalPlaybackError = nil
            engine.isLoading = false
            engine.isFileLoaded = true
            var event = mpv_event()
            event.event_id = MPV_EVENT_PLAYBACK_RESTART
            engine.handleEvent(event)
            #expect(engine.getDouble("volume") == 20)
        }
    }

    @Test @MainActor
    func `detached idle command reports unavailable client without leaking into later playback`() async throws {
        var errors: [MPVPlayerError] = []
        let engine = MPVEngine(configuration: .init()) { emission in
            if case let .error(error, _) = emission.update {
                errors.append(error)
            }
        }
        defer { engine.shutdownSynchronously() }
        engine.performCommand("set", arguments: ["volume", "80"], deferUntilPlaybackRestart: true, generation: 0)
        try await eventually("idle command reports unavailable client") { !errors.isEmpty }
        try installClient(on: engine)
        engine.queue.sync {
            engine.playbackRequestIsActive = true
            engine.isFileLoaded = true
            var event = mpv_event()
            event.event_id = MPV_EVENT_PLAYBACK_RESTART
            engine.handleEvent(event)
            #expect(engine.getDouble("volume") == 20)
        }
    }

    private func installClient(on engine: MPVEngine) throws {
        let handle = try #require(mpv_create())
        _ = mpv_set_option_string(handle, "vo", "null")
        _ = mpv_set_option_string(handle, "ao", "null")
        _ = mpv_set_option_string(handle, "terminal", "no")
        _ = mpv_set_option_string(handle, "volume", "20")
        let status = mpv_initialize(handle)
        guard status >= 0 else {
            mpv_destroy(handle)
            Issue.record("Unable to initialize the native client for deferred-command validation")
            throw MPVPlayerError.clientCreationFailed
        }
        engine.queue.sync {
            #expect(engine.handle == nil)
            engine.handle = handle
        }
    }
}

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVAutomaticRenderingCommandIntegrationTests {
    private nonisolated static var supportsGPUReadback: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    @Test(.enabled(if: supportsGPUReadback, "Metal Simulator cannot allocate this libplacebo readback buffer"))
    func `one shot screenshot waits for native to Metal reload and preserves paused position`() async throws {
        // Isolate the video from the baseline fixture's subtitle sidecars, which
        // would request full rendering before the command under test runs.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderer-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("video.mp4")
        try FileManager.default.copyItem(at: TestPaths.baselineMedia, to: media)
        let fixture = PlaybackFixture(configuration: .init(
            autoPlay: false, hardwareDecoding: .disabled, logLevel: .info
        ))
        defer { fixture.close() }
        let player = fixture.player
        let completionMarker = "RENDERER_COMMAND_COMPLETE_\(UUID().uuidString)"
        var completed = false
        var nativeLogs: [String] = []
        player.logHandler = { message in
            nativeLogs.append("[\(message.prefix)] \(message.message)")
            if message.message.contains(completionMarker) {
                completed = true
            }
        }
        defer {
            if !completed || player.lastError != nil {
                print(nativeLogs.joined(separator: "\n"))
            }
        }
        #expect(player.videoOutput == .sampleBuffer)
        try await fixture.loadPaused(media, at: .seconds(1))
        try #require(player.videoOutput == .sampleBuffer)
        let before = await player.lifecycleDiagnostics()
        // Raw readback exercises frame readiness without an image encoder.
        // The bundled FFmpeg does not enable the PNG encoder, so writing PNG
        // would fail independently of successful renderer replacement/readback.
        player.command("screenshot-raw", arguments: ["video", "bgr0"])
        #expect(player.videoOutput == .metal)
        // This also requires the full renderer and follows the screenshot in
        // the deferred-command queue. Its log proves both commands completed.
        player.command("print-text", arguments: [completionMarker])
        try await eventually("screenshot and following command after replacement frame", timeout: .seconds(10)) {
            completed || player.lastError != nil
        }
        try #require(completed)
        try #require(player.lastError == nil)
        let after = await player.lifecycleDiagnostics()
        #expect(after.loadCommands == before.loadCommands + 1)
        #expect(after.handlesCreated == before.handlesCreated + 1)
        #expect(after.handlesDestroyed == before.handlesDestroyed + 1)

        // Validate an actual raw frame returned by that same replacement VO.
        let frame = try #require(await player.renderedScreenshotForTesting()?.mapValue)
        let width = try Int(#require(frame["w"]?.integerValue))
        let height = try Int(#require(frame["h"]?.integerValue))
        let rowBytes = try Int(#require(frame["stride"]?.integerValue))
        try #require(width > 0 && height > 0 && rowBytes >= width * 4)
        #expect(frame["format"]?.stringValue == "bgr0")
        guard case let .data(pixels) = frame["data"] else {
            Issue.record("Replacement renderer screenshot has no pixel data")
            return
        }
        try #require(pixels.count >= rowBytes * height)
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: height, by: max(1, height / 16)) {
            for x in stride(from: 0, to: width, by: max(1, width / 16)) {
                let offset = y * rowBytes + x * 4
                colors.insert(UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2]))
            }
        }
        #expect(colors.count > 4, "Replacement frame must contain the fixture's varied image content")
        #expect(player.isPaused)
        #expect(abs(player.position.seconds - 1) < 0.2)
        #expect(player.lastError == nil)
    }
}
