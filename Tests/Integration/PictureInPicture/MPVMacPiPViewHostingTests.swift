#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
@testable import MPVUI
import Observation
import SwiftUI
import Testing

@Suite(.tags(.integration, .pictureInPicture), .serialized)
struct MPVMacPiPViewHostingTests {
    @Test @MainActor
    func `reparent preserves inline constraints sibling order and metal layer`() {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        let surface = MPVPlatformVideoPlayer(player: player)
        let sourceWindow = makeWindow()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        sourceWindow.contentView = root
        let behind = NSView()
        let ahead = NSView()
        root.addSubview(behind)
        root.addSubview(surface)
        root.addSubview(ahead)
        surface.translatesAutoresizingMaskIntoConstraints = false
        let constraints = [
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            surface.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            surface.widthAnchor.constraint(equalToConstant: 320),
            surface.heightAnchor.constraint(equalToConstant: 180),
        ]
        // These dimensions belong to the view itself. Keeping them active while
        // moving would constrain the PiP host to the inline dimensions.
        NSLayoutConstraint.activate(constraints)
        let overlay = NSView()
        surface.addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        let overlayConstraints = [
            overlay.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: surface.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ]
        NSLayoutConstraint.activate(overlayConstraints)
        root.layoutSubtreeIfNeeded()
        let metalLayer = surface.metalLayer
        let originalFrame = surface.frame
        surface.retainRenderingForPictureInPicture()
        let hosting = MPVMacPiPViewHosting(surface: surface)
        defer {
            hosting.restore()
            surface.releaseRenderingFromPictureInPicture()
            surface.detach()
            sourceWindow.contentView = nil
        }

        #expect(root.subviews.count == 3)
        #expect(root.subviews[0] === behind)
        #expect(root.subviews[1] === hosting.placeholder)
        #expect(root.subviews[2] === ahead)
        #expect(surface.superview === hosting.container)
        #expect(surface.metalLayer === metalLayer)
        #expect(surface.isActiveRenderingSurface)
        #expect(hosting.placeholder.frame == originalFrame)
        #expect(!constraints[0].isActive)
        #expect(!constraints[1].isActive)
        #expect(overlay.superview === surface)
        // swiftformat:disable:next preferKeyPath
        #expect(overlayConstraints.allSatisfy { $0.isActive })

        hosting.container.setFrameSize(NSSize(width: 200, height: 112))
        hosting.container.layoutSubtreeIfNeeded()
        #expect(surface.bounds.size == hosting.container.bounds.size)
        #expect(hosting.restore())
        #expect(surface.superview === root)
        #expect(root.subviews[1] === surface)
        #expect(surface.frame == originalFrame)
        #expect(!surface.translatesAutoresizingMaskIntoConstraints)
        // swiftformat:disable:next preferKeyPath
        #expect(constraints.allSatisfy { $0.isActive })
        #expect(surface.metalLayer === metalLayer)
    }

    @Test @MainActor
    func `window content view restores to its resized placeholder`() {
        let surface = MPVPlatformVideoPlayer(player: MPVPlayer())
        let sourceWindow = makeWindow()
        sourceWindow.contentView = surface
        surface.retainRenderingForPictureInPicture()
        let hosting = MPVMacPiPViewHosting(surface: surface)
        defer {
            hosting.restore()
            surface.releaseRenderingFromPictureInPicture()
            surface.detach()
            sourceWindow.contentView = nil
        }

        #expect(sourceWindow.contentView === hosting.placeholder)
        sourceWindow.setContentSize(NSSize(width: 800, height: 450))
        sourceWindow.contentView?.layoutSubtreeIfNeeded()
        let resizedInlineBounds = hosting.placeholder.bounds
        #expect(hosting.restore())
        #expect(sourceWindow.contentView === surface)
        #expect(surface.bounds == resizedInlineBounds)
        #expect(hosting.restore())
    }

    @Test @MainActor
    func `removing the inline hierarchy leaves the surface safely detached on return`() {
        let surface = MPVPlatformVideoPlayer(player: MPVPlayer())
        let sourceWindow = makeWindow()
        sourceWindow.contentView = surface
        surface.retainRenderingForPictureInPicture()
        let hosting = MPVMacPiPViewHosting(surface: surface)
        sourceWindow.contentView = NSView()

        #expect(!hosting.restore())
        surface.releaseRenderingFromPictureInPicture()
        #expect(surface.window == nil)
        #expect(surface.superview == nil)
        #expect(!surface.isActiveRenderingSurface)
        sourceWindow.contentView = nil
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
}
#endif
