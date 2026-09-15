#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
@testable import MPVUI
import Observation
import SwiftUI
import Testing

@Suite(.tags(.system, .pictureInPicture), .serialized)
struct MPVMacPictureInPictureTests {
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["MPVUI_RUN_MAC_PIP_SYSTEM_TESTS"] == "1",
        "Opt in on a logged-in Mac to open and validate real system PiP."
    ))
    @MainActor
    func `live overlay preserves environment state and intercepted subtitles in system PiP`() async throws {
        _ = NSApplication.shared
        let player = MPVPlayer(configuration: .init(autoPlay: false, hdrPolicy: .disabled))
        let model = LiveOverlayModel()
        func video() -> some View {
            MPVVideoPlayer(player: player)
                .videoOverlay { LiveOverlayProbe(model: model) }
                .environment(\.colorScheme, .dark)
        }
        let window = makeWindow()
        let host = NSHostingView(rootView: AnyView(video()))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        let pip = player.pictureInPicture
        let subtitles = player.textSubtitleStream()
        let observation = Task { @MainActor in
            for await snapshot in subtitles {
                model.caption = snapshot.text
            }
        }
        let subtitle = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-\(UUID()).srt")
        try "1\n00:00:00,000 --> 00:00:10,000\nIntercepted caption\n".write(to: subtitle, atomically: true, encoding: .utf8)
        defer {
            observation.cancel()
            pip.stop()
            player.stop()
            window.orderOut(nil)
            window.contentView = nil
            try? FileManager.default.removeItem(at: subtitle)
        }
        player.load(TestPaths.baselineMedia, autoPlay: false, startTime: .seconds(1))
        player.loadExternalTrack(subtitle, type: .subtitle, select: true)
        try #require(await waitUntil { pip.isPossible && model.caption == "Intercepted caption" && model.identity != nil })
        let identity = try #require(model.identity)
        #expect(model.colorScheme == .dark)
        let surface = try #require(findSurface(in: host))
        let overlayHost = try #require(surface.videoOverlayHost)

        pip.start()
        try #require(await waitUntil { pip.isActive || pip.lastError != nil })
        try #require(pip.isActive && pip.isVideoOverlayActive)
        #expect(overlayHost.window !== window)
        #expect(overlayHost.superview === surface.superview)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.caption == "Intercepted caption")
        #expect(await player.textSubtitleInterceptionForTesting() == true)

        model.isUpdated = true
        host.rootView = AnyView(video())
        host.layoutSubtreeIfNeeded()
        try #require(await waitUntil { model.renderedUpdate })
        #expect(model.identity == identity)
        #expect(surface.videoOverlayHost === overlayHost)

        // The retained view continues observing its model after SwiftUI removes
        // the inline representable. It must not be replaced by a new source.
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        model.isUpdated = false
        try #require(await waitUntil { !model.renderedUpdate })
        model.isUpdated = true
        try #require(await waitUntil { model.renderedUpdate })
        #expect(surface.videoOverlayHost === overlayHost)
        #expect(model.caption == "Intercepted caption")
        host.rootView = AnyView(video())
        host.layoutSubtreeIfNeeded()
        try #require(await waitUntil { findSurface(in: host) != nil })
        pip.stop()
        try #require(await waitUntil { !pip.isActive && !pip.isTransitioning })
        #expect(findSurface(in: host)?.isActiveRenderingSurface == true)
        #expect(!pip.isVideoOverlayActive)
        #expect(await player.textSubtitleInterceptionForTesting() == true)
        #expect(player.lastError == nil)
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["MPVUI_RUN_MAC_PIP_SYSTEM_TESTS"] == "1",
            "Opt in on a logged-in Mac to open and validate real system PiP."
        )
    )
    @MainActor
    func `SwiftUI source layout updates preserve the system hosted surface`() async throws {
        _ = NSApplication.shared
        let player = MPVPlayer(configuration: .init(autoPlay: true, hdrPolicy: .disabled))
        let sourceWindow = makeWindow()
        let inlineHost = NSHostingView(rootView: AnyView(MPVVideoPlayer(player: player)))
        sourceWindow.contentView = inlineHost
        sourceWindow.makeKeyAndOrderFront(nil)
        inlineHost.layoutSubtreeIfNeeded()
        try #require(await waitUntil { findSurface(in: inlineHost) != nil })
        let surface = try #require(findSurface(in: inlineHost))
        let pip = player.pictureInPicture
        defer {
            pip.stop()
            surface.detach()
            sourceWindow.orderOut(nil)
            sourceWindow.contentView = nil
        }
        player.load(TestPaths.media("01-h264-aac-baseline.mp4"))
        try #require(await waitUntil { player.state == .playing && pip.isPossible })
        pip.start()
        try #require(await waitUntil { pip.isActive || pip.lastError != nil })
        try #require(pip.isActive && pip.lastError == nil)
        let pipWindow = try #require(surface.window)
        try #require(pipWindow !== sourceWindow)

        sourceWindow.setContentSize(NSSize(width: 800, height: 450))
        inlineHost.rootView = AnyView(MPVVideoPlayer(player: player))
        inlineHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        #expect(surface.window === pipWindow)
        #expect(surface.isActiveRenderingSurface)
        #expect(pip.isActive)

        // Navigation can remove and recreate the representable while the
        // system still owns its video. The replacement stays inline and must
        // not steal rendering until PiP returns.
        inlineHost.rootView = AnyView(EmptyView())
        inlineHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        inlineHost.rootView = AnyView(MPVVideoPlayer(player: player))
        inlineHost.layoutSubtreeIfNeeded()
        try #require(await waitUntil { findSurface(in: inlineHost) != nil })
        let replacement = try #require(findSurface(in: inlineHost))
        #expect(replacement !== surface)
        #expect(!replacement.isActiveRenderingSurface)
        #expect(surface.window === pipWindow)

        pip.stop()
        try #require(await waitUntil { !pip.isActive && !pip.isTransitioning })
        #expect(replacement.window === sourceWindow)
        #expect(replacement.isActiveRenderingSurface)
        #expect(findSurface(in: inlineHost) === replacement)
        #expect(pip.lastError == nil)
        #expect(player.lastError == nil)
        print("MPVUI_PIP_EVIDENCE platform=macOS host=SwiftUI sourceResize=true rebuiltInlineView=true restored=true")
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["MPVUI_RUN_MAC_PIP_SYSTEM_TESTS"] == "1",
            "Opt in on a logged-in Mac to open and validate real system PiP."
        )
    )
    @MainActor
    func `stalled application restoration cannot retain active PiP indefinitely`() async throws {
        _ = NSApplication.shared
        let player = MPVPlayer(configuration: .init(autoPlay: true, hdrPolicy: .disabled))
        let surface = MPVPlatformVideoPlayer(player: player)
        let sourceWindow = makeWindow()
        sourceWindow.contentView = surface
        sourceWindow.makeKeyAndOrderFront(nil)
        surface.layoutSubtreeIfNeeded()
        let pip = MPVMacPictureInPictureController(player: player, restorationTimeout: .milliseconds(100))
        pip.attach(to: surface)
        var lastFailure: MPVPlayerError?
        var restorationWasCancelled = false
        pip.onFailure = { lastFailure = $0 }
        pip.restoreUserInterface = {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { restorationWasCancelled = true }
            return true
        }
        defer {
            pip.invalidate()
            surface.detach()
            sourceWindow.orderOut(nil)
            sourceWindow.contentView = nil
        }
        try #require(pip.isSupported)
        player.load(TestPaths.media("01-h264-aac-baseline.mp4"))
        try #require(await waitUntil { player.state == .playing && pip.isPossible })
        pip.start()
        try #require(await waitUntil { pip.isActive || lastFailure != nil })
        try #require(pip.isActive)
        pip.stop()
        try #require(await waitUntil { !pip.isActive && !pip.isTransitioning })
        #expect(lastFailure == .pictureInPictureTimedOut(operation: .restoreInterface))
        #expect(await waitUntil { restorationWasCancelled })
        #expect(surface.window === sourceWindow)
        #expect(surface.isActiveRenderingSurface)
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["MPVUI_RUN_MAC_PIP_SYSTEM_TESTS"] == "1",
            "Opt in on a logged-in Mac to open and validate real system PiP."
        )
    )
    @MainActor
    func `real system host plays resizes and restores one mpv session`() async throws {
        _ = NSApplication.shared
        let player = MPVPlayer(configuration: .init(autoPlay: true, hdrPolicy: .disabled))
        let surface = MPVPlatformVideoPlayer(player: player)
        let sourceWindow = makeWindow()
        sourceWindow.title = "MPVUI PiP validation"
        sourceWindow.contentView = surface
        sourceWindow.makeKeyAndOrderFront(nil)
        surface.layoutSubtreeIfNeeded()
        surface.updateRenderingConfiguration()
        let pip = player.pictureInPicture
        defer {
            pip.stop()
            surface.detach()
            sourceWindow.orderOut(nil)
            sourceWindow.contentView = nil
        }
        try #require(pip.isSupported)
        player.load(TestPaths.media("01-h264-aac-baseline.mp4"))
        try #require(await waitUntil { player.state == .playing && pip.isPossible })
        let layer = surface.metalLayer
        let initialLifecycle = await player.lifecycleDiagnostics()
        let positionBeforeStart = player.position

        pip.start()
        try #require(await waitUntil { pip.isActive || pip.lastError != nil })
        try #require(pip.lastError == nil, "\(String(describing: pip.lastError))")
        try #require(pip.isActive)
        let pipWindow = try #require(surface.window)
        #expect(pipWindow !== sourceWindow)
        #expect(pipWindow.isVisible)
        #expect(surface.metalLayer === layer)
        try #require(await waitUntil { player.position > positionBeforeStart + .seconds(1) })

        let originalPiPSize = surface.bounds.size
        pipWindow.setContentSize(NSSize(width: 360, height: 203))
        surface.layoutSubtreeIfNeeded()
        surface.requestAuthoritativeFinalResize()
        try #require(await waitUntil { surface.bounds.size != originalPiPSize })
        let resizedPixels = MPVRenderSurfaceConfiguration.drawableSize(
            for: surface.bounds.size, scale: surface.metalLayer.contentsScale
        )
        try #require(await waitForOutput(player, size: resizedPixels))
        player.pause()
        try #require(await waitUntil { player.isPaused })
        player.seek(to: .seconds(1))
        try #require(await waitUntil { abs(player.position.seconds - 1) < 0.5 })
        player.play()
        try #require(await waitUntil { player.state == .playing })

        pip.stop()
        try #require(await waitUntil { !pip.isActive && !pip.isTransitioning })
        #expect(pip.lastError == nil)
        #expect(sourceWindow.contentView === surface)
        #expect(surface.window === sourceWindow)
        #expect(surface.metalLayer === layer)

        // A second transition exercises the restored controller and surface,
        // rather than proving only the initial framework presentation.
        pip.start()
        try #require(await waitUntil { pip.isActive || pip.lastError != nil })
        try #require(pip.isActive && pip.lastError == nil)
        pip.stop()
        try #require(await waitUntil { !pip.isActive && !pip.isTransitioning })
        #expect(surface.window === sourceWindow)
        let finalLifecycle = await player.lifecycleDiagnostics()
        #expect(finalLifecycle.handlesCreated == initialLifecycle.handlesCreated)
        #expect(finalLifecycle.loadCommands == initialLifecycle.loadCommands)
        #expect(player.lastError == nil)
        print("MPVUI_PIP_EVIDENCE platform=macOS mechanism=private-system-host media=baseline-h264 "
            + "active=true nativeSize=\(Int(resizedPixels.width))x\(Int(resizedPixels.height)) "
            + "pauseSeekResume=true restored=true cycles=2 "
            + "handles=\(finalLifecycle.handlesCreated) loads=\(finalLifecycle.loadCommands)")
    }

    @MainActor
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.animationBehavior = .none
        return window
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 160 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @MainActor
    private func waitForOutput(_ player: MPVPlayer, size: CGSize) async -> Bool {
        let expected = MPVRenderOutputSize(width: Int(size.width), height: Int(size.height))
        for _ in 0 ..< 160 {
            if await player.renderOutputSize() == expected {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await player.renderOutputSize() == expected
    }

    @MainActor
    private func findSurface(in view: NSView) -> MPVPlatformVideoPlayer? {
        if let surface = view as? MPVPlatformVideoPlayer {
            return surface
        }
        for child in view.subviews {
            if let surface = findSurface(in: child) {
                return surface
            }
        }
        return nil
    }
}

@MainActor @Observable
private final class LiveOverlayModel {
    var caption = ""
    var isUpdated = false
    var renderedUpdate = false
    var identity: UUID?
    var colorScheme: ColorScheme?
}

private struct LiveOverlayProbe: View {
    let model: LiveOverlayModel
    @Environment(\.colorScheme)
    private var colorScheme
    @State
    private var identity = UUID()

    var body: some View {
        Text(model.caption)
            .padding()
            .background(model.isUpdated ? Color.green : Color.blue)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onAppear {
                model.identity = identity
                model.colorScheme = colorScheme
            }
            .onChange(of: model.isUpdated, initial: true) { _, value in
                model.renderedUpdate = value
            }
    }
}
#endif
