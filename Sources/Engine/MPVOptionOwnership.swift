import Foundation

/// One ownership table for startup options and deferred property writes.
/// Raw commands may customize mpv without replacing the configured video output.
enum MPVOptionOwnership {
    /// Renderer and surface wiring must remain consistent with the configuration.
    static let rendererProperties: Set<String> = ["vo", "gpu-api", "gpu-context", "wid"]

    /// Properties already managed
    static let reservedProperties: Set<String> = [
        "external-surface-size",
        "external-surface-size-live",
        "avfoundation-presentation",
        "avfoundation-pip-composite-osd",
        "avfoundation-subtitle-luminance",
        "gpu-api",
        "gpu-context",
        "mute",
        "pause",
        "speed",
        "sub-text-intercept",
        "sub-text-snapshot",
        "target-colorspace-hint",
        "target-peak",
        "target-prim",
        "target-trc",
        "vo",
        "volume",
        "wid",
    ]

    static let managedOptions = reservedProperties.union(MPVRenderingOptions.reserved).union(
        [
            "avfoundation-native-dovi-profile7",
            "external-surface-update",
            "icc-profile",
            "icc-profile-auto",
            "target-lut",
            "target-lut-type",
            "dither-depth",
            "sdr-adjust-gamma",
            "sdr-reference-luminance",
            "gamma-factor",
            "gamma-auto",
            "target-contrast",
            "target-gamut",
            "treat-srgb-as-power22",
            "hdr-reference-white",
            "icc-intent",
        ]
    )

    static func normalizedProperty(_ name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["options/", "file-local-options/"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    static func rendererPropertyModified(by rawName: String, arguments: [String]) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name == "expand-properties", let command = arguments.first {
            return rendererPropertyModified(by: command, arguments: Array(arguments.dropFirst()))
        }
        guard ["set", "add", "multiply", "cycle", "cycle-values", "change-list"].contains(name),
              let property = arguments.first,
              rendererProperties.contains(normalizedProperty(property)) else { return nil }
        return property
    }

    static func isManaged(_ rawName: String, deinterlace: MPVDeinterlacePolicy) -> Bool {
        let name = normalizedProperty(rawName)
        if Self.managedOptions.contains(name) {
            return true
        }
        if name == "vf" || name.hasPrefix("vf-") {
            return deinterlace.mode != .disabled
        }
        return name.hasPrefix("glsl-shaders-")
    }
}
