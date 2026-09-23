import CoreGraphics
import Foundation
import Metal

/// Immutable CoreGraphics profiles can be shared with the engine queue.
struct MPVRenderColorConfiguration: @unchecked Sendable, Equatable {

    // MARK: - Boolean options

    let usesExtendedDynamicRange: Bool

    // MARK: - Numeric options

    let outputHeadroom: Double

    // MARK: - Display and color

    let iccIntent: MPVColorManagement.RenderingIntent
    let layerColorSpace: CGColorSpace
    let pixelFormat: MTLPixelFormat
    let status: MPVRenderColorStatus

    init(
        iccIntent: MPVColorManagement.RenderingIntent,
        layerColorSpace: CGColorSpace,
        outputHeadroom: Double,
        pixelFormat: MTLPixelFormat,
        status: MPVRenderColorStatus,
        usesExtendedDynamicRange: Bool
    ) {
        self.iccIntent = iccIntent
        self.layerColorSpace = layerColorSpace
        self.outputHeadroom = outputHeadroom
        self.pixelFormat = pixelFormat
        self.status = status
        self.usesExtendedDynamicRange = usesExtendedDynamicRange
    }

    /// All target settings are committed while the native renderer is suspended.
    /// Explicitly clear ICC state when automatic system conversion owns output.
    var options: [(String, String)] {
        let referenceWhite = status.referenceWhite ?? 203
        let calibrated = status.conversionOwner == .libplaceboCalibratedICC
            || status.conversionOwner == .libplaceboCalibratedLUT
        return [
            ("target-prim", status.targetPrimaries ?? "auto"),
            ("target-trc", status.targetTransfer ?? "auto"),
            ("target-peak", usesExtendedDynamicRange ? String(Int(min(1_000_000, referenceWhite * outputHeadroom).rounded())) : "auto"),
            ("hdr-reference-white", String(Int(referenceWhite))),
            ("icc-profile-auto", "no"),
            ("icc-profile", status.calibratedProfileURL?.path ?? ""),
            ("icc-intent", String(iccIntent.rawValue)),
            ("target-lut", status.calibratedLUTURL?.path ?? ""),
            ("target-colorspace-hint", calibrated ? "no" : "yes"),
            (
                "sdr-adjust-gamma",
                status.sdrViewing == .legacyDisplay && status.precision == .unorm8
                    && !calibrated ? "no" : "yes"
            ),
            ("treat-srgb-as-power22", "no"),
            ("dither-depth", status.precision == .unorm8 ? "8" : "auto"),
        ]
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.usesExtendedDynamicRange == rhs.usesExtendedDynamicRange
            && lhs.outputHeadroom == rhs.outputHeadroom
            && lhs.status == rhs.status
            && lhs.pixelFormat == rhs.pixelFormat
            && lhs.iccIntent == rhs.iccIntent
            && CFEqual(lhs.layerColorSpace, rhs.layerColorSpace)
    }

    static func resolve(
        configuration: MPVPlayerConfiguration,
        native: Bool,
        usesExtendedDynamicRange: Bool,
        outputHeadroom: Double,
        supportsWideGamut: Bool,
        systemDisplayProfile: CGColorSpace?,
        displayProfileName: String?,
        calibratedProfile: MPVCalibratedDisplayProfile,
        supportsCalibratedICC: Bool
    ) -> Self {
        let management = configuration.colorManagement
        let headroom = outputHeadroom.isFinite ? max(1, outputHeadroom) : 1
        var fallback: MPVRenderColorStatus.FallbackReason?
        if case let .calibratedLUT(url, input) = management.displayProfile {
            if !supportsCalibratedICC {
                fallback = .calibratedICCRequiresMacOS
            } else if native || usesExtendedDynamicRange {
                fallback = .calibratedICCRequiresSDRMetal
            } else if !calibratedProfile.isValidLUT {
                fallback = .invalidCalibrationLUT
            } else if let systemDisplayProfile {
                return Self(
                    iccIntent: .relativeColorimetric,
                    layerColorSpace: systemDisplayProfile,
                    outputHeadroom: 1,
                    pixelFormat: .bgra8Unorm,
                    status: MPVRenderColorStatus(
                        conversionOwner: .libplaceboCalibratedLUT,
                        precision: .unorm8,
                        targetPrimaries: input == .displayP3SRGB ? "display-p3" : "bt.709",
                        targetTransfer: input == .rec709Gamma24 ? "gamma2.4" : "srgb",
                        displayProfileName: displayProfileName,
                        calibratedLUTURL: url,
                        referenceWhite: management.referenceWhite,
                        sdrViewing: management.sdrViewing
                    ),
                    usesExtendedDynamicRange: false
                )
            } else {
                fallback = .currentDisplayProfileUnavailable
            }
        }
        if case let .calibratedICC(url, intent) = management.displayProfile {
            if !supportsCalibratedICC {
                fallback = .calibratedICCRequiresMacOS
            } else if native || usesExtendedDynamicRange {
                fallback = .calibratedICCRequiresSDRMetal
            } else if calibratedProfile.colorSpace == nil {
                fallback = .invalidRGBDisplayProfile
            } else if let systemDisplayProfile {
                return Self(
                    iccIntent: intent,
                    layerColorSpace: systemDisplayProfile,
                    outputHeadroom: 1,
                    pixelFormat: .bgra8Unorm,
                    status: MPVRenderColorStatus(
                        conversionOwner: .libplaceboCalibratedICC,
                        precision: .unorm8,
                        displayProfileName: displayProfileName,
                        calibratedProfileURL: url,
                        referenceWhite: management.referenceWhite,
                        sdrViewing: management.sdrViewing
                    ),
                    usesExtendedDynamicRange: false
                )
            } else {
                fallback = .currentDisplayProfileUnavailable
            }
        }
        if native {
            return Self(
                iccIntent: .relativeColorimetric,
                layerColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                outputHeadroom: 1,
                pixelFormat: .bgra8Unorm,
                status: MPVRenderColorStatus(
                    conversionOwner: .avFoundation,
                    precision: .sourceManaged,
                    displayProfileName: displayProfileName,
                    fallbackReason: fallback ?? (configuration.sdrOutput == .automatic ? nil : .nativeManagesPrecision)
                ),
                usesExtendedDynamicRange: false
            )
        }
        let wide = usesExtendedDynamicRange || (supportsWideGamut && configuration.sdrOutput != .compatibility8Bit)
        let float = usesExtendedDynamicRange || wide || configuration.sdrOutput == .highPrecision
        let primaries = wide ? "display-p3" : "bt.709"
        let transfer = float ? "linear" : "srgb"
        let spaceName = wide ? CGColorSpace.extendedLinearDisplayP3
            : (float ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB)
        return Self(
            iccIntent: .relativeColorimetric,
            layerColorSpace: CGColorSpace(name: spaceName)!,
            outputHeadroom: usesExtendedDynamicRange ? headroom : 1,
            pixelFormat: float ? .rgba16Float : .bgra8Unorm,
            status: MPVRenderColorStatus(
                conversionOwner: .colorSync,
                precision: float ? .float16 : .unorm8,
                targetPrimaries: primaries,
                targetTransfer: transfer,
                displayProfileName: displayProfileName,
                referenceWhite: management.referenceWhite,
                sdrViewing: management.sdrViewing,
                fallbackReason: fallback
            ),
            usesExtendedDynamicRange: usesExtendedDynamicRange
        )
    }
}

/// Load once per player surface, never during brightness polling. ICC data must
/// describe an RGB display, not an input scanner or a CMYK printer profile.
struct MPVCalibratedDisplayProfile {
    let colorSpace: CGColorSpace?
    let isValidLUT: Bool

    init(policy: MPVColorManagement.DisplayProfile) {
        if case let .calibratedLUT(url, _) = policy {
            colorSpace = nil
            isValidLUT = Self.validateLUT(url)
            return
        }
        isValidLUT = false
        guard case let .calibratedICC(url, _) = policy,
              url.isFileURL,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count >= 128, data.count <= 16 * 1024 * 1024,
              String(data: data[12 ..< 16], encoding: .ascii) == "mntr",
              String(data: data[16 ..< 20], encoding: .ascii) == "RGB ",
              let profile = CGColorSpace(iccData: data as CFData),
              profile.model == .rgb
        else {
            colorSpace = nil
            return
        }
        colorSpace = profile
    }

    private static func validateLUT(_ url: URL) -> Bool {
        guard url.isFileURL,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= 16 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8)
        else { return false }
        var size: Int?
        var entries = 0
        var domains: Set<String> = []
        // Match the pinned native cube parser, including its narrower numeric
        // grammar. Accepting a file it rejects would leave the identity display
        // contract active without a calibration LUT.
        func number(_ token: Substring) -> Float? {
            guard token.allSatisfy({ "0123456789.-+e".contains($0) }),
                  let value = Float(token), value.isFinite else { return nil }
            return value
        }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.last == "\r" ? rawLine.dropLast() : rawLine[...]
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                continue
            }
            if entries == 0, line.hasPrefix("#") || line.hasPrefix("TITLE ") {
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first else { continue }
            if first == "DOMAIN_MIN" || first == "DOMAIN_MAX" {
                // The native parser treats DOMAIN as a table-output rescale,
                // not an input-domain transform. Only unit RGB is our contract.
                let domainParts = line.split(separator: " ", omittingEmptySubsequences: false)
                let expected: Float = first == "DOMAIN_MIN" ? 0 : 1
                guard entries == 0, domains.insert(String(first)).inserted,
                      domainParts.count == 4, domainParts.first == first,
                      domainParts.dropFirst().allSatisfy({ number($0) == expected })
                else { return false }
                continue
            }
            if first == "LUT_3D_SIZE" {
                guard entries == 0, size == nil, parts.count == 2,
                      let value = Int(parts[1]), (2 ... 65).contains(value),
                      line == "LUT_3D_SIZE \(value)" else { return false }
                size = value
                continue
            }
            guard size != nil, parts.count == 3, parts.allSatisfy({ number($0) != nil }),
                  line.allSatisfy({ "0123456789.-+e \t".contains($0) }) else { return false }
            if entries == 0 {
                // Native header parsing recognizes the first table row only
                // when its very first byte is a digit or minus sign.
                guard let initial = line.first, "0123456789-".contains(initial) else { return false }
            }
            entries += 1
        }
        guard let size else { return false }
        return entries == size * size * size
    }
}
