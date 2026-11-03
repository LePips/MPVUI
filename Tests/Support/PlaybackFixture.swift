import AVFoundation
import Foundation
@testable import MPVCore
@testable import MPVUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Owns a real player and attached rendering surface for one test only.
/// Call `close()` from `defer`. Each case starts with an independent native session.
@MainActor
final class PlaybackFixture {

    let player: MPVPlayer
    let surface: MPVPlatformVideoPlayer
    #if os(macOS)
    let window: NSWindow

    private var isWindowOnscreen: Bool {
        guard window.windowNumber > 0 else { return false }

        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]]
        return info?.first?[kCGWindowIsOnscreen as String] as? Bool == true
    }
    #else
    let window: UIWindow
    private weak var previousKeyWindow: UIWindow?
    #endif

    var presentationContext: String {
        #if os(macOS)
        "windowVisible=\(window.isVisible), windowOnscreen=\(isWindowOnscreen), "
            + "surfaceWindow=\(surface.window != nil), bounds=\(surface.bounds)"
        #else
        "windowScene=\(window.windowScene != nil), activation=\(window.windowScene?.activationState.rawValue ?? -1), "
            + "windowHidden=\(window.isHidden), key=\(window.isKeyWindow), "
            + "surfaceWindow=\(surface.window === window), bounds=\(surface.bounds)"
        #endif
    }

    init(
        configuration: MPVPlayerConfiguration = .init(
            additionalOptions: ["ao": "null"],
            automaticallyPlays: false,
            videoOutput: .sampleBuffer
        ),
        player: MPVPlayer? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.player = player ?? MPVPlayer(configuration: configuration)
        surface = MPVPlatformVideoPlayer(player: self.player, notificationCenter: notificationCenter)

        let frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        #if os(macOS)
        _ = NSApplication.shared
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        window.orderFront(nil)
        surface.layoutSubtreeIfNeeded()
        #else
        // A scene-based test host does not composite a legacy UIWindow that
        // has no windowScene. AVFoundation may report ready even though there
        // is no displayed image for copyDisplayedPixelBuffer to return.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }

        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }

        if let scene {
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            // Unhosted simulator/package runners may not create a scene.
            window = UIWindow(frame: frame)
        }

        let host = UIViewController()
        host.view = surface
        window.rootViewController = host
        window.makeKeyAndVisible()
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        #endif
        surface.activateRenderingSurface()
    }

    func loadForVideoReadback(_ url: URL, playAutomatically: Bool = false, startTime: Duration? = nil) async throws {
        #if os(macOS)
        // SwiftPM can retain stale AppKit occlusion state. Confirm presentation with WindowServer.
        if NSApplication.shared.activationPolicy() == .prohibited {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        window.center()
        window.orderFrontRegardless()
        try await eventually("WindowServer to present the video surface") {
            self.surface.window === self.window && self.isWindowOnscreen
        }
        #endif
        player.load(url, playAutomatically: playAutomatically, startTime: startTime)
    }

    func loadPaused(_ url: URL = TestPaths.baselineMedia, at position: Duration = .seconds(1)) async throws {
        player.load(url, playAutomatically: false, startTime: position)

        try await eventually("paused media at \(position)") {
            self.player.state == .paused && self.player.isPaused && self.player.isSeekable
                && abs(self.player.position.seconds - position.seconds) < 0.2
                && self.player.mediaInformation.dimensions != nil
                && self.player.playbackDiagnostics.startLatencySeconds != nil
        }
    }

    func close() {
        player.stop()
        surface.detach()
        #if os(macOS)
        window.orderOut(nil)
        window.contentView = nil
        #else
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
        #endif
    }
}
