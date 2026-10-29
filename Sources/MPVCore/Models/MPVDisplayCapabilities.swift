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
    /// Whether the output route supports a wide color gamut, or `nil` when unknown.
    /// Wide-gamut capability does not imply HDR support.
    public let supportsWideGamut: Bool?
    /// The selected display profile's name, when available.
    public let displayProfileName: String?
    /// Available EDR brightness relative to SDR white, which can change with
    /// display brightness, reference mode, power state, and other content.
    public let currentEDRHeadroom: Double?
    /// The maximum possible headroom, describing capability rather than available brightness.
    public let potentialEDRHeadroom: Double?
    /// Whether Android reports HDR10 support, or `nil` when unknown.
    public let supportsHDR10: Bool?
    /// Whether Android reports HLG support, or `nil` when unknown.
    public let supportsHLG: Bool?
    /// Whether Android reports Dolby Vision support, or `nil` when unknown.
    public let supportsDolbyVision: Bool?
    /// The nominal display refresh rate in hertz, or `nil` when unknown.
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
