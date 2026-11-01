import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

/// The full coordinator runs on every supported platform. Only OS translation
/// belongs in the adapter integration tests.
@Suite(.tags(.unit), .serialized)
@MainActor
struct MPVDisplayMatchingLifecycleTests {

    @MainActor
    fileprivate final class Endpoint {

        var enabled = true
        var switching = false
        var rejectsContent = false
        var requests: [MPVDisplayMatchingContent?] = []
        var observers: [UUID: @MainActor () -> Void] = [:]

        func notify() {
            for observer in Array(observers.values) {
                observer()
            }
        }
    }

    fileprivate final class Target {

        let endpoint: Endpoint

        init(_ endpoint: Endpoint) {
            self.endpoint = endpoint
        }
    }

    @Test
    func `recreated adapters keep endpoint ownership and one subscription`() {
        let endpoint = Endpoint()
        let coordinator = MPVDisplayMatchingCoordinator()
        defer { coordinator.detach() }
        update(coordinator, endpoint: endpoint)
        update(coordinator, endpoint: endpoint, state: .paused)
        update(coordinator, endpoint: endpoint)

        #expect(endpoint.requests.count == 1)
        #expect(endpoint.observers.count == 1)
        #expect(coordinator.content?.refreshRate == Float(24000.0 / 1001))
    }

    @Test
    func `switch and preference events drive the shared lifecycle`() {
        let endpoint = Endpoint()
        let coordinator = MPVDisplayMatchingCoordinator()
        var switches: [Bool] = []
        coordinator.displayModeSwitchDidChange = { switches.append($0) }
        defer { coordinator.detach() }
        update(coordinator, endpoint: endpoint)
        endpoint.switching = true
        endpoint.notify()
        update(coordinator, endpoint: endpoint, fps: 60)

        #expect(endpoint.requests.count == 1)
        endpoint.switching = false
        endpoint.notify()

        #expect(coordinator.content?.refreshRate == 60)
        #expect(switches == [true, false])
        endpoint.enabled = false
        endpoint.notify()

        #expect(coordinator.content == nil)
        endpoint.enabled = true
        endpoint.notify()

        #expect(coordinator.content?.refreshRate == 60)
        #expect(endpoint.requests.count == 4)
    }

    @Test
    func `speed changes update cadence and retain the latest value during a mode switch`() {
        let endpoint = Endpoint()
        let coordinator = MPVDisplayMatchingCoordinator()
        defer { coordinator.detach() }
        update(coordinator, endpoint: endpoint, fps: 24)
        update(coordinator, endpoint: endpoint, fps: 24, playbackRate: 1.5)

        #expect(coordinator.content?.refreshRate == 36)
        #expect(endpoint.requests.count == 2)
        endpoint.switching = true
        endpoint.notify()
        update(coordinator, endpoint: endpoint, fps: 24, playbackRate: 2)
        update(coordinator, endpoint: endpoint, fps: 24, playbackRate: 1)

        #expect(endpoint.requests.count == 2)
        endpoint.switching = false
        endpoint.notify()

        #expect(coordinator.content?.refreshRate == 24)
        #expect(endpoint.requests.count == 3)
    }

    @Test
    func `unsupported speed clears the old hint while missing metadata retains it`() {
        let endpoint = Endpoint()
        let coordinator = MPVDisplayMatchingCoordinator()
        defer { coordinator.detach() }
        update(coordinator, endpoint: endpoint, fps: 120)
        update(coordinator, endpoint: endpoint, fps: nil)

        #expect(coordinator.content?.refreshRate == 120)
        #expect(endpoint.requests.count == 1)
        update(coordinator, endpoint: endpoint, fps: 120, playbackRate: 3)

        #expect(coordinator.content == nil)
        #expect(endpoint.requests.count == 2)
        #expect(endpoint.requests[1] == nil)
        update(coordinator, endpoint: endpoint, fps: 120, playbackRate: 4)

        #expect(endpoint.requests.count == 2)
        update(coordinator, endpoint: endpoint, fps: 120)

        #expect(coordinator.content?.refreshRate == 120)
        #expect(endpoint.requests.count == 3)
    }

    @Test
    func `unsupported cadence waits for an active mode switch to finish`() {
        let endpoint = Endpoint()
        let coordinator = MPVDisplayMatchingCoordinator()
        defer { coordinator.detach() }
        update(coordinator, endpoint: endpoint, fps: 120)
        endpoint.switching = true
        endpoint.notify()
        update(coordinator, endpoint: endpoint, fps: 120, playbackRate: 3)

        #expect(coordinator.content?.refreshRate == 120)
        #expect(endpoint.requests.count == 1)
        endpoint.switching = false
        endpoint.notify()

        #expect(coordinator.content == nil)
        #expect(endpoint.requests.count == 2)
        #expect(endpoint.requests[1] == nil)
    }

    @Test
    func `handoff cancels the old subscription without clearing the successor`() {
        let endpoint = Endpoint()
        let old = MPVDisplayMatchingCoordinator()
        let current = MPVDisplayMatchingCoordinator()

        defer { old.detach()
            current.detach()
        }

        update(old, endpoint: endpoint)
        update(current, endpoint: endpoint)
        old.detach()

        #expect(endpoint.requests.count == 1)
        #expect(endpoint.observers.count == 1)
        update(current, endpoint: endpoint, state: .stopped)

        #expect(current.content == nil)
        #expect(endpoint.requests.count == 2)
        current.detach()

        #expect(endpoint.observers.isEmpty)
    }

    @Test
    func `unsupported or disconnected routes release matching and the playback clock`() {
        let endpoint = Endpoint()
        let coordinator = MPVDisplayMatchingCoordinator()
        var switches: [Bool] = []
        coordinator.displayModeSwitchDidChange = { switches.append($0) }
        update(coordinator, endpoint: endpoint)
        endpoint.switching = true
        endpoint.notify()
        update(coordinator, endpoint: nil)

        #expect(coordinator.content == nil)
        #expect(!coordinator.isDisplayModeSwitchInProgress)
        #expect(switches == [true, false])
        #expect(endpoint.observers.isEmpty)
        #expect(endpoint.requests.count == 2)
        #expect(endpoint.requests[1] == nil)
        endpoint.notify()
        update(coordinator, endpoint: nil)

        #expect(endpoint.requests.count == 2)
    }

    @Test
    func `failed platform translation clears the hint and permits retry`() {
        let endpoint = Endpoint()
        let coordinator = MPVDisplayMatchingCoordinator()
        defer { coordinator.detach() }
        endpoint.rejectsContent = true
        update(coordinator, endpoint: endpoint)

        #expect(coordinator.content == nil)
        #expect(endpoint.requests.count == 2)
        #expect(endpoint.requests[1] == nil)
        endpoint.rejectsContent = false
        update(coordinator, endpoint: endpoint)

        #expect(coordinator.content != nil)
        #expect(endpoint.requests.count == 3)
    }

    private func update(
        _ coordinator: MPVDisplayMatchingCoordinator,
        endpoint: Endpoint?,
        fps: Double? = 23.976,
        playbackRate: Double = 1,
        state: MPVPlaybackState = .playing
    ) {
        coordinator.update(
            target: endpoint.map(Target.init),
            media: .init(
                videoCodec: "hevc",
                dimensions: .init(width: 3840, height: 2160),
                framesPerSecond: fps,
                hdr: .init(source: .init(primaries: "bt.2020", transferFunction: .pq))
            ),
            mediaGeneration: 1,
            playbackRate: playbackRate,
            state: state,
            isActive: true,
            outputUsesHDR: true,
            videoOutput: .sampleBuffer,
            dolbyVisionStatus: .unknown
        )
    }
}

extension MPVDisplayMatchingLifecycleTests.Target: MPVDisplayMatchingTarget {

    var identity: ObjectIdentifier {
        ObjectIdentifier(endpoint)
    }

    var isMatchingEnabled: Bool {
        endpoint.enabled
    }

    var isModeSwitchInProgress: Bool {
        endpoint.switching
    }

    func apply(_ content: MPVDisplayMatchingContent?) -> Bool {
        endpoint.requests.append(content)
        return content == nil || !endpoint.rejectsContent
    }

    func observeChanges(_ onChange: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let id = UUID()
        endpoint.observers[id] = onChange
        return { [weak endpoint] in endpoint?.observers.removeValue(forKey: id) }
    }
}
