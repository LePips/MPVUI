import Foundation

/// Decoder evidence for this item, separate from a requested conversion policy.
/// Unknown fields must not be interpreted as proof of a successful conversion.
public struct MPVDolbyVisionStatus: Equatable, Sendable {
    /// The result of native frame-level Dolby Vision validation.
    public enum NativeValidation: String, Equatable, Sendable {
        /// No native frame validation result is available.
        case unknown
        /// Native frame-level validation succeeded.
        case validated
        /// Native frame-level validation rejected the stream.
        case rejected
    }

    /// The observed state of Profile 7 compatibility conversion.
    public enum Conversion: String, Equatable, Sendable {
        /// Compatibility conversion has not been requested or observed.
        case notRequested
        /// Compatibility conversion is requested but not yet confirmed.
        case pending
        /// Native evidence confirms compatibility conversion.
        case converted
        /// Compatibility conversion could not be completed.
        case unavailable
    }

    /// What is known about the source enhancement layer.
    public enum EnhancementLayer: String, Equatable, Sendable {
        /// Neither MEL/FEL classification nor complete reproduction is established.
        case unknown
        /// Compatibility conversion discarded the source enhancement layer.
        case discarded
    }

    /// The Dolby Vision policy requested for this item.
    public let requestedPolicy: MPVDolbyVisionPolicy
    /// The source Dolby Vision profile, when reported.
    public let sourceProfile: Int?
    /// The source base-layer compatibility identifier, when reported.
    public let sourceBaseLayerCompatibilityID: Int?
    /// Set only from validated native decoder evidence, never from policy alone.
    public let effectiveProfile: Int?
    /// The compatibility identifier established by native validation.
    public let effectiveBaseLayerCompatibilityID: Int?
    /// The native decoder's frame validation result.
    public let nativeValidation: NativeValidation
    /// The observed compatibility conversion state.
    public let conversion: Conversion
    /// The known treatment of the source enhancement layer.
    public let enhancementLayer: EnhancementLayer
    /// A native validation or conversion explanation, if available.
    public let reason: String?

    /// Changing the policy requires decoder recreation and a media reload.
    public var policyChangesRequireReload: Bool {
        true
    }

    /// Why a policy change requires reloading the item.
    public var reloadReason: String {
        "The native Dolby Vision policy is latched when the decoder is created."
    }

    init(
        requestedPolicy: MPVDolbyVisionPolicy = .strict,
        sourceProfile: Int? = nil,
        sourceBaseLayerCompatibilityID: Int? = nil,
        effectiveProfile: Int? = nil,
        effectiveBaseLayerCompatibilityID: Int? = nil,
        nativeValidation: NativeValidation = .unknown,
        conversion: Conversion = .notRequested,
        enhancementLayer: EnhancementLayer = .unknown,
        reason: String? = nil
    ) {
        self.requestedPolicy = requestedPolicy
        self.sourceProfile = sourceProfile
        self.sourceBaseLayerCompatibilityID = sourceBaseLayerCompatibilityID
        self.effectiveProfile = effectiveProfile
        self.effectiveBaseLayerCompatibilityID = effectiveBaseLayerCompatibilityID
        self.nativeValidation = nativeValidation
        self.conversion = conversion
        self.enhancementLayer = enhancementLayer
        self.reason = reason
    }

    /// A status with no native validation or conversion evidence.
    public static let unknown = Self()
}

/// Consumes a renderer sentinel emitted only after frame-level validation.
/// Container profiles cannot establish that native RPU validation succeeded.
struct MPVDolbyVisionStatusResolver {
    private let policy: MPVDolbyVisionPolicy
    private var validation: MPVDolbyVisionStatus.NativeValidation = .unknown
    private var converted = false
    private var reason: String?
    private var observedProfile: Int?
    private var observedCompatibilityID: Int?

    init(policy: MPVDolbyVisionPolicy) {
        self.policy = policy
    }

    mutating func reset() {
        validation = .unknown
        converted = false
        reason = nil
        observedProfile = nil
        observedCompatibilityID = nil
    }

    @discardableResult
    mutating func consume(log: MPVLogMessage) -> Bool {
        if let payload = MPVNativeDiagnosticParser.payload(
            log, sentinel: "MPVUI_NATIVE_DOLBY_VISION_UNSUPPORTED:", allowsDecoder: true
        ) {
            validation = .rejected
            converted = false
            observedProfile = nil
            observedCompatibilityID = nil
            reason = payload
            return true
        }
        guard let payload = MPVNativeDiagnosticParser.payload(log, sentinel: "MPVUI_NATIVE_DOLBY_VISION_VALIDATED:") else { return false }
        let fields = Dictionary(
            payload.split(whereSeparator: \.isWhitespace).compactMap { field -> (String, String)? in
                let parts = field.split(separator: "=", maxSplits: 1)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            },
            uniquingKeysWith: { _, last in last }
        )
        guard let conversion = fields["profile7-to81"], ["yes", "no"].contains(conversion) else { return false }
        // A malformed or unexpected success message must not claim permission
        // to perform a conversion the caller never requested.
        if conversion == "yes", policy != .profile7Compatibility {
            validation = .rejected
            converted = false
            observedProfile = nil
            observedCompatibilityID = nil
            reason = "Native Profile 7 conversion was not explicitly requested."
            return true
        }
        validation = .validated
        converted = conversion == "yes"
        observedProfile = fields["session-profile"].flatMap(Int.init).flatMap { (0 ... 10).contains($0) ? $0 : nil }
        observedCompatibilityID = fields["session-compatibility"].flatMap(Int.init).flatMap { (0 ... 15).contains($0) ? $0 : nil }
        reason = converted ? "Profile 7 compatibility conversion discards the enhancement layer; full FEL reproduction is not provided." :
            nil
        return true
    }

    func status(source: MPVVideoSignal, backend: MPVPlayerConfiguration.VideoOutput) -> MPVDolbyVisionStatus {
        let native = backend == .sampleBuffer
        let accepted = native && validation == .validated
        let didConvert = accepted && converted
        let conversion: MPVDolbyVisionStatus.Conversion = if policy == .strict {
            .notRequested
        } else if didConvert {
            .converted
        } else if source.dolbyVisionProfile == 7 {
            !native || validation == .rejected ? .unavailable : .pending
        } else {
            .notRequested
        }
        return MPVDolbyVisionStatus(
            requestedPolicy: policy,
            sourceProfile: source.dolbyVisionProfile,
            sourceBaseLayerCompatibilityID: source.dolbyVisionBaseLayerCompatibilityID,
            effectiveProfile: accepted ? (didConvert ? 8 : observedProfile ?? source.dolbyVisionProfile) : nil,
            effectiveBaseLayerCompatibilityID: accepted ?
                (didConvert ? 1 : observedCompatibilityID ?? source.dolbyVisionBaseLayerCompatibilityID) : nil,
            nativeValidation: validation,
            conversion: conversion,
            enhancementLayer: didConvert ? .discarded : .unknown,
            reason: reason
        )
    }
}
