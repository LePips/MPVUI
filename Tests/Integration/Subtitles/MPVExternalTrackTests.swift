import Foundation
import Libmpv
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVExternalTrackTests {

    private static let cue = "1\n00:00:00,000 --> 00:00:10,000\nExternal caption\n"

    @Test
    func `descriptor preserves client identity separately from metadata and reuses its resource`() async throws {
        let fixture = PlaybackFixture()
        let files = try TemporaryTestDirectory()
        defer {
            fixture.close()
            files.remove()
        }

        try await fixture.loadPaused()
        let url = try files.write("captions.srt", contents: Self.cue)
        let descriptor = MPVExternalTrack(
            url: url,
            type: .subtitle,
            clientID: "server-stream-17",
            title: "English captions",
            language: "en",
            selection: .unselected
        )

        let loaded = try await fixture.player.loadExternalTrack(descriptor)
        let track = try #require(loaded.tracks.first)

        #expect(loaded.source == descriptor)
        #expect(track.clientID == "server-stream-17")
        #expect(track.title == "English captions" && track.language == "en")
        #expect(track.externalURL == url && !track.isSelected)

        let again = try await fixture.player.loadExternalTrack(descriptor)

        #expect(again.tracks.map(\.id) == loaded.tracks.map(\.id))
        #expect(fixture.player.subtitleTracks.filter { $0.clientID == "server-stream-17" }.count == 1)

        fixture.player.selectSubtitle(track.id)
        try await eventually("the returned identity is immediately selectable") {
            fixture.player.subtitleTracks.first { $0.id == track.id }?.isSelected == true
        }
    }

    @Test
    func `failed resources report their descriptor and can retry after the file appears`() async throws {
        let fixture = PlaybackFixture()
        let files = try TemporaryTestDirectory()
        defer {
            fixture.close()
            files.remove()
        }

        try await fixture.loadPaused()
        let source = MPVExternalTrack(url: files.url.appendingPathComponent("missing.srt"), type: .subtitle, clientID: "retry")
        do {
            _ = try await fixture.player.loadExternalTrack(source)

            Issue.record("Missing subtitle unexpectedly loaded")
        } catch let MPVPlayerError.externalTrackFailed(failed, code, _) {
            #expect(failed == source && code < 0)

            guard case let .externalTrackFailed(observed, _, _) = fixture.player.lastError else {
                Issue.record("Awaited failure returned before observable diagnostics")

                return
            }

            #expect(observed == source)
        }
        _ = try files.write("missing.srt", contents: Self.cue)
        let loaded = try await fixture.player.loadExternalTrack(source)

        #expect(loaded.tracks.first?.clientID == "retry")
        #expect(loaded.tracks.first?.subtitleRole == .primary)
    }

    @Test
    func `client identity cannot silently move to a different external resource`() async throws {
        let fixture = PlaybackFixture()
        let files = try TemporaryTestDirectory()
        defer {
            fixture.close()
            files.remove()
        }

        try await fixture.loadPaused()
        let first = try files.write("one.srt", contents: Self.cue)
        let second = try files.write("two.srt", contents: Self.cue)
        _ = try await fixture.player.loadExternalTrack(.init(url: first, type: .subtitle, clientID: "same"))
        do {
            _ = try await fixture.player.loadExternalTrack(.init(url: second, type: .subtitle, clientID: "same"))

            Issue.record("Conflicting identity unexpectedly loaded")
        } catch let MPVPlayerError.externalTrackFailed(source, code, _) {
            #expect(source.url == second && code == MPV_ERROR_INVALID_PARAMETER.rawValue)
        }
    }

    @Test
    func `loading before the rendering surface exists waits and selects the requested role`() async throws {
        let files = try TemporaryTestDirectory()
        defer {
            files.remove()
        }

        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"], automaticallyPlays: false))

        player.load(TestPaths.baselineMedia, playAutomatically: false)
        let url = try files.write("pending.srt", contents: Self.cue)
        let loading = Task {
            try await player.loadExternalTrack(
                .init(
                    url: url,
                    type: .subtitle,
                    clientID: "pending",
                    selection: .secondarySubtitle
                )
            )
        }
        try await eventually("video discovery waits for a surface") {
            !player.mediaInformation.tracks.isEmpty && player.state == .loading
        }

        #expect(!player.subtitleTracks.contains { $0.clientID == "pending" })

        let fixture = PlaybackFixture(player: player)
        defer {
            fixture.close()
        }

        let result = try await loading.value

        #expect(result.tracks.first?.subtitleRole == .secondary)

        try await eventually("secondary selection reaches the observable player") {
            player.selectedSubtitle(for: .secondary)?.clientID == "pending"
        }
    }

    @Test
    func `replay restores client identities and latest subtitle roles`() async throws {
        let fixture = PlaybackFixture()
        let files = try TemporaryTestDirectory()
        defer {
            fixture.close()
            files.remove()
        }

        try await fixture.loadPaused()
        let first = try files.write("first.srt", contents: Self.cue)
        let second = try files.write("second.srt", contents: Self.cue)
        let one = try await fixture.player.loadExternalTrack(.init(url: first, type: .subtitle, clientID: "first"))
        _ = try await fixture.player.loadExternalTrack(
            .init(
                url: second,
                type: .subtitle,
                clientID: "second",
                selection: .secondarySubtitle
            )
        )
        try await eventually("both external roles are visible") {
            fixture.player.subtitleTracks.filter(\.isSelected).count == 2
        }
        fixture.player.selectSubtitle(one.tracks.first?.id, for: .secondary)
        try await eventually("the latest selection moves first to secondary") {
            fixture.player.selectedSubtitle(for: .secondary)?.clientID == "first" && fixture.player.selectedSubtitle() == nil
        }
        fixture.player.stop()
        try await eventually("playback releases the native client") {
            fixture.player.state == .stopped
        }
        fixture.player.play()
        try await eventually("replay restores the changed selection and both identities") {
            fixture.player.subtitleTracks.filter { $0.clientID != nil }.count == 2
                && fixture.player.selectedSubtitle(for: .secondary)?.clientID == "first"
                && fixture.player.selectedSubtitle() == nil
        }

        #expect(Set(fixture.player.subtitleTracks.compactMap(\.clientID)) == ["first", "second"])
    }

    @Test(arguments: [false, true])
    func `pending resource requests cancel on task cancellation and source replacement`(replaceSource: Bool) async throws {
        var platform = MPVPlatformServices()
        platform.initialOptions = { _, _, _ in [("ao", "null")] }
        let session = MPVSession(settings: .init(automaticallyPlays: false), platform: platform) { _ in }
        defer {
            session.close()
        }

        session.load(TestPaths.baselineMedia, playAutomatically: false, startTime: nil, generation: 1)
        let request = Task {
            try await session.loadExternalTrack(.init(url: URL(fileURLWithPath: "/pending.srt"), type: .subtitle))
        }
        try await eventually("external request waits before surface attachment") {
            session.queue.sync { session.externalTrackRequests.count == 1 }
        }

        if replaceSource {
            session.load(TestPaths.multitrackMedia, playAutomatically: false, startTime: nil, generation: 2)
        } else {
            request.cancel()
        }
        do {
            _ = try await request.value

            Issue.record("Canceled external load unexpectedly succeeded")
        } catch is CancellationError {}

        #expect(session.queue.sync { session.externalTrackRequests.isEmpty && session.externalTracks.isEmpty })
    }

    @Test(arguments: ["cancel", "overflow", "selection"])
    func `slow native loading leaves controls responsive and honors cancellation or newer selection`(action: String) async throws {
        let stream = GatedSubtitleStream()
        var platform = MPVPlatformServices()
        platform.initialOptions = { _, _, _ in [("ao", "null"), ("hwdec", "no")] }
        platform.prepareHandle = { handle in
            mpv_stream_cb_add_ro(handle, "gatedcaptions", Unmanaged.passUnretained(stream).toOpaque(), GatedSubtitleStream.open)
        }
        let session = MPVSession(settings: .init(additionalOptions: ["vid": "no"], automaticallyPlays: false), platform: platform) { _ in }
        defer {
            stream.release(cancel: true)
            session.close()
        }

        session.load(TestPaths.multitrackMedia, playAutomatically: false, startTime: nil, generation: 1)
        try await eventually("headless source loads") {
            session.queue.sync { session.isFileLoaded }
        }

        let url = try #require(URL(string: "gatedcaptions://captions.srt"))
        let request = Task {
            try await session.loadExternalTrack(.init(url: url, type: .subtitle, clientID: "slow"))
        }
        try await eventually("native subtitle load is waiting for bytes") {
            stream.isWaiting
        }

        session.setVolume(37)
        session.selectSubtitle(nil)
        // This queue fence must complete while the subtitle read remains blocked.
        let snapshot = session.snapshot

        #expect(snapshot.volume == 37)
        #expect(stream.isWaiting)

        if action != "selection" {
            if action == "overflow" {
                session.queue.sync {
                    var event = mpv_event()
                    event.event_id = MPV_EVENT_QUEUE_OVERFLOW
                    session.handleEvent(event)

                    #expect(session.activeExternalTrackRequest != nil)
                }
            } else {
                request.cancel()
            }
            do {
                _ = try await request.value

                Issue.record("Canceled native load unexpectedly succeeded")
            } catch is CancellationError {}
            try await eventually("cancellation retires native loading") {
                session.queue.sync { session.activeExternalTrackRequest == nil && session.externalTracks.isEmpty }
            }
        } else {
            stream.release()
            let result = try await request.value

            #expect(result.tracks.count == 1 && result.tracks[0].clientID == "slow")
            #expect(!result.tracks[0].isSelected)
            #expect(session.queue.sync { session.getString("sid") == "no" })
        }
    }
}
