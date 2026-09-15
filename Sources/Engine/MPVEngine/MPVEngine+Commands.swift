import Dispatch
import Foundation
import Libmpv

#if canImport(Darwin)
import Darwin
#endif

// Bridges commands and properties to libmpv and preserves desired runtime settings.
extension MPVEngine {
    /// Properties already managed
    private static let reservedProperties: Set<String> = [
        "external-surface-size",
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

    private static let managedOptions = reservedProperties.union(MPVRenderingOptions.reserved).union(
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

    func performPropertySet(_ name: String, value: String) {
        let propertyName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !propertyName.isEmpty else { return }
        guard !isManagedOption(propertyName) else {
            queue.async { [weak self] in
                self?.publish(
                    .error(
                        .reservedProperty(name: propertyName),
                        fatal: false
                    )
                )
            }
            return
        }
        setProperty(propertyName, to: value)
    }

    func isManagedOption(_ rawName: String) -> Bool {
        let name = rawName.lowercased().replacingOccurrences(of: "options/", with: "")
        if Self.managedOptions.contains(name) {
            return true
        }
        if name == "vf" || name.hasPrefix("vf-") {
            return configuration.deinterlace.mode != .disabled
        }
        return name.hasPrefix("glsl-shaders-")
    }

    func performCommand(_ name: String, arguments: [String]) {
        guard !name.isEmpty else { return }
        if name.caseInsensitiveCompare("stop") == .orderedSame, arguments.isEmpty {
            stop()
            return
        }
        command([name] + arguments)
    }

    func snapshotRuntimeProperties() {
        dispatchPrecondition(condition: .onQueue(queue))
        let names = [
            "volume", "mute", "speed", "vid", "aid", "sid", "secondary-sid",
            "audio-delay", "sub-delay", "secondary-sub-delay",
            "sub-visibility", "secondary-sub-visibility",
        ]
        for name in names {
            if let value = getString(name) {
                desiredProperties[name] = value
            }
        }
    }

    func applyDesiredProperties() {
        dispatchPrecondition(condition: .onQueue(queue))
        for (name, value) in desiredProperties {
            let status = setPropertyImmediately(name, to: value)
            if status < 0 {
                publishCommandError(status, context: "Restore \(name)")
            }
        }
    }

    func setInitialOption(_ name: String, value: String) throws(MPVPlayerError) {
        guard let handle else {
            throw .clientUnavailable
        }
        try check(mpv_set_option_string(handle, name, value), context: "Set option \(name)")
    }

    func command(_ arguments: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            let status = self.runCommand(arguments)
            if status < 0 {
                self.publishCommandError(status, context: arguments.first ?? "Command")
            }
        }
    }

    func runCommand(_ arguments: [String]) -> Int32 {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }

        var cArguments: [UnsafePointer<CChar>?] = arguments.map { argument in
            guard let duplicate = strdup(argument) else { return nil }
            return UnsafePointer(duplicate)
        }
        cArguments.append(nil)

        defer {
            for case let pointer? in cArguments {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }

        let status = mpv_command(handle, &cArguments)
        recordAcceptedCommand(arguments, status: status)
        return status
    }

    func runCommandReturningValue(_ arguments: [String]) -> (Int32, MPVNodeValue?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let handle else { return (MPV_ERROR_UNINITIALIZED.rawValue, nil) }

        var cArguments: [UnsafePointer<CChar>?] = arguments.map { argument in
            guard let duplicate = strdup(argument) else { return nil }
            return UnsafePointer(duplicate)
        }
        cArguments.append(nil)

        defer {
            for case let pointer? in cArguments {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }

        var result = mpv_node()
        let status = mpv_command_ret(handle, &cArguments, &result)
        recordAcceptedCommand(arguments, status: status)
        guard status >= 0 else { return (status, nil) }
        defer { mpv_free_node_contents(&result) }
        return (status, MPVNodeValue(copying: result))
    }

    func setProperty(_ name: String, to value: String) {
        queue.async { [weak self] in
            self?.setPropertyImmediatelyOrDefer(name, to: value)
        }
    }

    func setPropertyImmediatelyOrDefer(_ name: String, to value: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        desiredProperties[name] = value
        guard handle != nil else { return }

        let status = setPropertyImmediately(name, to: value)
        if status < 0 {
            publishCommandError(status, context: "Set \(name)")
        } else if Self.textSubtitleSnapshotRefreshProperties.contains(
            name.lowercased()
        ) {
            // `sub-text-snapshot` is a computed property. mpv updates the
            // value synchronously when subtitle settings change, but does not emit
            // a property-change notification for that dependency, so refresh
            // it explicitly for semantic-subtitle stream consumers.
            refreshTextSubtitleSnapshot()
        }
    }

    func setPropertyImmediately(_ name: String, to value: String) -> Int32 {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        return mpv_set_property_string(handle, name, value)
    }

    func getFlag(_ name: String) -> Bool? {
        guard let handle else { return nil }
        var value: Int32 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else { return nil }
        return value != 0
    }

    func getInt64(_ name: String) -> Int64? {
        guard let handle else { return nil }
        var value: Int64 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return value
    }

    func getDouble(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value: Double = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return nil }
        return value.isFinite ? value : nil
    }

    func getString(_ name: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(validatingCString: value)
    }

    func getNode(_ name: String) -> MPVNodeValue? {
        guard let handle else { return nil }
        var node = mpv_node()
        guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &node) >= 0 else { return nil }
        defer { mpv_free_node_contents(&node) }
        return MPVNodeValue(copying: node)
    }

    func check(_ status: Int32, context: String) throws(MPVPlayerError) {
        guard status < 0 else { return }
        throw .initializationFailed(context: context, code: status, message: mpvErrorMessage(status))
    }

    func mpvErrorMessage(_ code: Int32) -> String {
        mpv_error_string(code).map { String(cString: $0) } ?? "Unknown mpv error"
    }

    static func mpvPath(for url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }

    static func format(_ number: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), number)
    }

    static func format(_ duration: Duration) -> String {
        format(duration.seconds)
    }
}
