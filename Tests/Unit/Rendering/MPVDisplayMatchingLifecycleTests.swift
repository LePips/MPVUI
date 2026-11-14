import Foundation
@testable import MPVCore
@testable import MPVUI
import Synchronization
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
        var startsSwitchOnApply = false
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
    func `deinitialization clears owned criteria observations and the playback pause`() {
        let endpoint = Endpoint()
        var switches: [Bool] = []
        autoreleasepool {
            let coordinator = MPVDisplayMatchingCoordinator()
            coordinator.displayModeSwitchDidChange = { switches.append($0) }
            update(coordinator, endpoint: endpoint)
            endpoint.switching = true
            endpoint.notify()
        }
        #expect(endpoint.observers.isEmpty)
        #expect(endpoint.requests.count == 2)
        #expect(endpoint.requests.last == .some(nil))
        #expect(switches == [true, false])
    }

    @Test
    func `deferred deinitialization cannot clear a successor's criteria`() async throws {
        let endpoint = Endpoint()
        let current = MPVDisplayMatchingCoordinator()
        defer { current.detach() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.main.async {
                let owner = Mutex<MPVDisplayMatchingCoordinator?>(MPVDisplayMatchingCoordinator())
                owner.withLock { update($0!, endpoint: endpoint) }
                let released = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    owner.withLock { $0 = nil }
                    released.signal()
                }
                // Keep this callback synchronous until final release queues
                // cleanup, then give the endpoint to its successor first.
                continuation.resume(with: Result {
                    try #require(released.wait(timeout: .now() + 2) == .success)
                    update(current, endpoint: endpoint, fps: 60)
                })
            }
        }
        try await eventually("retired display owner releases its observation") {
            endpoint.observers.count == 1
        }
        #expect(endpoint.requests.count == 2)
        #expect(endpoint.requests.last??.refreshRate == 60)
        #expect(endpoint.observers.count == 1)
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

    @Test
    func `retired surface cannot release its successor's display pause`() {
        let player = MPVPlayer()
        let old = UUID()
        let current = UUID()
        player.activateRenderSurface(token: old)
        player.setDisplaySwitchInProgress(true, for: old)
        player.activateRenderSurface(token: current)
        player.setDisplaySwitchInProgress(true, for: current)
        player.setDisplaySwitchInProgress(false, for: old)
        #expect(player.isDisplayModeSwitchInProgress)
        player.setDisplaySwitchInProgress(false, for: current)
        #expect(!player.isDisplayModeSwitchInProgress)
    }

    @Test
    func `replacement preparation cancels the preceding wait and retains the current switch`() async throws {
        let endpoint = Endpoint()
        endpoint.startsSwitchOnApply = true
        let coordinator = MPVDisplayMatchingCoordinator(settlingInterval: .milliseconds(10))
        defer { coordinator.detach() }
        update(coordinator, endpoint: endpoint, state: .loading, isPaused: true)
        let first = Task { await coordinator.prepare(timeout: .seconds(3)) }
        try await eventually("first request") { endpoint.requests.count == 1 }
        let second = Task { await coordinator.prepare(timeout: .seconds(3)) }
        #expect(await first.value == .cancelled)
        endpoint.switching = false
        endpoint.notify()
        #expect(await second.value == .switchCompleted)
        #expect(endpoint.requests.count == 1)
    }

    @Test(arguments: [MPVPlaybackState.loading, .buffering])
    func `preparation submits initial criteria before playback starts`(state: MPVPlaybackState) async {
        let endpoint = Endpoint()
        let coordinator = MPVDisplayMatchingCoordinator(settlingInterval: .milliseconds(10))
        defer { coordinator.detach() }
        update(coordinator, endpoint: endpoint, state: state, isPaused: true)
        #expect(endpoint.requests.isEmpty)

        let result = await coordinator.prepare(timeout: .seconds(2))

        #expect(result == .noSwitchObserved)
        #expect(endpoint.requests.count == 1)
        #expect(coordinator.content?.refreshRate == Float(24000.0 / 1001))
        update(coordinator, endpoint: endpoint, state: .paused)
        #expect(endpoint.requests.count == 1)
    }

    @Test
    func `preparation observes a synchronous switch and waits for its end`() async throws {
        let endpoint = Endpoint()
        endpoint.startsSwitchOnApply = true
        let coordinator = MPVDisplayMatchingCoordinator(settlingInterval: .milliseconds(10))
        defer { coordinator.detach() }
        update(coordinator, endpoint: endpoint, state: .loading, isPaused: true)
        var result: MPVDisplayMatchingPreparationResult?
        let wait = Task { result = await coordinator.prepare(timeout: .seconds(2)) }
        try await eventually("initial display switch") { coordinator.isDisplayModeSwitchInProgress }
        #expect(result == nil)
        endpoint.switching = false
        endpoint.notify()
        await wait.value
        #expect(result == .switchCompleted)
        #expect(endpoint.requests.count == 1)
    }

    @Test
    func `late metadata and switch notifications restart settling`() async throws {
        let endpoint = Endpoint()
        let coordinator = MPVDisplayMatchingCoordinator(settlingInterval: .milliseconds(100))
        defer { coordinator.detach() }
        update(coordinator, endpoint: endpoint, fps: nil, state: .loading, isPaused: true)
        var result: MPVDisplayMatchingPreparationResult?
        let wait = Task { result = await coordinator.prepare(timeout: .seconds(3)) }
        await Task.yield()
        update(coordinator, endpoint: endpoint, state: .loading, isPaused: true)
        try await eventually("initial criteria") { endpoint.requests.count == 1 }
        endpoint.switching = true
        endpoint.notify()
        update(coordinator, endpoint: endpoint, fps: 60, state: .buffering, isPaused: true)
        #expect(result == nil)
        #expect(endpoint.requests.count == 1)
        let switchEnded = ContinuousClock.now
        endpoint.switching = false
        endpoint.notify()
        await wait.value
        #expect(switchEnded.duration(to: .now) >= .milliseconds(100))
        #expect(result == .switchCompleted)
        #expect(endpoint.requests.count == 2)
        #expect(coordinator.content?.refreshRate == 60)
    }

    @Test
    func `autoplay settles an observed switch even after its metadata deadline`() async throws {
        let endpoint = Endpoint()
        endpoint.startsSwitchOnApply = true
        let coordinator = MPVDisplayMatchingCoordinator(settlingInterval: .milliseconds(100))
        defer { coordinator.detach() }
        update(coordinator, endpoint: endpoint, state: .loading, isPaused: false)
        let wait = Task { await coordinator.prepare(timeout: .milliseconds(40), forAutoplay: true) }
        try await eventually("switch started") { coordinator.isDisplayModeSwitchInProgress }
        try await Task.sleep(for: .milliseconds(80))
        let switchEnded = ContinuousClock.now
        endpoint.switching = false
        endpoint.notify()
        #expect(await wait.value == .switchCompleted)
        #expect(switchEnded.duration(to: .now) >= .milliseconds(100))
    }

    @Test(arguments: [false, true])
    func `metadata and switch waits have a deadline`(switching: Bool) async {
        let endpoint = Endpoint()
        endpoint.switching = switching
        let coordinator = MPVDisplayMatchingCoordinator()
        defer { coordinator.detach() }
        update(coordinator, endpoint: endpoint, fps: nil, state: .loading, isPaused: true)
        let result = await coordinator.prepare(timeout: .milliseconds(20))
        #expect(result == .timedOut)
        // A timeout reports the observation honestly. It does not fabricate an
        // end notification or change the user's playback intent.
        #expect(coordinator.isDisplayModeSwitchInProgress == switching)
    }

    @Test
    func `disabled unsupported active and rejected requests report their outcome`() async {
        let endpoint = Endpoint()
        let coordinator = MPVDisplayMatchingCoordinator()
        defer { coordinator.detach() }
        #expect(await coordinator.prepare(timeout: .seconds(1)) == .unavailable)
        update(coordinator, endpoint: endpoint)
        #expect(await coordinator.prepare(timeout: .seconds(1)) == .requiresPausedPlayback)
        endpoint.enabled = false
        update(coordinator, endpoint: endpoint, state: .paused)
        #expect(await coordinator.prepare(timeout: .seconds(1)) == .disabled)
        endpoint.enabled = true
        update(coordinator, endpoint: endpoint, fps: 120, playbackRate: 3, state: .loading, isPaused: true)
        #expect(await coordinator.prepare(timeout: .seconds(1)) == .unavailable)
        #expect(coordinator.content == nil)
        endpoint.rejectsContent = true
        update(coordinator, endpoint: endpoint, state: .loading, isPaused: true)
        #expect(await coordinator.prepare(timeout: .seconds(1)) == .unavailable)
        #expect(coordinator.content == nil)
    }

    @Test
    func `task cancellation leaves criteria available for a subsequent wait`() async throws {
        let endpoint = Endpoint()
        endpoint.startsSwitchOnApply = true
        let coordinator = MPVDisplayMatchingCoordinator(settlingInterval: .milliseconds(10))
        defer { coordinator.detach() }
        update(coordinator, endpoint: endpoint, state: .loading, isPaused: true)
        let wait = Task { await coordinator.prepare(timeout: .seconds(3)) }
        try await eventually("criteria before cancellation") { endpoint.requests.count == 1 }
        wait.cancel()
        #expect(await wait.value == .cancelled)
        #expect(coordinator.content != nil)
        endpoint.switching = false
        endpoint.notify()
        #expect(await coordinator.prepare(timeout: .seconds(1)) == .noSwitchObserved)
        #expect(endpoint.requests.count == 1)
    }

    @Test(arguments: ["reload", "stop", "detach", "handoff", "play", "disable"])
    func `lifecycle changes finish outstanding preparation`(change: String) async throws {
        let endpoint = Endpoint()
        endpoint.startsSwitchOnApply = true
        let coordinator = MPVDisplayMatchingCoordinator()
        let successor = MPVDisplayMatchingCoordinator()
        defer { coordinator.detach()
            successor.detach()
        }
        update(coordinator, endpoint: endpoint, state: .loading, isPaused: true)
        let wait = Task { await coordinator.prepare(timeout: .seconds(3)) }
        try await eventually("preparation applies criteria") { endpoint.requests.count == 1 }
        var expected = MPVDisplayMatchingPreparationResult.cancelled
        switch change {
        case "reload": update(coordinator, endpoint: endpoint, state: .loading, isPaused: true, generation: 2)

        case "stop": update(coordinator, endpoint: endpoint, state: .stopped)

        case "detach": coordinator.detach()

        case "handoff": update(successor, endpoint: endpoint, state: .paused)

        case "play":
            update(coordinator, endpoint: endpoint)
            expected = .requiresPausedPlayback

        case "disable":
            endpoint.enabled = false
            endpoint.notify()
            expected = .disabled

        default: Issue.record("Unexpected case")
        }
        #expect(await wait.value == expected)
    }

    private func update(
        _ coordinator: MPVDisplayMatchingCoordinator,
        endpoint: Endpoint?,
        fps: Double? = 23.976,
        playbackRate: Double = 1,
        state: MPVPlaybackState = .playing,
        isPaused: Bool? = nil,
        generation: UInt64 = 1
    ) {
        coordinator.update(
            target: endpoint.map(Target.init),
            media: .init(
                videoCodec: "hevc",
                dimensions: .init(width: 3840, height: 2160),
                framesPerSecond: fps,
                hdr: .init(source: .init(primaries: "bt.2020", transferFunction: .pq))
            ),
            mediaGeneration: generation,
            playbackRate: playbackRate,
            state: state,
            isActive: true,
            outputUsesHDR: true,
            videoOutput: .sampleBuffer,
            dolbyVisionStatus: .unknown,
            isPaused: isPaused
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
        if content != nil, endpoint.startsSwitchOnApply, !endpoint.rejectsContent {
            endpoint.switching = true
        }
        return content == nil || !endpoint.rejectsContent
    }

    func observeChanges(_ onChange: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let id = UUID()
        endpoint.observers[id] = onChange
        return { [weak endpoint] in endpoint?.observers.removeValue(forKey: id) }
    }
}
