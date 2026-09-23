import Foundation
@testable import MPVUI
import Testing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Suite(.tags(.integration, .hdr), .serialized)
@MainActor
struct MPVDisplayNotificationTests {
    @Test
    func `display notifications coalesce into one live color update`() async throws {
        let center = NotificationCenter()
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"],
            autoPlay: false,
            hdrPolicy: .always,
            videoOutput: .metal
        ), notificationCenter: center)
        defer { fixture.close() }
        fixture.surface.edrHeadroomOverrideForTesting = (2, 2)
        fixture.surface.updateRenderingConfiguration()
        try await fixture.loadPaused()
        let before = await fixture.player.lifecycleDiagnostics()
        fixture.surface.edrHeadroomOverrideForTesting = (4, 4)
        #if os(macOS)
        let names = [NSApplication.didChangeScreenParametersNotification, NSScreen.colorSpaceDidChangeNotification]
        #else
        let names = [UIScreen.modeDidChangeNotification, UIScreen.referenceDisplayModeStatusDidChangeNotification]
        #endif
        for name in names {
            center.post(name: name, object: nil)
        }
        try await eventually("display change refreshes the native color target") {
            await fixture.player.lifecycleDiagnostics().liveColorUpdates > before.liveColorUpdates
        }
        let after = await fixture.player.lifecycleDiagnostics()
        #expect(after.liveColorUpdates == before.liveColorUpdates + 1)
        #expect(after.handlesCreated == before.handlesCreated)
        #expect(after.loadCommands == before.loadCommands)
        #expect(fixture.player.lastError == nil)
    }

    #if os(macOS)
    @Test(arguments: [true, false])
    func `fullscreen notifications commit only the owning windows final geometry`(entering: Bool) async throws {
        let center = NotificationCenter()
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"],
            autoPlay: false,
            videoOutput: .metal
        ), notificationCenter: center)
        defer { fixture.close() }
        try await fixture.loadPaused()
        let start = entering ? NSWindow.willEnterFullScreenNotification : NSWindow.willExitFullScreenNotification
        let end = entering ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
        center.post(name: start, object: fixture.window)
        fixture.surface.setFrameSize(CGSize(width: 500, height: 280))
        fixture.surface.layoutSubtreeIfNeeded()
        #expect(fixture.surface.resizeDiagnosticSnapshot.geometryChangeKind == .animatedTransition)
        #expect(fixture.surface.resizeDiagnosticSnapshot.hasAnimatedFallback)
        center.post(name: end, object: NSObject())
        #expect(fixture.surface.resizeDiagnosticSnapshot.hasAnimatedFallback)
        center.post(name: end, object: fixture.window)
        try await eventually("fullscreen completion commits exact drawable geometry") {
            let snapshot = fixture.surface.resizeDiagnosticSnapshot
            return !snapshot.hasAnimatedFallback && snapshot.inFlight == nil
                && snapshot.committedDrawableSize == fixture.surface.metalLayer.drawableSize
        }
        center.post(name: NSWindow.didChangeScreenNotification, object: fixture.window)
        #expect(fixture.surface.isActiveRenderingSurface)
        #expect(fixture.player.lastError == nil)
    }
    #endif
}
