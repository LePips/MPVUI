import Foundation

enum MPVVideoSignalParser {
    static func parse(_ node: MPVNodeValue?, track: MPVNodeValue? = nil) -> MPVVideoSignal {
        let values = node?.mapValue ?? [:]
        let track = track?.mapValue ?? [:]
        let pixelFormat = string(values["hw-pixelformat"]) ?? string(values["pixelformat"])
        let format = pixelFormatDescription(pixelFormat)
        let masteringKeys = [
            "prim-red-x", "prim-red-y", "prim-green-x", "prim-green-y",
            "prim-blue-x", "prim-blue-y", "prim-white-x", "prim-white-y",
        ]
        let sceneKeys = ["scene-max-r", "scene-max-g", "scene-max-b", "scene-avg"]
        let mastering = numericValues(values, keys: masteringKeys)
        let scene = numericValues(values, keys: sceneKeys)
        return MPVVideoSignal(
            primaries: string(values["primaries"]),
            transferFunction: MPVTransferFunction(mpvValue: string(values["gamma"])),
            matrix: string(values["colormatrix"]),
            range: string(values["colorlevels"]),
            bitDepth: integer(values["bit-depth"]) ?? format.depth,
            chromaSubsampling: string(values["chroma-subsampling"]) ?? format.chroma,
            chromaLocation: string(values["chroma-location"]),
            pixelFormat: pixelFormat,
            minimumLuminance: number(values["min-luma"]),
            maximumLuminance: number(values["max-luma"]),
            maxContentLightLevel: number(values["max-cll"]),
            maxFrameAverageLightLevel: number(values["max-fall"]),
            signalPeak: number(values["sig-peak"]),
            masteringDisplayPrimaries: mastering,
            hdr10PlusMetadata: scene,
            hasHDR10PlusMetadata: values["hdr10-plus"]?.boolValue
                ?? (scene.isEmpty ? nil : true),
            dolbyVisionProfile: integer(values["dolby-vision-profile"])
                ?? integer(track["dolby-vision-profile"]),
            dolbyVisionLevel: integer(values["dolby-vision-level"])
                ?? integer(track["dolby-vision-level"]),
            dolbyVisionBaseLayerCompatibilityID: integer(values["dolby-vision-bl-signal-compatibility-id"])
                ?? integer(track["dolby-vision-bl-signal-compatibility-id"])
                ?? integer(values["dolby-vision-compatibility-id"])
                ?? integer(track["dolby-vision-compatibility-id"])
        )
    }

    /// `average-bpp` includes chroma packing and is not component depth.
    /// Recognize only unambiguous formats; hardware handles alone stay unknown.
    static func pixelFormatDescription(_ format: String?) -> (depth: Int?, chroma: String?) {
        guard let format = format?.lowercased() else { return (nil, nil) }
        switch format {
        case "nv12", "nv21": return (8, "4:2:0")
        case "p010", "p010le", "p010be": return (10, "4:2:0")
        case "p016", "p016le", "p016be": return (16, "4:2:0")
        case "uyvy422", "yuyv422": return (8, "4:2:2")
        case "bgra", "rgba", "argb", "abgr", "bgr0", "rgb0", "rgb24", "bgr24":
            return (8, "4:4:4")
        default: break
        }
        guard let match = format.range(
            of: "^(?:yuvj?|yuva)(420|422|444|440|411|410)p([0-9]+)?(?:le|be)?$",
            options: .regularExpression
        ), match == format.startIndex ..< format.endIndex else {
            return (nil, nil)
        }
        let digits = format.filter(\.isNumber)
        let subsampling = String(digits.prefix(3))
        let depth = digits.count > 3 ? Int(digits.dropFirst(3)) : 8
        let chroma = subsampling.map(String.init).joined(separator: ":")
        return (depth, chroma)
    }

    private static func string(_ node: MPVNodeValue?) -> String? {
        guard let text = node?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !["auto", "unknown", "unspecified"].contains(text.lowercased())
        else { return nil }
        return text
    }

    private static func number(_ node: MPVNodeValue?) -> Double? {
        let value = node?.doubleValue ?? string(node).flatMap(Double.init)
        return value?.positiveOrZero
    }

    private static func integer(_ node: MPVNodeValue?) -> Int? {
        guard let value = number(node), value.rounded(.towardZero) == value,
              value < Double(Int.max) else { return nil }
        return Int(value)
    }

    private static func numericValues(_ values: [String: MPVNodeValue], keys: [String]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            number(values[key]).map { (key, $0) }
        })
    }
}
