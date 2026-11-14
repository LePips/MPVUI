import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVDisplayPreparationTests {

    private final class Target: MPVDisplayMatchingTarget {

        var isMatchingEnabled = true
        var isModeSwitchInProgress = false
        var startsSwitchOnApply = true
        var requests: [MPVDisplayMatchingContent?] = []
        var onChange: (@MainActor () -> Void)?

        var identity: ObjectIdentifier {
            ObjectIdentifier(self)
        }

        func apply(_ content: MPVDisplayMatchingContent?) -> Bool {
            requests.append(content)
            if content != nil, startsSwitchOnApply {
                isModeSwitchInProgress = true
            }
            return true
        }

        func observeChanges(_ onChange: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            self.onChange = onChange
            return { [weak self] in self?.onChange = nil }
        }

        func endSwitch() {
            isModeSwitchInProgress = false
            onChange?()
        }
    }

    #if os(tvOS)
    @Test(arguments: [false, true])
    func `autoplay holds the clock through a delayed HDMI switch`(attachAfterLoad: Bool) async throws {
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"]))
        if attachAfterLoad {
            player.load(TestPaths.baselineMedia)
            try await eventually("video discovered before attaching") { !player.videoTracks.isEmpty }
        }
        let fixture = PlaybackFixture(player: player)
        defer { fixture.close() }
        let target = Target()
        target.startsSwitchOnApply = false
        fixture.surface.displayMatchingTargetOverrideForTesting = target
        if !attachAfterLoad {
            player.load(TestPaths.baselineMedia)
        }

        try await eventually("autoplay submits display criteria") { target.requests.contains { $0 != nil } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!player.isPaused)
        #expect(player.state != .playing && player.position < .milliseconds(100))
        target.isModeSwitchInProgress = true
        target.onChange?()
        try await eventually("switch starts with the decoder ready") { player.isDisplayModeSwitchInProgress && player.isPlaybackReady }
        #expect(player.state != .playing && player.position < .milliseconds(100))
        target.endSwitch()
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.state != .playing && player.position < .milliseconds(100))
        try await eventually("autoplay starts after settling without a play call") {
            player.state == .playing && player.position > .milliseconds(300)
        }
    }

    @Test(arguments: [false, true])
    func `finishing an autoplay switch respects pause and replacement`(replace: Bool) async throws {
        let fixture = PlaybackFixture(configuration: .init(additionalOptions: ["ao": "null"]))
        defer { fixture.close() }
        let player = fixture.player
        let target = Target()
        fixture.surface.displayMatchingTargetOverrideForTesting = target
        player.load(TestPaths.baselineMedia)
        try await eventually("autoplay waits for switch") { player.isDisplayModeSwitchInProgress }
        if replace {
            player.load(TestPaths.baselineMedia, playAutomatically: false)
        } else {
            player.pause()
        }
        target.endSwitch()
        try await eventually("requested pause reaches native playback") { player.isPaused && player.state == .paused }
        try await Task.sleep(for: .milliseconds(650))
        #expect(player.isPaused && player.state == .paused && player.position < .milliseconds(100))
    }

    @Test(arguments: [false, true])
    func `autoplay bypasses the display wait for audio or disabled system matching`(audioOnly: Bool) async throws {
        let fixture = PlaybackFixture(configuration: .init(additionalOptions: ["ao": "null"]))
        defer { fixture.close() }
        let target = Target()
        target.isMatchingEnabled = audioOnly
        fixture.surface.displayMatchingTargetOverrideForTesting = target
        let file = audioOnly ? "audio-pcm-stereo.mka" : "baseline.mp4"
        try fixture.player.load(TestPaths.testMedia(file))

        try await eventually("audio track discovered") { !fixture.player.audioTracks.isEmpty }
        try await eventually("playback advances without display preparation", timeout: .seconds(3)) {
            fixture.player.position > .milliseconds(200)
        }
        #expect(target.requests.compactMap(\.self).isEmpty)
    }
    #endif

    @Test
    func `paused load prepares display and plays only after an explicit request`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        let target = Target()
        fixture.surface.displayMatchingTargetOverrideForTesting = target
        fixture.player.load(TestPaths.baselineMedia, playAutomatically: false)
        let preparation = Task { await fixture.player.prepareDisplayMatching() }
        try await eventually("criteria submitted while paused") {
            target.requests.contains { $0 != nil } && fixture.player.isDisplayModeSwitchInProgress
        }
        #expect(fixture.player.isPaused)
        #expect(fixture.player.position < .milliseconds(200))
        target.endSwitch()
        #expect(await preparation.value == .switchCompleted)
        #expect(fixture.player.isPaused)
        #expect(!fixture.player.isDisplayModeSwitchInProgress)
        #expect(fixture.player.position < .milliseconds(200))

        fixture.player.play()
        try await eventually("play after preparation") {
            fixture.player.state == .playing && fixture.player.position > .milliseconds(300)
        }
        #expect(target.requests.compactMap(\.self).count == 1)
    }

    @Test
    func `preparation timeout leaves paused playback recoverable`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        let target = Target()
        fixture.surface.displayMatchingTargetOverrideForTesting = target
        fixture.player.load(TestPaths.baselineMedia, playAutomatically: false)
        try await eventually("initial paused frame") { fixture.player.isPlaybackReady }
        #expect(await fixture.player.prepareDisplayMatching(timeout: .milliseconds(20)) == .timedOut)
        #expect(fixture.player.isPaused)
        target.endSwitch()
        fixture.player.play()
        try await eventually("play after timeout") { fixture.player.position > .milliseconds(300) }
    }

    @Test
    func `settled replacement surface releases the previous display pause`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        let switching = Target()
        fixture.surface.displayMatchingTargetOverrideForTesting = switching
        fixture.player.load(TestPaths.baselineMedia, playAutomatically: false)
        let preparation = Task { await fixture.player.prepareDisplayMatching() }
        defer { preparation.cancel() }
        try await eventually("original surface holds the display pause") {
            fixture.player.isDisplayModeSwitchInProgress
        }

        let successor = PlaybackFixture(player: fixture.player)
        defer { successor.close() }
        let settled = Target()
        settled.startsSwitchOnApply = false
        successor.surface.displayMatchingTargetOverrideForTesting = settled
        successor.surface.updateRenderingConfiguration()
        #expect(!fixture.player.isDisplayModeSwitchInProgress)

        fixture.player.play()
        try await eventually("replacement surface permits playback") {
            fixture.player.position > .milliseconds(300)
        }
    }

    @Test
    func `disabled and missing routes finish without waiting`() async {
        let player = MPVPlayer(configuration: .init(displayMatching: .disabled))
        #expect(await player.prepareDisplayMatching() == .disabled)
        let unattached = MPVPlayer()
        #expect(await unattached.prepareDisplayMatching() == .unavailable)
    }
}
