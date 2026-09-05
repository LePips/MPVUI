import Foundation
import Libmpv
@testable import MPVUI
import Observation
import Testing

#if os(iOS) || os(tvOS)
import UIKit
#endif

@Suite(.serialized)
struct MPVPlayerTests {
    @MainActor
    @Test
    func `player state uses observation`() async {
        let player = MPVPlayer(configuration: .init(volume: 42))

        await confirmation("Volume change is observed") { change in
            withObservationTracking {
                _ = player.volume
            } onChange: {
                change()
            }

            player.setVolume(24)
        }
    }

    @MainActor
    @Test
    func `player reflects configuration before surface attachment`() {
        let configuration = MPVPlayerConfiguration(
            autoPlay: false,
            volume: 42,
            playbackRate: 1.5,
            hdrPolicy: .disabled
        )
        let player = MPVPlayer(configuration: configuration)

        #expect((player.configuration) == configuration)
        #expect((player.state) == .idle)
        #expect((player.volume) == 42)
        #expect((player.playbackRate) == 1.5)
        #expect(!(player.isMuted))
        #expect((player.bufferStatus) == .empty)
        #expect((player.mediaInformation) == .empty)
    }

    @MainActor
    @Test
    func `load can be queued before surface attachment`() throws {
        let url = try #require(URL(string: "https://media.example/movie.mkv"))
        let player = MPVPlayer(configuration: .init(startTime: .seconds(12)))

        player.load(url)

        #expect((player.state) == .loading)
        #expect((player.position) == .seconds(12))
        #expect((player.duration) == .zero)
        #expect(!(player.isSeekable))
        #expect((player.mediaInformation.sourceURL) == url)
        #expect((player.bufferStatus) == .empty)

        player.load(url, startTime: .seconds(-5))
        #expect((player.position) == .zero)
    }

    @MainActor
    @Test
    func `raw property escape hatch protects typed state`() async {
        let player = MPVPlayer(configuration: .init(volume: 42))

        player.setProperty("deinterlace", to: "yes")
        await Task.yield()
        #expect((player.lastError) == nil)

        player.setProperty(" volume ", to: "0")
        for _ in 0 ..< 20 {
            if player.lastError != nil {
                break
            }
            await Task.yield()
        }

        #expect((player.volume) == 42)
        #expect(
            (player.lastError?.localizedDescription)
                == "The mpv property 'volume' is managed by MPVUI."
        )
    }

    @MainActor
    @Test
    func `most recently activated render surface owns player`() {
        let player = MPVPlayer()
        let first = UUID()
        let second = UUID()

        #expect(!(player.hasActiveRenderSurface))
        player.activateRenderSurface(token: first)
        #expect(player.hasActiveRenderSurface)
        #expect(player.isRenderSurfaceActive(token: first))

        player.activateRenderSurface(token: second)
        #expect(!(player.isRenderSurfaceActive(token: first)))
        #expect(player.isRenderSurfaceActive(token: second))

        player.detachRenderTarget(token: first, layerAddress: 1)
        #expect(player.hasActiveRenderSurface)
        player.detachRenderTarget(token: second, layerAddress: 2)
        #expect(!(player.hasActiveRenderSurface))
    }

    @Test
    func `bundled mpv accepts required startup options`() throws {
        let handle = try #require(mpv_create())
        defer { mpv_destroy(handle) }

        let options = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("external-surface-size", "640x360"),
            ("target-colorspace-hint", "yes"),
            ("input-default-bindings", "no"),
            ("subs-match-os-language", "yes"),
            ("subs-fallback", "yes"),
            ("sub-text-intercept", "yes"),
            ("ao", "avfoundation,"),
            ("hwdec", "auto-safe"),
            ("cache", "auto"),
            ("cache-secs", "10"),
            ("cache-pause", "yes"),
            ("cache-pause-initial", "yes"),
            ("cache-pause-wait", "1"),
            ("loop-file", "no"),
            ("volume", "100"),
            ("speed", "1"),
            ("target-prim", "display-p3"),
            ("target-trc", "linear"),
            ("target-peak", "812"),
            ("target-peak", "203"),
            ("target-trc", "srgb"),
            ("target-peak", "auto"),
        ]

        for (name, value) in options {
            #expect(
                mpv_set_option_string(handle, name, value) >= 0,
                "Bundled mpv rejected \(name)=\(value)"
            )
        }
    }

    @Test
    func `bundled mpv exposes text subtitle snapshot property`() throws {
        let handle = try #require(mpv_create())
        var initialized = false
        defer {
            if initialized {
                mpv_terminate_destroy(handle)
            } else {
                mpv_destroy(handle)
            }
        }

        #expect(mpv_set_option_string(handle, "vo", "null") >= 0)
        #expect(mpv_set_option_string(handle, "ao", "null") >= 0)
        #expect(mpv_set_option_string(handle, "idle", "yes") >= 0)
        #expect(mpv_set_option_string(handle, "sub-text-intercept", "yes") >= 0)
        let initializeStatus = mpv_initialize(handle)
        #expect(initializeStatus >= 0)
        guard initializeStatus >= 0 else { return }
        initialized = true

        var node = mpv_node()
        #expect(mpv_get_property(handle, "sub-text-snapshot", MPV_FORMAT_NODE, &node) >= 0)
        defer { mpv_free_node_contents(&node) }

        #expect(MPVNodeValue(copying: node) == .array([]))
    }

    #if os(macOS)
    @Test
    func `bundled mpv text subtitle snapshot contract`() throws {
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

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MPVUI-subtitle-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let webVTT = temporaryDirectory.appendingPathComponent("overlap.vtt")
        try """
        WEBVTT

        00:00.000 --> 00:30.000 position:25%,line-left line:80% size:40%
        positioned

        00:00.000 --> 00:30.000
        default

        """.write(to: webVTT, atomically: true, encoding: .utf8)

        let ass = temporaryDirectory.appendingPathComponent("native.ass")
        try """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 384
        PlayResY: 288

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,24,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:30.00,Default,,0,0,0,,native ASS

        """.write(to: ass, atomically: true, encoding: .utf8)

        let srt = temporaryDirectory.appendingPathComponent("automatic.srt")
        try """
        1
        00:00:00,000 --> 00:00:30,000
        automatic

        """.write(to: srt, atomically: true, encoding: .utf8)

        #expect(mpv_command_string(handle, "loadfile \(video.path) replace") >= 0)
        #expect(waitForMPVEvent(handle, id: MPV_EVENT_FILE_LOADED, timeout: 10))

        #expect(mpv_command_string(handle, "sub-add \(webVTT.path) select") >= 0)
        #expect(waitForSelectedSubtitleCodec(handle, "webvtt", timeout: 5))
        let webVTTSnapshot = try #require(
            waitForSubtitleSnapshot(
                handle,
                timeout: 5,
                where: { $0.arrayValue?.count == 2 }
            )
        )
        let webVTTRegions = try #require(webVTTSnapshot.arrayValue)
        #expect((webVTTRegions[0].mapValue?["text"]?.stringValue) == "positioned")
        #expect((webVTTRegions[0].mapValue?["format"]?.stringValue) == "webvtt")
        #expect(
            (webVTTRegions[0].mapValue?["settings"]?.stringValue)
                == "position:25%,line-left line:80% size:40%"
        )
        #expect((webVTTRegions[1].mapValue?["text"]?.stringValue) == "default")
        #expect((webVTTRegions[1].mapValue?["settings"]?.stringValue) == "")

        #expect(mpv_set_property_string(handle, "sub-visibility", "no") >= 0)
        #expect(
            waitForSubtitleSnapshot(
                handle,
                timeout: 5,
                where: { $0.arrayValue?.isEmpty == true }
            ) != nil
        )
        #expect(mpv_set_property_string(handle, "sub-visibility", "yes") >= 0)
        #expect(
            waitForSubtitleSnapshot(
                handle,
                timeout: 5,
                where: { $0.arrayValue?.count == 2 }
            ) != nil
        )

        #expect(mpv_command_string(handle, "sub-add \(ass.path) select") >= 0)
        #expect(waitForSelectedSubtitleCodec(handle, "ass", timeout: 5))
        #expect(
            waitForSubtitleSnapshot(
                handle,
                timeout: 5,
                where: { $0.arrayValue?.isEmpty == true }
            ) != nil
        )

        #expect(mpv_command_string(handle, "sub-add \(srt.path) select") >= 0)
        #expect(waitForSelectedSubtitleCodec(handle, "subrip", timeout: 5))
        let automaticSnapshot = try #require(
            waitForSubtitleSnapshot(
                handle,
                timeout: 5,
                where: { $0.arrayValue?.count == 1 }
            )
        )
        let automaticRegion = try #require(automaticSnapshot.arrayValue?.first?.mapValue)
        #expect((automaticRegion["text"]?.stringValue) == "automatic")
        #expect(automaticRegion["format"] == nil)

        #expect(mpv_set_property_string(handle, "sub-forced-events-only", "yes") >= 0)
        #expect(
            waitForSubtitleSnapshot(
                handle,
                timeout: 5,
                where: { $0.arrayValue?.isEmpty == true }
            ) != nil
        )
    }
    #endif

    #if os(iOS) || os(tvOS)
    @MainActor
    @Test
    func `mobile surface preserves playback subtitles and lifecycle across resize`()
        async throws
    {
        let player = MPVPlayer(
            configuration: .init(
                autoPlay: false,
                loop: true,
                playbackRate: 0.1,
                hardwareDecoding: .disabled,
                hdrPolicy: .disabled,
                logLevel: .debug
            )
        )
        let subtitleSnapshots = MobileSubtitleSnapshotRecorder()
        let nativeSurfaceFormats = MobileNativeSurfaceFormatRecorder()
        player.logHandler = { message in
            nativeSurfaceFormats.capture(message)
        }
        let subtitleStream = player.textSubtitleStream()
        let subtitleObservation = Task { @MainActor in
            for await snapshot in subtitleStream {
                subtitleSnapshots.values.append(snapshot)
            }
        }
        try #require(await waitForInitialSubtitleSnapshot(in: subtitleSnapshots))
        let surface = MPVPlatformVideoPlayer(player: player)
        let rootViewController = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        let portraitSurfaceFrame = CGRect(x: 0, y: 0, width: 180, height: 320)

        rootViewController.view.addSubview(surface)
        surface.frame = portraitSurfaceFrame
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        surface.layoutIfNeeded()
        surface.updateRenderingConfiguration()
        defer {
            subtitleObservation.cancel()
            surface.detach()
            window.isHidden = true
        }

        try await Task.sleep(nanoseconds: 300_000_000)

        #expect((player.lastError) == nil)
        #expect((player.state) == .idle)

        let mediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        let subtitleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("srt")
        let expectedSubtitleText = "cross-platform resize cue"
        // A generated 12-second, 24-frame red stream keeps the native test
        // self-contained. Unlike the old one-frame fixture, it establishes a
        // real playback PTS for semantic subtitles and keeps the loop boundary
        // out of the resize-observation interval. Software decoding avoids the
        // simulator-only VideoToolbox -12906 failure seen with synthetic media.
        let video = try #require(
            Data(
                base64Encoded:
                "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAQDbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAALuAAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAy50cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAALuAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAC7gAABAAAABAAAAAAKmbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAADAABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAACUW1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAhFzdGJsAAAAwXN0c2QAAAAAAAAAAQAAALFhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMSBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAAN2F2Y0MBZAAK/+EAGWdkAAqscgRewEQAAAMABAAAAwAQPEiWEYABAAdo6EOGSyLA/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAAKtAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAYAAAgAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAeGN0dHMAAAAAAAAADQAAAAEAAEAAAAAAAQABQAAAAAABAACAAAAAAAMAAAAAAAAABAAAIAAAAAABAAFAAAAAAAEAAIAAAAAAAwAAAAAAAAAEAAAgAAAAAAEAAMAAAAAAAQAAQAAAAAABAAAAAAAAAAIAACAAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAYAAAAAQAAAHRzdHN6AAAAAAAAAAAAAAAYAAACzAAAAA0AAAANAAAADQAAAA0AAAANAAAADQAAAA0AAAANAAAADQAAABMAAAANAAAADQAAAA0AAAANAAAADQAAAA0AAAANAAAADQAAABQAAAANAAAADQAAAA0AAAANAAAAFHN0Y28AAAAAAAAAAQAABDMAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAxAAAACGZyZWUAAAQMbWRhdAAAAq8GBf//q9xF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0xNiBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4MTMzIG1lPXVtaCBzdWJtZT0xMCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTI0IGNocm9tYV9tZT0xIHRyZWxsaXM9MiA4eDhkY3Q9MSBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz04IGJfcHlyYW1pZD0yIGJfYWRhcHQ9MiBiX2JpYXM9MCBkaXJlY3Q9MyB3ZWlnaHRiPTEgb3Blbl9nb3A9MCB3ZWlnaHRwPTIga2V5aW50PTI1MCBrZXlpbnRfbWluPTIgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD02MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTMyLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAAVZYiBAAMf/uZ1+BTTCBpJMvxDzj+BAAAACUGaCS2IL//+4AAAAAlBnhCHEFv/uoEAAAAJAZ4YJogl/8eAAAAACQGeGEaIJf/HgQAAAAkBnhhmiCX/x4EAAAAJAZ4YrUgl/8eBAAAACQGeGM1IJf/HgQAAAAkBnhjtSCX/x4AAAAAJAZ4ZDUgl/8eAAAAAD0GaGkk1AgLRMpgQV//+4QAAAAlBniGlxBb/uoAAAAAJAZ4pRaIJf8eAAAAACQGeKWWiCX/HgQAAAAkBnimFogl/x4EAAAAJAZ4pzJIJf8eBAAAACQGeKeySCX/HgAAAAAkBnioMkgl/x4AAAAAJAZ4qLJIJf8eBAAAAEEGaKum1AgLa0TKYAQS//sAAAAAJQZ4yhLEFP8GAAAAACQGeOmSogl/HgQAAAAkBnjqs0gl/x4AAAAAJAZ46zNIJf8eB"
            )
        )
        try video.write(to: mediaURL)
        try """
        1
        00:00:00,000 --> 00:01:00,000
        \(expectedSubtitleText)

        """.write(to: subtitleURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: subtitleURL)
            try? FileManager.default.removeItem(at: mediaURL)
        }

        player.load(mediaURL, autoPlay: false)
        for _ in 0 ..< 100 {
            if player.lastError != nil || player.mediaInformation.dimensions != nil {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect((player.lastError) == nil)
        #expect((player.mediaInformation.dimensions?.width) == 16)
        #expect((player.mediaInformation.dimensions?.height) == 16)
        let requiresNativeSurfaceConfiguration =
            ProcessInfo.processInfo.environment[
                "MPVUI_REQUIRE_NATIVE_SURFACE_CONFIGURATION"
            ] == "1"
        let requiredNativeSurfaceConfiguration: String? =
            if requiresNativeSurfaceConfiguration {
                await waitForNativeSurfaceConfiguration(in: nativeSurfaceFormats)
            } else {
                nil
            }
        try #require(
            !requiresNativeSurfaceConfiguration
                || requiredNativeSurfaceConfiguration != nil,
            "libplacebo must report its selected native Vulkan surface format."
        )

        // Only the last request in a burst may reach START_FILE. Its returned
        // playlist entry ID keeps lifecycle events from displaced entries from
        // changing the state associated with the newest load.
        for _ in 0 ..< 8 {
            player.load(mediaURL, autoPlay: false)
        }
        for _ in 0 ..< 100 {
            if player.lastError != nil || player.state == .ready || player.state == .paused {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect((player.lastError) == nil)
        #expect(player.state == .ready || player.state == .paused)
        #expect((player.mediaInformation.dimensions?.width) == 16)

        player.loadExternalTrack(subtitleURL, type: .subtitle, select: true)
        #expect(await waitForSelectedExternalSubtitle(in: player))
        let selectedSubtitle = try #require(
            player.subtitleTracks.first {
                $0.isExternal && $0.isSelected
            }
        )

        let portraitDrawableSize = surface.metalLayer.drawableSize
        let portraitOutputSize = MPVRenderOutputSize(
            width: Int(portraitDrawableSize.width),
            height: Int(portraitDrawableSize.height)
        )
        #expect((portraitOutputSize.width) > 0)
        #expect((portraitOutputSize.height) > (portraitOutputSize.width))
        let initialRenderOutputSize = await waitForRenderOutputSize(
            portraitOutputSize,
            from: player
        )
        #expect(
            initialRenderOutputSize == portraitOutputSize,
            "mpv should initially configure its output from the portrait drawable."
        )

        player.seek(to: .seconds(0.5))
        for _ in 0 ..< 40 {
            if approximatelyEqual(player.position, .seconds(0.5), tolerance: .milliseconds(10)),
               player.state == .paused
            {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(
            approximatelyEqual(player.position, .seconds(0.5), tolerance: .milliseconds(10))
        )
        #expect((player.state) == .paused)
        try #require(
            await waitForSubtitleText(
                expectedSubtitleText,
                in: subtitleSnapshots
            ),
            "The selected SubRip track must produce a semantic cue before resizing."
        )

        player.play()
        for _ in 0 ..< 100 {
            if player.lastError != nil || player.state == .playing {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect((player.lastError) == nil)
        #expect((player.state) == .playing)
        let lifecycleBeforePlayingResize = await player.lifecycleDiagnostics()

        let playingResizeSizes = [
            CGSize(width: 210, height: 300),
            CGSize(width: 280, height: 220),
            CGSize(width: 320, height: 180),
        ]
        for size in playingResizeSizes {
            surface.frame = CGRect(origin: .zero, size: size)
            surface.setNeedsLayout()
            surface.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
            #expect(surface.metalLayer.contentsGravity == .resizeAspectFill)
            #expect(surface.metalLayer.drawableSize.width > 1)
            #expect(surface.metalLayer.drawableSize.height > 1)
        }

        let landscapeDrawableSize = MPVRenderSurfaceConfiguration.drawableSize(
            for: surface.bounds.size,
            scale: surface.metalLayer.contentsScale
        )
        let landscapeOutputSize = MPVRenderOutputSize(
            width: Int(landscapeDrawableSize.width),
            height: Int(landscapeDrawableSize.height)
        )
        #expect((landscapeOutputSize.width) > (landscapeOutputSize.height))
        #expect(landscapeOutputSize != portraitOutputSize)
        let settledRenderOutputSize = await waitForRenderOutputSize(
            landscapeOutputSize,
            from: player
        )
        try #require(
            settledRenderOutputSize == landscapeOutputSize,
            "mpv should resize its existing output at the settled landscape drawable size."
        )
        try #require(
            (surface.metalLayer.drawableSize)
                == CGSize(
                    width: CGFloat(landscapeOutputSize.width),
                    height: CGFloat(landscapeOutputSize.height)
                )
        )

        for _ in 0 ..< 100 {
            if player.lastError != nil || player.state == .playing {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require((player.lastError) == nil)
        try #require((player.state) == .playing)
        try #require(surface.isActiveRenderingSurface)
        try #require((player.mediaInformation.sourceURL) == mediaURL)
        try #require(!(player.bufferStatus.isBuffering))
        let subtitleSelectedDuringPlayingResize =
            player.subtitleTracks.first(where: { $0.id == selectedSubtitle.id })?
                .isSelected == true
        try #require(
            subtitleSelectedDuringPlayingResize,
            "The external subtitle selection must survive a playing resize."
        )
        let subtitleObservedDuringPlayingResize = await waitForSubtitleText(
            expectedSubtitleText,
            in: subtitleSnapshots
        )
        try #require(
            subtitleObservedDuringPlayingResize,
            "The semantic subtitle stream must survive a playing resize."
        )

        let lifecycleAfterPlayingResize = await player.lifecycleDiagnostics()
        try #require(
            lifecycleAfterPlayingResize.handlesCreated
                == lifecycleBeforePlayingResize.handlesCreated
        )
        try #require(
            lifecycleAfterPlayingResize.handlesDestroyed
                == lifecycleBeforePlayingResize.handlesDestroyed
        )
        try #require(
            lifecycleAfterPlayingResize.loadCommands
                == lifecycleBeforePlayingResize.loadCommands
        )
        try #require(
            lifecycleAfterPlayingResize.startFileEvents
                == lifecycleBeforePlayingResize.startFileEvents
        )
        try #require(
            lifecycleAfterPlayingResize.seekCommands
                == lifecycleBeforePlayingResize.seekCommands
        )
        try #require(
            lifecycleAfterPlayingResize.loadingStateTransitions
                == lifecycleBeforePlayingResize.loadingStateTransitions
        )
        try #require(
            lifecycleAfterPlayingResize.bufferingStateTransitions
                == lifecycleBeforePlayingResize.bufferingStateTransitions
        )
        try #require(
            lifecycleAfterPlayingResize.seekingStateTransitions
                == lifecycleBeforePlayingResize.seekingStateTransitions
        )
        let playingResizeCommandCount =
            lifecycleAfterPlayingResize.surfaceResizeCommands
                - lifecycleBeforePlayingResize.surfaceResizeCommands
        try #require(playingResizeCommandCount > 0)
        // The coordinator may accept each distinct changed size plus one
        // authoritative trailing final. In-flight sizes can still coalesce, so
        // this is a hard upper bound rather than an exact command count.
        try #require(
            playingResizeCommandCount <= UInt64(playingResizeSizes.count + 1)
        )
        try #require(surface.metalLayer.pixelFormat == .bgra8Unorm)
        let playingResizeLatency = try #require(
            surface.resizeDiagnosticSnapshot.resizeLatencyNanoseconds
        )
        let capturedNativeSurfaceConfiguration =
            requiredNativeSurfaceConfiguration
                ?? nativeSurfaceFormats.latestConfiguration
        let nativeSurfaceConfiguration =
            capturedNativeSurfaceConfiguration ?? "NOT_CAPTURED"
        #if os(iOS)
        let resizePlatform = "ios"
        #else
        let resizePlatform = "tvos"
        #endif
        print(
            "MPVUI_RESIZE_EVIDENCE scenario=\(resizePlatform)-sdr-playing commands="
                + "\(playingResizeCommandCount) "
                + "latencyNs=\(playingResizeLatency) pixelFormat="
                + "\(surface.metalLayer.pixelFormat.rawValue) "
                + "output=\(landscapeOutputSize.width)x\(landscapeOutputSize.height) "
                + "subtitle=\(subtitleObservedDuringPlayingResize) "
                + "nativeSurfaceConfig=\"\(nativeSurfaceConfiguration)\""
        )

        player.pause()
        for _ in 0 ..< 100 {
            if player.lastError != nil || player.state == .paused {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require((player.lastError) == nil)
        try #require((player.state) == .paused)
        let positionBeforePausedFinal = player.position
        let lifecycleBeforePausedFinal = await player.lifecycleDiagnostics()

        try #require(surface.requestAuthoritativeFinalResize())
        var lifecycleAfterForcedFinal = lifecycleBeforePausedFinal
        for _ in 0 ..< 100 {
            lifecycleAfterForcedFinal = await player.lifecycleDiagnostics()
            if lifecycleAfterForcedFinal.surfaceResizeCommands
                == lifecycleBeforePausedFinal.surfaceResizeCommands + 1
            {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(
            lifecycleAfterForcedFinal.surfaceResizeCommands
                == lifecycleBeforePausedFinal.surfaceResizeCommands + 1
        )
        try #require(
            lifecycleAfterForcedFinal.handlesCreated
                == lifecycleBeforePausedFinal.handlesCreated
        )
        try #require(
            lifecycleAfterForcedFinal.handlesDestroyed
                == lifecycleBeforePausedFinal.handlesDestroyed
        )
        try #require(
            lifecycleAfterForcedFinal.loadCommands
                == lifecycleBeforePausedFinal.loadCommands
        )
        try #require(
            lifecycleAfterForcedFinal.startFileEvents
                == lifecycleBeforePausedFinal.startFileEvents
        )
        try #require(
            lifecycleAfterForcedFinal.seekCommands
                == lifecycleBeforePausedFinal.seekCommands
        )
        try #require(
            lifecycleAfterForcedFinal.loadingStateTransitions
                == lifecycleBeforePausedFinal.loadingStateTransitions
        )
        try #require(
            lifecycleAfterForcedFinal.bufferingStateTransitions
                == lifecycleBeforePausedFinal.bufferingStateTransitions
        )
        try #require(
            lifecycleAfterForcedFinal.seekingStateTransitions
                == lifecycleBeforePausedFinal.seekingStateTransitions
        )
        try #require(
            await waitForRenderOutputSize(landscapeOutputSize, from: player)
                == landscapeOutputSize
        )
        let resizeLatency = try #require(
            surface.resizeDiagnosticSnapshot.resizeLatencyNanoseconds
        )
        try #require((player.state) == .paused)
        try #require(
            approximatelyEqual(
                player.position,
                positionBeforePausedFinal,
                tolerance: .milliseconds(100)
            )
        )
        let subtitleSelectedAfterPausedFinal =
            player.subtitleTracks.first(where: { $0.id == selectedSubtitle.id })?
                .isSelected == true
        try #require(
            subtitleSelectedAfterPausedFinal,
            "The external subtitle selection must survive a paused forced final."
        )
        let subtitleObservedAfterPausedFinal = await waitForSubtitleText(
            expectedSubtitleText,
            in: subtitleSnapshots
        )
        try #require(
            subtitleObservedAfterPausedFinal,
            "The semantic subtitle stream must survive a paused forced final."
        )
        try #require(surface.metalLayer.pixelFormat == .bgra8Unorm)
        try #require(
            surface.metalLayer.drawableSize
                == CGSize(
                    width: CGFloat(landscapeOutputSize.width),
                    height: CGFloat(landscapeOutputSize.height)
                )
        )
        print(
            "MPVUI_RESIZE_EVIDENCE scenario=\(resizePlatform)-sdr-paused-forced-final commands="
                + "\(lifecycleAfterForcedFinal.surfaceResizeCommands - lifecycleBeforePausedFinal.surfaceResizeCommands) "
                + "totalCommands="
                + "\(lifecycleAfterForcedFinal.surfaceResizeCommands - lifecycleBeforePlayingResize.surfaceResizeCommands) "
                + "latencyNs=\(resizeLatency) pixelFormat=\(surface.metalLayer.pixelFormat.rawValue) "
                + "output=\(landscapeOutputSize.width)x\(landscapeOutputSize.height) "
                + "subtitle=\(subtitleObservedAfterPausedFinal) "
                + "nativeSurfaceConfig=\"\(nativeSurfaceConfiguration)\""
        )

        // Host-side 1x1 layouts are rejected. MoltenVK's render-thread-only
        // retirement sentinel remains available to its swapchain lifecycle.
        surface.metalLayer.drawableSize = CGSize(width: 1, height: 1)
        #expect(
            (surface.metalLayer.drawableSize)
                == CGSize(
                    width: CGFloat(landscapeOutputSize.width),
                    height: CGFloat(landscapeOutputSize.height)
                )
        )
        surface.frame = .zero
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        #expect(
            (surface.metalLayer.drawableSize)
                == CGSize(
                    width: CGFloat(landscapeOutputSize.width),
                    height: CGFloat(landscapeOutputSize.height)
                )
        )
        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)

        let lifecycleAfterTransientResize = await player.lifecycleDiagnostics()
        let renderOutputAfterTransientResize = await player.renderOutputSize()
        #expect(lifecycleAfterTransientResize == lifecycleAfterForcedFinal)
        #expect(renderOutputAfterTransientResize == landscapeOutputSize)
        #expect((player.state) == .paused)
        #expect(
            approximatelyEqual(
                player.position,
                positionBeforePausedFinal,
                tolerance: .milliseconds(100)
            )
        )

        // A replacement queues STOP for the displaced playlist entry. An
        // immediately requested explicit stop must still be attributed to the
        // replacement rather than consumed by that stale event.
        for _ in 0 ..< 8 {
            player.load(mediaURL, autoPlay: false)
        }
        player.stop()
        // Let every queued START/END pair settle; observing an intermediate
        // STOP from a displaced entry is not sufficient.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect((player.state) == .stopped)

        player.seek(to: .seconds(0.5))
        for _ in 0 ..< 40 {
            if approximatelyEqual(player.position, .seconds(0.5), tolerance: .milliseconds(10)) {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(
            approximatelyEqual(player.position, .seconds(0.5), tolerance: .milliseconds(10))
        )
        #expect((player.lastError) == nil)

        player.play()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect((player.lastError) == nil)
    }

    @MainActor
    private func waitForRenderOutputSize(
        _ expectedSize: MPVRenderOutputSize,
        from player: MPVPlayer
    ) async -> MPVRenderOutputSize? {
        for _ in 0 ..< 100 {
            let size = await player.renderOutputSize()
            if size == expectedSize {
                return size
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await player.renderOutputSize()
    }

    @MainActor
    private func waitForSelectedExternalSubtitle(in player: MPVPlayer) async -> Bool {
        for _ in 0 ..< 100 {
            if player.subtitleTracks.contains(where: {
                $0.isExternal && $0.isSelected
            }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return player.subtitleTracks.contains(where: {
            $0.isExternal && $0.isSelected
        })
    }

    @MainActor
    private func waitForInitialSubtitleSnapshot(
        in recorder: MobileSubtitleSnapshotRecorder
    ) async -> Bool {
        for _ in 0 ..< 100 {
            if recorder.values.first?.isEmpty == true {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return recorder.values.first?.isEmpty == true
    }

    @MainActor
    private func waitForSubtitleText(
        _ expected: String,
        in recorder: MobileSubtitleSnapshotRecorder
    ) async -> Bool {
        for _ in 0 ..< 100 {
            if recorder.values.last?.text == expected {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return recorder.values.last?.text == expected
    }

    @MainActor
    private func waitForNativeSurfaceConfiguration(
        in recorder: MobileNativeSurfaceFormatRecorder
    ) async -> String? {
        for _ in 0 ..< 100 {
            if let configuration = recorder.latestConfiguration {
                return configuration
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return recorder.latestConfiguration
    }

    private func approximatelyEqual(
        _ lhs: Duration,
        _ rhs: Duration,
        tolerance: Duration
    ) -> Bool {
        let difference = lhs - rhs
        return difference >= .zero - tolerance && difference <= tolerance
    }
    #endif
}

#if os(iOS) || os(tvOS)
@MainActor
private final class MobileSubtitleSnapshotRecorder {
    var values: [TextSubtitleSnapshot] = []
}

@MainActor
private final class MobileNativeSurfaceFormatRecorder {
    private(set) var latestConfiguration: String?

    func capture(_ message: MPVLogMessage) {
        guard message.message.contains("Picked surface configuration") else { return }
        latestConfiguration = message.message
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
#endif

#if os(macOS)
fileprivate extension MPVPlayerTests {
    func waitForMPVEvent(
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

    func waitForSelectedSubtitleCodec(
        _ handle: OpaquePointer,
        _ expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let tracks = MPVEngine.parseTracks(copiedMPVNode(handle, property: "track-list"))
            if tracks.contains(where: {
                $0.type == .subtitle && $0.isSelected && $0.codec == expected
            }) {
                return true
            }
            _ = mpv_wait_event(handle, 0.05)
        }
        return false
    }

    func waitForSubtitleSnapshot(
        _ handle: OpaquePointer,
        timeout: TimeInterval,
        where predicate: (MPVNodeValue) -> Bool
    ) -> MPVNodeValue? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let node = copiedMPVNode(handle, property: "sub-text-snapshot"),
               predicate(node)
            {
                return node
            }
            _ = mpv_wait_event(handle, 0.05)
        }
        return nil
    }

    func copiedMPVNode(
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
}
#endif
