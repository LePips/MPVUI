import Foundation

enum MPVRenderingOptions {
    static let reserved: Set<String> = [
        "scale", "cscale", "scale-antiring", "cscale-antiring", "deband",
        "dither", "tone-mapping", "gamut-mapping-mode", "hdr-compute-peak",
        "glsl-shaders", "glsl-shaders-append", "glsl-shader", "lut", "lut-type",
        "deinterlace", "deinterlace-field-parity",
    ]

    struct Resolution {
        var preset: MPVRenderingQuality.Preset
        var options: [String: String]
        var unsupportedFeatures: [String]
        var shaderPaths: [String] = []
    }

    static func resolve(
        _ quality: MPVRenderingQuality,
        backend: MPVPlayerConfiguration.VideoOutput,
        lowPowerMode: Bool
    ) -> Resolution {
        let preset = quality.preset == .automatic ? (lowPowerMode ? .battery : .balanced) : quality.preset
        guard backend == .metal else {
            return Resolution(
                preset: preset, options: [:],
                unsupportedFeatures: [
                    "Native output uses AVFoundation scaling and color conversion; gpu-next presets, dithering, shaders and LUTs are unavailable."
                ]
            )
        }
        let scale: MPVRenderingQuality.Scaling
        let cscale: MPVRenderingQuality.Scaling
        let antiring: Double
        let deband: Bool
        let peak: MPVRenderingQuality.PeakDetection
        switch preset {
        case .battery:
            scale = .bilinear
            cscale = .bilinear
            antiring = 0
            deband = false
            peak = .disabled
        case .highQuality:
            scale = .ewaLanczosSharp
            cscale = .ewaLanczos
            antiring = 0.7
            deband = true
            peak = .enabled
        case .automatic, .balanced:
            scale = .bicubic
            cscale = .bilinear
            antiring = 0
            deband = false
            peak = .automatic
        }
        var options = [
            "scale": (quality.scaling ?? scale).rawValue,
            "cscale": (quality.chromaScaling ?? cscale).rawValue,
            "scale-antiring": normalized(quality.antiringing, fallback: antiring),
            "cscale-antiring": normalized(quality.chromaAntiringing, fallback: antiring),
            "deband": (quality.debanding ?? deband) ? "yes" : "no",
            "tone-mapping": (quality.toneMapping ?? .automatic).rawValue,
            "gamut-mapping-mode": (quality.gamutMapping ?? .automatic).rawValue,
            "hdr-compute-peak": (quality.peakDetection ?? peak).rawValue,
        ]
        switch quality.dithering ?? .automatic {
        case .automatic: options["dither"] = "fruit"
        case .disabled: options["dither"] = "no"
        case let value: options["dither"] = value.rawValue
        }
        var unsupported: [String] = []
        let shaders = quality.shaders.filter { url in
            let valid = url.isFileURL && FileManager.default.isReadableFile(atPath: url.path)
            if !valid {
                unsupported.append("Unreadable local shader: \(url.lastPathComponent)")
            }
            return valid
        }
        if let lut = quality.lut {
            if lut.url.isFileURL, FileManager.default.isReadableFile(atPath: lut.url.path) {
                options["lut"] = lut.url.path
                options["lut-type"] = lut.domain.rawValue
            } else {
                unsupported.append("Unreadable local LUT: \(lut.url.lastPathComponent)")
            }
        }
        return Resolution(preset: preset, options: options, unsupportedFeatures: unsupported, shaderPaths: shaders.map(\.path))
    }

    static func deinterlaceOptions(_ policy: MPVDeinterlacePolicy) -> [String: String] {
        guard policy.mode != .disabled else { return ["deinterlace": "no"] }
        if policy.algorithm == .automatic, !policy.analyzeFieldOrder {
            return [
                "deinterlace": policy.mode == .automatic ? "auto" : "yes",
                "deinterlace-field-parity": policy.fieldOrder.rawValue,
            ]
        }
        let algorithm = policy.algorithm == .automatic ? "bwdif" : policy.algorithm.rawValue
        let deint = policy.mode == .automatic ? "interlaced" : "all"
        let graph = (policy.analyzeFieldOrder ? "idet," : "")
            + "\(algorithm)=mode=send_field:parity=\(policy.fieldOrder.rawValue):deint=\(deint)"
        // mpv's lavfi wrapper negotiates software input through its autoconverter.
        return ["deinterlace": "no", "vf": "lavfi=[\(graph)]"]
    }

    static func deinterlaceStatus(
        policy: MPVDeinterlacePolicy,
        interlaced: Bool?,
        hardwareDecoder: String?,
        automaticFilterIsActive: Bool? = nil
    ) -> MPVDeinterlaceStatus {
        var result = MPVDeinterlaceStatus()
        result.requested = policy
        result.outputFrameIsInterlaced = interlaced
        guard policy.mode != .disabled else {
            result.requiresSoftwareFrames = false
            result.isActive = false
            return result
        }
        if policy.algorithm == .automatic, !policy.analyzeFieldOrder {
            result.isActive = automaticFilterIsActive
            if automaticFilterIsActive == false {
                result.requiresSoftwareFrames = false
            } else if automaticFilterIsActive == true {
                result.effectiveFilter = "bwdif (one frame per field)"
                result.requiresSoftwareFrames = true
                result.reason = hardwareDecoder?.hasPrefix("videotoolbox") == true
                    ? "VideoToolbox frames are downloaded for the software bwdif filter."
                    : "bwdif runs on software-accessible frames."
            }
        } else {
            result.effectiveFilter = policy.algorithm == .yadif ? "yadif" : "bwdif"
            result.requiresSoftwareFrames = true
            result.reason = "Explicit lavfi processing requires software-accessible frames, including progressive frames."
        }
        return result
    }

    private static func normalized(_ value: Double?, fallback: Double) -> String {
        guard let value, value.isFinite else { return String(fallback) }
        return String(min(1, max(0, value)))
    }
}
