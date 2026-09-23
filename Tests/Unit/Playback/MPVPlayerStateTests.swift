import Foundation
import Libmpv
@testable import MPVUI
import Observation
import Testing

#if os(iOS) || os(tvOS)
import UIKit
#endif

@Suite(.tags(.unit), .serialized)
struct MPVPlayerStateTests {
    @MainActor
    @Test
    func `player state uses observation`() async {
        let player = MPVPlayer(configuration: .init(volume: 42))

        await confirmation("Volume change is observed") { change in
            withObservationTracking {
                _ = player.volume
            } onChange: {
                change()
            }

            player.setVolume(24)
        }
    }

    @MainActor
    @Test
    func `player reflects configuration before surface attachment`() {
        let configuration = MPVPlayerConfiguration(
            autoPlay: false,
            hdrPolicy: .disabled,
            playbackRate: 1.5,
            volume: 42
        )
        let player = MPVPlayer(configuration: configuration)

        #expect((player.configuration) == configuration)
        #expect((player.state) == .idle)
        #expect((player.volume) == 42)
        #expect((player.playbackRate) == 1.5)
        #expect(!(player.isMuted))
        #expect((player.bufferStatus) == .empty)
        #expect((player.mediaInformation) == .empty)
    }

    @MainActor
    @Test
    func `load can be queued before surface attachment`() throws {
        let url = try #require(URL(string: "https://media.example/movie.mkv"))
        let player = MPVPlayer(configuration: .init(startTime: .seconds(12)))

        player.load(url)

        #expect((player.state) == .loading)
        #expect((player.position) == .seconds(12))
        #expect((player.duration) == .zero)
        #expect(!(player.isSeekable))
        #expect((player.mediaInformation.sourceURL) == url)
        #expect((player.bufferStatus) == .empty)

        player.load(url, startTime: .seconds(-5))
        #expect((player.position) == .zero)
    }

    @MainActor
    @Test
    func `raw property escape hatch protects typed state`() async {
        let player = MPVPlayer(configuration: .init(volume: 42))

        player.setProperty("sub-scale", to: "1.2")
        await Task.yield()
        #expect((player.lastError) == nil)

        player.setProperty(" volume ", to: "0")
        for _ in 0 ..< 20 {
            if player.lastError != nil {
                break
            }
            await Task.yield()
        }

        #expect((player.volume) == 42)
        #expect(player.lastError == .reservedProperty(name: "volume"))
        #expect(
            (player.lastError?.localizedDescription)
                == "The mpv property 'volume' is managed by MPVUI."
        )
    }

    @MainActor
    @Test
    func `command errors preserve native code and context without failing playback`() async throws {
        let player = MPVPlayer()
        player.command("seek", arguments: ["10"])

        for _ in 0 ..< 100 {
            if player.lastError != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let error = try #require(player.lastError)
        guard case let .commandFailed(context, code, message) = error else {
            Issue.record("Expected a command error, got \(error)")
            return
        }
        #expect(context == "seek")
        #expect(code == MPV_ERROR_UNINITIALIZED.rawValue)
        #expect(message == String(cString: mpv_error_string(code)))
        #expect(player.state == .idle)

        player.clearLastError()
        #expect(player.lastError == nil)
    }

    @MainActor
    @Test
    func `most recently activated render surface owns player`() {
        let player = MPVPlayer()
        let first = UUID()
        let second = UUID()

        #expect(!(player.hasActiveRenderSurface))
        player.activateRenderSurface(token: first)
        #expect(player.hasActiveRenderSurface)
        #expect(player.isRenderSurfaceActive(token: first))

        player.activateRenderSurface(token: second)
        #expect(!(player.isRenderSurfaceActive(token: first)))
        #expect(player.isRenderSurfaceActive(token: second))

        player.detachRenderTarget(token: first, layerAddress: 1)
        #expect(player.hasActiveRenderSurface)
        player.detachRenderTarget(token: second, layerAddress: 2)
        #expect(!(player.hasActiveRenderSurface))
    }
}
