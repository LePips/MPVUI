import Foundation
import Libmpv
@testable import MPVUI
import Testing

#if os(macOS)
import AppKit
import Darwin

@Suite(.tags(.integration, .subtitles), .serialized)
struct MPVSemanticSubtitleIntegrationTests {
    @Test
    func `query reads unselected embedded cues beyond playback cache`() throws {
        let handle = try #require(mpv_create())
        defer { mpv_terminate_destroy(handle) }
        for (name, value) in [
            ("vo", "null"),
            ("ao", "null"),
            ("pause", "yes"),
            ("idle", "yes"),
            ("keep-open", "yes"),
            ("sid", "no")
        ] {
            #expect(mpv_set_option_string(handle, name, value) >= 0)
        }
        try #require(mpv_initialize(handle) >= 0)
        try #require(runCommand(handle, ["loadfile", TestPaths.media("02-h264-multitrack.mkv").path]) >= 0)
        try #require(waitForEvent(handle, id: MPV_EVENT_FILE_LOADED, timeout: 10))
        let track = try #require(waitForSubtitleTracks(handle, minimumCount: 3, timeout: 5)?.first { $0.title == "Overlapping cues" })
        let timeline = try #require(MPVTextSubtitleTimeline.snapshots(from: commandValue(handle, ["sub-text-cues", String(track.mpvID)])))
        #expect(timeline.first { $0.contains(.seconds(3)) }?.snapshot.text == "first cue\nlong cue\noverlap")
        #expect(timeline.first { $0.contains(.seconds(15)) }?.snapshot.text == "long cue")
        #expect(timeline.last?.snapshot.text == "last cue")
        #expect(copiedNode(handle, property: "sid") == .bool(false))
        #expect(copiedNode(handle, property: "pause") == .bool(true))
        #expect(copiedNode(handle, property: "sub-text-intercept") == .bool(false))
        #expect(commandValue(handle, ["sub-text-cues", "999"]) == nil)

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let external = directory.appendingPathComponent("query.vtt")
        try """
        WEBVTT

        00:01.000 --> 00:05.000 line:10% position:20%
        external cue

        00:19.000 --> 00:20.000
        external last

        """.write(to: external, atomically: true, encoding: .utf8)
        try #require(runCommand(handle, ["sub-add", external.path, "auto"]) >= 0)
        let externalTrack = try #require(waitForSubtitleTracks(handle, minimumCount: 4, timeout: 5)?.first { $0.isExternal })
        let externalTimeline = try #require(MPVTextSubtitleTimeline.snapshots(from: commandValue(
            handle,
            ["sub-text-cues", String(externalTrack.mpvID)]
        )))
        #expect(externalTimeline.map(\.snapshot.text) == ["external cue", "external last"])
        guard case .webVTT = externalTimeline.first?.snapshot.regions.first?.placement else {
            Issue.record("External WebVTT settings were lost")
            return
        }
    }

    @Test
    @MainActor
    func `public queries and paused seeks include cues containing the destination`() async throws {
        let player = MPVPlayer(configuration: .init(autoPlay: false, hdrPolicy: .disabled))
        let recorder = SemanticSubtitleRecorder()
        let observation = record(player.textSubtitleStream(), in: recorder)
        defer { observation.cancel() }
        let surface = MPVPlatformVideoPlayer(player: player)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.updateRenderingConfiguration()
        defer { surface.detach()
            window.contentView = nil
        }
        player.load(TestPaths.media("02-h264-multitrack.mkv"), autoPlay: false)
        try #require(try await waitForPlayer(player) { !$0.subtitleTracks.isEmpty && $0.state == .paused })
        let track = try #require(player.subtitleTracks.first { $0.title == "Overlapping cues" })
        player.disableTrack(.subtitle)
        try #require(try await waitForPlayer(player) { !$0.subtitleTracks.contains(where: \.isSelected) })
        player.setSubtitleDelay(.seconds(2))
        let position = player.position
        let all = try await player.textSubtitleSnapshots(for: track.id)
        #expect(all.last?.snapshot.text == "last cue")
        #expect(try await player.textSubtitleSnapshot(for: track.id, at: .seconds(3)).text == "first cue\nlong cue\noverlap")
        #expect(try await player.textSubtitleSnapshot(for: track.id, at: .seconds(18)).isEmpty)
        #expect(player.position == position)
        #expect(player.isPaused)
        #expect(!player.subtitleTracks.contains { $0.isSelected })
        let cancelled = Task { try await player.textSubtitleSnapshots(for: track.id) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        player.setSubtitleDelay(.zero)

        // Start in the middle of a cue that began far before the seek target.
        try #require(await player.seekForPictureInPicture(to: .seconds(15)))
        let beforeEnable = recorder.values.count
        player.selectTrack(track.id)
        #expect(await waitForSnapshot(in: recorder, after: beforeEnable) { $0.text == "long cue" } != nil)
        for (destination, expected) in [
            (3.0, "first cue\nlong cue\noverlap"),
            (3, "first cue\nlong cue\noverlap"),
            (18.5, ""),
            (15, "long cue"),
            (1, "first cue\nlong cue")
        ] {
            let beforeSeek = recorder.values.count
            try #require(await player.seekForPictureInPicture(to: .seconds(destination)))
            #expect(
                await waitForSnapshot(in: recorder, after: beforeSeek) { $0.text == expected } != nil,
                "Missing subtitles at \(destination)"
            )
            #expect(player.isPaused)
        }
        #expect(player.lastError == nil)
    }

    @Test
    @MainActor
    func `public subtitle roles preserve identity controls and selection across reloads`() async throws {
        let player = MPVPlayer(configuration: .init(
            autoPlay: false, hardwareDecoding: .disabled, videoOutput: .sampleBuffer,
            // The shared baseline also has example sidecars; this test supplies its own.
            additionalOptions: ["ao": "null", "sub-auto": "no"]
        ))
        let recorder = SemanticSubtitleRecorder()
        let observation = record(player.textSubtitleStream(), in: recorder)
        defer { observation.cancel() }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstFile = directory.appendingPathComponent("primary.srt")
        let secondFile = directory.appendingPathComponent("secondary.srt")
        for (url, start, text) in [(firstFile, "05", "primary later"), (secondFile, "07", "secondary later")] {
            try """
            1
            00:00:00,000 --> 00:00:04,000
            shared

            2
            00:00:\(start),000 --> 00:00:09,000
            \(text)

            """.write(to: url, atomically: true, encoding: .utf8)
        }
        // Queue both external selections before a surface exists.
        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(2))
        player.loadExternalSubtitle(firstFile)
        player.loadExternalSubtitle(secondFile, selecting: .secondary)
        let surface = MPVPlatformVideoPlayer(player: player)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.updateRenderingConfiguration()
        defer { player.stop()
            surface.detach()
            window.contentView = nil
        }
        try #require(try await waitForPlayer(player) {
            $0.state == .paused && $0.selectedSubtitle() != nil && $0.selectedSubtitle(for: .secondary) != nil
        })
        let primary = try #require(player.selectedSubtitle())
        let secondary = try #require(player.selectedSubtitle(for: .secondary))
        #expect(primary.id != secondary.id)
        let initial = try #require(await waitForSnapshot(in: recorder) { $0.text == "shared\nshared" })
        #expect(initial.regions.map(\.role) == [.primary, .secondary])
        #expect(initial.regions.map(\.trackID) == [primary.id, secondary.id])

        var before = recorder.values.count
        player.selectSubtitle(nil)
        let secondaryOnly = try #require(await waitForSnapshot(in: recorder, after: before) { $0.text == "shared" })
        #expect(secondaryOnly.regions.first?.role == .secondary)
        #expect(secondaryOnly.regions.first?.trackID == secondary.id)
        try #require(try await waitForPlayer(player) { $0.selectedSubtitle() == nil })
        player.selectTrack(primary.id) // Existing API selects primary only.
        try #require(try await waitForPlayer(player) { $0.selectedSubtitle()?.id == primary.id })

        before = recorder.values.count
        player.setSubtitleDelay(.seconds(4))
        #expect(await waitForSnapshot(in: recorder, after: before) {
            $0.regions.map(\.role) == [.secondary]
        } != nil)
        player.setSubtitleDelay(.zero)
        before = recorder.values.count
        player.setSubtitleDelay(.seconds(-5), for: .secondary)
        #expect(await waitForSnapshot(in: recorder, after: before) { $0.text == "shared\nsecondary later" } != nil)
        player.setSubtitleDelay(.zero, for: .secondary)

        before = recorder.values.count
        player.setSubtitlesVisible(false)
        #expect(await waitForSnapshot(in: recorder, after: before) {
            $0.text == "shared" && $0.regions.first?.role == .secondary
        } != nil)
        player.setSubtitlesVisible(false, for: .secondary)
        #expect(await waitForSnapshot(in: recorder, after: before) { $0.isEmpty } != nil)
        #expect(player.selectedSubtitle()?.id == primary.id)
        #expect(player.selectedSubtitle(for: .secondary)?.id == secondary.id)
        player.setSubtitlesVisible(true)
        player.setSubtitlesVisible(true, for: .secondary)

        let invalid = MPVMediaTrackIdentifier(type: .audio, mpvID: primary.mpvID)
        player.selectSubtitle(invalid, for: .secondary)
        #expect(player.lastError == .invalidSubtitleTrack(invalid))
        #expect(player.selectedSubtitle(for: .secondary)?.id == secondary.id)
        player.clearLastError()

        // Moving a track disables its old slot, even when the text is identical.
        before = recorder.values.count
        player.selectSubtitle(primary.id, for: .secondary)
        try #require(try await waitForPlayer(player) {
            $0.selectedSubtitle() == nil && $0.selectedSubtitle(for: .secondary)?.id == primary.id
        })
        #expect(await waitForSnapshot(in: recorder, after: before) {
            $0.regions.count == 1 && $0.regions.first?.trackID == primary.id && $0.regions.first?.role == .secondary
        } != nil)
        player.selectSubtitle(secondary.id)
        try #require(try await waitForPlayer(player) { $0.selectedSubtitle()?.id == secondary.id })

        // Capture non-default timing and hidden state during a real renderer replacement.
        player.setSubtitleDelay(.seconds(-5))
        player.setSubtitlesVisible(false, for: .secondary)
        before = recorder.values.count
        player.handleNativeVideoOutputUnavailable("Subtitle role restoration test")
        try #require(try await waitForPlayer(player) {
            $0.videoOutput == .metal && $0.state == .paused
                && $0.selectedSubtitle()?.id == secondary.id
                && $0.selectedSubtitle(for: .secondary)?.id == primary.id
        })
        #expect(await waitForSnapshot(in: recorder, after: before) {
            $0.text == "secondary later" && $0.regions.first?.role == .primary
        } != nil)
        #expect(abs(player.position.seconds - 2) < 0.2)
        player.setSubtitlesVisible(true, for: .secondary)
        #expect(await waitForSnapshot(in: recorder, after: before) { $0.text == "secondary later\nshared" } != nil)
        #expect(player.lastError == nil)

        // Independent queries identify the source, without inventing a live role.
        let timeline = try await player.textSubtitleSnapshots(for: primary.id)
        #expect(timeline.first?.snapshot.regions.first?.trackID == primary.id)
        #expect(timeline.first?.snapshot.regions.first?.role == nil)
        // Seeking can deliver the desired snapshot before its async completion.
        // Resetting an already-inactive primary cue need not emit it again.
        before = recorder.values.count
        try #require(await player.seekForPictureInPicture(to: .seconds(6)))
        player.setSubtitleDelay(.zero)
        #expect(await waitForSnapshot(in: recorder, after: before) {
            $0.text == "primary later" && $0.regions.first?.role == .secondary
        } != nil)

        player.setSubtitleDelay(.seconds(4))
        player.setSubtitleDelay(.seconds(4), for: .secondary)
        _ = await player.lifecycleDiagnostics()
        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(2))
        try #require(try await waitForPlayer(player) { $0.state == .paused && $0.subtitleTracks.isEmpty })
        #expect(player.selectedSubtitle(for: .secondary) == nil)
        before = recorder.values.count
        player.loadExternalSubtitle(firstFile)
        player.loadExternalSubtitle(secondFile, selecting: .secondary)
        #expect(await waitForSnapshot(in: recorder, after: before) { $0.text == "shared\nshared" } != nil)
        try #require(try await waitForPlayer(player) { $0.selectedSubtitle(for: .secondary) != nil })
        let selected = player.selectedSubtitle(for: .secondary)?.id
        let unselected = directory.appendingPathComponent("unselected.srt")
        try FileManager.default.copyItem(at: firstFile, to: unselected)
        player.loadExternalSubtitle(unselected, selecting: nil)
        try #require(try await waitForPlayer(player) { $0.subtitleTracks.count == 3 })
        #expect(player.selectedSubtitle(for: .secondary)?.id == selected)
        #expect(player.subtitleTracks.filter(\.isSelected).count == 2)
        player.loadExternalSubtitle(secondFile, selecting: .secondary)
        _ = await player.lifecycleDiagnostics()
        #expect(player.subtitleTracks.count == 3)
        #expect(player.lastError == nil)
    }

    private func commandValue(_ handle: OpaquePointer, _ arguments: [String]) -> MPVNodeValue? {
        var pointers: [UnsafePointer<CChar>?] = arguments.map { argument in
            guard let duplicate = strdup(argument) else { return nil }
            return UnsafePointer(duplicate)
        }
        pointers.append(nil)
        defer { for case let pointer? in pointers {
            free(UnsafeMutablePointer(mutating: pointer))
        } }
        var result = mpv_node()
        guard mpv_command_ret(handle, &pointers, &result) >= 0 else { return nil }
        defer { mpv_free_node_contents(&result) }
        return MPVNodeValue(copying: result)
    }

    @Test
    func `semantic snapshots exclude styled and bitmap subtitle tracks`() throws {
        let media = try TestPaths.testMedia("subtitle-formats.mkv")
        let handle = try #require(mpv_create())
        var initialized = false
        defer {
            if initialized {
                mpv_terminate_destroy(handle)
            } else {
                mpv_destroy(handle)
            }
        }

        for (name, value) in [
            ("vo", "null"),
            ("ao", "null"),
            ("idle", "yes"),
            ("pause", "yes"),
            ("keep-open", "yes"),
            ("sub-text-intercept", "yes"),
        ] {
            #expect(mpv_set_option_string(handle, name, value) >= 0)
        }

        let initializeStatus = mpv_initialize(handle)
        #expect(initializeStatus >= 0)
        guard initializeStatus >= 0 else { return }
        initialized = true

        #expect(FileManager.default.fileExists(atPath: media.path))
        #expect(runCommand(handle, ["loadfile", media.path, "replace"]) >= 0)
        #expect(waitForEvent(handle, id: MPV_EVENT_FILE_LOADED, timeout: 10))

        let tracks = try #require(
            waitForSubtitleTracks(handle, minimumCount: 4, timeout: 5)
        )
        for codec in [
            "ass",
            "hdmv_pgs_subtitle",
            "dvd_subtitle",
            "dvb_subtitle",
        ] {
            let track = try #require(tracks.first { $0.codec == codec })
            #expect(
                mpv_set_property_string(handle, "sid", String(track.mpvID)) >= 0
            )
            #expect(waitForSelectedSubtitle(handle, id: track.id, timeout: 5))
            #expect(waitForSubtitleTexts(handle, expected: []))
            #expect(commandValue(handle, ["sub-text-cues", String(track.mpvID)]) == nil)
        }
    }

    @Test
    func `native snapshots preserve primary secondary order and visibility`() throws {
        let handle = try #require(mpv_create())
        var initialized = false
        defer {
            if initialized {
                mpv_terminate_destroy(handle)
            } else {
                mpv_destroy(handle)
            }
        }

        for (name, value) in [
            ("vo", "null"),
            ("ao", "null"),
            ("idle", "yes"),
            ("pause", "yes"),
            ("keep-open", "yes"),
            ("sub-text-intercept", "yes"),
        ] {
            #expect(mpv_set_option_string(handle, name, value) >= 0)
        }

        let initializeStatus = mpv_initialize(handle)
        #expect(initializeStatus >= 0)
        guard initializeStatus >= 0 else { return }
        initialized = true

        let video = TestPaths.baselineMedia
        #expect(FileManager.default.fileExists(atPath: video.path))

        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let primarySubtitle = temporaryDirectory.appendingPathComponent("primary.srt")
        let secondarySubtitle = temporaryDirectory.appendingPathComponent("secondary.srt")
        try writeSubtitle("primary semantic cue", to: primarySubtitle)
        try writeSubtitle("secondary semantic cue", to: secondarySubtitle)

        #expect(runCommand(handle, ["loadfile", video.path, "replace"]) >= 0)
        #expect(waitForEvent(handle, id: MPV_EVENT_FILE_LOADED, timeout: 10))

        #expect(
            runCommand(
                handle,
                ["sub-add", primarySubtitle.path, "select", "Primary", "eng"]
            ) >= 0
        )
        let primaryTracks = try #require(
            waitForSubtitleTracks(handle, minimumCount: 1, timeout: 5)
        )
        let primaryTrack = try #require(
            primaryTracks.first { $0.title == "Primary" }
        )

        #expect(
            runCommand(
                handle,
                ["sub-add", secondarySubtitle.path, "auto", "Secondary", "spa"]
            ) >= 0
        )
        let allTracks = try #require(
            waitForSubtitleTracks(handle, minimumCount: 2, timeout: 5)
        )
        let secondaryTrack = try #require(
            allTracks.first { $0.title == "Secondary" }
        )

        #expect(
            mpv_set_property_string(handle, "sid", String(primaryTrack.mpvID)) >= 0
        )
        #expect(
            mpv_set_property_string(
                handle,
                "secondary-sid",
                String(secondaryTrack.mpvID)
            ) >= 0
        )
        #expect(
            waitForSubtitleTexts(handle, expected: [
                "primary semantic cue",
                "secondary semantic cue",
            ])
        )

        #expect(mpv_set_property_string(handle, "sub-visibility", "no") >= 0)
        #expect(
            waitForSubtitleTexts(handle, expected: ["secondary semantic cue"])
        )

        #expect(mpv_set_property_string(handle, "sub-visibility", "yes") >= 0)
        #expect(
            waitForSubtitleTexts(handle, expected: [
                "primary semantic cue",
                "secondary semantic cue",
            ])
        )

        #expect(
            mpv_set_property_string(handle, "secondary-sub-visibility", "no") >= 0
        )
        #expect(waitForSubtitleTexts(handle, expected: ["primary semantic cue"]))

        #expect(mpv_set_property_string(handle, "sub-visibility", "no") >= 0)
        #expect(waitForSubtitleTexts(handle, expected: []))

        #expect(
            mpv_set_property_string(handle, "secondary-sub-visibility", "yes") >= 0
        )
        #expect(
            waitForSubtitleTexts(handle, expected: ["secondary semantic cue"])
        )
    }

    @Test
    @MainActor
    func `public streams independently receive update clear and replay`() async throws {
        let player = MPVPlayer(
            configuration: .init(
                autoPlay: false, hdrPolicy: .disabled,
                additionalOptions: ["sub-auto": "no"]
            )
        )
        let firstRecorder = SemanticSubtitleRecorder()
        let secondRecorder = SemanticSubtitleRecorder()
        let firstStream = player.textSubtitleStream()
        let secondStream = player.textSubtitleStream()
        let firstObservation = record(firstStream, in: firstRecorder)
        let secondObservation = record(secondStream, in: secondRecorder)
        defer {
            firstObservation.cancel()
            secondObservation.cancel()
        }

        #expect(
            await waitForSnapshot(in: firstRecorder) { $0.isEmpty } != nil
        )
        #expect(
            await waitForSnapshot(in: secondRecorder) { $0.isEmpty } != nil
        )

        let surface = MPVPlatformVideoPlayer(player: player)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.updateRenderingConfiguration()
        defer {
            surface.detach()
            window.contentView = nil
        }

        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let subtitle = temporaryDirectory.appendingPathComponent("public-stream.srt")
        try """
        1
        00:00:00,000 --> 00:00:03,000
        first public cue

        2
        00:00:04,000 --> 00:00:09,000
        second public cue

        """.write(to: subtitle, atomically: true, encoding: .utf8)

        let video = TestPaths.baselineMedia
        #expect(FileManager.default.fileExists(atPath: video.path))
        player.load(video, autoPlay: false)
        player.loadExternalTrack(subtitle, type: .subtitle, select: true)

        #expect(
            try await waitForPlayer(player) {
                $0.subtitleTracks.contains {
                    $0.isExternal && $0.isSelected && $0.codec == "subrip"
                }
            }
        )
        player.seek(to: .seconds(1))

        let firstCue = try #require(
            await waitForSnapshot(in: firstRecorder) {
                $0.text == "first public cue"
            }
        )
        #expect(
            await waitForSnapshot(in: secondRecorder) {
                $0 == firstCue
            } != nil
        )

        let lateRecorder = SemanticSubtitleRecorder()
        let lateObservation = record(player.textSubtitleStream(), in: lateRecorder)
        defer { lateObservation.cancel() }
        #expect(
            await waitForSnapshot(in: lateRecorder) { $0 == firstCue } != nil
        )
        #expect(lateRecorder.values.first == firstCue)

        firstObservation.cancel()
        await firstObservation.value
        player.seek(to: .seconds(5))

        #expect(
            await waitForSnapshot(in: secondRecorder) {
                $0.text == "second public cue"
            } != nil
        )
        #expect(
            await waitForSnapshot(in: lateRecorder) {
                $0.text == "second public cue"
            } != nil
        )
        #expect(!firstRecorder.values.contains { $0.text == "second public cue" })

        let secondCountBeforeClear = secondRecorder.values.count
        let lateCountBeforeClear = lateRecorder.values.count
        player.setProperty("sub-visibility", to: "no")
        #expect(
            await waitForSnapshot(
                in: secondRecorder,
                after: secondCountBeforeClear,
                matching: { $0.isEmpty }
            ) != nil
        )
        #expect(
            await waitForSnapshot(
                in: lateRecorder,
                after: lateCountBeforeClear,
                matching: { $0.isEmpty }
            ) != nil
        )

        let secondCountBeforeRestore = secondRecorder.values.count
        player.setProperty("sub-visibility", to: "yes")
        player.seek(to: .seconds(5))
        #expect(
            await waitForSnapshot(in: secondRecorder, after: secondCountBeforeRestore) {
                $0.text == "second public cue"
            } != nil
        )
        #expect(player.lastError == nil)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MPVUI-semantic-subtitles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func writeSubtitle(_ text: String, to url: URL) throws {
        try """
        1
        00:00:00,000 --> 00:00:30,000
        \(text)

        """.write(to: url, atomically: true, encoding: .utf8)
    }

    private func runCommand(
        _ handle: OpaquePointer,
        _ arguments: [String]
    ) -> Int32 {
        var cArguments: [UnsafePointer<CChar>?] = arguments.map { argument in
            guard let duplicate = strdup(argument) else { return nil }
            return UnsafePointer(duplicate)
        }
        cArguments.append(nil)
        defer {
            for case let pointer? in cArguments {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }
        return mpv_command(handle, &cArguments)
    }

    private func waitForEvent(
        _ handle: OpaquePointer,
        id: mpv_event_id,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let event = mpv_wait_event(handle, 0.05) else { continue }
            if event.pointee.event_id == id {
                return true
            }
        }
        return false
    }

    private func waitForSubtitleTracks(
        _ handle: OpaquePointer,
        minimumCount: Int,
        timeout: TimeInterval
    ) -> [MPVMediaTrack]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let tracks = MPVEngine.parseTracks(
                copiedNode(handle, property: "track-list")
            ).filter { $0.type == .subtitle }
            if tracks.count >= minimumCount {
                return tracks
            }
            _ = mpv_wait_event(handle, 0.05)
        }
        return nil
    }

    private func waitForSelectedSubtitle(
        _ handle: OpaquePointer,
        id: MPVMediaTrackIdentifier,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let tracks = MPVEngine.parseTracks(
                copiedNode(handle, property: "track-list")
            )
            if tracks.first(where: { $0.id == id })?.isSelected == true {
                return true
            }
            _ = mpv_wait_event(handle, 0.05)
        }
        return false
    }

    private func waitForSubtitleTexts(
        _ handle: OpaquePointer,
        expected: [String],
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if subtitleTexts(
                from: copiedNode(handle, property: "sub-text-snapshot")
            ) == expected {
                return true
            }
            _ = mpv_wait_event(handle, 0.05)
        }
        return false
    }

    private func copiedNode(
        _ handle: OpaquePointer,
        property: String
    ) -> MPVNodeValue? {
        var node = mpv_node()
        guard mpv_get_property(handle, property, MPV_FORMAT_NODE, &node) >= 0 else {
            return nil
        }
        defer { mpv_free_node_contents(&node) }
        return MPVNodeValue(copying: node)
    }

    private func subtitleTexts(from node: MPVNodeValue?) -> [String]? {
        node?.arrayValue?.map { region in
            region.mapValue?["text"]?.stringValue ?? "<missing text>"
        }
    }

    @MainActor
    private func record(
        _ stream: AsyncStream<TextSubtitleSnapshot>,
        in recorder: SemanticSubtitleRecorder
    ) -> Task<Void, Never> {
        Task { @MainActor in
            for await snapshot in stream {
                recorder.values.append(snapshot)
            }
        }
    }

    @MainActor
    private func waitForSnapshot(
        in recorder: SemanticSubtitleRecorder,
        after previousCount: Int = 0,
        matching predicate: (TextSubtitleSnapshot) -> Bool
    ) async -> TextSubtitleSnapshot? {
        for _ in 0 ..< 100 {
            if let snapshot = recorder.values.dropFirst(previousCount).first(where: predicate) {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return recorder.values.dropFirst(previousCount).first(where: predicate)
    }

    @MainActor
    private func waitForPlayer(
        _ player: MPVPlayer,
        satisfying predicate: (MPVPlayer) -> Bool
    ) async throws -> Bool {
        for _ in 0 ..< 100 {
            if predicate(player) {
                return true
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate(player)
    }
}

@MainActor
private final class SemanticSubtitleRecorder {
    var values: [TextSubtitleSnapshot] = []
}
#endif
