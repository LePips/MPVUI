/// Capabilities and current brightness budget of the selected output route.
public struct MPVDisplayCapabilities: Equatable, Sendable {
    /// Whether the output route reports HDR support.
    public enum HDRSupport: String, Equatable, Sendable {
        /// HDR capability has not been established.
        case unknown
        /// The output route does not report HDR support.
        case unsupported
        /// The output route reports HDR support.
        case supported
    }

    /// The output route's reported HDR capability.
    public let hdrSupport: HDRSupport
    /// Wide-gamut capability does not imply HDR support.
    public let supportsWideGamut: Bool?
    /// The selected display profile's name, when available.
    public let displayProfileName: String?
    /// Available EDR brightness relative to SDR white, which can change with
    /// display brightness, reference mode, power state, and other content.
    public let currentEDRHeadroom: Double?
    /// Maximum possible headroom; describes capability, not usable brightness.
    public let potentialEDRHeadroom: Double?

    init(
        hdrSupport: HDRSupport = .unknown,
        currentEDRHeadroom: Double? = nil,
        potentialEDRHeadroom: Double? = nil,
        supportsWideGamut: Bool? = nil,
        displayProfileName: String? = nil
    ) {
        self.hdrSupport = hdrSupport
        self.supportsWideGamut = supportsWideGamut
        self.displayProfileName = displayProfileName
        self.currentEDRHeadroom = Self.validHeadroom(currentEDRHeadroom)
        self.potentialEDRHeadroom = Self.validHeadroom(potentialEDRHeadroom)
    }

    private static func validHeadroom(_ value: Double?) -> Double? {
        value.flatMap {
            guard $0.isFinite, $0 >= 1, ($0 * 100).isFinite else { return nil }
            return ($0 * 100).rounded() / 100
        }
    }

    /// Display capabilities with no known output route information.
    public static let unknown = Self()
}
