import MPVUI
import SwiftUI

enum ExampleControlFocus: Hashable {
    case media
    case tracks
    case pictureInPicture
    case info
}

@MainActor
struct ExamplePlayerControls: View {
    let player: MPVPlayer
    let isVisible: Bool
    let mediaCatalog: [ExampleMedia]
    let media: ExampleMedia?
    let mediaTitle: String
    @Binding
    var isScrubbing: Bool
    @Binding
    var focusedControl: ExampleControlFocus
    let selectMedia: (ExampleMedia) -> Void
    let openLocalFile: () -> Void
    let showInfo: () -> Void
    let onInteraction: () -> Void
    let hideControls: () -> Void
    let loadSidecar: (ExampleSubtitleSidecar, MPVSubtitleRole) -> Void
    let disableSubtitles: (MPVSubtitleRole) -> Void
    let seek: (Duration) -> Void
    let jump: (Duration) -> Void
    let onBottomControlsHeightChange: (CGFloat) -> Void

    @State
    private var lastSettledPlaybackWasPlaying = false
    @FocusState
    private var focusedSelector: ExampleControlFocus?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 240)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            #if !os(tvOS)
            ExampleGlassControls {
                transportButtons
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            #endif

            VStack {
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    ExampleGlassControls {
                        selectors
                    }
                    ExamplePlaybackTimeline(
                        player: player,
                        isScrubbing: $isScrubbing,
                        onInteraction: onInteraction,
                        seek: seek
                    )
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, bottomPadding)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    onBottomControlsHeightChange($0)
                }
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playerControls")
        #if os(tvOS)
        .focusSection()
        .defaultFocus($focusedSelector, focusedControl)
        .onExitCommand(perform: hideControls)
        #endif
        .onChange(of: isVisible) { _, visible in
            focusedSelector = visible ? focusedControl : nil
        }
        .onChange(of: focusedSelector) { _, focus in
            guard let focus else { return }
            focusedControl = focus
            onInteraction()
        }
        .onAppear {
            focusedSelector = focusedControl
        }
        .onChange(of: player.state, initial: true) { _, state in
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

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        64
        #elseif os(macOS)
        32
        #else
        24
        #endif
    }

    private var bottomPadding: CGFloat {
        #if os(tvOS)
        36
        #else
        16
        #endif
    }

    private var selectors: some View {
        HStack(spacing: 12) {
            Menu {
                mediaChoices
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                    Text(mediaTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .frame(minHeight: 36)
                .padding(.horizontal, 4)
            }
            .menuIndicator(.hidden)
            .menuOrder(.fixed)
            .exampleGlassButton()
            .focused($focusedSelector, equals: .media)
            .accessibilityLabel("Media")
            .accessibilityValue(mediaTitle)
            .accessibilityIdentifier("mediaMenu")

            Spacer(minLength: 0)

            Menu {
                trackSection(title: "Video", type: .video, tracks: player.videoTracks)
                trackSection(title: "Audio", type: .audio, tracks: player.audioTracks)
                subtitleSection
            } label: {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 28, height: 36)
            }
            .menuIndicator(.hidden)
            .menuOrder(.fixed)
            .exampleGlassButton()
            .focused($focusedSelector, equals: .tracks)
            .accessibilityLabel("Tracks")
            .accessibilityIdentifier("tracksMenu")

            if player.pictureInPicture.isSupported {
                selectorButton(
                    systemImage: player.pictureInPicture.isActive ? "pip.exit" : "pip.enter",
                    label: player.pictureInPicture.isActive ? "Exit picture in picture" : "Picture in picture",
                    focus: .pictureInPicture,
                    action: player.pictureInPicture.toggle
                )
                .disabled((!player.pictureInPicture.isPossible && !player.pictureInPicture.isActive)
                    || player.pictureInPicture.isTransitioning)
                .accessibilityIdentifier("pictureInPictureButton")
            }

            selectorButton(systemImage: "info.circle", label: "Info", focus: .info, action: showInfo)
                .accessibilityIdentifier("infoButton")
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 24) {
            transportButton(systemImage: "gobackward.10", label: "Go back 10 seconds") {
                jump(.seconds(-10))
            }
            .disabled(!canSeek)
            .accessibilityIdentifier("jumpBackwardButton")

            transportButton(
                systemImage: displaysPauseButton ? "pause.fill" : "play.fill",
                label: displaysPauseButton ? "Pause" : "Play",
                prominent: true,
                action: player.togglePlayback
            )
            .disabled(!canTogglePlayback)
            .accessibilityIdentifier("playPauseButton")

            transportButton(systemImage: "goforward.10", label: "Go forward 10 seconds") {
                jump(.seconds(10))
            }
            .disabled(!canSeek)
            .accessibilityIdentifier("jumpForwardButton")
        }
    }

    private func transportButton(
        systemImage: String,
        label: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            onInteraction()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 32 : 24, weight: .semibold))
                .frame(width: prominent ? 64 : 44, height: prominent ? 76 : 56)
        }
        .exampleGlassButton()
        .accessibilityLabel(label)
    }

    private func selectorButton(
        systemImage: String,
        label: String,
        focus: ExampleControlFocus,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            focusedControl = focus
            onInteraction()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 28, height: 36)
        }
        .exampleGlassButton()
        .focused($focusedSelector, equals: focus)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var mediaChoices: some View {
        ForEach(mediaCatalog) { item in
            Button {
                onInteraction()
                selectMedia(item)
            } label: {
                selectionLabel(item.title, selected: item == media)
            }
            .accessibilityIdentifier("mediaChoice.\(item.id)")
        }
        if mediaCatalog.isEmpty {
            Text("No bundled media")
        }
        #if os(macOS) || os(iOS)
        Divider()
        Button {
            onInteraction()
            openLocalFile()
        } label: {
            Label("Open File…", systemImage: "folder")
        }
        .accessibilityIdentifier("openLocalFileButton")
        #endif
    }

    private func trackSection(title: String, type: MPVTrackType, tracks: [MPVMediaTrack]) -> some View {
        Section(title) {
            if type == .video {
                Button {
                    onInteraction()
                    player.disableTrack(type)
                } label: {
                    selectionLabel("Off", selected: !tracks.contains(where: \.isSelected))
                }
            }
            if tracks.isEmpty {
                Text("No tracks").foregroundStyle(.secondary)
            }
            ForEach(tracks) { track in trackButton(track) }
        }
    }

    private var subtitleSection: some View {
        Section("Subtitles") {
            subtitleMenu(for: .primary, title: "Primary subtitles")
            subtitleMenu(for: .secondary, title: "Secondary subtitles")
        }
    }

    private func subtitleMenu(for role: MPVSubtitleRole, title: String) -> some View {
        Menu {
            Button {
                onInteraction()
                disableSubtitles(role)
            } label: {
                selectionLabel("Off", selected: player.selectedSubtitle(for: role) == nil)
            }
            ForEach(player.subtitleTracks) { track in
                Button {
                    onInteraction()
                    player.selectSubtitle(track.id, for: role)
                } label: {
                    selectionLabel(trackTitle(track), selected: track.subtitleRole == role)
                }
                .accessibilityIdentifier("subtitle.\(role.rawValue).\(track.mpvID)")
            }
            if let sidecars = media?.sidecars, !sidecars.isEmpty {
                Section("Load external subtitles") {
                    ForEach(sidecars) { sidecar in
                        Button(sidecar.title) {
                            onInteraction()
                            loadSidecar(sidecar, role)
                        }
                    }
                }
            }
        } label: {
            Text(title)
        }
        .accessibilityIdentifier("subtitleMenu.\(role.rawValue)")
    }

    private func trackButton(_ track: MPVMediaTrack) -> some View {
        Button {
            onInteraction()
            player.selectTrack(track.id)
        } label: {
            selectionLabel(trackTitle(track), selected: track.isSelected)
        }
    }

    @ViewBuilder
    private func selectionLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func trackTitle(_ track: MPVMediaTrack) -> String {
        let candidates: [String?] = [track.title, track.language, track.codec]
        return candidates.compactMap(\.self).first(where: { !$0.isEmpty }) ?? "Track \(track.mpvID)"
    }

    private var canSeek: Bool {
        player.isSeekable && player.duration > .zero
    }

    private var displaysPauseButton: Bool {
        switch player.state {
        case .playing, .buffering: true
        case .seeking: lastSettledPlaybackWasPlaying
        default: false
        }
    }

    private var canTogglePlayback: Bool {
        switch player.state {
        case .idle, .loading, .failed: false
        default: true
        }
    }
}
