/// Features whose implementation depends on the current item and renderer.
public enum MPVVideoFeature: String, CaseIterable, Hashable, Sendable {
    /// ASS/SSA and bitmap subtitles composed by mpv into the video frame.
    case nativeSubtitles
    /// Graphics rasterized into the video sample, including iOS PiP overlays.
    case bakedOverlays
    /// Scaling and repositioning video content within the output frame.
    case zoomAndPan
    /// App UI placed above the inline video. It does not modify decoder pixels.
    case inlineSwiftUIOverlays
    /// App-provided subtitle overlays carried into PiP. Native ASS/bitmap
    /// composition remains separately described by `nativeSubtitles`.
    case pictureInPictureSubtitles
}

/// Renderer capabilities, not AVKit's current ability to start PiP. Consult
/// `player.pictureInPicture.isSupported` and `isPossible` for device/session state.
public struct MPVVideoFeatureCapabilities: Equatable, Sendable {
    /// Whether a feature can be used with the current item and renderer.
    public enum Availability: String, Equatable, Sendable {
        /// The feature is supported for the current item and renderer.
        case available
        /// A known restriction prevents the feature from being used.
        case unavailable
        /// There is not enough information to determine support.
        case unknown
    }

    /// A condition preventing a video feature from being available.
    public enum Restriction: String, Equatable, Sendable {
        /// Video metadata is needed to determine support.
        case awaitingVideoMetadata
        /// Modifying native Dolby Vision pixels would invalidate RPU metadata.
        case nativeDolbyVisionPreservesRPU
        /// Picture in picture requires native sample-buffer output.
        case pictureInPictureRequiresNativeOutput
        /// The platform does not support this picture-in-picture feature.
        case pictureInPictureUnavailableOnPlatform
    }

    /// The availability of one feature and any restriction.
    public struct Capability: Equatable, Sendable {
        /// Whether this feature is available.
        public let availability: Availability
        /// The condition limiting this feature, if any.
        public let restriction: Restriction?

        static let available = Self(availability: .available, restriction: nil)
    }

    /// The renderer used to evaluate these capabilities.
    public let backend: MPVPlayerConfiguration.VideoOutput
    /// Support for subtitles composed by mpv into video frames.
    public let nativeSubtitles: Capability
    /// Support for graphics rasterized into video samples.
    public let bakedOverlays: Capability
    /// Support for scaling and repositioning video content.
    public let zoomAndPan: Capability
    /// Support for SwiftUI content above the inline video.
    public let inlineSwiftUIOverlays: Capability
    /// Support for app-provided subtitle overlays in picture in picture.
    public let pictureInPictureSubtitles: Capability

    /// Returns the capability for the specified video feature.
    public subscript(feature: MPVVideoFeature) -> Capability {
        switch feature {
        case .nativeSubtitles: nativeSubtitles
        case .bakedOverlays: bakedOverlays
        case .zoomAndPan: zoomAndPan
        case .inlineSwiftUIOverlays: inlineSwiftUIOverlays
        case .pictureInPictureSubtitles: pictureInPictureSubtitles
        }
    }

    init(
        backend: MPVPlayerConfiguration.VideoOutput,
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
        } else if !hasVideo {
            Capability(availability: .unknown, restriction: .awaitingVideoMetadata)
        } else {
            .available
        }
        nativeSubtitles = videoCapability
        bakedOverlays = videoCapability
        zoomAndPan = videoCapability
        inlineSwiftUIOverlays = .available
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
}

/// The concrete effect of requesting features for the current item.
public struct MPVVideoFeatureRequestResult: Equatable, Sendable {
    /// The action taken or required to satisfy a feature request.
    public enum Outcome: String, Equatable, Sendable {
        /// The requested features are available on the current renderer.
        case available
        /// The request is waiting for video metadata.
        case awaitingVideoMetadata
        /// The requested features require a switch to Metal.
        case requiresMetalFallback
        /// The request switched playback to Metal.
        case switchedToMetal
        /// The requested features cannot be provided under the current policy.
        case unavailable
    }

    /// The result of the feature request.
    public let outcome: Outcome
    /// The features requested by the caller.
    public let requestedFeatures: Set<MPVVideoFeature>
    /// Requested features unavailable on the evaluated renderer.
    public let unavailableFeatures: Set<MPVVideoFeature>
    /// A renderer switch reloads the item while preserving position and intent.
    public let requiresReload: Bool
    /// Whether switching renderers removes picture-in-picture support.
    public let losesPictureInPicture: Bool
    /// An explanation of the request outcome, if available.
    public let reason: String?
}
