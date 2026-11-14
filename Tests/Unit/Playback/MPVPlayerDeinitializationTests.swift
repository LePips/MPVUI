import Foundation
@testable import MPVUI
import SwiftUI
import Synchronization
import Testing

@Suite(.tags(.unit), .serialized)
@MainActor
struct MPVPlayerDeinitializationTests {

    enum Resource: CaseIterable, Sendable {

        case controllers
        case displayMatching
        case resizing
        case overlay
        case hls
    }

    private enum ReleaseContext {

        @TaskLocal
        static var marker = false
    }

    private final class ReleaseProbe {

        let didRelease: @Sendable (Bool) -> Void

        init(didRelease: @escaping @Sendable (Bool) -> Void) {
            self.didRelease = didRelease
        }

        nonisolated deinit {
            didRelease(Thread.isMainThread)
        }
    }

    @Test
    func `resource values release on main while background ownership retains their storage`() throws {
        let releasedOnMain = Mutex<Bool?>(nil)
        let resource = MPVMainActorResource(wrappedValue: ReleaseProbe { mainThread in
            releasedOnMain.withLock { $0 = mainThread }
        })
        let retained = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            withExtendedLifetime(resource) {
                retained.signal()
                _ = finish.wait(timeout: .now() + 5)
            }
        }
        defer { finish.signal() }
        try #require(retained.wait(timeout: .now() + 2) == .success)

        resource.release()

        #expect(releasedOnMain.withLock { $0 } == true)
    }

    @Test
    func `player released inside task`() {
        #expect(Thread.isMainThread)
        #expect(withUnsafeCurrentTask { $0 != nil })

        ReleaseContext.$marker.withValue(true) {
            expectPlayerReleased()
        }
    }

    @Test
    func `player released on main queue`() async throws {
        try await onMainQueue {
            #expect(!ReleaseContext.marker)
            expectPlayerReleased()
        }
    }

    @Test
    func `player released on main queue with task local`() async throws {
        try await onMainQueue {
            ReleaseContext.$marker.withValue(true) {
                expectPlayerReleased()
            }
        }
    }

    @Test
    func `surface released on main queue with task local`() async throws {
        try await onMainQueue {
            ReleaseContext.$marker.withValue(true) {
                let player = MPVPlayer()
                weak var releasedSurface: MPVPlatformVideoPlayer?

                autoreleasepool {
                    let surface = MPVPlatformVideoPlayer(player: player)
                    releasedSurface = surface
                    #expect(releasedSurface != nil)
                }

                #expect(releasedSurface == nil)
                withExtendedLifetime(player) {}
            }
        }
    }

    @Test(arguments: Resource.allCases)
    func `owned resources release on main queue with task local`(_ resource: Resource) async throws {
        try await onMainQueue {
            try ReleaseContext.$marker.withValue(true) {
                weak var released: AnyObject?
                try autoreleasepool {
                    let object = try makeResource(resource)
                    released = object
                    #expect(released != nil)
                }
                #expect(released == nil)
            }
        }
    }

    @Test
    func `background release retires retained controllers and finishes event streams`() async throws {
        let (events, pictureInPicture) = try await onMainQueue {
            let owner = Mutex<MPVPlayer?>(MPVPlayer())
            weak var releasedPlayer: MPVPlayer?
            releasedPlayer = owner.withLock { $0 }
            let events = owner.withLock { $0!.makeEventStream() }
            let pictureInPicture = owner.withLock { $0!.pictureInPicture }
            _ = owner.withLock { $0!.externalPlayback }
            let released = DispatchSemaphore(value: 0)

            DispatchQueue.global().async {
                #expect(!Thread.isMainThread)
                #expect(withUnsafeCurrentTask { $0 == nil })
                ReleaseContext.$marker.withValue(true) {
                    owner.withLock { $0 = nil }
                }
                released.signal()
            }
            // Keep queued PiP initialization from temporarily retaining the
            // player, so its final release must occur on the background queue.
            try #require(released.wait(timeout: .now() + 2) == .success)
            #expect(releasedPlayer == nil)
            return (events, pictureInPicture)
        }

        var count = 0
        for await _ in events {
            count += 1
        }
        #expect(count == 1)
        #expect(!pictureInPicture.isSupported)
    }

    private func makeResource(_ resource: Resource) throws -> AnyObject {
        switch resource {
        case .controllers:
            let player = MPVPlayer()
            _ = player.externalPlayback
            _ = player.pictureInPicture
            return player

        case .displayMatching:
            return MPVDisplayMatchingCoordinator()

        case .resizing:
            return MPVRenderSurfaceResizeCoordinator(commit: { _ in true })

        case .overlay:
            return MPVVideoOverlayRenderer(content: AnyView(Text("Overlay")), submit: { _ in true }, availabilityChanged: { _ in })

        case .hls:
            return try MPVHLSStream(startTime: .zero)
        }
    }

    private func expectPlayerReleased() {
        weak var releasedPlayer: MPVPlayer?

        autoreleasepool {
            let player = MPVPlayer()
            releasedPlayer = player
            #expect(releasedPlayer != nil)
        }

        #expect(releasedPlayer == nil)
    }

    private func onMainQueue<Value: Sendable>(_ body: @escaping @MainActor @Sendable () throws -> Value) async throws -> Value {
        // Swift Testing runs even synchronous tests inside a task. A dispatch
        // callback exercises UIKit teardown's main-thread, task-free context.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
            DispatchQueue.main.async {
                #expect(Thread.isMainThread)
                #expect(withUnsafeCurrentTask { $0 == nil })
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
