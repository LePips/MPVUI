import CoreMedia
import VideoToolbox

/// Codec support is capability evidence, never evidence of a particular decode session.
enum MPVAppleHardwareProbe {

    static func supports(_ codec: String?, probe: (CMVideoCodecType) -> Bool = { VTIsHardwareDecodeSupported($0) }) -> Bool? {
        let type: CMVideoCodecType? = switch codec {
        case "h264": kCMVideoCodecType_H264
        case "hevc", "h265": kCMVideoCodecType_HEVC
        case "av1": kCMVideoCodecType_AV1
        case "vp9": kCMVideoCodecType_VP9
        case "mpeg2video": kCMVideoCodecType_MPEG2Video
        default: nil
        }
        return type.map(probe)
    }
}
