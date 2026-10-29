import Foundation

/// One ownership table for startup options and deferred property writes.
/// Raw commands may customize mpv without replacing the configured video output.
package enum MPVOptionOwnership {

    /// Renderer and surface wiring must remain consistent with the configuration.
    package static let rendererProperties: Set<String> = ["vo", "gpu-api", "gpu-context", "wid", "force-window"]

    /// Properties already managed
    package static let reservedProperties: Set<String> = [
        "external-surface-size",
        "external-surface-size-live",
        "force-window",
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

    package static let managedOptions = reservedProperties.union(MPVRenderingOptions.reserved).union(
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

    package static func normalizedProperty(_ name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        for prefix in ["options/", "file-local-options/"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }

        return name
    }

    package static func rendererPropertyModified(by rawName: String, arguments: [String]) -> String? {
        let (name, arguments) = commandComponents(rawName, arguments: arguments)

        guard ["set", "add", "multiply", "cycle", "cycle-values", "change-list"].contains(name),
              let property = arguments.first,
              rendererProperties.union(["sub-text-intercept", "sub-text-snapshot"]).contains(normalizedProperty(property))
        else { return nil }

        return property
    }

    // libmpv accepts these prefixes before the actual command and normalizes
    // underscores to hyphens in command names. Ownership follows that command.
    package static func commandComponents(_ name: String, arguments: [String]) -> (String, ArraySlice<String>) {
        let prefixes: Set<String> = [
            "no-osd",
            "osd-bar",
            "osd-msg",
            "osd-msg-bar",
            "osd-auto",
            "expand-properties",
            "raw",
            "repeatable",
            "nonrepeatable",
            "nonscalable",
            "async",
            "sync",
        ]

        var components = ([name] + arguments)[...]

        while let first = components.first, prefixes.contains(first) {
            components = components.dropFirst()
        }

        return (
            (components.first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-"),
            components.dropFirst()
        )
    }

    package static func isManaged(_ rawName: String, deinterlace: MPVDeinterlacePolicy) -> Bool {
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
