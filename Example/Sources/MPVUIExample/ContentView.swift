#if !os(Android)
import MPVUI
#endif
import SwiftUI

@MainActor
struct ContentView: View {

    @State
    var model: PlayerModel?

    var body: some View {
        Group {
            if let model {
                PlayerScreen(model: model)
            } else {
                Color.black
                    .ignoresSafeArea()
            }
        }
        .task {
            // View values can be reconstructed during recomposition. Create the
            // native player only after SwiftUI has restored this screen's State.
            if model == nil {
                model = PlayerModel()
            }
        }
    }
}

@MainActor
struct PlayerScreen: View {

    let model: PlayerModel

    @Environment(\.scenePhase)
    var scenePhase

    @State
    var showFiles = false
    @State
    var showURL = false
    @State
    var showInfo = false
    @State
    var showControls = true
    @State
    var networkURL = ""
    #if !os(Android)
    @State
    private var textSubtitles: TextSubtitleSnapshot?
    #endif

    #if !os(Android)
    private var subtitleVideoSize: CGSize? {
        guard let dimensions = model.player.mediaInformation.dimensions else { return nil }

        var width = CGFloat(dimensions.effectiveWidth)
        var height = CGFloat(dimensions.effectiveHeight)
        guard width > 0, height > 0 else { return nil }

        let rotation = ((model.player.mediaInformation.rotation % 360) + 360) % 360

        if rotation == 90 || rotation == 270 {
            swap(&width, &height)
        }

        return CGSize(width: width, height: height)
    }
    #endif

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            #if os(Android)
            MPVVideoPlayer(player: model.player, showsVideoSurface: model.showsVideoSurface)
                .ignoresSafeArea()
                .accessibilityIdentifier("exampleVideoPlayer")
            #else
            if model.showsVideoSurface {
                MPVVideoPlayer(player: model.player)
                    .videoOverlay {
                        if let textSubtitles {
                            TextSubtitleOverlay(
                                snapshot: textSubtitles,
                                videoSize: subtitleVideoSize
                            )
                        }
                    }
                    .ignoresSafeArea()
                    .accessibilityIdentifier("exampleVideoPlayer")
            }
            #endif
            if !model.showsVideoSurface {
                PlayerAudioArtwork()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .accessibilityLabel("Audio playback")
                    .accessibilityIdentifier("exampleAudioArtwork")
            }

            if !model.inPictureInPicture {
                PlayerChrome(
                    model: model,
                    media: model.media,
                    showFiles: $showFiles,
                    showURL: $showURL,
                    showInfo: $showInfo,
                    showControls: $showControls
                )
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showInfo) {
            PlayerInspector(model: model)
        }
        .alert("Open media URL", isPresented: $showURL) {
            TextField("https://example.com/video.mp4", text: $networkURL)

            Button("Open") { model.openNetworkURL(networkURL) }

            Button("Cancel", role: .cancel) {}
        }
        .exampleFileImporter(isPresented: $showFiles, model: model)
        #if !os(Android)
        .task {
            for await snapshot in model.subtitleStream {
                guard !Task.isCancelled else { return }

                textSubtitles = snapshot
            }
        }
        #endif
        .task(id: scenePhase) {
            await model.updateScenePhase(scenePhase)
        }
        .onChange(of: model.player.state) { _, _ in
            model.playbackStateChanged()
        }
        .alert("Picture in Picture", isPresented: Binding(
            get: { model.player.pictureInPicture.lastError != nil },
            set: {
                if !$0 {
                    model.player.pictureInPicture.clearLastError()
                }
            }
        )) {
            Button("OK") { model.player.pictureInPicture.clearLastError() }
        } message: {
            Text(model.player.pictureInPicture.lastError?.message ?? "Picture in picture could not start.")
        }
        #if os(tvOS)
        .onPlayPauseCommand { model.player.togglePlayback() }
        #endif
    }
}
