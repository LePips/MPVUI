import Foundation
import Libmpv
@testable import MPVUI
import Observation
import Testing

#if os(iOS) || os(tvOS)
import UIKit
#endif

@Suite(.tags(.integration), .serialized)
struct MPVMobilePlaybackLifecycleTests {

    #if os(iOS) || os(tvOS)
    @MainActor
    @Test
    func `mobile surface preserves playback subtitles and lifecycle across resize`()
        async throws
    {
        let player = MPVPlayer(
            configuration: .init(
                autoPlay: false,
                hardwareDecoding: .disabled,
                hdrPolicy: .disabled,
                logLevel: .debug,
                loop: true,
                playbackRate: 0.1,
                // This scenario verifies 8-bit SDR resize behavior. Automatic
                // SDR legitimately selects float16 on a wide-gamut display.
                sdrOutput: .compatibility8Bit
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

        let playingResizeLatency = try await waitForResizeLatency(landscapeOutputSize, from: surface)
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
        let resizeLatency = try await waitForResizeLatency(landscapeOutputSize, from: surface)
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
    private func waitForResizeLatency(
        _ expected: MPVRenderOutputSize,
        from surface: MPVPlatformVideoPlayer
    ) async throws -> UInt64 {
        // Native output dimensions can change before the coordinator receives
        // the final acknowledgement and records its latency.
        let size = CGSize(width: CGFloat(expected.width), height: CGFloat(expected.height))
        try await eventually("final resize is acknowledged") {
            let snapshot = surface.resizeDiagnosticSnapshot
            return snapshot.committedDrawableSize == size
                && snapshot.inFlight == nil && snapshot.pendingDrawableSize == nil
                && !snapshot.hasScheduledCommit && !snapshot.finalCommitRequired
                && snapshot.resizeLatencyNanoseconds != nil
        }
        return try #require(surface.resizeDiagnosticSnapshot.resizeLatencyNanoseconds)
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
