/// Reported color metadata at one point in the video pipeline. Missing fields
/// remain unknown; metadata from another stage is never substituted.
public struct MPVVideoSignal: Equatable, Sendable {
    /// The reported color primaries.
    public let primaries: String?
    /// The reported signal transfer function.
    public let transferFunction: MPVTransferFunction
    /// The reported color conversion matrix.
    public let matrix: String?
    /// The reported signal range, such as full or limited.
    public let range: String?
    /// The number of bits per color component, when known.
    public let bitDepth: Int?
    /// The reported chroma sampling format.
    public let chromaSubsampling: String?
    /// The reported chroma sample location.
    public let chromaLocation: String?
    /// The pixel format reported at this pipeline stage.
    public let pixelFormat: String?
    /// The mastering display's minimum luminance in cd/m².
    public let minimumLuminance: Double?
    /// The mastering display's maximum luminance in cd/m².
    public let maximumLuminance: Double?
    /// The content's reported maximum light level in cd/m².
    public let maxContentLightLevel: Double?
    /// The content's reported maximum frame-average light level in cd/m².
    public let maxFrameAverageLightLevel: Double?
    /// The reported signal peak relative to reference white.
    public let signalPeak: Double?
    /// CIE xy coordinates keyed by mpv's `prim-red-x`, `prim-white-y`, etc.
    public let masteringDisplayPrimaries: [String: Double]
    /// HDR10+ scene values, when exposed by the decoder. Absence is unknown.
    public let hdr10PlusMetadata: [String: Double]
    /// Whether the decoder reports HDR10+ metadata; nil means unknown.
    public let hasHDR10PlusMetadata: Bool?
    /// The reported Dolby Vision profile.
    public let dolbyVisionProfile: Int?
    /// The reported Dolby Vision level.
    public let dolbyVisionLevel: Int?
    /// Explicit base-layer compatibility identifier. Profile 8 alone does not
    /// distinguish HDR10-compatible 8.1 from HLG-compatible 8.4.
    public let dolbyVisionBaseLayerCompatibilityID: Int?

    init(
        primaries: String? = nil,
        transferFunction: MPVTransferFunction = .unknown,
        matrix: String? = nil,
        range: String? = nil,
        bitDepth: Int? = nil,
        chromaSubsampling: String? = nil,
        chromaLocation: String? = nil,
        pixelFormat: String? = nil,
        minimumLuminance: Double? = nil,
        maximumLuminance: Double? = nil,
        maxContentLightLevel: Double? = nil,
        maxFrameAverageLightLevel: Double? = nil,
        signalPeak: Double? = nil,
        masteringDisplayPrimaries: [String: Double] = [:],
        hdr10PlusMetadata: [String: Double] = [:],
        hasHDR10PlusMetadata: Bool? = nil,
        dolbyVisionProfile: Int? = nil,
        dolbyVisionLevel: Int? = nil,
        dolbyVisionBaseLayerCompatibilityID: Int? = nil
    ) {
        self.primaries = primaries
        self.transferFunction = transferFunction
        self.matrix = matrix
        self.range = range
        self.bitDepth = bitDepth.flatMap { (1 ... 64).contains($0) ? $0 : nil }
        self.chromaSubsampling = chromaSubsampling
        self.chromaLocation = chromaLocation
        self.pixelFormat = pixelFormat
        self.minimumLuminance = minimumLuminance?.positiveOrZero
        self.maximumLuminance = maximumLuminance?.positiveOrZero
        self.maxContentLightLevel = maxContentLightLevel?.positiveOrZero
        self.maxFrameAverageLightLevel = maxFrameAverageLightLevel?.positiveOrZero
        self.signalPeak = signalPeak?.positiveOrZero
        self.masteringDisplayPrimaries = masteringDisplayPrimaries.filter {
            $0.value.isFinite && (0 ... 1).contains($0.value)
        }
        self.hdr10PlusMetadata = hdr10PlusMetadata.filter { $0.value.positiveOrZero != nil }
        self.hasHDR10PlusMetadata = hasHDR10PlusMetadata
        self.dolbyVisionProfile = dolbyVisionProfile.flatMap { (0 ... 10).contains($0) ? $0 : nil }
        self.dolbyVisionLevel = dolbyVisionLevel.flatMap { (0 ... 15).contains($0) ? $0 : nil }
        self.dolbyVisionBaseLayerCompatibilityID = dolbyVisionBaseLayerCompatibilityID.flatMap { (0 ... 15).contains($0) ? $0 : nil }
    }

    /// Whether the transfer function identifies PQ or HLG video.
    public var isHDR: Bool {
        transferFunction.isHDR
    }

    /// A video signal with no reported color metadata.
    public static let unknown = Self()
}
