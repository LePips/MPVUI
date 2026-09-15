import Dispatch
import Foundation

/// Owns the libmpv handle and confines all client API access to one queue.
///
/// The wakeup callback only schedules a drain, as required by libmpv. Event
/// values are copied into Swift models before the next call to
/// `mpv_wait_event` invalidates them.
///
/// Responsibilities live in the `MPVEngine+…` extensions. Shared implementation
/// members are internal for cross-file access; mutable state remains isolated
/// to `queue` across all of those files.
final class MPVEngine: @unchecked Sendable {
    typealias Sink = @MainActor @Sendable (MPVEngineEmission) -> Void

    // MARK: - Queue and update delivery

    let queue = DispatchQueue(label: "com.lepips.MPVUI.engine", qos: .userInitiated)
    let queueKey = DispatchSpecificKey<UInt8>()
    let queueValue: UInt8 = 1
    let configuration: MPVPlayerConfiguration
    let updateContinuation: AsyncStream<MPVEngineEmission>.Continuation
    private let updateDeliveryTask: Task<Void, Never>
    lazy var wakeupContext = WeakBox(self)

    // MARK: - Handle and rendering state

    var handle: OpaquePointer?
    var videoOutput: MPVPlayerConfiguration.VideoOutput
    var didRequestNativeOutputFallback = false
    var currentGeneration: UInt64 = 0
    var renderTarget: MPVRenderTarget?
    var outputHeadroom: Double = 1
    var presentationFallbackReason: MPVPresentationStatus.FallbackReason?
    var liveConfigurationFailure: String?

    // MARK: - Source and playback state

    var sourceURL: URL?
    var pendingStartTime: Duration?
    var pendingSeekAfterLoad: Duration?
    var needsSourceLoad = false
    var shouldAutoPlay: Bool
    var isDisplaySwitchInProgress = false
    var securityScopedURL: URL?
    var externalTracks: [ExternalTrack] = []
    var pendingExternalTracks: [ExternalTrack] = []
    var externalSecurityScopedURLs: Set<URL> = []
    var desiredProperties: [String: String]
    var isLoading = false
    var isFileLoaded = false
    var isPaused = false
    var isSeeking = false
    var isPausedForCache = false
    var isIdle = true
    var didReachEnd = false
    var hasPlaybackStarted = false
    var playbackRequestIsActive = false
    var requestedPlaylistEntryID: Int64?
    var activePlaylistEntryID: Int64?
    var fatalPlaybackError: MPVPlayerError?

    // MARK: - Published state

    var lastPosition: Duration = .zero
    var lastDuration: Duration = .zero
    var lastSeekable = false
    var lastState: MPVPlaybackState = .idle

    // MARK: - Text subtitles

    var lastTextSubtitleSnapshot = TextSubtitleSnapshot()
    var isTextSubtitleInterceptionEnabled = false
    var nextSubtitleQueryID: UInt64 = 1
    var subtitleQueries: [UInt64: SubtitleQuery] = [:]

    // MARK: - Picture in picture

    var pendingPiPSeek: PiPSeek?

    // MARK: - Diagnostics and color updates

    var lifecycleDiagnostics = MPVEngineLifecycleDiagnostics()
    var diagnosticsTimer: DispatchSourceTimer?
    var playbackDiagnostics = MPVPlaybackDiagnostics()
    var renderingResolution: MPVRenderingOptions.Resolution?
    var requestedLoadUptime: UInt64?
    var seekUptime: UInt64?
    var dolbyVisionResolver: MPVDolbyVisionStatusResolver
    var colorUpdateLayerAddress: Int64?
    var colorUpdateHasNativeFence = false
    var videoToolboxSessionUsesHardware: Bool?

    // MARK: - Initialization and teardown

    init(configuration: MPVPlayerConfiguration, sink: @escaping Sink) {
        self.configuration = configuration
        dolbyVisionResolver = MPVDolbyVisionStatusResolver(policy: configuration.dolbyVisionPolicy)
        videoOutput = configuration.videoOutput
        // This unified stream carries state and errors as well as diagnostics;
        // it must remain lossless. If logging needs backpressure in the future,
        // move logs to a separately bounded channel with explicit drop reporting.
        let (updates, continuation) = AsyncStream<MPVEngineEmission>.makeStream()
        updateContinuation = continuation
        updateDeliveryTask = Task { @MainActor in
            for await update in updates {
                sink(update)
            }
        }
        shouldAutoPlay = configuration.autoPlay
        pendingStartTime = configuration.startTime
        desiredProperties = [
            "volume": Self.format(configuration.volume),
            "mute": "no",
            "speed": Self.format(configuration.playbackRate),
        ]
        queue.setSpecific(key: queueKey, value: queueValue)
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            destroyHandle(preservePlayback: false)
        } else {
            queue.sync {
                destroyHandle(preservePlayback: false)
            }
        }
        updateContinuation.finish()
        updateDeliveryTask.cancel()
    }
}
