import AVFoundation
import Foundation
@testable import MPVUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Owns a real player and attached rendering surface for one test only.
/// Call close() from defer; each case starts with an independent native session.
@MainActor
final class PlaybackFixture {
    let player: MPVPlayer
    let surface: MPVPlatformVideoPlayer
    #if os(macOS)
    let window: NSWindow
    #else
    let window: UIWindow
    private weak var previousKeyWindow: UIWindow?
    #endif

    init(
        configuration: MPVPlayerConfiguration = .init(
            additionalOptions: ["ao": "null"],
            autoPlay: false,
            videoOutput: .sampleBuffer
        ),
        notificationCenter: NotificationCenter = .default
    ) {
        player = MPVPlayer(configuration: configuration)
        surface = MPVPlatformVideoPlayer(player: player, notificationCenter: notificationCenter)
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

    var presentationContext: String {
        #if os(macOS)
        "windowVisible=\(window.isVisible), surfaceWindow=\(surface.window != nil), bounds=\(surface.bounds)"
        #else
        "windowScene=\(window.windowScene != nil), activation=\(window.windowScene?.activationState.rawValue ?? -1), "
            + "windowHidden=\(window.isHidden), key=\(window.isKeyWindow), "
            + "surfaceWindow=\(surface.window === window), bounds=\(surface.bounds)"
        #endif
    }

    func loadPaused(_ url: URL = TestPaths.baselineMedia, at position: Duration = .seconds(1)) async throws {
        player.load(url, autoPlay: false, startTime: position)
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
