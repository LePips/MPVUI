import CMPV
import Foundation
import MPVCore
import Synchronization
import Testing

struct MPVSessionContractTests {

    @Test(arguments: [false, true])
    func `video only load errors preserve pending time while a surface arrives`(attached: Bool) {
        let player = session()
        defer { player.close() }
        player.queue.sync {
            player.playbackRequestIsActive = true
            player.sourceLoadWasHeadless = true
            player.lastPosition = .seconds(2)
            player.pendingSeekAfterLoad = attached ? .seconds(4) : nil
            if attached {
                player.renderTarget = .init(
                    layerAddress: 1,
                    layerOwner: NSObject(),
                    drawableWidth: 100,
                    drawableHeight: 100,
                    usesExtendedDynamicRange: false,
                    displaySupportsExtendedDynamicRange: false,
                    outputHeadroom: 1
                )
            }
            var end = mpv_event_end_file()
            end.reason = MPV_END_FILE_REASON_ERROR
            end.error = MPV_ERROR_NOTHING_TO_PLAY.rawValue
            withUnsafeMutablePointer(to: &end) { pointer in
                var event = mpv_event()
                event.event_id = MPV_EVENT_END_FILE
                event.data = UnsafeMutableRawPointer(pointer)
                player.handleEvent(event)
            }
            #expect(player.isLoading && player.needsSourceLoad && !player.isFileLoaded)
            #expect(player.pendingStartTime == .seconds(attached ? 4 : 2))
            #expect(player.pendingSeekAfterLoad == nil)
            #expect(player.latestSnapshot.state == .loading && player.latestSnapshot.error == nil)
        }
    }

    @Test
    func `typed controls retain settings and external tracks before native playback exists`() throws {
        let player = session()
        defer { player.close() }
        let audio = MPVMediaTrackIdentifier(type: .audio, mpvID: 3)
        let source = URL(fileURLWithPath: "/queued-audio.mka")
        for command: MPVSessionCommand in [
            .volume(42),
            .mute(true),
            .playbackRate(1.25),
            .selectTrack(audio),
            .disableTrack(.video),
            .selectSubtitle(nil, role: .secondary),
            .interceptTextSubtitles(true),
            .diagnostics(true),
            .externalTrack(source, type: .audio, select: true, role: nil),
        ] {
            try player.send(command)
        }
        let snapshot = player.snapshot
        #expect(snapshot.volume == 42 && snapshot.isMuted && snapshot.playbackRate == 1.25)
        #expect(snapshot.interceptsTextSubtitles && snapshot.isDiagnosticsEnabled)
        player.queue.sync {
            #expect(player.handle == nil && player.diagnosticsTimer == nil)
            #expect(player.desiredProperties["aid"] == "3")
            #expect(player.desiredProperties["vid"] == "no")
            #expect(player.desiredProperties["secondary-sid"] == "no")
            #expect(player.pendingExternalTracks.count == 1)
        }
        try player.send(.frameStep(backward: true))
        guard case let .commandFailed(_, code, _) = player.snapshot.error else {
            Issue.record("Frame stepping without a client must report unavailability")
            return
        }
        #expect(code == MPV_ERROR_UNINITIALIZED.rawValue)
        try player.send(.clearError)
        try player.send(.native([]))
        try player.send(.native([""]))
        try player.send(.property(" \n", "unused"))
        #expect(player.snapshot.error == nil)
        #expect(player.snapshot.generation == 0)
        player.close()
        _ = player.requestVideoFeatures([.inlineOverlays])
        #expect(player.snapshot.isClosed && player.snapshot.requestedVideoFeatures == nil)
    }

    @Test
    func `software deinterlacing preserves explicit field processing contracts`() {
        let forced = MPVDeinterlacePolicy(mode: .forced)
        #expect(MPVRenderingOptions.deinterlaceOptions(forced)["deinterlace"] == "yes")
        let analyzed = MPVDeinterlacePolicy(analyzeFieldOrder: true, mode: .automatic)
        #expect(MPVRenderingOptions.deinterlaceOptions(analyzed)["vf"] == "lavfi=[idet,bwdif=mode=send_field:parity=auto:deint=interlaced]")
        let explicit = MPVDeinterlacePolicy(algorithm: .bwdif, mode: .automatic)
        #expect(MPVRenderingOptions.deinterlaceOptions(explicit)["vf"] == "lavfi=[bwdif=mode=send_field:parity=auto:deint=interlaced]")
        for policy in [analyzed, explicit, .init(algorithm: .yadif, mode: .forced)] {
            let status = MPVRenderingOptions.deinterlaceStatus(policy: policy, interlaced: true, hardwareDecoder: "no")
            #expect(status.requiresSoftwareFrames == true)
            #expect(status.effectiveFilter == (policy.algorithm == .yadif ? "yadif" : "bwdif"))
            #expect(status.reason?.contains("software-accessible") == true)
        }
        let active = MPVRenderingOptions.deinterlaceStatus(
            policy: forced,
            interlaced: true,
            hardwareDecoder: "no",
            automaticFilterIsActive: true
        )
        #expect(active.isActive == true && active.requiresSoftwareFrames == true)
        #expect(active.reason == "bwdif runs on software-accessible frames.")
    }

    @Test
    func `native command prefixes preserve source and renderer ownership`() throws {
        let player = session()
        defer { player.close() }
        for prefix in [
            "no-osd",
            "osd-bar",
            "osd-msg",
            "osd-msg-bar",
            "osd-auto",
            "expand-properties",
            "raw",
            "repeatable",
            "nonrepeatable",
            "nonscalable",
            "async",
            "sync"
        ] {
            try player.send(.native([prefix, "loadfile", "/unexpected.mp4"]))
            guard case .commandFailed = player.snapshot.error else {
                Issue.record("Prefixed source replacement escaped the typed load API")
                return
            }
            try player.send(.native([prefix, "set", "vo", "null"]))
            #expect(player.snapshot.error == .reservedProperty(name: "vo"))
        }
        try player.send(.native(["playlist_next"]))
        guard case .commandFailed = player.snapshot.error else {
            Issue.record("Command alias escaped source ownership")
            return
        }
        try player.send(.native(["no-osd", "raw", "expand-properties", "set", "options/sub-text-intercept", "yes"]))
        #expect(player.snapshot.error == .reservedProperty(name: "options/sub-text-intercept"))
        #expect(player.snapshot.generation == 0)
        #expect(player.queue.sync { player.handle == nil })
        player.queue.sync {
            player.recordPersistentCommandMutation(["no-osd", "cycle_values", "audio-delay", "0", "1"])
            #expect(player.commandMutatedOptions == ["audio-delay"])
        }
    }

    @Test
    func `embedded NUL bytes cannot truncate commands or retained properties`() throws {
        let player = session()
        defer { player.close() }
        player.queue.sync { player.createHandle() }
        let commands: [MPVSessionCommand] = [
            .native(["loadfile\0", "/unexpected.mp4"]),
            .native(["set", "volume", "25\0"]),
            .property("mute\0", "yes"),
            .property("audio-delay", "1\0"),
        ]
        for command in commands {
            try player.send(command)
            guard case let .commandFailed(_, code, _) = player.snapshot.error else {
                Issue.record("Unexpected result for \(String(reflecting: command)): \(String(describing: player.snapshot.error))")
                return
            }
            #expect(code == MPV_ERROR_INVALID_PARAMETER.rawValue)
            try player.send(.clearError)
            #expect(player.snapshot.error == nil)
        }
        #expect(player.snapshot.generation == 0)
        player.queue.sync {
            #expect(player.getDouble("volume") == 100)
            #expect(player.getFlag("mute") == false)
            #expect(player.desiredProperties["mute"] != "yes")
            #expect(player.desiredProperties["mute\0"] == nil)
            #expect(player.desiredProperties["audio-delay"] == nil)
            let (status, value) = player.runCommandReturningValue(["loadfile\0", "/unexpected.mp4"])
            #expect(status == MPV_ERROR_INVALID_PARAMETER.rawValue && value == nil)
            #expect(player.setPropertyImmediately("mute\0", to: "yes") == MPV_ERROR_INVALID_PARAMETER.rawValue)
            #expect(player.setPropertyImmediately("mute", to: "yes\0") == MPV_ERROR_INVALID_PARAMETER.rawValue)
            #expect(player.lifecycleDiagnostics.loadCommands == 0)
        }
    }

    @Test(arguments: [("vo\0", "null"), ("user-agent", "truncated\0agent")])
    func `initial options reject embedded NUL bytes and destroy the incomplete client`(name: String, value: String) {
        let player = MPVSession(settings: .init(additionalOptions: ["ao": "null", name: value]), platform: .init()) { _ in }
        defer { player.close() }
        player.queue.sync { player.createHandle() }
        guard case let .initializationFailed(_, code, _) = player.snapshot.error else {
            Issue.record("An invalid initial option was accepted")
            return
        }
        #expect(code == MPV_ERROR_INVALID_PARAMETER.rawValue)
        #expect(player.queue.sync { player.handle == nil })
    }

    @Test
    func `platform source access is balanced when initialization fails and a load is replaced`() throws {
        let access = Mutex<[String]>([])
        var platform = MPVPlatformServices()
        platform.beginSourceAccess = { url in
            access.withLock { $0.append("begin:\(url.lastPathComponent)") }
            return true
        }
        platform.endSourceAccess = { url in access.withLock { $0.append("end:\(url.lastPathComponent)") } }
        platform.prepareHandle = { _ in MPV_ERROR_UNINITIALIZED.rawValue }
        let player = MPVSession(settings: .init(autoPlay: false), platform: platform) { _ in }
        defer { player.close() }
        try player.send(.load(URL(fileURLWithPath: "/scoped-first.mp4")))
        guard case let .initializationFailed(context, code, _) = player.snapshot.error else {
            Issue.record("Platform initialization failure was not delivered")
            return
        }
        #expect(context == "Prepare native session" && code == MPV_ERROR_UNINITIALIZED.rawValue)
        try player.send(.load(URL(fileURLWithPath: "/scoped-second.mp4")))
        _ = player.snapshot
        try player.send(.stop)
        _ = player.snapshot
        player.close()
        #expect(access.withLock { $0 } == [
            "begin:scoped-first.mp4",
            "end:scoped-first.mp4",
            "begin:scoped-second.mp4",
            "end:scoped-second.mp4",
        ])
        #expect(player.queue.sync { player.handle == nil })
    }

    @Test
    func `packaging preserves source options without creating a playback client`() async {
        let player = MPVSession(settings: .init(additionalOptions: [
            "vid": "no",
            "user-agent": "Shared core",
            "referrer": "https://example.invalid/",
            "http-header-fields": "X-Playback: token",
            "network-timeout": "invalid",
            "volume": "80",
        ]), platform: .init()) { _ in }
        defer { player.close() }
        let options = await player.externalPlaybackOptions()
        #expect(options.videoIndex == -2)
        #expect(options.input["user_agent"] == "Shared core")
        #expect(options.input["referer"] == "https://example.invalid/")
        #expect(options.input["rw_timeout"] == "60000000")
        #expect(options.requiresRenderer)
        #expect(options.mpv["volume"] == nil)
        #expect(player.queue.sync { player.handle == nil })
        let defaults = session()
        defer { defaults.close() }
        #expect(await defaults.externalPlaybackOptions().mpv["vid"] == "auto")
    }

    @Test
    func `packaging validates input timeouts and retains renderer dependent options`() {
        let headers = MPVMediaPackagingOptions(mpv: ["audio-delay": "invalid", "network-timeout": "-4"], httpHeaders: ["X-Playback: token"])
        #expect(!headers.requiresRenderer)
        #expect(headers.input["headers"] == "X-Playback: token\r\n")
        #expect(headers.input["rw_timeout"] == "1000000")
        let cookies = MPVMediaPackagingOptions(mpv: ["cookies": "yes", "network-timeout": "99999", "tls-verify": "no"])
        #expect(cookies.requiresRenderer)
        #expect(cookies.input["tls_verify"] == "0")
        #expect(cookies.input["rw_timeout"] == "3600000000")
        #expect(!MPVMediaPackagingOptions(mpv: ["sid": "3", "sub-visibility": "no"]).requiresRenderer)
        #expect(MPVMediaPackagingOptions(mpv: ["secondary-sid": "4"]).requiresRenderer)
    }

    @Test
    func `display metadata keeps fractional refresh rates and rejects invalid measurements`() {
        #expect(MPVDisplayCapabilities(refreshRate: 60000.0 / 1001).refreshRate == 60000.0 / 1001)
        for rate in [Double.nan, .infinity, -.infinity, 0, -60] {
            #expect(MPVDisplayCapabilities(refreshRate: rate).refreshRate == nil)
        }
        #expect(!MPVMediaTrack(id: 1, type: .subtitle).isSemanticTextSubtitle)
    }

    @Test
    func `commands have ordered identities and preserve deferred seek intention`() throws {
        let player = session()
        defer { player.close() }
        let first = try player.send(.pause)
        let second = try player.send(.seek(.seconds(12.125)))
        let third = try player.send(.seekRelative(.seconds(-2.5)))
        #expect(first.id < second.id && second.id < third.id)
        #expect(first.generation == 0 && third.generation == 0)
        #expect(player.snapshot.position == .seconds(9.625))
        #expect(player.snapshot.isPaused)
    }

    @Test
    func `close finishes observers and rejects attempts to create another handle`() async throws {
        let player = session()
        let events = player.events()
        player.queue.sync { player.createHandle() }
        #expect(player.queue.sync { player.handle != nil })
        player.close()
        player.close()
        #expect(player.snapshot.isClosed)
        #expect(player.snapshot.state == .stopped)
        #expect(throws: MPVPlayerError.clientUnavailable) { try player.send(.play) }
        #expect(player.queue.sync { player.handle == nil && player.lifecycleDiagnostics.handlesDestroyed == 1 })
        var final: MPVSessionSnapshot?
        for await event in events {
            if case let .snapshot(value) = event {
                final = value
            }
        }
        #expect(final?.isClosed == true)
        var late = player.events().makeAsyncIterator()
        _ = await late.next()
        #expect(await late.next() == nil)
    }

    @Test
    func `independent sessions own distinct native clients and state`() throws {
        let first = session()
        let second = session()
        defer { first.close()
            second.close()
        }
        first.queue.sync { first.createHandle() }
        second.queue.sync { second.createHandle() }
        let firstHandle = first.queue.sync { first.handle }
        let secondHandle = second.queue.sync { second.handle }
        #expect(firstHandle != nil && secondHandle != nil && firstHandle != secondHandle)
        try first.send(.volume(35))
        first.queue.sync { first.refreshAudioState() }
        #expect(first.snapshot.volume == 35)
        #expect(second.snapshot.volume == 100)
        first.close()
        #expect(second.queue.sync { second.handle != nil })
    }

    @Test
    func `stale native terminal events cannot fail a replacement generation`() {
        let player = session()
        defer { player.close() }
        player.queue.sync {
            player.currentGeneration = 2
            player.playbackRequestIsActive = true
            player.requestedPlaylistEntryID = 2
            player.activePlaylistEntryID = 1
            var end = mpv_event_end_file()
            end.playlist_entry_id = 1
            end.reason = MPV_END_FILE_REASON_ERROR
            end.error = MPV_ERROR_LOADING_FAILED.rawValue
            withUnsafeMutablePointer(to: &end) { pointer in
                var event = mpv_event()
                event.event_id = MPV_EVENT_END_FILE
                event.data = UnsafeMutableRawPointer(pointer)
                player.handleEvent(event)
            }
            #expect(player.requestedPlaylistEntryID == 2)
            #expect(player.fatalPlaybackError == nil)
            #expect(player.playbackRequestIsActive)
        }
    }

    @Test
    func `subtitle query cancellation completes without a loaded source`() async {
        let player = session()
        defer { player.close() }
        let query = Task { try await player.textSubtitleSnapshots(for: .init(type: .subtitle, mpvID: 1)) }
        query.cancel()
        do {
            _ = try await query.value
            Issue.record("Cancelled subtitle query unexpectedly returned cues")
        } catch is CancellationError {
        } catch let error as MPVPlayerError {
            // A validation failure may win the race with cancellation.
            guard case .commandFailed = error else { Issue.record("Unexpected error: \(error)")
                return
            }
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(player.queue.sync { player.subtitleQueries.isEmpty })
    }

    @Test
    func `seconds transport preserves fractions and rejects nonfinite values`() {
        let seconds = 123.125
        #expect(Duration(mpvSeconds: seconds)?.seconds == seconds)
        #expect(Duration(mpvSeconds: .nan) == nil)
        #expect(Duration(mpvSeconds: .infinity) == nil)
        #expect(Duration(mpvSeconds: Double.greatestFiniteMagnitude) == nil)
    }

    @Test
    func `renderer requests share canonical capabilities and reset after stop`() throws {
        let player = session()
        defer { player.close() }
        let pending = player.requestVideoFeatures([.nativeSubtitles])
        #expect(pending.outcome == .awaitingVideoMetadata)
        player.queue.sync {
            player.latestSnapshot.mediaInformation = .init(
                tracks: [.init(id: 1, type: .video)],
                hdr: .init(presentation: .init(backend: .nativeSurface))
            )
        }
        let denied = player.requestVideoFeatures([.zoomAndPan])
        #expect(denied.unavailableFeatures == [.nativeSubtitles, .zoomAndPan])
        #expect(player.snapshot.videoFeatureCapabilities[.inlineOverlays].availability == .available)
        try player.send(.stop)
        #expect(player.snapshot.videoFeatureRequestResult == nil)
    }

    @Test
    func `raw source replacement cannot bypass typed generation ownership`() throws {
        let player = session()
        defer { player.close() }
        try player.send(.native(["loadfile", "/tmp/other.mp4"]))
        #expect(player.snapshot.error != nil)
        #expect(player.snapshot.generation == 0)
        #expect(player.queue.sync { player.handle == nil })
    }

    @Test
    func `failure before file loaded is a load error`() {
        let player = session()
        defer { player.close() }
        player.queue.sync {
            player.playbackRequestIsActive = true
            player.isFileLoaded = false
            var end = mpv_event_end_file()
            end.reason = MPV_END_FILE_REASON_ERROR
            end.error = MPV_ERROR_LOADING_FAILED.rawValue
            withUnsafeMutablePointer(to: &end) { pointer in
                var event = mpv_event()
                event.event_id = MPV_EVENT_END_FILE
                event.data = UnsafeMutableRawPointer(pointer)
                player.handleEvent(event)
            }
            #expect(player.latestSnapshot.error == .loadFailed(code: MPV_ERROR_LOADING_FAILED.rawValue, message: "loading failed"))
        }
    }

    @Test
    func `inband Dolby Vision metadata does not require a container profile`() {
        #expect(MPVVideoSignal(matrix: "dolbyvision").hasDolbyVisionMetadata)
        #expect(MPVVideoSignal(dolbyVisionProfile: 5).hasDolbyVisionMetadata)
        #expect(!MPVVideoSignal(transferFunction: .pq, matrix: "bt.2020-ncl").hasDolbyVisionMetadata)
    }

    @Test
    func `queued mute toggles use core state before UI delivery`() throws {
        let player = session()
        defer { player.close() }
        try player.send(.toggleMute)
        try player.send(.toggleMute)
        #expect(!player.snapshot.isMuted)
        try player.send(.toggleMute)
        #expect(player.snapshot.isMuted)
    }

    @Test
    func `raw aliases cannot bypass subtitle interception ownership`() throws {
        let player = session()
        defer { player.close() }
        try player.send(.native(["set", "options/sub-text-intercept", "yes"]))
        #expect(player.snapshot.error == .reservedProperty(name: "options/sub-text-intercept"))
        #expect(!player.snapshot.interceptsTextSubtitles)
    }

    @Test
    func `subtitle commands reject a different track type in the shared session`() throws {
        let player = session()
        defer { player.close() }
        let id = MPVMediaTrackIdentifier(type: .audio, mpvID: 1)
        try player.send(.selectSubtitle(id, role: .secondary))
        #expect(player.snapshot.error == .invalidSubtitleTrack(id))
        #expect(player.queue.sync { player.desiredProperties["secondary-sid"] == nil })
        #expect(player.snapshot.state == .idle)
    }

    #if os(Android)
    @Test
    func `C ABI owns one production Android client and rejects incompatible layouts`() throws {
        var configuration = MPVCoreConfiguration()
        configuration.version = UInt32(MPVCORE_ABI_VERSION)
        configuration.size = UInt32(MemoryLayout<MPVCoreConfiguration>.size)
        configuration.volume = 100
        configuration.playback_rate = 1
        configuration.initial_buffer_seconds = 1
        configuration.network_cache_seconds = 10
        let handle = try #require(mpvcore_session_create(&configuration))
        defer { mpvcore_session_release(handle) }
        #expect(mpvcore_abi_version() == MPVCORE_ABI_VERSION)
        #expect(mpvcore_session_initialize(handle) == 0)
        mpvcore_session_retain(handle)
        mpvcore_session_close(handle)
        mpvcore_session_close(handle)
        #expect(mpvcore_session_initialize(handle) == MPV_ERROR_UNINITIALIZED.rawValue)
        mpvcore_session_release(handle)
        configuration.version += 1
        #expect(mpvcore_session_create(&configuration) == nil)
    }

    @Test
    func `C ABI rejects malformed UTF8 and releases copied snapshots`() throws {
        var configuration = MPVCoreConfiguration()
        configuration.version = UInt32(MPVCORE_ABI_VERSION)
        configuration.size = UInt32(MemoryLayout<MPVCoreConfiguration>.size)
        configuration.volume = 100
        configuration.playback_rate = 1
        let handle = try #require(mpvcore_session_create(&configuration))
        defer { mpvcore_session_close(handle)
            mpvcore_session_release(handle)
        }
        var command = MPVCoreCommand()
        command.version = UInt32(MPVCORE_ABI_VERSION)
        command.size = UInt32(MemoryLayout<MPVCoreCommand>.size)
        command.kind = 18
        for bytes: [UInt8] in [[0xC3, 0x28], [0x61, 0, 0x62]] {
            bytes.withUnsafeBufferPointer { buffer in
                var string = MPVCoreString(data: buffer.baseAddress, length: buffer.count)
                withUnsafePointer(to: &string) { pointer in
                    command.strings = pointer
                    command.string_count = 1
                    #expect(mpvcore_session_send(handle, &command, nil) == MPV_ERROR_INVALID_PARAMETER.rawValue)
                }
            }
        }
        command.strings = nil
        command.string_count = 0
        command.kind = 6
        command.value = .infinity
        #expect(mpvcore_session_send(handle, &command, nil) == MPV_ERROR_INVALID_PARAMETER.rawValue)
        let snapshot = mpvcore_session_snapshot(handle)
        let bytes = Array(UnsafeBufferPointer(start: snapshot.data, count: snapshot.length))
        mpvcore_buffer_release(snapshot)
        #expect(Array(bytes.prefix(8)) == [77, 80, 86, 67, 1, 0, 0, 0])
        #expect(bytes.count > 8)
    }

    @Test
    func `C observer cancellation fences its borrowed callback context`() throws {
        var configuration = MPVCoreConfiguration()
        configuration.version = UInt32(MPVCORE_ABI_VERSION)
        configuration.size = UInt32(MemoryLayout<MPVCoreConfiguration>.size)
        let handle = try #require(mpvcore_session_create(&configuration))
        defer { mpvcore_session_release(handle) }
        let calls = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        calls.initialize(to: 0)
        defer { calls.deinitialize(count: 1)
            calls.deallocate()
        }
        let subscription = try #require(mpvcore_session_subscribe(handle, calls) { context, _, _, buffer in
            context?.assumingMemoryBound(to: Int.self).pointee += 1
            mpvcore_buffer_release(buffer)
        })
        mpvcore_subscription_release(subscription)
        let delivered = calls.pointee
        mpvcore_session_close(handle)
        #expect(delivered == 1)
        #expect(calls.pointee == delivered)
    }
    #endif
    private func session() -> MPVSession {
        var platform = MPVPlatformServices()
        platform.initialOptions = { _, _, _ in [("ao", "null"), ("hwdec", "no")] }
        return MPVSession(settings: .init(autoPlay: false), platform: platform) { _ in }
    }
}
