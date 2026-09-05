import Foundation
import Libmpv
@testable import MPVUI
import Testing

#if os(macOS)
import AppKit
import Darwin

@Suite(.serialized)
struct MPVSemanticSubtitleIntegrationTests {
    @Test
    func `semantic snapshots exclude styled and bitmap subtitle tracks`() throws {
        try #require(TestPaths.hasMedia("16-h264-subtitle-matrix.mkv"), "Required bundled subtitle fixture is missing")
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

        let media = TestPaths.media("16-h264-subtitle-matrix.mkv")
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
            configuration: .init(autoPlay: false, hdrPolicy: .disabled)
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
