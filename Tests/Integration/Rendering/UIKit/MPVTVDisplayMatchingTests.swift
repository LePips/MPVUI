#if os(tvOS)
import AVFoundation
import AVKit
import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration, .hdr), .serialized)
@MainActor
struct MPVTVDisplayMatchingTests {
    private final class DisplayManager: NSObject, MPVAVDisplayManaging {
        var matchingEnabled = true
        var switching = false
        var assignments: [AVDisplayCriteria?] = []
        var isDisplayCriteriaMatchingEnabled: Bool {
            matchingEnabled
        }

        var isDisplayModeSwitchInProgress: Bool {
            switching
        }

        var preferredDisplayCriteria: AVDisplayCriteria? {
            get { assignments.last ?? nil }
            set { assignments.append(newValue) }
        }
    }

    private func update(
        _ coordinator: MPVDisplayMatchingCoordinator,
        manager: any MPVAVDisplayManaging,
        fps: Double = 24000.0 / 1001,
        state: MPVPlaybackState = .playing,
        dolbyVision: MPVDolbyVisionStatus = .unknown
    ) {
        coordinator.update(
            target: MPVTVDisplayMatchingTarget(manager: manager),
            media: .init(
                videoCodec: "hevc", dimensions: .init(width: 3840, height: 1606),
                framesPerSecond: fps,
                hdr: .init(source: .init(
                    primaries: "bt.2020", transferFunction: .pq,
                    dolbyVisionProfile: 8, dolbyVisionLevel: 6,
                    dolbyVisionBaseLayerCompatibilityID: 1
                ))
            ),
            mediaGeneration: 1, state: state, isActive: true, outputUsesHDR: true,
            videoOutput: .sampleBuffer, dolbyVisionStatus: dolbyVision
        )
    }

    @Test
    func `frame rate and late Dolby validation reach the actual criteria setter`() throws {
        let manager = DisplayManager()
        let coordinator = MPVDisplayMatchingCoordinator()
        defer { coordinator.detach() }
        update(coordinator, manager: manager)
        #expect(manager.assignments.count == 1)
        let first = try #require(manager.preferredDisplayCriteria)
        update(coordinator, manager: manager, state: .seeking)
        update(coordinator, manager: manager, state: .paused)
        #expect(manager.assignments.count == 1)
        update(coordinator, manager: manager, fps: 24)
        #expect(manager.assignments.count == 2)
        #expect(manager.preferredDisplayCriteria !== first)
        update(coordinator, manager: manager, fps: 24, dolbyVision: .init(
            effectiveProfile: 8, effectiveBaseLayerCompatibilityID: 1, nativeValidation: .validated
        ))
        #expect(manager.assignments.count == 3)
        coordinator.detach()
        #expect(manager.preferredDisplayCriteria == nil)
        #expect(manager.assignments.count == 4)
    }

    @Test
    func `mode switch and settings notifications resume deferred matching`() {
        let manager = DisplayManager()
        let coordinator = MPVDisplayMatchingCoordinator()
        var switches: [Bool] = []
        coordinator.displayModeSwitchDidChange = { switches.append($0) }
        defer { coordinator.detach() }
        update(coordinator, manager: manager)
        manager.switching = true
        NotificationCenter.default.post(name: .AVDisplayManagerModeSwitchStart, object: manager)
        update(coordinator, manager: manager, fps: 60)
        #expect(manager.assignments.count == 1)
        #expect(switches == [true])
        manager.switching = false
        NotificationCenter.default.post(name: .AVDisplayManagerModeSwitchEnd, object: manager)
        #expect(manager.assignments.count == 2)
        #expect(switches == [true, false])
        manager.matchingEnabled = false
        NotificationCenter.default.post(name: .AVDisplayManagerModeSwitchSettingsChanged, object: manager)
        #expect(manager.preferredDisplayCriteria == nil)
        manager.matchingEnabled = true
        NotificationCenter.default.post(name: .AVDisplayManagerModeSwitchSettingsChanged, object: manager)
        #expect(manager.preferredDisplayCriteria != nil)
        #expect(manager.assignments.count == 4)
    }

    @Test
    func `surface handoff retains criteria until the current owner stops`() {
        let manager = DisplayManager()
        let old = MPVDisplayMatchingCoordinator()
        let current = MPVDisplayMatchingCoordinator()
        defer { old.detach()
            current.detach()
        }
        update(old, manager: manager)
        update(current, manager: manager)
        old.detach()
        #expect(manager.assignments.count == 1)
        #expect(manager.preferredDisplayCriteria != nil)
        update(current, manager: manager, state: .stopped)
        #expect(manager.assignments.count == 2)
        #expect(manager.preferredDisplayCriteria == nil)
    }
}
#endif
