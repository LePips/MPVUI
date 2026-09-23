#if os(iOS) && !targetEnvironment(macCatalyst)
import AVKit
import CoreMedia
import Foundation
@testable import MPVUI
import SwiftUI
import Testing
import UIKit

@Suite(.tags(.integration, .pictureInPicture), .serialized)
@MainActor
struct MPVSampleBufferPictureInPictureControllerTests {
    @Test(arguments: [CGSize(width: 640, height: 360), CGSize(width: 390, height: 844)])
    func `PiP preserves inline text size and wrapping`(inlineSize: CGSize) async throws {
        let player = MPVPlayer(configuration: .init(
            additionalOptions: ["ao": "null"],
            autoPlay: false,
            hardwareDecoding: .disabled,
            videoOutput: .sampleBuffer
        ))
        let surface = MPVPlatformVideoPlayer(player: player)
        let window = UIWindow(frame: CGRect(origin: .zero, size: inlineSize))
        let host = UIViewController()
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)
        window.rootViewController = host
        host.view.addSubview(surface)
        surface.frame = CGRect(origin: .zero, size: inlineSize)
        window.isHidden = false
        surface.activateRenderingSurface()
        let pip = player.pictureInPicture
        let measurements = CaptionMeasurements()
        func overlay(revision: Int = 0) -> MPVVideoOverlay {
            MPVVideoOverlay(content: AnyView(
                CaptionLayout(measurements: measurements) {
                    Text("This caption should keep the same line breaks in picture in picture.")
                        .font(.system(size: 24))
                }.id(revision)
            ))
        }
        defer {
            pip.setNativeRendering(false)
            player.stop()
            surface.detach()
            window.isHidden = true
            window.rootViewController = nil
        }
        surface.setVideoOverlay(overlay())
        surface.layoutIfNeeded()
        surface.videoOverlayHost?.layoutIfNeeded()
        try await waitForOverlayCondition("inline caption layout") {
            !measurements.values.isEmpty && (surface.videoOverlayHost?.layoutSize.width ?? 0) > 0
        }
        let inline = try #require(measurements.values.last)
        #expect(inline.canvas.width == inlineSize.width - 48)
        measurements.values.removeAll()

        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(1))
        try await waitForOverlayCondition("native video") { player.sampleBufferDisplayLayer.isReadyForDisplay }
        pip.setNativeRendering(true)
        try await waitForOverlayCondition("rasterized caption layout") {
            pip.isVideoOverlayActive && !measurements.values.isEmpty
        }
        #expect(
            measurements.values.allSatisfy { $0.canvas.width == inline.canvas.width && $0.text == inline.text },
            "PiP: \(measurements.values); inline: \(inline)"
        )

        // Leaving the source screen can remove its window and collapse its
        // layout. PiP resizes must still use the original logical width.
        surface.removeFromSuperview()
        surface.frame = .zero
        surface.layoutIfNeeded()
        surface.videoOverlayHost?.layoutIfNeeded()
        for (revision, size) in [CGSize(width: 160, height: 90), CGSize(width: 640, height: 360)].enumerated() {
            measurements.values.removeAll()
            pip.updateRenderSize(size)
            surface.setVideoOverlay(overlay(revision: revision + 1))
            try await waitForOverlayCondition("resized PiP caption") { !measurements.values.isEmpty }
            #expect(
                measurements.values.allSatisfy { $0.canvas.width == inline.canvas.width && $0.text == inline.text },
                "PiP at \(size): \(measurements.values); inline: \(inline)"
            )
        }
    }

    @Test(arguments: [false, true])
    func `PiP preserves subtitle interception with and without overlays`(intercepts: Bool) async throws {
        let player = MPVPlayer(configuration: .init(
            additionalOptions: ["ao": "null"],
            autoPlay: false,
            hardwareDecoding: .disabled,
            videoOutput: .sampleBuffer
        ))
        let surface = MPVPlatformVideoPlayer(player: player)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let host = UIViewController()
        host.view = surface
        window.rootViewController = host
        window.isHidden = false
        surface.activateRenderingSurface()
        let pip = player.pictureInPicture
        var latestCaption = ""
        var observation: Task<Void, Never>?
        if intercepts {
            let stream = player.textSubtitleStream()
            observation = Task { @MainActor in
                for await snapshot in stream {
                    latestCaption = snapshot.text
                }
            }
        }
        let subtitle = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-\(UUID()).srt")
        try "1\n00:00:00,000 --> 00:00:10,000\nIntercepted caption\n".write(to: subtitle, atomically: true, encoding: .utf8)
        defer {
            pip.setNativeRendering(false)
            observation?.cancel()
            player.stop()
            surface.detach()
            window.isHidden = true
            window.rootViewController = nil
            try? FileManager.default.removeItem(at: subtitle)
        }
        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(1))
        player.loadExternalTrack(subtitle, type: .subtitle, select: true)
        try await waitForOverlayCondition("initial caption") {
            player.sampleBufferDisplayLayer.isReadyForDisplay
                && (!intercepts || latestCaption == "Intercepted caption")
        }
        pip.setNativeRendering(true)
        #expect(await player.textSubtitleInterceptionForTesting() == intercepts)
        #expect(!pip.isVideoOverlayActive)

        surface.setVideoOverlay(MPVVideoOverlay(content: AnyView(Text("Styled caption"))))
        // Exercise the same rendering callback on simulators that cannot open
        // real PiP. Native pixel fidelity is checked in the macOS VO tests.
        try await waitForOverlayCondition("accepted bitmap") { pip.isVideoOverlayActive }
        #expect(!intercepts || latestCaption == "Intercepted caption")
        #expect(await player.textSubtitleInterceptionForTesting() == intercepts)
        #expect(surface.videoOverlayHost?.isHidden == true)

        surface.setVideoOverlay(MPVVideoOverlay(content: AnyView(Text("Badge"))))
        #expect(await player.textSubtitleInterceptionForTesting() == intercepts)
        #expect(pip.isVideoOverlayActive)
        surface.setVideoOverlay(nil)
        #expect(await player.textSubtitleInterceptionForTesting() == intercepts)
        #expect(!pip.isVideoOverlayActive)
        surface.setVideoOverlay(MPVVideoOverlay(content: AnyView(Text("Styled caption"))))
        #expect(await player.textSubtitleInterceptionForTesting() == intercepts)

        pip.setNativeRendering(false)
        #expect(await player.textSubtitleInterceptionForTesting() == intercepts)
        #expect(!pip.isVideoOverlayActive)
        #expect(surface.videoOverlayHost?.isHidden == false)
        #expect(player.isPaused)
        #expect(player.lastError == nil)

        // An entry canceled before the first render cannot install stale pixels
        // or publish an active overlay after teardown.
        pip.setNativeRendering(true)
        pip.setNativeRendering(false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!pip.isVideoOverlayActive)
        #expect(await player.textSubtitleInterceptionForTesting() == intercepts)
    }

    private func waitForOverlayCondition(_ operation: String, _ condition: () -> Bool) async throws {
        for _ in 0 ..< 250 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "PiP overlay did not reach its expected state: \(operation)")
    }

    @Test
    func `start before native video is ready reports failure without a pending transition`() {
        let player = MPVPlayer()
        let helper = MPVSampleBufferPictureInPictureController(
            player: player,
            displayLayer: AVSampleBufferDisplayLayer(),
            onStateChange: { _ in },
            restoreUserInterface: { false },
            onRenderingModeChange: { _ in }
        )

        helper.start()

        #expect(helper.snapshot.lastError == (helper.snapshot.isSupported
                ? .pictureInPictureNotReady : .pictureInPictureUnsupported))
        #expect(!helper.snapshot.isStarting)
        #expect(!helper.snapshot.isActive)
        helper.invalidate()
        helper.invalidate()
        #expect(!helper.snapshot.isPossible)
    }

    @Test
    func `automatic startup failure retires native PiP mode and clears transition`() {
        let player = MPVPlayer()
        let layer = AVSampleBufferDisplayLayer()
        var renderingModes: [Bool] = []
        let helper = MPVSampleBufferPictureInPictureController(
            player: player,
            displayLayer: layer,
            onStateChange: { _ in },
            restoreUserInterface: { false },
            onRenderingModeChange: { renderingModes.append($0) }
        )
        defer { helper.invalidate() }

        helper.prepareToStartPictureInPicture()
        #expect(helper.snapshot.isStarting)
        helper.didFailToStartPictureInPicture(
            error: NSError(domain: "PiPTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native startup failed"])
        )

        #expect(renderingModes == [true, false])
        #expect(!helper.snapshot.isStarting)
        #expect(!helper.snapshot.isActive)
        #expect(helper.snapshot.lastError == .pictureInPictureFailed(operation: .start, message: "Native startup failed"))
    }

    @Test
    func `invalidating during interface restoration completes the system request exactly once`() async throws {
        let player = MPVPlayer()
        let layer = AVSampleBufferDisplayLayer()
        var restoration: CheckedContinuation<Bool, Never>?
        var completions: [Bool] = []
        let helper = MPVSampleBufferPictureInPictureController(
            player: player,
            displayLayer: layer,
            onStateChange: { _ in },
            restoreUserInterface: {
                await withCheckedContinuation { restoration = $0 }
            },
            onRenderingModeChange: { _ in }
        )
        helper.requestInterfaceRestoration { completions.append($0) }
        for _ in 0 ..< 100 where restoration == nil {
            await Task.yield()
        }
        let pending = try #require(restoration)
        #expect(completions.isEmpty)

        helper.invalidate()
        #expect(completions == [false])
        pending.resume(returning: true)
        await Task.yield()
        #expect(completions == [false])
    }

    @Test
    func `native skip completes only after the display clock reaches a paused seek`() async throws {
        let player = MPVPlayer(configuration: .init(
            additionalOptions: ["ao": "null"],
            autoPlay: false,
            hardwareDecoding: .disabled,
            videoOutput: .sampleBuffer
        ))
        let frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        let surface = MPVPlatformVideoPlayer(player: player)
        surface.frame = frame
        let host = UIViewController()
        host.view.addSubview(surface)
        let window = UIWindow(frame: frame)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        surface.layoutIfNeeded()
        surface.activateRenderingSurface()
        let layer = player.sampleBufferDisplayLayer
        let helper = MPVSampleBufferPictureInPictureController(
            player: player,
            displayLayer: layer,
            onStateChange: { _ in },
            restoreUserInterface: { true },
            onRenderingModeChange: { _ in }
        )
        defer {
            helper.invalidate()
            player.stop()
            surface.detach()
            window.isHidden = true
            window.rootViewController = nil
        }

        player.load(TestPaths.baselineMedia, autoPlay: false)
        for _ in 0 ..< 250 {
            if player.isPaused, player.isSeekable, layer.isReadyForDisplay,
               let timebase = layer.controlTimebase, CMTimebaseGetRate(timebase) == 0
            {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(
            player.isPaused && player.isSeekable && layer.isReadyForDisplay,
            "Native PiP fixture failed: state=\(player.state), bounds=\(layer.bounds), renderer=\(layer.sampleBufferRenderer.status.rawValue), ready=\(layer.isReadyForDisplay), rate=\(layer.controlTimebase.map(CMTimebaseGetRate) ?? -1), appState=\(UIApplication.shared.applicationState.rawValue), error=\(String(describing: player.lastError))"
        )
        let timebase = try #require(layer.controlTimebase)
        let target = player.position.seconds + 0.75
        var completionCount = 0
        var displayedTimeAtCompletion = Double.nan
        var displayRateAtCompletion = Double.nan
        helper.requestSkip(by: CMTime(seconds: 0.75, preferredTimescale: 600)) {
            completionCount += 1
            displayedTimeAtCompletion = CMTimebaseGetTime(timebase).seconds
            displayRateAtCompletion = CMTimebaseGetRate(timebase)
        }
        #expect(completionCount == 0)
        for _ in 0 ..< 600 where completionCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(completionCount == 1)
        #expect(helper.snapshot.lastError == nil)
        #expect(abs(displayedTimeAtCompletion - target) < 0.25)
        #expect(displayRateAtCompletion == 0)
        #expect(player.isPaused)

        var endpointCompletions = 0
        helper.requestSkip(by: CMTime(seconds: player.duration.seconds, preferredTimescale: 600)) {
            endpointCompletions += 1
        }
        for _ in 0 ..< 600 where endpointCompletions == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(endpointCompletions == 1)
        #expect(helper.snapshot.lastError == nil)
        #expect(player.state == .ended)
        #expect(player.isPlaybackPausedForPictureInPicture)

        // A forward skip at EOF is an already-completed operation. A backward
        // skip reopens the same source paused and receives a new VO timebase.
        var forwardAtEndCompletions = 0
        helper.requestSkip(by: CMTime(seconds: 15, preferredTimescale: 600)) {
            forwardAtEndCompletions += 1
        }
        for _ in 0 ..< 100 where forwardAtEndCompletions == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(forwardAtEndCompletions == 1)
        #expect(helper.snapshot.lastError == nil)
        #expect(player.state == .ended)

        let backwardTarget = player.duration.seconds - 0.75
        var backwardCompletions = 0
        var backwardDisplayTime = Double.nan
        var backwardDisplayRate = Double.nan
        helper.requestSkip(by: CMTime(seconds: -0.75, preferredTimescale: 600)) {
            backwardCompletions += 1
            if let restartedTimebase = layer.controlTimebase {
                backwardDisplayTime = CMTimebaseGetTime(restartedTimebase).seconds
                backwardDisplayRate = CMTimebaseGetRate(restartedTimebase)
            }
        }
        for _ in 0 ..< 600 where backwardCompletions == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(backwardCompletions == 1)
        #expect(helper.snapshot.lastError == nil)
        #expect(abs(backwardDisplayTime - backwardTarget) < 0.25)
        #expect(backwardDisplayRate == 0)
        // The completion checks the native clock; the public state arrives
        // through the engine's separate stream of main-actor updates.
        for _ in 0 ..< 100 where player.state != .paused {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(player.state == .paused)
        #expect(player.isPlaybackPausedForPictureInPicture)
    }
}

@MainActor
private final class CaptionMeasurements {
    struct Measurement: Equatable {
        let canvas: CGSize
        let text: CGSize
    }

    var values: [Measurement] = []
}

private struct CaptionLayout: Layout {
    let measurements: CaptionMeasurements

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        let proposal = ProposedViewSize(bounds.size)
        let size = text.sizeThatFits(proposal)
        MainActor.assumeIsolated {
            measurements.values.append(.init(canvas: bounds.size, text: size))
        }
        text.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: proposal)
    }
}
#endif
