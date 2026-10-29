import Dispatch
import Foundation

/// A playback session that serializes commands and native events on one queue.
///
/// Send typed commands with ``send(_:)`` and observe copied state through
/// ``snapshot`` or ``makeEventStream()``. Call ``close()`` to release resources
/// permanently. Closed sessions reject further commands.
public final class MPVSession: @unchecked Sendable {

    package typealias Sink = @Sendable (MPVEngineEmission) async -> Void

    /// Normalized immutable settings used by this session.
    public let configuration: MPVSessionConfiguration

    // MARK: - Queue and update delivery

    package var nextOperationID: UInt64 = 1
    package var isClosed = false
    package var latestSnapshot = MPVSessionSnapshot()
    package var observers: [UUID: AsyncStream<MPVSessionEvent>.Continuation] = [:]
    package var nativeObservers: [UUID: @Sendable (MPVSessionEvent) -> Void] = [:]

    package let queue = DispatchQueue(label: "com.lepips.MPVUI.engine", qos: .userInitiated)
    package let queueKey = DispatchSpecificKey<UInt8>()
    package let queueValue: UInt8 = 1
    package let platform: MPVPlatformServices
    package let eventDrainSource: DispatchSourceUserDataAdd
    package let updateContinuation: AsyncStream<MPVEngineEmission>.Continuation
    package lazy var wakeupContext = WeakBox(self)
    package var isCoalescingPropertySnapshots = false
    package var pendingBufferSnapshot = false
    package var pendingMediaSnapshot = false

    // MARK: - Handle and rendering state

    package var handle: OpaquePointer?
    package var videoOutput: MPVSessionConfiguration.VideoOutput
    package var didFallbackFromAndroidNative = false
    package var androidNativeFallbackReason: String?
    package var didRejectNativeOutput = false
    package var currentGeneration: UInt64 = 0
    package var renderTarget: MPVRenderTarget?
    package var outputHeadroom: Double = 1
    package var presentationFallbackReason: MPVPresentationStatus.FallbackReason?
    package var liveConfigurationFailure: String?

    // MARK: - Source and playback state

    package var sourceURL: URL?
    package var pendingStartTime: Duration?
    package var pendingSeekAfterLoad: Duration?
    package var needsSourceLoad = false

    // Held after demuxing, before track selection or decoder creation.
    package var pendingPreloadHookID: UInt64?

    // A stopped player keeps its source and surface for replay without keeping
    // native decoder/renderer allocations alive. Geometry updates cannot restart it.
    package var isStoppedForResourceRelease = false
    package var shouldAutoPlay: Bool
    package var isDisplaySwitchInProgress = false
    package var securityScopedURL: URL?
    package var externalTracks: [ExternalTrack] = []
    package var pendingExternalTracks: [ExternalTrack] = []
    package var externalSecurityScopedURLs: Set<URL> = []
    package var desiredProperties: [String: String]
    package var commandMutatedOptions: Set<String> = []
    package var isLoading = false
    package var isFileLoaded = false
    package var isPaused = false
    package var isSeeking = false
    package var isPausedForCache = false
    package var isIdle = true
    package var didReachEnd = false
    package var hasPlaybackStarted = false
    package var playbackRequestIsActive = false
    package var requestedPlaylistEntryID: Int64?
    package var activePlaylistEntryID: Int64?
    package var fatalPlaybackError: MPVPlayerError?

    // MARK: - Published state

    package var lastPosition: Duration = .zero
    package var lastDuration: Duration = .zero
    package var lastSeekable = false
    package var lastState: MPVPlaybackState = .idle
    package var lastPublishedPaused: Bool?
    package var lastContainerFramesPerSecond: Double?
    package var lastEstimatedFramesPerSecond: Double?

    // MARK: - Text subtitles

    package var lastTextSubtitleSnapshot = TextSubtitleSnapshot()
    package var isTextSubtitleInterceptionEnabled = false
    package var nextSubtitleQueryID: UInt64 = 1
    package var subtitleQueries: [UInt64: SubtitleQuery] = [:]

    // MARK: - Picture in picture

    package var pendingPiPSeek: PiPSeek?

    // MARK: - Diagnostics and color updates

    package var lifecycleDiagnostics = MPVEngineLifecycleDiagnostics()
    package var diagnosticsTimer: DispatchSourceTimer?
    package var isDiagnosticsEnabled = false
    package var renderingOptionsDirty = true
    package var playbackDiagnostics = MPVPlaybackDiagnostics()
    package var renderingResolution: MPVRenderingOptions.Resolution?
    package var requestedLoadUptime: UInt64?
    package var seekUptime: UInt64?
    package var dolbyVisionResolver: MPVDolbyVisionStatusResolver
    package var colorUpdateLayerAddress: Int64?
    package var colorUpdateHasNativeFence = false
    package var videoToolboxSessionUsesHardware: Bool?

    private let updateDeliveryTask: Task<Void, Never>

    // MARK: - Initialization and teardown

    package init(settings configuration: MPVSessionConfiguration, platform: MPVPlatformServices, sink: @escaping Sink) {
        latestSnapshot.volume = configuration.volume
        latestSnapshot.playbackRate = configuration.playbackRate
        latestSnapshot.dolbyVision = .init(requestedPolicy: configuration.dolbyVisionPolicy)
        self.platform = platform
        self.configuration = configuration
        eventDrainSource = DispatchSource.makeUserDataAddSource(queue: queue)
        dolbyVisionResolver = MPVDolbyVisionStatusResolver(policy: configuration.dolbyVisionPolicy)
        videoOutput = configuration.videoOutput == .automaticAndroid ? .gpu : configuration.videoOutput

        // This unified stream carries state and errors as well as diagnostics;
        // it must remain lossless. If logging needs backpressure in the future,
        // move logs to a separately bounded channel with explicit drop reporting.
        let (updates, continuation) = AsyncStream<MPVEngineEmission>.makeStream()
        updateContinuation = continuation

        updateDeliveryTask = Task {
            for await update in updates {
                await sink(update)
            }
        }

        shouldAutoPlay = configuration.automaticallyPlays
        pendingStartTime = configuration.startTime

        desiredProperties = [
            "volume": Self.format(configuration.volume),
            "mute": "no",
            "speed": Self.format(configuration.playbackRate),
        ]

        queue.setSpecific(key: queueKey, value: queueValue)

        eventDrainSource.setEventHandler { [weak self] in
            guard let self else { return }

            self.lifecycleDiagnostics.engineActivity.nativeWakeups &+= Int64(truncatingIfNeeded: self.eventDrainSource.data)
            self.drainEvents()
        }

        eventDrainSource.activate()
    }

    deinit {
        eventDrainSource.cancel()

        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            destroyHandle(preservePlayback: false)
        } else {
            queue.sync {
                destroyHandle(preservePlayback: false)
            }
        }

        for observer in observers.values {
            observer.finish()
        }

        updateContinuation.finish()
        updateDeliveryTask.cancel()
    }
}
