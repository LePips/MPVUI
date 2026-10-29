/// Features whose implementation depends on the current item and renderer.
public enum MPVVideoFeature: String, CaseIterable, Hashable, Sendable {

    /// ASS/SSA and bitmap subtitles composed by mpv into the video frame.
    /// - Note: Unavailable for native Dolby Vision sample buffers.
    case nativeSubtitles
    /// Graphics rasterized into the video sample, including iOS PiP overlays.
    /// - Note: Unavailable for native Dolby Vision sample buffers.
    case bakedOverlays
    /// Scaling and repositioning video content within the output frame.
    /// - Note: Unavailable for native Dolby Vision sample buffers.
    case zoomAndPan
    /// App UI placed above the inline video. It does not modify decoder pixels.
    case inlineOverlays
    /// App-provided subtitle overlays carried into PiP. Native ASS/bitmap
    /// composition remains separately described by `nativeSubtitles`.
    case pictureInPictureSubtitles
}

/// Capabilities for composing video features on the current renderer.
///
/// Platform picture-in-picture readiness is separate. On Apple platforms, consult
/// `player.pictureInPicture.isSupported` and `isPossible` for device and session state.
public struct MPVVideoFeatureCapabilities: Equatable, Sendable {

    /// Whether the current item and renderer support a feature.
    public enum Availability: String, Equatable, Sendable {

        /// The current item and renderer support the feature.
        case available
        /// A known restriction prevents use of the feature.
        case unavailable
        /// There is too little information to determine support.
        case unknown
    }

    /// A condition preventing a video feature from being available.
    public enum Restriction: String, Equatable, Sendable {

        /// Determining support requires video metadata.
        case awaitingVideoMetadata
        /// Modifying native Dolby Vision pixels would invalidate RPU metadata.
        case nativeDolbyVisionPreservesRPU
        /// Android native surfaces cannot compose renderer graphics or filters.
        case nativeSurfaceCompositionUnavailable
        /// Picture in picture requires native sample-buffer output.
        case pictureInPictureRequiresNativeOutput
        /// The platform does not support this picture-in-picture feature.
        case pictureInPictureUnavailableOnPlatform
    }

    /// The availability of one feature and any restriction.
    public struct Capability: Equatable, Sendable {

        static let available = Self(availability: .available, restriction: nil)
        /// Whether this feature is available.
        public let availability: Availability
        /// The condition limiting this feature, if any.
        public let restriction: Restriction?
    }

    /// The renderer used to evaluate these capabilities.
    public let backend: MPVVideoOutput
    /// Support for subtitles composed by mpv into video frames.
    public let nativeSubtitles: Capability
    /// Support for graphics rasterized into video samples.
    public let bakedOverlays: Capability
    /// Support for scaling and repositioning video content.
    public let zoomAndPan: Capability
    /// Support for SwiftUI content above the inline video.
    public let inlineOverlays: Capability
    /// Support for app-provided subtitle overlays in picture in picture.
    public let pictureInPictureSubtitles: Capability

    package init(
        backend: MPVVideoOutput,
        dolbyVision: MPVDolbyVisionStatus,
        hasVideo: Bool,
        pictureInPictureRequiresNativeOutput: Bool,
        supportsPictureInPicture: Bool
    ) {
        self.backend = backend

        let modifiesNativeDolbyVision = backend == .sampleBuffer
            && (dolbyVision.sourceProfile != nil || dolbyVision.nativeValidation == .validated)

        let videoCapability: Capability = if modifiesNativeDolbyVision {
            Capability(availability: .unavailable, restriction: .nativeDolbyVisionPreservesRPU)
        } else if backend == .nativeSurface, hasVideo {
            Capability(availability: .unavailable, restriction: .nativeSurfaceCompositionUnavailable)
        } else if !hasVideo {
            Capability(availability: .unknown, restriction: .awaitingVideoMetadata)
        } else {
            .available
        }
        nativeSubtitles = videoCapability
        bakedOverlays = videoCapability
        zoomAndPan = videoCapability
        inlineOverlays = .available

        if !supportsPictureInPicture {
            pictureInPictureSubtitles = Capability(availability: .unavailable, restriction: .pictureInPictureUnavailableOnPlatform)
        } else if pictureInPictureRequiresNativeOutput && backend != .sampleBuffer {
            pictureInPictureSubtitles = Capability(availability: .unavailable, restriction: .pictureInPictureRequiresNativeOutput)
        } else if pictureInPictureRequiresNativeOutput {
            pictureInPictureSubtitles = videoCapability
        } else {
            // macOS PiP can carry the view and inline app overlays. This does
            // not mean ASS can be baked into an untouched native DV frame.
            pictureInPictureSubtitles = .available
        }
    }

    /// Returns the capability for the specified video feature.
    public subscript(feature: MPVVideoFeature) -> Capability {
        switch feature {
        case .nativeSubtitles: nativeSubtitles
        case .bakedOverlays: bakedOverlays
        case .zoomAndPan: zoomAndPan
        case .inlineOverlays: inlineOverlays
        case .pictureInPictureSubtitles: pictureInPictureSubtitles
        }
    }
}

/// The concrete effect of requesting features for the current item.
public struct MPVVideoFeatureRequestResult: Equatable, Sendable {

    /// The action taken or required to satisfy a feature request.
    public enum Outcome: String, Equatable, Sendable {

        /// The requested features are available on the current renderer.
        case available
        /// The request is waiting for video metadata.
        case awaitingVideoMetadata
        /// The selected renderer cannot provide the requested features.
        case unavailable
    }

    /// The result of the feature request.
    public let outcome: Outcome
    /// The features requested by the caller.
    public let requestedFeatures: Set<MPVVideoFeature>
    /// Requested features unavailable on the evaluated renderer.
    public let unavailableFeatures: Set<MPVVideoFeature>
    /// An explanation of the request outcome, if available.
    public let reason: String?

    /// Creates a feature request result for the active renderer.
    public init(
        outcome: Outcome,
        requestedFeatures: Set<MPVVideoFeature>,
        unavailableFeatures: Set<MPVVideoFeature>,
        reason: String? = nil
    ) {
        self.outcome = outcome
        self.requestedFeatures = requestedFeatures
        self.unavailableFeatures = unavailableFeatures
        self.reason = reason
    }
}

public extension MPVVideoFeatureCapabilities {

    /// Returns the result of evaluating a request against the current renderer capabilities.
    /// Evaluating a request does not enable features or change the renderer.
    func requestResult(for features: Set<MPVVideoFeature>) -> MPVVideoFeatureRequestResult {
        let unavailable = Set(features.filter { self[$0].availability == .unavailable })
        let unknown = features.contains { self[$0].availability == .unknown }
        let outcome: MPVVideoFeatureRequestResult.Outcome
        let reason: String?

        if !unavailable.isEmpty {
            outcome = .unavailable

            if unavailable.contains(where: { self[$0].restriction == .nativeDolbyVisionPreservesRPU }) {
                reason = "Native Dolby Vision preserves unmodified RPU frames; baked subtitles, overlays, and geometry are unavailable."
            } else if unavailable.contains(where: { self[$0].restriction == .nativeSurfaceCompositionUnavailable }) {
                reason = "Native surfaces cannot compose subtitles, baked overlays, or video geometry changes."
            } else {
                reason = "The requested picture-in-picture feature is unavailable on this platform or backend."
            }
        } else if unknown {
            outcome = .awaitingVideoMetadata
            reason = "Video metadata is not yet available."
        } else {
            outcome = .available
            reason = nil
        }

        return .init(outcome: outcome, requestedFeatures: features, unavailableFeatures: unavailable, reason: reason)
    }
}
