#if os(Android)
import Foundation
import MPVCore
import MPVCoreAndroid
import Observation
import SkipFuse
import SwiftUI

/// Bridges observation and Android services around the shared native session.
@MainActor
@dynamicMemberLookup
final class AndroidPlayer: Observable {

    let controller: MPVSessionController
    let bridge: AndroidPlayerBridge
    let pictureInPicture: MPVPictureInPictureController
    let surfaceID = UUID().uuidString
    private let registrar = Observation.ObservationRegistrar()
    private var observed = Set<AnyKeyPath>()

    init(configuration: MPVPlayerConfiguration = .init()) {
        let names = configuration.additionalOptions.keys.sorted()

        bridge = AndroidPlayerBridge(
            automaticallyPlays: configuration.automaticallyPlays,
            isLoopingEnabled: configuration.isLoopingEnabled,
            rate: configuration.playbackRate,
            volume: configuration.volume,
            start: configuration.startTime?.seconds ?? 0,
            hasStart: configuration.startTime != nil,
            buffer: configuration.initialBufferDuration.seconds,
            cache: configuration.networkCacheDuration.seconds,
            optionNames: names,
            optionValues: names.map { configuration.additionalOptions[$0]! }
        )

        let session = MPVAndroidSession.consumeRetainedHandle(bridge.retainSession())!
        controller = MPVSessionController(session: session)
        pictureInPicture = MPVPictureInPictureController(bridge: bridge)
    }

    isolated deinit { bridge.close() }

    // The shared controller uses native Observation. Register each consumed key
    // with Skip's registrar as well, preserving selective Compose invalidation.
    subscript<Value: Equatable>(dynamicMember path: KeyPath<MPVSessionController, Value>) -> Value {
        registrar.access(self, keyPath: \.[dynamicMember: path])

        if observed.insert(path).inserted {
            observe(path)
        }

        return controller[keyPath: path]
    }

    func load(_ url: URL, playAutomatically: Bool? = nil, startTime: Duration? = nil) {
        controller.load(
            url,
            playAutomatically: bridge.prepareLoad(playAutomatically ?? controller.configuration.automaticallyPlays),
            startTime: startTime
        )
    }

    func play() {
        if bridge.requestAudioFocus() {
            controller.play()
        }
    }

    func pause() {
        bridge.cancelAudioResume()
        controller.pause()
    }

    func togglePlayback() {
        if controller.isPaused || controller.state == .ended {
            play()
        } else {
            pause()
        }
    }

    func seek(to time: Duration) {
        controller.seek(to: time)
    }

    func seek(by time: Duration) {
        controller.seek(by: time)
    }

    func selectTrack(_ id: MPVMediaTrackIdentifier) {
        controller.selectTrack(id)
    }

    func selectSubtitle(_ id: MPVMediaTrackIdentifier?, for role: MPVSubtitleRole = .primary) {
        controller.selectSubtitle(id, for: role)
    }

    func clearLastError() {
        controller.clearLastError()
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        controller.setDiagnosticsEnabled(enabled)
    }

    private func observe(_ path: KeyPath<MPVSessionController, some Equatable>) {
        let invalidate: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }

            self.registrar.withMutation(of: self, keyPath: \.[dynamicMember: path]) {}
            self.observe(path)
        }

        withObservationTracking { _ = controller[keyPath: path] } onChange: {
            Task { await invalidate() }
        }
    }
}

@MainActor
@Observable
final class MPVPictureInPictureController {

    private(set) var isSupported = false
    private(set) var isPossible = false
    private(set) var isActive = false
    private(set) var isTransitioning = false
    private(set) var lastError: MPVPlayerError?

    @ObservationIgnored
    private let bridge: AndroidPlayerBridge

    init(bridge: AndroidPlayerBridge) {
        self.bridge = bridge

        bridge.observePictureInPicture { [weak self] supported, possible, active, transitioning, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                self.isSupported = supported
                self.isPossible = possible
                self.isActive = active
                self.isTransitioning = transitioning
                self.lastError = error.map { .playbackFailed(code: 0, message: $0) }
            }
        }
    }

    func start() {
        bridge.startPictureInPicture()
    }

    func clearLastError() {
        bridge.clearPictureInPictureError()
    }
}

/// Retains the Compose host while the native video surface enters or leaves.
struct MPVVideoPlayer: View {

    let player: MPVPlayer
    let showsVideoSurface: Bool

    var body: some View {
        ComposeView { PlayerComposer(bridge: player.bridge, showsVideoSurface: showsVideoSurface) }
            .androidCompositionBoundary(id: player.surfaceID, inputs: showsVideoSurface ? "video" : "audio")
    }
}
#endif

#if SKIP
import SwiftUI

struct PlayerComposer {

    let bridge: AndroidPlayerBridge
    let showsVideoSurface: Bool
}

extension PlayerComposer: ContentComposer {

    @Composable
    func Compose(context: ComposeContext) {
        bridge.core.Content(modifier: context.modifier, showSurface: showsVideoSurface)
    }
}
#endif
