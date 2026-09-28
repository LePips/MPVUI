#if os(iOS)
import AVFoundation
@testable import MPVUI
import QuartzCore
import SwiftUI
import Testing
import UIKit

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVOrientationResizeTests {
    @Test(arguments: [false, true], [false, true])
    func `system rotation animates video through intermediate sizes`(metal: Bool, playing: Bool) async throws {
        for swiftUI in [false, true] {
            try await validateRotation(metal: metal, playing: playing, swiftUI: swiftUI)
        }
    }

    private func validateRotation(metal: Bool, playing: Bool, swiftUI: Bool) async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null", "loop-file": "inf"], autoPlay: false,
            hardwareDecoding: .disabled, hdrPolicy: .disabled,
            sdrOutput: .compatibility8Bit, videoOutput: metal ? .metal : .sampleBuffer
        ))
        defer { fixture.close() }
        let scene = try #require(fixture.window.windowScene)
        fixture.window.rootViewController?.view = UIView()
        let content: UIViewController
        if swiftUI {
            fixture.surface.detach()
            content = UIHostingController(rootView:
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        MPVVideoPlayer(player: fixture.player)
                        Color.gray.frame(width: geometry.size.width * 0.25)
                    }
                }
            )
        } else {
            content = UIViewController()
            content.view = fixture.surface
        }
        let controller = OrientationHostingController(content: content)
        fixture.window.rootViewController = controller
        fixture.window.frame = scene.coordinateSpace.bounds
        fixture.window.makeKeyAndVisible()
        fixture.window.layoutIfNeeded()
        try await eventually("rotation surface is hosted") { findSurface(in: controller.view) != nil }
        let surface = try #require(findSurface(in: controller.view))
        surface.activateRenderingSurface()
        try await rotate(scene, controller: controller, to: .portrait)
        try await fixture.loadPaused()
        try #require(fixture.player.videoOutput == (metal ? .metal : .sampleBuffer))
        if playing {
            fixture.player.play()
            try await eventually("rotation fixture is playing") { fixture.player.state == .playing }
        }
        let before = await fixture.player.lifecycleDiagnostics()
        let host = surface.metalLayer
        let video = fixture.player.sampleBufferDisplayLayer

        for orientation in [UIInterfaceOrientation.landscapeRight, .portrait] {
            let finalBefore = MPVRenderSurfaceConfiguration.drawableSize(
                for: surface.bounds.size, scale: host.contentsScale
            )
            if metal {
                try await eventually("previous rotation settled") { host.drawableSize == finalBefore }
            }
            let initialDrawable = host.drawableSize
            let initialWidth = host.bounds.width
            let startPosition = fixture.player.position
            let transitionsBefore = controller.transitionCount
            var requestError: (any Error)?
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask(for: orientation))) {
                requestError = $0
            }
            try await eventually("system rotation starts") {
                requestError != nil || controller.transitionCount > transitionsBefore
            }
            try #require(requestError == nil, "Rotation request failed: \(String(describing: requestError))")
            try #require(controller.transitionDuration > 0)
            var presentationWidths: Set<Int> = []
            var viewportWidths: Set<Int> = []
            var sampleCount = 0
            let deadline = CACurrentMediaTime() + 3
            while controller.isRotating, CACurrentMediaTime() < deadline {
                if let presentation = host.presentation() {
                    let size = presentation.bounds.size
                    if abs(size.width - initialWidth) > 1, abs(size.width - host.bounds.width) > 1 {
                        sampleCount += 1
                        presentationWidths.insert(Int(size.width))
                        if metal {
                            #expect(host.drawableSize == initialDrawable, "Rotation must retain its buffers until the animation ends")
                            if let viewport = surface.resizeDiagnosticSnapshot.committedDrawableSize {
                                viewportWidths.insert(Int(viewport.width))
                            }
                        } else {
                            let videoSize = try #require(video.presentation()).bounds.size
                            #expect(abs(videoSize.width - size.width) < 1, "Native video width must follow the rotation animation")
                            #expect(abs(videoSize.height - size.height) < 1, "Native video height must follow the rotation animation")
                        }
                    }
                }
                try await Task.sleep(for: .milliseconds(8))
            }
            #expect(!controller.isRotating)
            #expect(scene.interfaceOrientation == orientation)
            #expect(presentationWidths.count > 5, "Rotation must animate through intermediate sizes instead of snapping")
            if metal {
                #expect(viewportWidths.count > 5, "mpv must follow the changing aspect ratio throughout rotation")
                let finalSize = MPVRenderSurfaceConfiguration.drawableSize(
                    for: surface.bounds.size, scale: host.contentsScale
                )
                try await eventually("rotation restores exact resolution") {
                    host.drawableSize == finalSize && !surface.resizeDiagnosticSnapshot.finalCommitRequired
                }
            } else {
                #expect(video.frame == host.bounds)
                #expect(video.isReadyForDisplay)
                #expect(video.sampleBufferRenderer.status != .failed)
            }
            if playing {
                #expect(fixture.player.position > startPosition)
                #expect(fixture.player.state == .playing)
            } else {
                #expect(fixture.player.isPaused)
                #expect(fixture.player.position == startPosition)
            }
            print(
                "Rotation \(swiftUI ? "SwiftUI" : "UIKit") \(metal ? "metal" : "native") \(playing ? "playing" : "paused") \(orientation.rawValue): \(sampleCount) intermediate samples, \(presentationWidths.count) view widths, \(viewportWidths.count) viewport widths"
            )
        }
        let after = await fixture.player.lifecycleDiagnostics()
        #expect(after.handlesCreated == before.handlesCreated)
        #expect(after.loadCommands == before.loadCommands)
        #expect(fixture.player.videoOutput == (metal ? .metal : .sampleBuffer))
        #expect(fixture.player.lastError == nil)
    }

    private func rotate(
        _ scene: UIWindowScene,
        controller: OrientationHostingController,
        to orientation: UIInterfaceOrientation
    ) async throws {
        if scene.interfaceOrientation != orientation {
            var requestError: (any Error)?
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask(for: orientation))) {
                requestError = $0
            }
            try await eventually("initial portrait orientation") {
                requestError != nil || (scene.interfaceOrientation == orientation && !controller.isRotating)
            }
            try #require(requestError == nil)
        }
        try await Task.sleep(for: .milliseconds(200))
    }

    private func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        orientation == .portrait ? .portrait : .landscapeRight
    }

    private func findSurface(in view: UIView) -> MPVPlatformVideoPlayer? {
        if let surface = view as? MPVPlatformVideoPlayer {
            return surface
        }
        return view.subviews.lazy.compactMap { findSurface(in: $0) }.first
    }
}

@MainActor
private final class OrientationHostingController: UIViewController {
    private let content: UIViewController
    var transitionCount = 0
    var transitionDuration: TimeInterval = 0
    var isRotating = false

    init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .allButUpsideDown
    }

    override func loadView() {
        view = UIView()
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: view.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        content.didMove(toParent: self)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        transitionCount += 1
        transitionDuration = coordinator.transitionDuration
        isRotating = true
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.isRotating = false
        }
    }
}
#endif
