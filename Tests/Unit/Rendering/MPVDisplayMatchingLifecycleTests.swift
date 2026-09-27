import Foundation
@testable import MPVUI
import Testing

/// The full coordinator runs on every supported platform; only OS translation
/// belongs in the adapter integration tests.
@Suite(.tags(.unit), .serialized)
@MainActor
struct MPVDisplayMatchingLifecycleTests {
    @MainActor
    private final class Endpoint {
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

    private final class Target: MPVDisplayMatchingTarget {
        let endpoint: Endpoint
        init(_ endpoint: Endpoint) {
            self.endpoint = endpoint
        }

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

    private func update(
        _ coordinator: MPVDisplayMatchingCoordinator,
        endpoint: Endpoint?,
        fps: Double = 23.976,
        state: MPVPlaybackState = .playing
    ) {
        coordinator.update(
            target: endpoint.map(Target.init),
            media: .init(
                videoCodec: "hevc", dimensions: .init(width: 3840, height: 2160),
                framesPerSecond: fps,
                hdr: .init(source: .init(primaries: "bt.2020", transferFunction: .pq))
            ), mediaGeneration: 1, state: state, isActive: true,
            outputUsesHDR: true, videoOutput: .sampleBuffer, dolbyVisionStatus: .unknown
        )
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
}
