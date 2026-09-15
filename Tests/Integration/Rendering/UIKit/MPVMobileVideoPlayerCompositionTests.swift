#if os(iOS) || os(tvOS)
@testable import MPVUI
import SwiftUI
import Testing
import UIKit

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVMobileVideoPlayerCompositionTests {
    @Test
    func `SwiftUI updates overlays then transfers ownership when its player changes`() async throws {
        let first = MPVPlayer(configuration: .init(autoPlay: false, videoOutput: .sampleBuffer, additionalOptions: ["ao": "null"]))
        let second = MPVPlayer(configuration: .init(autoPlay: false, videoOutput: .sampleBuffer, additionalOptions: ["ao": "null"]))
        var appeared: [String] = []
        let video = MPVVideoPlayer(player: first)
            .videoOverlay { Text("Discarded").onAppear { appeared.append("discarded") } }
            .videoOverlay(alignment: .bottom) { Text("Current").onAppear { appeared.append("current") } }
        let host = UIHostingController(rootView: AnyView(video))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer {
            findSurface(in: host.view)?.detach()
            first.stop()
            second.stop()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await eventually("SwiftUI mounts the latest overlay") { appeared.contains("current") && first.hasActiveRenderSurface }
        #expect(!appeared.contains("discarded"))
        let original = try #require(findSurface(in: host.view))
        #expect(original.player === first)
        #expect(original.videoOverlayHost != nil)
        host
            .rootView = AnyView(MPVVideoPlayer(player: first)
                .videoOverlay { Text("Updated").id("updated").onAppear { appeared.append("updated") } })
        host.view.layoutIfNeeded()
        try await eventually("SwiftUI updates the existing surface overlay") { appeared.contains("updated") }
        #expect(findSurface(in: host.view) === original)
        host.rootView = AnyView(MPVVideoPlayer(player: second))
        host.view.layoutIfNeeded()
        try await eventually("SwiftUI transfers the active render surface") {
            second.hasActiveRenderSurface && !first.hasActiveRenderSurface
        }
        let replacement = try #require(findSurface(in: host.view))
        #expect(replacement.player === second)
        #expect(replacement.videoOverlayHost == nil)
        #expect(!original.isActiveRenderingSurface)
    }

    private func findSurface(in view: UIView) -> MPVPlatformVideoPlayer? {
        if let surface = view as? MPVPlatformVideoPlayer {
            return surface
        }
        return view.subviews.lazy.compactMap { findSurface(in: $0) }.first
    }
}
#endif
