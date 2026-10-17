/// Capabilities and current brightness budget of the selected output route.
public struct MPVDisplayCapabilities: Equatable, Sendable {

    /// Whether the output route reports HDR support.
    public enum HDRSupport: String, Equatable, Sendable {

        /// The output route's HDR capability is unknown.
        case unknown
        /// The output route does not report HDR support.
        case unsupported
        /// The output route reports HDR support.
        case supported
    }

    /// Display capabilities with no known output route information.
    public static let unknown = Self()
    /// The output route's reported HDR capability.
    public let hdrSupport: HDRSupport
    /// Wide-gamut capability does not imply HDR support.
    public let supportsWideGamut: Bool?
    /// The selected display profile's name, when available.
    public let displayProfileName: String?
    /// Available EDR brightness relative to SDR white, which can change with
    /// display brightness, reference mode, power state, and other content.
    public let currentEDRHeadroom: Double?
    /// The maximum possible headroom, describing capability rather than available brightness.
    public let potentialEDRHeadroom: Double?
    /// HDR10 support reported by Android, or nil when unknown.
    public let supportsHDR10: Bool?
    /// HLG support reported by Android, or nil when unknown.
    public let supportsHLG: Bool?
    /// Dolby Vision support reported by Android, or nil when unknown.
    public let supportsDolbyVision: Bool?
    /// Nominal display refresh rate reported by the platform.
    public let refreshRate: Double?

    package init(
        hdrSupport: HDRSupport = .unknown,
        currentEDRHeadroom: Double? = nil,
        potentialEDRHeadroom: Double? = nil,
        supportsWideGamut: Bool? = nil,
        displayProfileName: String? = nil,
        supportsHDR10: Bool? = nil,
        supportsHLG: Bool? = nil,
        supportsDolbyVision: Bool? = nil,
        refreshRate: Double? = nil
    ) {
        self.hdrSupport = hdrSupport
        self.supportsWideGamut = supportsWideGamut
        self.displayProfileName = displayProfileName
        self.currentEDRHeadroom = Self.validHeadroom(currentEDRHeadroom)
        self.potentialEDRHeadroom = Self.validHeadroom(potentialEDRHeadroom)
        self.supportsHDR10 = supportsHDR10
        self.supportsHLG = supportsHLG
        self.supportsDolbyVision = supportsDolbyVision
        self.refreshRate = refreshRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private static func validHeadroom(_ value: Double?) -> Double? {
        value.flatMap {
            guard $0.isFinite, $0 >= 1, ($0 * 100).isFinite else { return nil }
            return ($0 * 100).rounded() / 100
        }
    }
}
