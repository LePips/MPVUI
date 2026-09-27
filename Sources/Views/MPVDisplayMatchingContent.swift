import CoreMedia
import CoreVideo
import Foundation

/// Content characteristics used as a display-mode hint, never as a decoder format.
/// Unknown color properties remain absent. An enforced SDR conversion replaces
/// the source HDR description so it cannot request an HDR HDMI mode accidentally.
struct MPVDisplayMatchingContent: Equatable {
    let width: Int32
    let height: Int32
    let refreshRate: Float
    let codec: CMVideoCodecType
    let signal: MPVVideoSignal
    let convertsHDRToSDR: Bool
    let dolbyVision: DolbyVision?

    /// A display hint for the validated, single-layer native output. This is
    /// never passed to a decoder; the decoder owns the actual HEVC parameter
    /// sets and per-frame RPU. In particular, a source Profile 7 declaration
    /// cannot advertise the converted Profile 8.1 output without evidence.
    struct DolbyVision: Equatable {
        let profile: Int
        let level: Int
        let compatibilityID: Int

        init?(status: MPVDolbyVisionStatus, level: Int?) {
            guard status.nativeValidation == .validated,
                  let profile = status.effectiveProfile,
                  let compatibilityID = status.effectiveBaseLayerCompatibilityID,
                  let level, (1 ... 15).contains(level),
                  (profile == 5 && compatibilityID == 0)
                  || (profile == 8 && [1, 4].contains(compatibilityID))
            else { return nil }
            self.profile = profile
            self.level = level
            self.compatibilityID = compatibilityID
        }

        var atomName: String {
            profile > 7 ? "dvvC" : "dvcC"
        }

        var configurationRecord: Data {
            // Dolby Vision configuration record v1.0, in network byte order.
            // Validated native output has an RPU and base layer, with no EL.
            let flags = UInt16(profile << 9 | level << 3 | 0b101)
            return Data([
                1, 0, UInt8(flags >> 8), UInt8(flags & 0xFF),
                UInt8(compatibilityID << 4),
            ] + Array(repeating: UInt8(0), count: 19))
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              lhs.refreshRate == rhs.refreshRate, lhs.codec == rhs.codec,
              lhs.convertsHDRToSDR == rhs.convertsHDRToSDR,
              lhs.dolbyVision == rhs.dolbyVision
        else { return false }
        if lhs.convertsHDRToSDR {
            return true
        }
        // Dynamic scene metadata and signal-peak changes do not select a new
        // HDMI mode. Compare only fields represented by this display hint.
        return lhs.signal.primaries == rhs.signal.primaries
            && lhs.signal.transferFunction == rhs.signal.transferFunction
            && lhs.signal.matrix == rhs.signal.matrix
            && lhs.signal.range == rhs.signal.range
            && lhs.signal.bitDepth == rhs.signal.bitDepth
            && lhs.signal.maxContentLightLevel == rhs.signal.maxContentLightLevel
            && lhs.signal.maxFrameAverageLightLevel == rhs.signal.maxFrameAverageLightLevel
    }

    init?(
        media: MPVMediaInformation,
        outputUsesHDR: Bool,
        videoOutput: MPVPlayerConfiguration.VideoOutput = .metal,
        dolbyVisionStatus: MPVDolbyVisionStatus = .unknown
    ) {
        let selectedCodec = media.tracks.first { $0.type == .video && $0.isSelected }?.codec
        guard let dimensions = media.dimensions,
              let width = Int32(exactly: dimensions.width), width > 0,
              let height = Int32(exactly: dimensions.height), height > 0,
              let refreshRate = Self.refreshRate(for: media.framesPerSecond),
              let codec = Self.codecType(for: selectedCodec ?? media.videoCodec)
        else { return nil }

        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        let decoded = media.hdr.decoded
        signal = decoded == .unknown ? media.hdr.source : decoded
        convertsHDRToSDR = !outputUsesHDR
            && (signal.transferFunction.isHDR || media.hdr.source.dolbyVisionProfile != nil)
        dolbyVision = outputUsesHDR && videoOutput == .sampleBuffer && codec == kCMVideoCodecType_HEVC
            ? DolbyVision(
                status: dolbyVisionStatus,
                level: media.hdr.source.dolbyVisionLevel ?? decoded.dolbyVisionLevel
            ) : nil
        self.codec = dolbyVision == nil ? codec : kCMVideoCodecType_DolbyVisionHEVC
    }

    /// Preserve the NTSC rational families, including when mpv reports their
    /// common three-decimal spelling. In particular, never round 23.976 to 24.
    static func refreshRate(for framesPerSecond: Double?) -> Float? {
        guard let value = framesPerSecond, value.isFinite,
              value > 0, value <= 240
        else { return nil }
        let standardRates = [
            24000.0 / 1001, 24, 25, 30000.0 / 1001, 30,
            48000.0 / 1001, 48, 50, 60000.0 / 1001, 60,
            100, 120_000.0 / 1001, 120,
        ]
        let rate = standardRates.first { abs($0 - value) < 0.001 } ?? value
        return Float(rate)
    }

    func makeFormatDescription() -> CMVideoFormatDescription? {
        var extensions: [String: Any] = [:]
        if convertsHDRToSDR {
            // The renderer's SDR contract is BT.709/sRGB. Do not copy mastering,
            // content-light or Dolby Vision metadata across this conversion.
            extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] =
                kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            extensions[kCMFormatDescriptionExtension_TransferFunction as String] =
                kCMFormatDescriptionTransferFunction_sRGB
        } else {
            if let dolbyVision {
                extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = [
                    dolbyVision.atomName: dolbyVision.configurationRecord,
                ]
            }
            if let primaries = Self.colorPrimaries(signal.primaries) {
                extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = primaries
            }
            if let transfer = Self.transferFunction(signal.transferFunction) {
                extensions[kCMFormatDescriptionExtension_TransferFunction as String] = transfer
            }
            if let matrix = Self.colorMatrix(signal.matrix) {
                extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = matrix
            }
            switch signal.range?.lowercased() {
            case "full", "pc":
                extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] = true
            case "limited", "tv":
                extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] = false
            default:
                break
            }
            if let depth = signal.bitDepth {
                extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] = depth
            }
            if signal.transferFunction.isHDR,
               let maxCLL = signal.maxContentLightLevel,
               let maxFALL = signal.maxFrameAverageLightLevel,
               maxCLL.isFinite, maxFALL.isFinite,
               maxCLL >= 0, maxFALL >= 0,
               maxCLL <= Double(UInt16.max), maxFALL <= Double(UInt16.max)
            {
                let cll = UInt16(maxCLL.rounded())
                let fall = UInt16(maxFALL.rounded())
                extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] = Data([
                    UInt8(cll >> 8), UInt8(cll & 0xFF),
                    UInt8(fall >> 8), UInt8(fall & 0xFF),
                ])
            }
        }

        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    private static func codecType(for value: String?) -> CMVideoCodecType? {
        switch value?.lowercased() {
        case "h264", "avc1": kCMVideoCodecType_H264
        case "hevc", "h265", "hev1", "hvc1", "dvh1", "dvhe": kCMVideoCodecType_HEVC
        case "av1", "av01": kCMVideoCodecType_AV1
        case "vp9", "vp09": kCMVideoCodecType_VP9
        case "mpeg4": kCMVideoCodecType_MPEG4Video
        case "mpeg2video": kCMVideoCodecType_MPEG2Video
        default: nil
        }
    }

    private static func colorPrimaries(_ value: String?) -> CFString? {
        switch value?.lowercased() {
        case "bt.709", "bt709": kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case "bt.601-525", "smpte170m", "smpte-c": kCMFormatDescriptionColorPrimaries_SMPTE_C
        case "bt.601-625", "bt470bg": kCMFormatDescriptionColorPrimaries_EBU_3213
        case "bt.2020", "bt2020": kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case "display-p3", "p3-d65": kCMFormatDescriptionColorPrimaries_P3_D65
        case "dci-p3", "p3-dci": kCMFormatDescriptionColorPrimaries_DCI_P3
        default: nil
        }
    }

    private static func colorMatrix(_ value: String?) -> CFString? {
        switch value?.lowercased() {
        case "bt.709", "bt709": kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case "bt.601", "bt601", "smpte170m", "bt470bg": kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        case "bt.2020-ncl", "bt.2020-cl", "bt2020nc", "bt2020c": kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case "smpte-240m", "smpte240m": kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995
        default: nil
        }
    }

    private static func transferFunction(_ value: MPVTransferFunction) -> CFString? {
        switch value {
        case .bt709, .bt1886: kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case .sRGB: kCMFormatDescriptionTransferFunction_sRGB
        case .linear: kCMFormatDescriptionTransferFunction_Linear
        case .pq: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        default: nil
        }
    }
}
