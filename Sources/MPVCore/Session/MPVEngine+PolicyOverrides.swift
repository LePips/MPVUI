import Foundation

package extension MPVSession {

    /// Native values whose defaults are adjusted at source or playback boundaries.
    static let automaticPlaybackPolicyOptions: Set<String> = [
        "hr-seek-demuxer-offset",
        "cache-pause-wait",
        "cache-pause-initial",
    ]

    func playbackPolicyOverride(for name: String) -> String? {
        if fileLocalPlaybackPolicyOverrides.contains(name) {
            return getString("options/\(name)")
        }
        if let value = desiredProperties[name] {
            return value
        }
        if let value = desiredProperties.first(where: {
            !$0.key.hasPrefix("file-local-options/") && MPVOptionOwnership.normalizedProperty($0.key) == name
        })?.value {
            return value
        }
        return configuration.additionalOptions
            .first {
                MPVOptionOwnership.normalizedProperty($0.key) == name
            }?.value
    }

    /// Keep resolved global mutations separate from the current file's values.
    /// A later file-local change must not replace the value restored on reload.
    func recordPlaybackPolicyMutation(_ property: String) {
        let name = MPVOptionOwnership.normalizedProperty(property)
        guard Self.automaticPlaybackPolicyOptions.contains(name) else { return }

        if property.hasPrefix("file-local-options/") {
            fileLocalPlaybackPolicyOverrides.insert(name)
        } else if let value = getString("options/\(name)") {
            fileLocalPlaybackPolicyOverrides.remove(name)
            desiredProperties[name] = value
        }
    }

    func resetFileLocalPlaybackPolicyOverrides() {
        fileLocalPlaybackPolicyOverrides.removeAll()
        for name in Self.automaticPlaybackPolicyOptions {
            desiredProperties.removeValue(forKey: "file-local-options/\(name)")
        }
    }
}
