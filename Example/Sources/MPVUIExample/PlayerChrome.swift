import SwiftUI

/// Shared floating controls leave the video unobstructed between the center transport and bottom toolbar.
@MainActor
struct PlayerChrome: View {

    let model: PlayerModel
    let media: [ExampleMedia]

    @Binding
    var showFiles: Bool
    @Binding
    var showURL: Bool
    @Binding
    var showInfo: Bool
    @Binding
    var showControls: Bool

    private var showsAirPlaySurface: Bool {
        #if os(iOS)
        model.player.externalPlayback.isPreparing || model.player.externalPlayback.isPrepared
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            // Keep this in the same stack as the controls: Compose passes taps
            // through noninteractive siblings, but not through a separate overlay.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
            } label: {
                Color.clear
                    .playerSurfaceHitArea()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showControls ? "Hide playback controls" : "Show playback controls")
            .accessibilityValue(model.showsVideoSurface ? "" : "Audio playback")
            .accessibilityIdentifier("togglePlaybackControls")
            .ignoresSafeArea()

            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .opacity(showControls ? 1 : 0)

            TransportControls(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .playerControlsVisible(showControls && !showsAirPlaySurface)

            VStack(spacing: 10) {
                #if os(iOS)
                if showsAirPlaySurface {
                    AppleAirPlaySurface(model: model)

                    TransportControls(model: model)
                        .padding(.bottom, 12)
                        .playerControlsVisible(showControls)
                } else {
                    Spacer(minLength: 0)
                }
                #else
                Spacer(minLength: 0)
                #endif
                if let error = model.selectionError ?? model.error {
                    Text(error)
                        .font(.callout)
                        .padding()
                        .background(.black.opacity(0.8))
                        .playerControlsVisible(showControls)
                }

                HStack(spacing: 12) {
                    Menu {
                        #if !os(tvOS)
                        Button("Open file…") {
                            showFiles = true
                        }
                        #endif
                        Button("Open URL…") { showURL = true }

                        if !media.isEmpty {
                            Divider()

                            ForEach(media) { item in
                                Button(item.name) { model.load(item.url) }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            PlayerGlyph(name: "folder", size: 19)

                            Text(model.hasMedia ? model.selectedName : "Choose media")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .playerMediaTitle()

                            PlayerGlyph(name: "chevron.down", size: 12)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .playerCapsule()
                    }
                    .playerMenu()
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose media")
                    .accessibilityIdentifier("chooseMedia")

                    Spacer(minLength: 12)

                    HStack(spacing: 0) {
                        TrackMenu(model: model)

                        #if os(iOS)
                        AppleAirPlayButton(model: model)
                        #endif

                        #if !os(tvOS)
                        Button { model.player.pictureInPicture.start() } label: {
                            PlayerGlyph(name: "pip.enter", size: 22)
                                .frame(width: 46, height: 48)
                        }
                        .disabled(!model.canStartPictureInPicture)
                        .accessibilityLabel("Picture in picture")
                        .accessibilityIdentifier("pictureInPictureButton")
                        #endif

                        Button { showInfo = true } label: {
                            PlayerGlyph(name: "info.circle", size: 22)
                                .frame(width: 46, height: 48)
                        }
                        .accessibilityLabel("Info")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    .playerCapsule()
                    .accessibilityIdentifier("playerToolbar")
                    .fixedSize()
                }
                .playerControlsVisible(showControls)

                PlaybackTimeline(model: model)
                    .playerControlsVisible(showControls)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }

        // Keep both video outputs attached beneath the AirPlay screen so playback can switch back to mpv.
        // Keep the same route picker instance alive while its sheet is open.
        .background {
            if showsAirPlaySurface {
                Color.black
                    .ignoresSafeArea()
            }
        }
        .foregroundStyle(.white)
    }
}

@MainActor
struct TransportControls: View {

    let model: PlayerModel

    var body: some View {
        HStack(spacing: 24) {
            Button { model.player.seek(by: .seconds(-10)) } label: {
                PlayerGlyph(name: "gobackward.10", size: 28)
                    .frame(width: 60, height: 60)
                    .playerCapsule()
            }
            .disabled(!model.seekable)
            .accessibilityLabel("Back 10 seconds")

            Button { model.player.togglePlayback() } label: {
                PlayerGlyph(name: model.hasMedia && !model.paused ? "pause.fill" : "play.fill", size: 34)
                    .frame(width: 80, height: 80)
                    .playerCapsule()
            }
            .disabled(!model.hasMedia)
            .accessibilityLabel(model.hasMedia && !model.paused ? "Pause" : "Play")

            Button { model.player.seek(by: .seconds(10)) } label: {
                PlayerGlyph(name: "goforward.10", size: 28)
                    .frame(width: 60, height: 60)
                    .playerCapsule()
            }
            .disabled(!model.seekable)
            .accessibilityLabel("Forward 10 seconds")
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct TrackMenu: View {

    let model: PlayerModel

    var body: some View {
        Menu {
            trackSection("Video", kind: .video)
            trackSection("Audio", kind: .audio)

            Section("Subtitles") {
                subtitleMenu("Primary subtitles", role: .primary)
                subtitleMenu("Secondary subtitles", role: .secondary)
            }
        } label: {
            PlayerGlyph(name: "captions.bubble", size: 22)
                .frame(width: 46, height: 48)
        }
        .playerMenu()
        .disabled(!model.hasMedia)
        #if os(iOS)
        .disabled(model.player.externalPlayback.isPreparing || model.player.externalPlayback.isPrepared)
        #endif
        .accessibilityLabel("Tracks")
        .accessibilityIdentifier("tracksMenu")
    }

    @ViewBuilder
    func trackSection(_ title: String, kind: MPVTrackType) -> some View {
        Section(title) {
            let tracks = model.details.tracks.filter { $0.type == kind }

            if tracks.isEmpty {
                Text("No tracks")
            }

            ForEach(tracks) { track in
                Button((track.isSelected ? "✓ " : "") + track.exampleTitle) {
                    model.player.selectTrack(track.id)
                }
            }
        }
    }

    func subtitleMenu(_ title: String, role: MPVSubtitleRole) -> some View {
        Menu(title) {
            Button((model.details.tracks.contains { $0.subtitleRole == role } ? "" : "✓ ") + "Off") {
                model.player.selectSubtitle(nil, for: role)
            }

            ForEach(model.details.tracks.filter { $0.type == .subtitle }) { track in
                Button((track.subtitleRole == role ? "✓ " : "") + track.exampleTitle) {
                    model.player.selectSubtitle(track.id, for: role)
                }
            }
        }
    }
}
