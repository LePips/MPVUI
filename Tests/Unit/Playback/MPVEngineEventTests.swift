import Foundation
import Libmpv
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
struct MPVEngineEventTests {

    @Test
    func `accepted start clears Dolby Vision evidence from the previous item`() {
        let engine = MPVSession(configuration: .init(videoOutput: .sampleBuffer)) { _ in }
        defer { engine.close() }

        engine.queue.sync {
            engine.playbackRequestIsActive = true
            engine.requestedPlaylistEntryID = 2
            engine.activePlaylistEntryID = 1

            let consumed = engine.dolbyVisionResolver.consume(log: .init(
                prefix: "vo/avfoundation",
                level: .info,
                message: "MPVUI_NATIVE_DOLBY_VISION_VALIDATED: profile7-to81=no session-profile=5 session-compatibility=0"
            ))
            #expect(consumed)

            var start = mpv_event_start_file()
            start.playlist_entry_id = 1

            withUnsafeMutablePointer(to: &start) { pointer in
                var event = mpv_event()
                event.event_id = MPV_EVENT_START_FILE
                event.data = UnsafeMutableRawPointer(pointer)
                engine.handleEvent(event)
                #expect(engine.dolbyVisionResolver.status(source: .unknown, backend: .sampleBuffer).nativeValidation == .validated)
                pointer.pointee.playlist_entry_id = 2
                engine.handleEvent(event)

                let status = engine.dolbyVisionResolver.status(source: .unknown, backend: .sampleBuffer)
                #expect(status.nativeValidation == .unknown)
                #expect(status.effectiveProfile == nil)
            }
        }
    }

    @Test(arguments: [true, false], [29.0, 29.9995, 30.0])
    func `EOF completes only picture in picture seeks that reached the requested endpoint`(knownDuration: Bool, target: Double) async {
        let engine = MPVSession(configuration: .init()) { _ in }
        defer { engine.close() }

        let result = await withCheckedContinuation { continuation in
            engine.queue.async {
                engine.playbackRequestIsActive = true
                engine.isFileLoaded = true
                engine.lastDuration = knownDuration ? .seconds(30) : .zero
                engine.pendingPiPSeek = .init(id: UUID(), target: .seconds(target), continuation: continuation)

                var end = mpv_event_end_file()
                end.reason = MPV_END_FILE_REASON_EOF

                withUnsafeMutablePointer(to: &end) { pointer in
                    var event = mpv_event()
                    event.event_id = MPV_EVENT_END_FILE
                    event.data = UnsafeMutableRawPointer(pointer)
                    engine.handleEvent(event)
                }
            }
        }
        #expect(result == (knownDuration && target >= 29.999))
        #expect(engine.snapshot.state == .ended && engine.snapshot.position == (knownDuration ? .seconds(30) : .zero))
        #expect(engine.queue.sync { engine.pendingPiPSeek == nil })
    }

    @Test
    func `metadata observations clear unavailable values and identify properties without borrowed names`() {
        let engine = MPVSession(configuration: .init()) { _ in }
        defer { engine.close() }

        engine.queue.sync {
            engine.playbackRequestIsActive = true

            func deliver(_ property: inout mpv_event_property, id: UInt64) {
                withUnsafeMutablePointer(to: &property) { pointer in
                    var event = mpv_event()
                    event.event_id = MPV_EVENT_PROPERTY_CHANGE
                    event.reply_userdata = id
                    event.data = UnsafeMutableRawPointer(pointer)
                    engine.handleEvent(event)
                }
            }

            let chapterID = UInt64(MPVSession.observedProperties.firstIndex(of: "chapter")! + 1)
            let durationID = UInt64(MPVSession.observedProperties.firstIndex(of: "duration")! + 1)
            var property = mpv_event_property()
            property.format = MPV_FORMAT_INT64

            for chapter: Int64 in [2, -1, 0] {
                var value = chapter

                withUnsafeMutablePointer(to: &value) { pointer in
                    property.data = UnsafeMutableRawPointer(pointer)
                    deliver(&property, id: chapterID)
                }

                #expect(engine.latestSnapshot.currentChapterIndex == (chapter < 0 ? nil : Int(chapter)))
            }

            property.format = MPV_FORMAT_NONE
            property.data = nil
            deliver(&property, id: chapterID)
            #expect(engine.latestSnapshot.currentChapterIndex == nil)

            for seconds in [4.25, Double.nan, .infinity, -2] {
                var value = seconds

                property.format = MPV_FORMAT_DOUBLE

                withUnsafeMutablePointer(to: &value) { pointer in
                    property.data = UnsafeMutableRawPointer(pointer)
                    deliver(&property, id: durationID)
                }

                #expect(engine.latestSnapshot.duration == (seconds == 4.25 ? .seconds(4.25) : .zero))
            }

            let before = engine.lifecycleDiagnostics.engineActivity.propertyChangeEvents

            property.format = MPV_FORMAT_NONE
            property.data = nil
            deliver(&property, id: 0)
            #expect(engine.lifecycleDiagnostics.engineActivity.propertyChangeEvents == before)
        }
    }

    @Test(arguments: [("yes", true as Bool?), ("no", false as Bool?), ("unknown", nil as Bool?)])
    func `decoder session evidence only updates the matching active media`(hardware: String, expected: Bool?) {
        let engine = MPVSession(configuration: .init()) { _ in }

        engine.queue.sync {
            engine.playbackRequestIsActive = true
            engine.requestedPlaylistEntryID = 2
            engine.activePlaylistEntryID = 1
            engine.videoToolboxSessionUsesHardware = true

            "ffmpeg/video".withCString { prefix in
                "info".withCString { level in
                    "MPVUI_VIDEOTOOLBOX_SESSION: hardware=\(hardware) native-dovi=no".withCString { text in
                        var log = mpv_event_log_message()
                        log.prefix = prefix
                        log.level = level
                        log.text = text

                        withUnsafeMutablePointer(to: &log) { pointer in
                            var event = mpv_event()
                            event.event_id = MPV_EVENT_LOG_MESSAGE
                            event.data = UnsafeMutableRawPointer(pointer)
                            engine.handleEvent(event)

                            #expect(engine.videoToolboxSessionUsesHardware == true)
                            engine.activePlaylistEntryID = 2
                            engine.handleEvent(event)

                            #expect(engine.videoToolboxSessionUsesHardware == expected)
                        }
                    }
                }
            }
        }
    }

    @Test
    @MainActor
    func `native output rejection reports one fatal error without requesting a replacement`() async throws {
        var rejected: [String] = []

        let engine = MPVSession(configuration: .init(additionalOptions: ["ao": "null"], videoOutput: .sampleBuffer)) { emission in
            if case let .error(.nativeVideoOutputUnavailable(reason), fatal: true) = emission.update {
                rejected.append(reason)
            }
        }

        engine.queue.sync {
            engine.sourceURL = TestPaths.baselineMedia
            engine.lastPosition = .seconds(3)
            engine.isPaused = true
            engine.playbackRequestIsActive = true
            engine.desiredProperties["vid"] = "1"

            "vo/avfoundation".withCString { prefix in
                "error".withCString { level in
                    "MPVUI_NATIVE_VIDEO_UNSUPPORTED: Rejected pixel format".withCString { text in
                        var log = mpv_event_log_message()
                        log.prefix = prefix
                        log.level = level
                        log.text = text

                        withUnsafeMutablePointer(to: &log) { pointer in
                            var event = mpv_event()
                            event.event_id = MPV_EVENT_LOG_MESSAGE
                            event.data = UnsafeMutableRawPointer(pointer)
                            engine.handleEvent(event)
                            engine.handleEvent(event)
                        }
                    }
                }
            }

            #expect(engine.didRejectNativeOutput && !engine.needsSourceLoad)
            #expect(!engine.playbackRequestIsActive)
            #expect(engine.videoOutput == .sampleBuffer)
            #expect(engine.fatalPlaybackError == .nativeVideoOutputUnavailable("Rejected pixel format"))
            #expect(engine.desiredProperties["vid"] == "1")
        }

        try await eventually("native rejection is published exactly once") { !rejected.isEmpty }

        #expect(rejected == ["Rejected pixel format"])
        engine.load(TestPaths.baselineMedia, playAutomatically: false, startTime: nil, generation: 1)
        _ = await engine.lifecycleSnapshot()

        engine.queue.sync {
            #expect(!engine.didRejectNativeOutput)
            #expect(engine.fatalPlaybackError == nil)
            #expect(engine.videoOutput == .sampleBuffer)
            #expect(!engine.needsSourceLoad && engine.handle != nil)
            #expect(engine.lifecycleDiagnostics.loadCommands == 1)
        }
    }

    @Test
    @MainActor
    func `missing native log fields use safe defaults without dropping the message`() async throws {
        var logs: [MPVLogMessage] = []

        let engine = MPVSession(configuration: .init(logLevel: .info)) { emission in
            if case let .log(log) = emission.update {
                logs.append(log)
            }
        }

        engine.queue.sync {
            var message = mpv_event_log_message()

            withUnsafeMutablePointer(to: &message) { pointer in
                var event = mpv_event()
                event.event_id = MPV_EVENT_LOG_MESSAGE
                event.data = UnsafeMutableRawPointer(pointer)
                engine.handleEvent(event)
            }
        }

        try await eventually("missing log fields are copied") { !logs.isEmpty }

        #expect(logs == [MPVLogMessage(prefix: "mpv", level: .info, message: "")])
    }

    @Test
    func `unavailable pause and timestamp properties preserve the last known values`() {
        let engine = MPVSession(configuration: .init()) { _ in }

        engine.queue.sync {
            engine.playbackRequestIsActive = true
            engine.isPaused = true
            engine.lastPosition = .seconds(3)

            for name in ["pause", "time-pos"] {
                name.withCString { name in
                    var property = mpv_event_property()
                    property.name = name
                    property.format = MPV_FORMAT_NONE

                    withUnsafeMutablePointer(to: &property) { pointer in
                        var event = mpv_event()
                        event.event_id = MPV_EVENT_PROPERTY_CHANGE
                        event.data = UnsafeMutableRawPointer(pointer)
                        engine.handleEvent(event)
                    }
                }
            }

            #expect(engine.isPaused)
            #expect(engine.lastPosition == .seconds(3))
        }
    }

    @Test
    func `start events cannot resurrect an inactive or superseded request`() {
        let engine = MPVSession(configuration: .init()) { _ in }

        engine.queue.sync {
            var start = mpv_event_start_file()
            start.playlist_entry_id = 12

            withUnsafeMutablePointer(to: &start) { pointer in
                var event = mpv_event()
                event.event_id = MPV_EVENT_START_FILE
                event.data = UnsafeMutableRawPointer(pointer)
                engine.handleEvent(event)

                #expect(engine.lastState == .idle)
                engine.playbackRequestIsActive = true
                engine.requestedPlaylistEntryID = 13
                engine.handleEvent(event)

                #expect(engine.activePlaylistEntryID == nil)
                #expect(engine.lastState == .idle)
                engine.requestedPlaylistEntryID = 12
                engine.handleEvent(event)

                #expect(engine.activePlaylistEntryID == 12)
                #expect(engine.lastState == .loading)
                #expect(engine.isLoading && !engine.isFileLoaded)
                #expect(engine.lifecycleDiagnostics.startFileEvents == 3)
            }
        }
    }

    @Test
    func `redirect awaits a new playlist identity while stop leaves typed ownership intact`() {
        let engine = MPVSession(configuration: .init()) { _ in }

        engine.queue.sync {
            engine.playbackRequestIsActive = true
            engine.requestedPlaylistEntryID = 12
            engine.activePlaylistEntryID = 12
            engine.isFileLoaded = true
            engine.isSeeking = true
            engine.isPausedForCache = true

            var end = mpv_event_end_file()
            end.playlist_entry_id = 12
            end.reason = MPV_END_FILE_REASON_STOP

            withUnsafeMutablePointer(to: &end) { pointer in
                var event = mpv_event()
                event.event_id = MPV_EVENT_END_FILE
                event.data = UnsafeMutableRawPointer(pointer)
                engine.handleEvent(event)

                #expect(engine.playbackRequestIsActive && engine.isFileLoaded)
                pointer.pointee.reason = MPV_END_FILE_REASON_REDIRECT
                engine.handleEvent(event)

                #expect(engine.playbackRequestIsActive)
                #expect(engine.requestedPlaylistEntryID == nil && engine.activePlaylistEntryID == nil)
                #expect(engine.isLoading && !engine.isFileLoaded)
                #expect(!engine.isSeeking && !engine.isPausedForCache)
                #expect(engine.lastState == .loading)
            }
        }
    }

    @Test(arguments: [MPV_END_FILE_REASON_EOF.rawValue, MPV_END_FILE_REASON_QUIT.rawValue, MPV_END_FILE_REASON_ERROR.rawValue])
    func `terminal events clear request state and preserve the specific outcome`(reason: UInt32) {
        let engine = MPVSession(configuration: .init()) { _ in }

        engine.queue.sync {
            engine.playbackRequestIsActive = true
            engine.requestedPlaylistEntryID = 12
            engine.activePlaylistEntryID = 12
            engine.isFileLoaded = true
            engine.lastDuration = .seconds(30)

            var end = mpv_event_end_file()
            end.playlist_entry_id = 12
            end.reason = mpv_end_file_reason(rawValue: reason)
            end.error = MPV_ERROR_LOADING_FAILED.rawValue

            withUnsafeMutablePointer(to: &end) { pointer in
                var event = mpv_event()
                event.event_id = MPV_EVENT_END_FILE
                event.data = UnsafeMutableRawPointer(pointer)
                engine.handleEvent(event)
            }

            #expect(!engine.playbackRequestIsActive && !engine.isFileLoaded)
            #expect(engine.isIdle && !engine.hasPlaybackStarted)
            #expect(engine.requestedPlaylistEntryID == nil && engine.activePlaylistEntryID == nil)

            switch reason {
            case MPV_END_FILE_REASON_EOF.rawValue:
                #expect(engine.lastState == .ended && engine.didReachEnd)
                #expect(engine.lastPosition == .seconds(30))

            case MPV_END_FILE_REASON_QUIT.rawValue:
                #expect(engine.lastState == .stopped)

            default:
                #expect(engine.lastState == .failed(.playbackFailed(
                    code: MPV_ERROR_LOADING_FAILED.rawValue,
                    message: "loading failed"
                )))
            }
        }
    }

    @Test
    func `end for a displaced entry only retires that old active identity`() {
        let engine = MPVSession(configuration: .init()) { _ in }

        engine.queue.sync {
            engine.playbackRequestIsActive = true
            engine.requestedPlaylistEntryID = 13
            engine.activePlaylistEntryID = 12

            var end = mpv_event_end_file()
            end.playlist_entry_id = 12
            end.reason = MPV_END_FILE_REASON_ERROR

            withUnsafeMutablePointer(to: &end) { pointer in
                var event = mpv_event()
                event.event_id = MPV_EVENT_END_FILE
                event.data = UnsafeMutableRawPointer(pointer)
                engine.handleEvent(event)
            }

            #expect(engine.playbackRequestIsActive)
            #expect(engine.requestedPlaylistEntryID == 13)
            #expect(engine.activePlaylistEntryID == nil)
            #expect(engine.fatalPlaybackError == nil)
            #expect(engine.lastState == .idle)
        }
    }

    @Test
    func `missing payloads and unknown events do not dereference unavailable native storage`() {
        let engine = MPVSession(configuration: .init()) { _ in }

        engine.queue.sync {
            engine.playbackRequestIsActive = true

            for id in [MPV_EVENT_START_FILE, MPV_EVENT_PROPERTY_CHANGE, MPV_EVENT_COMMAND_REPLY, MPV_EVENT_NONE] {
                var event = mpv_event()
                event.event_id = id
                engine.handleEvent(event)

                #expect(engine.lastState == .idle)
            }

            var event = mpv_event()
            event.event_id = MPV_EVENT_END_FILE
            engine.handleEvent(event)

            #expect(engine.lastState == .ended)
            #expect(!engine.playbackRequestIsActive)
            event.event_id = MPV_EVENT_SHUTDOWN
            engine.handleEvent(event)

            #expect(engine.handle == nil)
        }
    }

    @Test
    @MainActor
    func `overflow reports a recoverable error and refreshes the active snapshot`() async throws {
        var updates: [MPVEngineUpdate] = []
        let engine = MPVSession(configuration: .init(volume: 37)) { updates.append($0.update) }

        engine.queue.sync {
            engine.playbackRequestIsActive = true
            engine.isPausedForCache = true

            var event = mpv_event()
            event.event_id = MPV_EVENT_QUEUE_OVERFLOW
            engine.handleEvent(event)

            #expect(engine.lastState == .buffering)
            #expect(engine.lifecycleDiagnostics.bufferingStateTransitions == 1)
        }

        try await eventually("overflow recovery publishes fresh audio and buffer state") {
            updates.contains {
                if case .audio(volume: 37, isMuted: false, playbackRate: 1) = $0 {
                    true
                } else {
                    false
                }
            }
        }

        #expect(updates.contains {
            if case .error(.eventQueueOverflow, fatal: false) = $0 {
                true
            } else {
                false
            }
        })

        #expect(updates.contains {
            if case let .buffer(buffer) = $0 {
                buffer.isBuffering
            } else {
                false
            }
        })

        #expect(engine.queue.sync { engine.fatalPlaybackError == nil })
    }

    @Test(arguments: ["time-pos", "paused-for-cache", "core-idle", "seeking", "unknown-property"])
    func `property events use copied time values and preserve unavailable state`(name: String) {
        let engine = MPVSession(configuration: .init()) { _ in }

        engine.queue.sync {
            engine.playbackRequestIsActive = true
            engine.lastPosition = .seconds(9)
            engine.isPausedForCache = true

            var seconds = -2.0

            name.withCString { namePointer in
                withUnsafeMutablePointer(to: &seconds) { value in
                    var property = mpv_event_property()
                    property.name = namePointer
                    property.format = MPV_FORMAT_DOUBLE
                    property.data = UnsafeMutableRawPointer(value)

                    withUnsafeMutablePointer(to: &property) { pointer in
                        var event = mpv_event()
                        event.event_id = MPV_EVENT_PROPERTY_CHANGE
                        event.data = UnsafeMutableRawPointer(pointer)
                        engine.handleEvent(event)
                    }
                }
            }

            #expect(engine.lastPosition == (name == "time-pos" ? .zero : .seconds(9)))
            #expect(engine.isPausedForCache)
        }
    }

    @Test(arguments: ["cancelled", "native-error", "missing-result", "empty-timeline"])
    func `subtitle command replies complete and remove exactly their pending query`(outcome: String) async {
        let engine = MPVSession(configuration: .init()) { _ in }
        let cancellation = MPVSubtitleQueryCancellation()

        if outcome == "cancelled" {
            cancellation.cancel()
        }

        do {
            let snapshots: [TimedTextSubtitleSnapshot] = try await withCheckedThrowingContinuation { continuation in
                engine.queue.sync {
                    engine.subtitleQueries[7] = .init(cancellation: cancellation, continuation: continuation)

                    var event = mpv_event()
                    event.event_id = MPV_EVENT_COMMAND_REPLY
                    event.reply_userdata = 7
                    event.error = outcome == "native-error" ? MPV_ERROR_COMMAND.rawValue : 0

                    var command = mpv_event_command()
                    command.result.format = MPV_FORMAT_NODE_ARRAY

                    withUnsafeMutablePointer(to: &command) { pointer in
                        if outcome == "empty-timeline" {
                            event.data = UnsafeMutableRawPointer(pointer)
                        }

                        engine.handleEvent(event)
                        engine.handleEvent(event) // Duplicate delivery must not resume twice.
                    }
                }
            }

            #expect(outcome == "empty-timeline")
            #expect(snapshots.isEmpty)
        } catch is CancellationError {
            #expect(outcome == "cancelled")
        } catch let error as MPVPlayerError {
            #expect(error == engine.subtitleQueryError(outcome == "native-error" ? MPV_ERROR_COMMAND.rawValue : MPV_ERROR_GENERIC.rawValue))
        } catch {
            Issue.record("Unexpected subtitle reply error: \(error)")
        }

        #expect(engine.queue.sync { engine.subtitleQueries.isEmpty })
    }

    @Test
    func `state precedence retains failures and terminal outcomes ahead of transient flags`() {
        let engine = MPVSession(configuration: .init()) { _ in }

        engine.queue.sync {
            engine.isIdle = false
            engine.isFileLoaded = false
            engine.refreshState()

            #expect(engine.lastState == .idle)
            engine.isFileLoaded = true
            engine.refreshState()

            #expect(engine.lastState == .ready)
            engine.isPausedForCache = true
            engine.refreshState()

            #expect(engine.lastState == .buffering)
            engine.isSeeking = true
            engine.refreshState()

            #expect(engine.lastState == .seeking)
            engine.isLoading = true
            engine.refreshState()

            #expect(engine.lastState == .loading)
            engine.didReachEnd = true
            engine.refreshState()

            #expect(engine.lastState == .ended)
            engine.fatalPlaybackError = .clientCreationFailed
            engine.refreshState()

            #expect(engine.lastState == .failed(.clientCreationFailed))
        }
    }
}
