import Foundation
import MPVUI
import SwiftUI

@MainActor
struct PlayerInspector: View {
    @Environment(\.dismiss)
    private var dismiss

    let media: ExampleMedia?
    let mediaTitle: String
    let localFileURL: URL?
    let player: MPVPlayer

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                playbackSection
                bufferSection
                decodedMediaSection
                hdrSection
                renderingSection
                dolbyVisionSection
                diagnosticsSection
                tracksSection
                errorSection
            }
            .navigationTitle("Player Info")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    #if os(macOS)
                    .keyboardShortcut(.defaultAction)
                    #endif
                    .accessibilityIdentifier("inspectorDoneButton")
                }
            }
        }
        .inspectorSheetPresentation()
        .accessibilityIdentifier("playerInspector")
    }

    @ViewBuilder
    private var sourceSection: some View {
        if let media {
            Section("Fixture") {
                InspectorRow("File", value: media.fileName, monospaced: true)
            }
        } else if let localFileURL {
            Section("Local File") {
                InspectorRow("Title", value: mediaTitle)
                InspectorRow("File", value: localFileURL.lastPathComponent, monospaced: true)
                InspectorRow(
                    "Location",
                    value: localFileURL.deletingLastPathComponent().path,
                    monospaced: true
                )
            }
        }
    }

    private var playbackSection: some View {
        Section("Playback") {
            InspectorRow("State", value: ExampleDisplayFormat.playbackState(player.state))
            InspectorPlaybackPositionRow(player: player)
            InspectorRow("Duration", value: ExampleDisplayFormat.duration(player.duration))
            InspectorRow("Seekable", value: yesNo(player.isSeekable))
            InspectorRow(
                "Rate",
                value: "\(ExampleDisplayFormat.decimal(player.playbackRate))×"
            )
            InspectorRow(
                "Volume",
                value: "\(ExampleDisplayFormat.decimal(player.volume))%"
            )
            InspectorRow("Muted", value: yesNo(player.isMuted))
        }
    }

    private var bufferSection: some View {
        Section("Buffer") {
            InspectorRow("Buffering", value: yesNo(player.bufferStatus.isBuffering))
            InspectorRow(
                "Resume Progress",
                value: ExampleDisplayFormat.percentage(player.bufferStatus.progress)
            )
            InspectorRow(
                "Ahead",
                value: ExampleDisplayFormat.decimal(
                    player.bufferStatus.secondsBufferedAhead,
                    suffix: "s"
                )
            )
            InspectorRow(
                "Buffered End",
                value: ExampleDisplayFormat.duration(player.bufferStatus.bufferedEnd)
            )
            InspectorRow(
                "Bytes Ahead",
                value: ExampleDisplayFormat.bytes(player.bufferStatus.bytesAhead)
            )
            InspectorRow(
                "Input Rate",
                value: ExampleDisplayFormat.dataRate(player.bufferStatus.inputRate)
            )
            InspectorRow(
                "Seekable Ranges",
                value: "\(player.bufferStatus.seekableRanges.count)"
            )
        }
    }

    private var decodedMediaSection: some View {
        Section("Decoded Media") {
            InspectorRow("Title", value: player.mediaInformation.title ?? "—")
            InspectorRow("Container", value: player.mediaInformation.container ?? "—")
            InspectorRow(
                "File Size",
                value: ExampleDisplayFormat.bytes(player.mediaInformation.fileSize)
            )
            InspectorRow("Video Codec", value: player.mediaInformation.videoCodec ?? "—")
            InspectorRow("Audio Codec", value: player.mediaInformation.audioCodec ?? "—")
            InspectorRow(
                "Decoder",
                value: decoderSessionName
            )
            InspectorRow(
                "Video Output",
                value: player.videoOutput == .sampleBuffer ? "AVFoundation" : "Metal (gpu-next)"
            )
            if let reason = player.videoOutputFallbackReason {
                InspectorRow("Output Fallback", value: reason)
            }
            InspectorRow("Dimensions", value: decodedDimensions)
            InspectorRow(
                "Frame Rate",
                value: ExampleDisplayFormat.frameRate(player.mediaInformation.framesPerSecond)
            )
            InspectorRow("Rotation", value: "\(player.mediaInformation.rotation)°")
            InspectorRow("Chapters", value: "\(player.mediaInformation.chapters.count)")
        }
    }

    private var hdrSection: some View {
        Section {
            InspectorRow("Source Transfer", value: ExampleDisplayFormat.transferFunction(hdr.source.transferFunction))
            InspectorRow("Requested Range", value: hdrPolicyName(player.configuration.hdrPolicy))
            InspectorRow("Configured Range", value: dynamicRangeName(hdr.presentation.configuredDynamicRange))
            InspectorRow("OS Presentation", value: dynamicRangeName(hdr.presentation.actualDynamicRange))
            InspectorDisclosureGroup("Display and color conversion") {
                InspectorRow("HDR Support", value: readable(hdr.displayCapabilities.hdrSupport.rawValue))
                InspectorRow("Wide Gamut", value: yesNo(hdr.displayCapabilities.supportsWideGamut))
                InspectorRow("Current Headroom", value: number(hdr.displayCapabilities.currentEDRHeadroom, suffix: "× SDR white"))
                InspectorRow("Potential Headroom", value: number(hdr.displayCapabilities.potentialEDRHeadroom, suffix: "× SDR white"))
                InspectorRow("Conversion Owner", value: colorOwnerName)
                InspectorRow("Output Precision", value: colorPrecisionName)
                InspectorRow("Target Primaries", value: player.renderColorStatus.targetPrimaries ?? "Unknown")
                InspectorRow("Target Transfer", value: player.renderColorStatus.targetTransfer ?? "Unknown")
                InspectorRow("Display Profile", value: player.renderColorStatus.displayProfileName ?? "Unknown")
                if let url = player.renderColorStatus.calibratedProfileURL ?? player.renderColorStatus.calibratedLUTURL {
                    InspectorRow("Calibration File", value: url.lastPathComponent)
                }
                InspectorRow("Reference White Model", value: number(player.renderColorStatus.referenceWhite, suffix: "nits"))
                InspectorRow("SDR Viewing", value: player.renderColorStatus.sdrViewing.map { readable($0.rawValue) } ?? "Unknown")
                if let fallback = player.renderColorStatus.fallbackReason {
                    InspectorRow("Color Fallback", value: colorFallbackName(fallback))
                }
                if let fallback = hdr.presentation.fallbackReason {
                    InspectorRow("Range Fallback", value: presentationFallbackName(fallback))
                }
            }
            InspectorDisclosureGroup("Signal metadata") {
                InspectorRow("Source", value: signalDescription(hdr.source))
                InspectorRow("After Decode", value: signalDescription(hdr.decoded))
                InspectorRow("After Filters", value: signalDescription(hdr.videoOutputInput))
                InspectorRow("Renderer Output", value: signalDescription(hdr.output))
                InspectorRow("Mastering Minimum", value: number(hdr.minimumLuminance, suffix: "nits"))
                InspectorRow("Mastering Maximum", value: number(hdr.maximumLuminance, suffix: "nits"))
                InspectorRow("MaxCLL", value: number(hdr.maxContentLightLevel, suffix: "nits"))
                InspectorRow("MaxFALL", value: number(hdr.maxFrameAverageLightLevel, suffix: "nits"))
                InspectorRow("HDR10+ Metadata", value: yesNo(hdr.source.hasHDR10PlusMetadata))
            }
        } header: {
            Text("Color & HDR")
        } footer: {
            Text(
                "Configured settings describe the rendering pipeline. Screen luminance is not measured; OS presentation remains Unknown when it cannot be established."
            )
        }
    }

    private var renderingSection: some View {
        Section("Rendering") {
            InspectorDisclosureGroup("Quality settings") {
                InspectorRow("Requested Preset", value: readable(player.configuration.renderingQuality.preset.rawValue))
                InspectorRow("Effective Preset", value: effectivePresetName)
                ForEach(qualitySettings, id: \.0) { title, key in
                    InspectorRow(title, value: diagnostics.renderingQuality.effectiveOptions[key] ?? "Unknown / not applied")
                }
                if !diagnostics.renderingQuality.unsupportedFeatures.isEmpty {
                    InspectorRow("Not Applied", value: diagnostics.renderingQuality.unsupportedFeatures.joined(separator: "; "))
                }
                Text("Effective values are accepted renderer settings. Quality changes require recreating the player and reloading media.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            InspectorDisclosureGroup("Deinterlacing") {
                InspectorRow("Requested Mode", value: readable(player.configuration.deinterlace.mode.rawValue))
                InspectorRow("Requested Algorithm", value: readable(player.configuration.deinterlace.algorithm.rawValue))
                InspectorRow("Requested Field Order", value: fieldOrderName)
                InspectorRow("Active", value: yesNo(diagnostics.deinterlace.isActive))
                InspectorRow("Effective Filter", value: diagnostics.deinterlace.effectiveFilter ?? "Unknown / none reported")
                InspectorRow("Software Frames", value: yesNo(diagnostics.deinterlace.requiresSoftwareFrames))
                InspectorRow("Output Interlaced", value: yesNo(diagnostics.deinterlace.outputFrameIsInterlaced))
                InspectorRow("Filter Output Rate", value: frameRate(diagnostics.estimatedFilterFramesPerSecond))
                if let reason = diagnostics.deinterlace.reason {
                    InspectorRow("Details", value: reason)
                }
            }
            InspectorDisclosureGroup("Features for this item") {
                ForEach(MPVVideoFeature.allCases, id: \.self) { feature in
                    InspectorRow(featureName(feature), value: capabilityDescription(player.videoFeatureCapabilities[feature]))
                }
                if let request = player.videoFeatureRequestResult {
                    InspectorRow("Feature Request", value: readable(request.outcome.rawValue))
                    InspectorRow("Reload Required", value: yesNo(request.requiresReload))
                    InspectorRow("PiP Lost with Fallback", value: yesNo(request.losesPictureInPicture))
                    if let reason = request.reason {
                        InspectorRow("Details", value: reason)
                    }
                }
                Text("Inline app overlays do not modify video pixels. PiP availability also depends on the device and current session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dolbyVisionSection: some View {
        Section("Dolby Vision") {
            InspectorRow(
                "Requested Policy",
                value: player.configuration.dolbyVisionPolicy == .strict ? "Strict" : "Lossy Profile 7 compatibility"
            )
            InspectorRow(
                "Source Profile",
                value: dolbyProfile(
                    player.dolbyVisionStatus.sourceProfile,
                    compatibility: player.dolbyVisionStatus.sourceBaseLayerCompatibilityID
                )
            )
            InspectorRow(
                "Effective Native Profile",
                value: dolbyProfile(
                    player.dolbyVisionStatus.effectiveProfile,
                    compatibility: player.dolbyVisionStatus.effectiveBaseLayerCompatibilityID
                )
            )
            InspectorDisclosureGroup("Validation and conversion") {
                InspectorRow("Native RPU Validation", value: readable(player.dolbyVisionStatus.nativeValidation.rawValue))
                InspectorRow("Conversion", value: readable(player.dolbyVisionStatus.conversion.rawValue))
                InspectorRow("Enhancement Layer", value: readable(player.dolbyVisionStatus.enhancementLayer.rawValue))
                if let reason = player.dolbyVisionStatus.reason {
                    InspectorRow("Details", value: reason)
                }
                Text(
                    "Native validation is decoder evidence, not proof of the TV's output. Compatibility conversion discards the enhancement layer and does not reproduce full FEL video. Policy changes require a new player and media reload."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Playback Diagnostics") {
            InspectorDisclosureGroup("Timing and frame delivery") {
                InspectorRow("Decoder Drops", value: count(diagnostics.decoderDroppedFrames))
                InspectorRow("Output Drops", value: count(diagnostics.outputDroppedFrames))
                InspectorRow("Mistimed Frames", value: count(diagnostics.mistimedFrames))
                InspectorRow("Delayed Frames", value: count(diagnostics.delayedFrames))
                InspectorRow("Audio / Video Drift", value: milliseconds(diagnostics.audioVideoDriftSeconds))
                InspectorRow("Start Latency", value: milliseconds(diagnostics.startLatencySeconds))
                InspectorRow("Seek Latency", value: milliseconds(diagnostics.seekLatencySeconds))
                InspectorRow("Container Rate", value: frameRate(diagnostics.containerFramesPerSecond))
                InspectorRow("Decoded Rate", value: frameRate(diagnostics.estimatedDecodedFramesPerSecond))
                InspectorRow("Filter Output Rate", value: frameRate(diagnostics.estimatedFilterFramesPerSecond))
                InspectorRow("Nominal Display Rate", value: frameRate(diagnostics.nominalDisplayFramesPerSecond))
                InspectorRow("Estimated Refresh", value: frameRate(diagnostics.estimatedDisplayFramesPerSecond))
                Text(
                    "These are player counters and timing estimates. Start and seek latency end at playback restart, not at a measured HDMI-visible frame."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            InspectorDisclosureGroup("Decoder and render work") {
                InspectorRow("Selected Decoder", value: diagnostics.decoder.selectedDecoder ?? "Unknown")
                InspectorRow("Decoder Session", value: decoderSessionName)
                InspectorRow("VideoToolbox Hardware", value: yesNo(diagnostics.decoder.videoToolboxSessionUsesHardware))
                InspectorRow("VideoToolbox Codec Probe", value: yesNo(diagnostics.decoder.videoToolboxSupportsCodec))
                InspectorRow("Pixel Format", value: diagnostics.decoder.decodedPixelFormat ?? "Unknown")
                InspectorRow("Interop", value: diagnostics.decoder.interop ?? "Unknown")
                InspectorRow("Native Buffer Copies", value: count(diagnostics.nativeOutputStatistics?.pixelBufferCopies))
                InspectorRow("Native Samples Built", value: count(diagnostics.nativeOutputStatistics?.sampleBuildCount))
                InspectorRow(
                    "Last Sample Build",
                    value: milliseconds(diagnostics.nativeOutputStatistics?.lastSampleBuildNanoseconds.map { Double($0) / 1_000_000_000 })
                )
                ForEach(Array(slowestRenderPasses.enumerated()), id: \.offset) { _, pass in
                    InspectorRow("GPU · \(pass.name)", value: milliseconds(pass.averageNanoseconds.map { Double($0) / 1_000_000_000 }))
                }
                if slowestRenderPasses.isEmpty {
                    InspectorRow("GPU Pass Timings", value: "Unknown")
                }
                Text(
                    "Copy counts cover native output work only. The codec probe does not establish support for every profile, bit depth or resolution."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !diagnostics.fallbackReasons.isEmpty {
                InspectorRow("Fallback Details", value: diagnostics.fallbackReasons.joined(separator: "; "))
            }
        }
    }

    private var tracksSection: some View {
        Section("Tracks") {
            InspectorTrackRows(title: "Video", tracks: player.videoTracks)
            InspectorTrackRows(title: "Audio", tracks: player.audioTracks)
            InspectorTrackRows(title: "Subtitles", tracks: player.subtitleTracks)
        }
    }

    private var errorSection: some View {
        Section("Error") {
            if let error = player.lastError {
                InspectorRow("Description", value: error.localizedDescription)
                Button("Clear Error") {
                    player.clearLastError()
                }
                .accessibilityIdentifier("clearPlayerErrorButton")
            } else {
                InspectorRow("Latest", value: "None")
            }
        }
    }

    private var decodedDimensions: String {
        guard let dimensions = player.mediaInformation.dimensions else { return "—" }
        return ExampleDisplayFormat.dimensions(
            width: dimensions.effectiveWidth,
            height: dimensions.effectiveHeight
        )
    }

    private var hdr: MPVHDRStatus {
        player.mediaInformation.hdr
    }

    private var diagnostics: MPVPlaybackDiagnostics {
        player.playbackDiagnostics
    }

    private var qualitySettings: [(String, String)] {
        [
            ("Scaling", "scale"),
            ("Chroma Scaling", "cscale"),
            ("Debanding", "deband"),
            ("Dithering", "dither"),
            ("Tone Mapping", "tone-mapping"),
            ("Gamut Mapping", "gamut-mapping-mode")
        ]
    }

    private var effectivePresetName: String {
        if player.videoOutput == .sampleBuffer {
            return "Managed by AVFoundation"
        }
        guard !diagnostics.renderingQuality.effectiveOptions.isEmpty else { return "Unknown" }
        return readable(diagnostics.renderingQuality.resolvedPreset.rawValue)
    }

    private var colorOwnerName: String {
        switch player.renderColorStatus.conversionOwner {
        case .unknown: "Unknown"
        case .colorSync: "ColorSync · system display profile"
        case .libplaceboCalibratedICC: "Renderer · calibrated ICC"
        case .libplaceboCalibratedLUT: "Renderer · calibrated LUT"
        case .avFoundation: "AVFoundation"
        }
    }

    private var colorPrecisionName: String {
        switch player.renderColorStatus.precision {
        case .unknown: "Unknown"
        case .unorm8: "8-bit normalized"
        case .float16: "16-bit float"
        case .sourceManaged: "Managed by native output"
        }
    }

    private var fieldOrderName: String {
        switch player.configuration.deinterlace.fieldOrder {
        case .automatic: "Automatic"
        case .topFirst: "Top field first"
        case .bottomFirst: "Bottom field first"
        }
    }

    private var decoderSessionName: String {
        switch diagnostics.decoder.session {
        case .unknown: "Unknown"
        case .software: "Software"
        case let .hardware(name): "Hardware API · \(name)"
        }
    }

    private var slowestRenderPasses: [MPVPlaybackDiagnostics.RenderPass] {
        Array((diagnostics.freshRenderPasses ?? []).sorted {
            ($0.averageNanoseconds ?? -1) > ($1.averageNanoseconds ?? -1)
        }.prefix(3))
    }

    private func hdrPolicyName(_ policy: MPVPlayerConfiguration.HDRPolicy) -> String {
        switch policy {
        case .automatic: "Automatic"
        case .always: "HDR when available"
        case .disabled: "SDR"
        case .constrained: "Constrained HDR"
        }
    }

    private func dynamicRangeName(_ range: MPVPresentationStatus.DynamicRange) -> String {
        switch range {
        case .unknown: "Unknown"
        case .automatic: "Chosen by the OS"
        case .sdr: "SDR"
        case .hdr: "HDR"
        case .constrainedHDR: "Constrained HDR"
        }
    }

    private func colorFallbackName(_ fallback: MPVRenderColorStatus.FallbackReason) -> String {
        switch fallback {
        case .calibratedICCRequiresMacOS: "Display calibration requires macOS."
        case .calibratedICCRequiresSDRMetal: "Display calibration requires SDR Metal output."
        case .invalidRGBDisplayProfile: "The RGB display profile is invalid."
        case .invalidCalibrationLUT: "The calibration LUT is invalid."
        case .currentDisplayProfileUnavailable: "The current display profile is unavailable."
        case .nativeManagesPrecision: "Native output manages precision."
        }
    }

    private func presentationFallbackName(_ fallback: MPVPresentationStatus.FallbackReason) -> String {
        switch fallback {
        case .unsupportedPolicy: "The requested range policy is unsupported."
        case .unsupportedSubtitleLuminance: "The native build cannot apply subtitle luminance."
        case .displayDoesNotSupportHDR: "The display route does not support HDR."
        case .insufficientCurrentHeadroom: "Current display headroom is insufficient."
        case let .nativeOutputUnavailable(reason), let .liveConfigurationFailed(reason): reason
        }
    }

    private func signalDescription(_ signal: MPVVideoSignal) -> String {
        let depth = signal.bitDepth.map { "\($0)-bit" } ?? "Unknown depth"
        return [
            signal.primaries ?? "Unknown primaries",
            ExampleDisplayFormat.transferFunction(signal.transferFunction),
            signal.range ?? "Unknown range",
            depth
        ].joined(separator: " · ")
    }

    private func dolbyProfile(_ profile: Int?, compatibility: Int?) -> String {
        guard let profile else { return "Unknown / not reported" }
        if profile == 8, let compatibility {
            return [1, 4].contains(compatibility) ? "8.\(compatibility)" : "8 · compatibility ID \(compatibility)"
        }
        return String(profile) + (profile == 8 ? " · subtype unknown" : "")
    }

    private func featureName(_ feature: MPVVideoFeature) -> String {
        switch feature {
        case .nativeSubtitles: "ASS / Bitmap Subtitles"
        case .bakedOverlays: "Baked Video Overlays"
        case .zoomAndPan: "Zoom / Pan"
        case .inlineSwiftUIOverlays: "Inline App Overlays"
        case .pictureInPictureSubtitles: "PiP App Subtitles"
        }
    }

    private func capabilityDescription(_ capability: MPVVideoFeatureCapabilities.Capability) -> String {
        switch capability.restriction {
        case .none: readable(capability.availability.rawValue)
        case .awaitingVideoMetadata: "Unknown · awaiting video metadata"
        case .nativeDolbyVisionPreservesRPU: "Unavailable · preserving native DV frames"
        case .pictureInPictureRequiresNativeOutput: "Unavailable · PiP requires native output"
        case .pictureInPictureUnavailableOnPlatform: "Unavailable on this platform"
        }
    }

    private func readable(_ raw: String) -> String {
        raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func number(_ value: Double?, suffix: String = "") -> String {
        guard let value, value.isFinite else { return "Unknown" }
        return ExampleDisplayFormat.decimal(value, suffix: suffix)
    }

    private func count(_ value: Int64?) -> String {
        value.map(String.init) ?? "Unknown"
    }

    private func milliseconds(_ seconds: Double?) -> String {
        number(seconds.map { $0 * 1000 }, suffix: "ms")
    }

    private func frameRate(_ rate: Double?) -> String {
        rate == nil ? "Unknown" : ExampleDisplayFormat.frameRate(rate)
    }

    private func yesNo(_ value: Bool?) -> String {
        value.map { $0 ? "Yes" : "No" } ?? "Unknown"
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }
}

@MainActor
private struct InspectorDisclosureGroup<Content: View>: View {
    let title: String
    let content: Content
    @State
    private var isExpanded = false

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        #if os(tvOS)
        Button {
            isExpanded.toggle()
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            }
        }
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        if isExpanded {
            content
        }
        #else
        DisclosureGroup(title, isExpanded: $isExpanded) { content }
        #endif
    }
}

// Observe position only in this row, rather than rebuilding the entire inspector.
@MainActor
private struct InspectorPlaybackPositionRow: View {
    let player: MPVPlayer

    var body: some View {
        InspectorRow("Position", value: ExampleDisplayFormat.duration(player.position))
    }
}

@MainActor
private struct InspectorRow: View {
    let title: String
    let value: String
    let monospaced: Bool

    init(_ title: String, value: String, monospaced: Bool = false) {
        self.title = title
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .fontDesign(monospaced ? .monospaced : .default)
                .multilineTextAlignment(.trailing)
                .inspectorTextSelectionEnabled()
        }
    }
}

@MainActor
private struct InspectorTrackRows: View {
    let title: String
    let tracks: [MPVMediaTrack]

    var body: some View {
        if tracks.isEmpty {
            InspectorRow(title, value: "None")
        } else {
            ForEach(tracks) { track in
                InspectorRow(
                    "\(title) \(track.mpvID)\(track.isSelected ? " · Selected" : "")",
                    value: ExampleDisplayFormat.track(track)
                )
            }
        }
    }
}

fileprivate extension View {
    @ViewBuilder
    func inspectorSheetPresentation() -> some View {
        #if os(macOS)
        // The default macOS Form is a non-scrolling columns layout. Grouped
        // rows scroll inside the sheet instead of expanding beyond its bounds.
        formStyle(.grouped)
            .frame(minWidth: 480, minHeight: 420)
            .presentationSizing(.form)
        #else
        self
        #endif
    }

    @ViewBuilder
    func inspectorTextSelectionEnabled() -> some View {
        #if os(tvOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }
}
