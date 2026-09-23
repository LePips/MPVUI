import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVNativeFailureRecoveryTests {
    @Test
    func `invalid native options report initialization failure without retrying on layout`() async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null", "mpvui-invalid-option": "yes"],
            autoPlay: false,
            videoOutput: .sampleBuffer
        ))
        defer { fixture.close() }
        try await eventually("invalid option is reported") { fixture.player.lastError != nil }
        let failure = try #require(fixture.player.lastError)
        guard case let .initializationFailed(context, _, _) = failure else {
            Issue.record("Expected initialization failure, received \(failure)")
            return
        }
        #expect(context == "Set option mpvui-invalid-option")
        #expect(fixture.player.state == .failed(failure))
        fixture.surface.updateRenderingConfiguration()
        let diagnostics = await fixture.player.lifecycleDiagnostics()
        #expect(diagnostics.handlesCreated == 0)
        #expect(await fixture.player.renderedScreenshotForTesting() == nil)
        #expect(await !fixture.player.seekForPictureInPicture(to: .seconds(1)))
        #expect(await !fixture.player.setPictureInPictureOverlay(nil))
        #expect(fixture.player.lastError == failure)
    }

    @Test
    func `native shutdown retires the client and the next load can recover`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        let before = await fixture.player.lifecycleDiagnostics()
        fixture.player.command("quit")
        try await eventually("native shutdown retires its handle") {
            await fixture.player.lifecycleDiagnostics().handlesDestroyed > before.handlesDestroyed
        }
        // Handle diagnostics and main-actor state arrive through separate queues.
        try await eventually("native shutdown publishes stopped state") {
            fixture.player.state == .stopped
        }
        fixture.surface.detach()
        fixture.surface.activateRenderingSurface()
        try await fixture.loadPaused(at: .seconds(2))
        #expect(fixture.player.lastError == nil)
        #expect(await fixture.player.lifecycleDiagnostics().handlesCreated == before.handlesCreated + 1)
    }
}
