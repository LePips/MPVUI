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
                tracksSection
                errorSection
            }
            .navigationTitle("Player Info")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("inspectorDoneButton")
                }
            }
        }
        .inspectorSheetSize()
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
            InspectorRow("Position", value: ExampleDisplayFormat.duration(player.position))
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
                value: player.mediaInformation.hardwareDecoder ?? "Software / unknown"
            )
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
        Section("HDR") {
            InspectorRow("Source", value: yesNo(hdr.isHDRContent))
            InspectorRow(
                "Transfer",
                value: ExampleDisplayFormat.transferFunction(hdr.transferFunction)
            )
            InspectorRow("Primaries", value: hdr.primaries ?? "—")
            InspectorRow("Display Capable", value: yesNo(hdr.isDisplayHDRCapable))
            InspectorRow("Output Active", value: yesNo(hdr.isHDRActive))
            InspectorRow(
                "Signal Peak",
                value: ExampleDisplayFormat.decimal(hdr.signalPeak)
            )
            InspectorRow(
                "Mastering Minimum",
                value: ExampleDisplayFormat.decimal(hdr.minimumLuminance, suffix: "nits")
            )
            InspectorRow(
                "Mastering Maximum",
                value: ExampleDisplayFormat.decimal(hdr.maximumLuminance, suffix: "nits")
            )
            InspectorRow(
                "MaxCLL",
                value: ExampleDisplayFormat.decimal(
                    hdr.maxContentLightLevel,
                    suffix: "nits"
                )
            )
            InspectorRow(
                "MaxFALL",
                value: ExampleDisplayFormat.decimal(
                    hdr.maxFrameAverageLightLevel,
                    suffix: "nits"
                )
            )
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

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
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
    func inspectorSheetSize() -> some View {
        #if os(macOS)
        frame(minWidth: 480, minHeight: 560)
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
