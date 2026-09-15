/// Resolves the configured pipeline separately from the screen's actual output.
struct MPVHDRSurfacePolicy {
    let usesExtendedDynamicRange: Bool
    let dynamicRange: MPVPresentationStatus.DynamicRange
    let fallbackReason: MPVPresentationStatus.FallbackReason?

    init(
        policy: MPVPlayerConfiguration.HDRPolicy,
        native: Bool,
        supportsLayerPolicy: Bool,
        supportsMetalHDR: Bool,
        displaySupportsHDR: Bool,
        sourceIsHDR: Bool
    ) {
        if native {
            usesExtendedDynamicRange = false // AVFoundation owns conversion.
            guard supportsLayerPolicy else {
                dynamicRange = .automatic
                fallbackReason = policy == .automatic ? nil : .unsupportedPolicy
                return
            }
            switch policy {
            case .automatic: dynamicRange = .automatic
            case .disabled: dynamicRange = .sdr
            case .always: dynamicRange = .hdr
            case .constrained: dynamicRange = .constrainedHDR
            }
            fallbackReason = policy != .disabled && !displaySupportsHDR
                && (sourceIsHDR || policy != .automatic)
                ? .displayDoesNotSupportHDR : nil
            return
        }

        let requestsHDR = policy == .always || policy == .constrained
            || (policy == .automatic && sourceIsHDR)
        usesExtendedDynamicRange = requestsHDR && displaySupportsHDR && supportsMetalHDR
        dynamicRange = usesExtendedDynamicRange
            ? (policy == .constrained && supportsLayerPolicy ? .constrainedHDR : .hdr)
            : .sdr
        if requestsHDR && !supportsMetalHDR {
            fallbackReason = .unsupportedPolicy
        } else if requestsHDR && !displaySupportsHDR {
            fallbackReason = .displayDoesNotSupportHDR
        } else if policy == .constrained && !supportsLayerPolicy {
            fallbackReason = .unsupportedPolicy
        } else {
            fallbackReason = nil
        }
    }
}
