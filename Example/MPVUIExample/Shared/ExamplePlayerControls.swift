import MPVUI
import SwiftUI

@MainActor
struct ExamplePlayerControls: View {
    let player: MPVPlayer

    let mediaCatalog: [ExampleMedia]
    let media: ExampleMedia?
    let mediaTitle: String
    @Binding
    var isScrubbing: Bool
    @Binding
    var scrubPosition: Duration
    @Binding
    var requestedSidecarID: String?
    let selectMedia: (ExampleMedia) -> Void
    let openLocalFile: () -> Void
    let showInfo: () -> Void
    let hideOverlay: () -> Void
    let loadSidecar: (ExampleSubtitleSidecar) -> Void
    let disableSubtitles: () -> Void

    @State
    private var lastSettledPlaybackWasPlaying = false

    var body: some View {
        VStack {
            Spacer(minLength: 0)

            VStack(spacing: 8) {
                header
                transportButtons
                    .frame(maxWidth: .infinity, alignment: .center)
                timeline
            }
            .padding(12)
            .frame(maxWidth: 760)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .environment(\.colorScheme, .dark)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playerControls")
        .onChange(of: player.state) { _, state in
            switch state {
            case .playing, .buffering:
                lastSettledPlaybackWasPlaying = true
            case .idle, .ready, .paused, .ended, .stopped, .failed:
                lastSettledPlaybackWasPlaying = false
            case .loading, .seeking:
                break
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            mediaMenu
                .frame(maxWidth: .infinity, alignment: .leading)

            auxiliaryButton(
                systemImage: "info.circle",
                label: "Info",
                action: showInfo
            )
            .accessibilityIdentifier("infoButton")

            trackMenu

            auxiliaryButton(
                systemImage: "eye.slash",
                label: "Hide controls",
                action: hideOverlay
            )
            .accessibilityIdentifier("hideOverlayButton")
        }
    }

    private var mediaMenu: some View {
        Menu {
            ForEach(mediaCatalog) { item in
                Button {
                    selectMedia(item)
                } label: {
                    if item == media {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Text(item.title)
                    }
                }
                .accessibilityIdentifier("mediaChoice.\(item.id)")
            }

            if mediaCatalog.isEmpty {
                Button("No bundled media") {}
                    .disabled(true)
            }

            #if os(macOS) || os(iOS)
            Divider()
            Button(action: openLocalFile) {
                Label("Open File…", systemImage: "folder")
            }
            .accessibilityIdentifier("openLocalFileButton")
            #endif
        } label: {
            HStack(spacing: 6) {
                Text(mediaTitle)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Media")
        .accessibilityValue(mediaTitle)
        .accessibilityIdentifier("mediaMenu")
    }

    private var timeline: some View {
        HStack(spacing: 12) {
            Text(ExampleDisplayFormat.duration(displayedPosition))
                .accessibilityHidden(true)

            timelineControl

            Text(ExampleDisplayFormat.duration(player.duration))
                .accessibilityHidden(true)
        }
        .font(.caption.monospacedDigit())
    }

    @ViewBuilder
    private var timelineControl: some View {
        #if os(tvOS)
        ProgressView(
            value: displayedPosition.seconds,
            total: scrubberUpperBound.seconds
        )
        .progressViewStyle(.linear)
        .tint(.white)
        .frame(minHeight: 20)
        .accessibilityLabel("Playback position")
        .accessibilityValue(playbackPositionDescription)
        #else
        Slider(
            value: scrubberBinding,
            in: 0 ... scrubberUpperBound.seconds,
            onEditingChanged: scrubberEditingChanged
        )
        .tint(.white)
        .frame(minHeight: 44)
        .disabled(!canSeek)
        .accessibilityLabel("Playback position")
        .accessibilityValue(playbackPositionDescription)
        #endif
    }

    private var transportButtons: some View {
        HStack(spacing: 8) {
            transportButton(
                systemImage: "gobackward.10",
                label: "Go back 10 seconds",
                action: { player.seek(by: .seconds(-10)) }
            )
            .disabled(!player.isSeekable)
            .accessibilityIdentifier("jumpBackwardButton")

            transportButton(
                systemImage: displaysPauseButton ? "pause.fill" : "play.fill",
                label: displaysPauseButton ? "Pause" : "Play",
                prominent: true,
                action: player.togglePlayback
            )
            .disabled(!canTogglePlayback)
            .accessibilityIdentifier("playPauseButton")

            transportButton(
                systemImage: "goforward.10",
                label: "Go forward 10 seconds",
                action: { player.seek(by: .seconds(10)) }
            )
            .disabled(!player.isSeekable)
            .accessibilityIdentifier("jumpForwardButton")
        }
    }

    private func transportButton(
        systemImage: String,
        label: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 26 : 19, weight: .semibold))
                .frame(width: prominent ? 52 : 44, height: prominent ? 52 : 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func auxiliaryButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var trackMenu: some View {
        Menu {
            trackSubmenu(title: "Video", type: .video, tracks: player.videoTracks)
            trackSubmenu(title: "Audio", type: .audio, tracks: player.audioTracks)
            subtitleSubmenu
        } label: {
            Image(systemName: "captions.bubble")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tracks")
        .accessibilityIdentifier("tracksMenu")
    }

    private func trackSubmenu(
        title: String,
        type: MPVTrackType,
        tracks: [MPVMediaTrack]
    ) -> some View {
        Menu(title) {
            if type != .audio {
                Button("Off") {
                    if type == .subtitle {
                        requestedSidecarID = nil
                    }
                    player.disableTrack(type)
                }
            }

            if tracks.isEmpty {
                Button("No tracks") {}
                    .disabled(true)
            } else {
                ForEach(tracks) { track in
                    trackButton(track)
                }
            }
        }
    }

    private var subtitleSubmenu: some View {
        Menu("Subtitles") {
            Button("Off") {
                requestedSidecarID = nil
                disableSubtitles()
            }

            ForEach(player.subtitleTracks) { track in
                trackButton(track)
            }

            if !sidecars.isEmpty {
                Section("External") {
                    ForEach(sidecars) { sidecar in
                        Button {
                            loadSidecar(sidecar)
                        } label: {
                            if requestedSidecarID == sidecar.id {
                                Label(sidecar.title, systemImage: "checkmark")
                            } else {
                                Text(sidecar.title)
                            }
                        }
                    }
                }
            }

            if player.subtitleTracks.isEmpty, sidecars.isEmpty {
                Button("No tracks") {}
                    .disabled(true)
            }
        }
    }

    private var sidecars: [ExampleSubtitleSidecar] {
        media?.sidecars ?? []
    }

    private func trackButton(_ track: MPVMediaTrack) -> some View {
        Button {
            if track.type == .subtitle {
                requestedSidecarID = nil
            }
            player.selectTrack(track)
        } label: {
            if track.isSelected {
                Label(trackTitle(track), systemImage: "checkmark")
            } else {
                Text(trackTitle(track))
            }
        }
    }

    private func trackTitle(_ track: MPVMediaTrack) -> String {
        let candidates: [String?] = [track.title, track.language, track.codec]
        return candidates.compactMap(\.self).first(where: { !$0.isEmpty })
            ?? "Track \(track.mpvID)"
    }

    private var scrubberBinding: Binding<Double> {
        Binding(
            get: { displayedPosition.seconds },
            set: { scrubPosition = normalizedPosition(.seconds($0)) }
        )
    }

    private var scrubberUpperBound: Duration {
        guard player.duration > .zero else { return .seconds(1) }
        return player.duration
    }

    private var displayedPosition: Duration {
        isScrubbing ? scrubPosition : normalizedPosition(player.position)
    }

    private var canSeek: Bool {
        player.isSeekable && player.duration > .zero
    }

    private var displaysPauseButton: Bool {
        switch player.state {
        case .playing, .buffering:
            true
        case .seeking:
            lastSettledPlaybackWasPlaying
        default:
            false
        }
    }

    private var canTogglePlayback: Bool {
        switch player.state {
        case .idle, .loading, .failed:
            false
        default:
            true
        }
    }

    private var playbackPositionDescription: String {
        "\(ExampleDisplayFormat.duration(displayedPosition)) of \(ExampleDisplayFormat.duration(player.duration))"
    }

    private func scrubberEditingChanged(_ editing: Bool) {
        if editing {
            isScrubbing = true
            scrubPosition = normalizedPosition(player.position)
        } else {
            let target = scrubPosition
            isScrubbing = false
            player.seek(to: target)
        }
    }

    private func normalizedPosition(_ position: Duration) -> Duration {
        clamp(position, to: .zero ... scrubberUpperBound)
    }
}
