/// A video signal transfer function relevant to mpv playback.
public enum MPVTransferFunction: Equatable, Hashable, Sendable {
    /// The source did not report a transfer function.
    case unknown

    /// ITU-R BT.709 transfer characteristics.
    case bt709

    /// ITU-R BT.1886 transfer characteristics.
    case bt1886

    /// The sRGB transfer function.
    case sRGB

    /// A linear-light signal.
    case linear

    /// A gamma 1.8 signal.
    case gamma18

    /// A gamma 2.0 signal.
    case gamma20

    /// A gamma 2.2 signal.
    case gamma22

    /// A gamma 2.4 signal.
    case gamma24

    /// A gamma 2.6 signal.
    case gamma26

    /// A gamma 2.8 signal.
    case gamma28

    /// SMPTE ST 2084 Perceptual Quantizer, an HDR transfer function.
    case pq

    /// ARIB STD-B67 Hybrid Log-Gamma, an HDR transfer function.
    case hlg

    /// A transfer function not recognized by this MPVUI version.
    case other(String)

    /// Creates a transfer function from the value reported by mpv.
    ///
    /// Common spelling variants for PQ, HLG, BT.709, and BT.1886 are
    /// normalized. Unknown nonempty values are preserved in ``other(_:)``.
    ///
    /// - Parameter mpvValue: The value of an mpv transfer/gamma property.
    public init(mpvValue: String?) {
        guard let value = mpvValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            self = .unknown
            return
        }

        switch value.lowercased() {
        case "bt.709", "bt709":
            self = .bt709
        case "bt.1886", "bt1886":
            self = .bt1886
        case "srgb":
            self = .sRGB
        case "linear":
            self = .linear
        case "gamma1.8", "gamma18":
            self = .gamma18
        case "gamma2.0", "gamma20":
            self = .gamma20
        case "gamma2.2", "gamma22":
            self = .gamma22
        case "gamma2.4", "gamma24":
            self = .gamma24
        case "gamma2.6", "gamma26":
            self = .gamma26
        case "gamma2.8", "gamma28":
            self = .gamma28
        case "pq", "st2084", "smpte2084", "smpte-st-2084", "smpte-st2084":
            self = .pq
        case "hlg", "arib-std-b67", "arib-std-b-67":
            self = .hlg
        default:
            self = .other(value)
        }
    }

    /// The canonical string representation used by mpv.
    public var mpvValue: String? {
        switch self {
        case .unknown:
            nil
        case .bt709:
            "bt.709"
        case .bt1886:
            "bt.1886"
        case .sRGB:
            "srgb"
        case .linear:
            "linear"
        case .gamma18:
            "gamma1.8"
        case .gamma20:
            "gamma2.0"
        case .gamma22:
            "gamma2.2"
        case .gamma24:
            "gamma2.4"
        case .gamma26:
            "gamma2.6"
        case .gamma28:
            "gamma2.8"
        case .pq:
            "pq"
        case .hlg:
            "hlg"
        case let .other(value):
            value
        }
    }

    /// Whether this transfer function represents an HDR signal.
    ///
    /// Wide-gamut primaries do not imply HDR. Only PQ and HLG transfer
    /// functions are classified as HDR.
    public var isHDR: Bool {
        switch self {
        case .pq, .hlg:
            true
        default:
            false
        }
    }
}
