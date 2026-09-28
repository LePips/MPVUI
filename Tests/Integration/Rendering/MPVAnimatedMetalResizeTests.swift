import CoreGraphics
@testable import MPVUI
import QuartzCore
import Testing
#if os(macOS)
import AppKit
import SwiftUI
#endif

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVAnimatedMetalResizeTests {
    #if os(macOS)
    @Test
    func `SwiftUI sidebar animation updates the intermediate video viewport`() async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"], autoPlay: false,
            hardwareDecoding: .disabled, hdrPolicy: .disabled,
            sdrOutput: .compatibility8Bit, videoOutput: .metal
        ))
        defer { fixture.close() }
        fixture.surface.detach()
        let model = ResizeSidebarModel()
        let hosting = NSHostingView(rootView: GeometryReader { geometry in
            HStack(spacing: 0) {
                MPVVideoPlayer(player: fixture.player)
                Color.gray.frame(width: geometry.size.width * model.fraction)
            }
        })
        fixture.window.contentView = hosting
        fixture.window.setContentSize(CGSize(width: 800, height: 450))
        hosting.layoutSubtreeIfNeeded()
        func findSurface(_ view: NSView) -> MPVPlatformVideoPlayer? {
            if let surface = view as? MPVPlatformVideoPlayer {
                return surface
            }
            return view.subviews.lazy.compactMap(findSurface).first
        }
        try await eventually("SwiftUI player is attached") { findSurface(hosting) != nil }
        let surface = try #require(findSurface(hosting))
        surface.activateRenderingSurface()
        try await fixture.loadPaused()
        let layer = surface.metalLayer
        for fraction in [0.45, 0.0] {
            let initialDrawable = layer.drawableSize
            withAnimation(.easeInOut(duration: 0.8)) { model.fraction = fraction }
            var viewWidths: Set<Int> = []
            var viewportWidths: Set<Int> = []
            for _ in 0 ..< 12 {
                try await Task.sleep(for: .milliseconds(40))
                #expect(layer.drawableSize == initialDrawable)
                try viewWidths.insert(Int(#require(layer.presentation()).bounds.width))
                try viewportWidths.insert(Int(#require(surface.resizeDiagnosticSnapshot.committedDrawableSize).width))
            }
            #expect(viewWidths.count > 5)
            #expect(viewportWidths.count > 5, "The rendered aspect ratio must follow SwiftUI's sidebar animation")
            try await eventually("sidebar animation finishes at full resolution") {
                layer.drawableSize == MPVRenderSurfaceConfiguration.drawableSize(for: surface.bounds.size, scale: layer.contentsScale)
                    && !surface.resizeDiagnosticSnapshot.finalCommitRequired
                    && !((layer as? MPVMetalLayer)?.hasGeometryAnimation ?? false)
            }
        }
        #expect(fixture.player.isPaused)
        #expect(fixture.player.lastError == nil)
    }
    #endif

    @Test
    func `animated layout renders intermediate aspect ratios without replacing buffers`() async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"], autoPlay: false,
            hardwareDecoding: .disabled, hdrPolicy: .disabled,
            sdrOutput: .compatibility8Bit, videoOutput: .metal
        ))
        defer { fixture.close() }
        try await fixture.loadPaused()
        let host = fixture.surface.metalLayer
        let initialDrawable = host.drawableSize
        let before = await fixture.player.lifecycleDiagnostics()
        let animation = CABasicAnimation(keyPath: "bounds")
        animation.fromValue = host.bounds
        animation.duration = 0.8
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        #if os(macOS)
        fixture.window.setContentSize(CGSize(width: 600, height: 240))
        fixture.surface.layoutSubtreeIfNeeded()
        #else
        fixture.surface.bounds.size = CGSize(width: 600, height: 240)
        fixture.surface.layoutIfNeeded()
        #endif
        animation.toValue = host.bounds
        host.add(animation, forKey: "resize")
        CATransaction.commit()
        var intermediateWidths: Set<Int> = []
        for _ in 0 ..< 12 {
            try await Task.sleep(for: .milliseconds(40))
            #expect(host.drawableSize == initialDrawable)
            let size = try #require(fixture.surface.resizeDiagnosticSnapshot.committedDrawableSize)
            intermediateWidths.insert(Int(size.width))
        }
        #expect(intermediateWidths.count > 5, "mpv must render the changing presentation aspect ratio")
        let finalSize = MPVRenderSurfaceConfiguration.drawableSize(
            for: fixture.surface.bounds.size, scale: host.contentsScale
        )
        try await eventually("full resolution restored after animation") {
            host.drawableSize == finalSize && !fixture.surface.resizeDiagnosticSnapshot.finalCommitRequired
        }
        let after = await fixture.player.lifecycleDiagnostics()
        #expect(after.surfaceResizeCommands > before.surfaceResizeCommands + 5)
        #expect(after.handlesCreated == before.handlesCreated)
        #expect(after.loadCommands == before.loadCommands)
        #expect(fixture.player.isPaused)
        #expect(fixture.player.lastError == nil)
    }
}

#if os(macOS)
@Observable
@MainActor
private final class ResizeSidebarModel {
    var fraction = 0.0
}
#endif
