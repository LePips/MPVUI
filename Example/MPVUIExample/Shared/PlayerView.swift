import Foundation
import MPVUI
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UniformTypeIdentifiers
#endif

@MainActor
struct PlayerView: View {
    private enum PlaybackSource: Hashable {
        case bundled(ExampleMedia)
        case localFile(URL)
        case unavailable

        var bundledMedia: ExampleMedia? {
            guard case let .bundled(media) = self else { return nil }
            return media
        }

        var localFileURL: URL? {
            guard case let .localFile(url) = self else { return nil }
            return url
        }

        var title: String {
            switch self {
            case let .bundled(media):
                media.title
            case let .localFile(url):
                url.lastPathComponent
            case .unavailable:
                "No media found"
            }
        }
    }

    let player: MPVPlayer
    private let mediaCatalog: [ExampleMedia]

    @State
    private var playbackSource: PlaybackSource
    @State
    private var isShowingInspector = false
    @State
    private var isScrubbing = false
    @State
    private var scrubPosition: Duration = .zero
    @State
    private var requestedSidecarID: String?
    @State
    private var resourceError: String?
    @State
    private var textSubtitles = TextSubtitleSnapshot()
    @State
    private var isShowingControls = true
    #if os(iOS)
    @State
    private var isShowingFileImporter = false
    #endif

    init(player: MPVPlayer) {
        let mediaCatalog = ExampleMedia.catalog()

        self.player = player
        self.mediaCatalog = mediaCatalog
        _playbackSource = State(
            initialValue: mediaCatalog.first.map(PlaybackSource.bundled)
                ?? .unavailable
        )
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            MPVVideoPlayer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .accessibilityIdentifier("exampleVideoPlayer")

            if !isShowingControls {
                Button(action: showControls) {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show controls")
                .accessibilityIdentifier("showOverlayButton")
            }

            TextSubtitleOverlay(
                snapshot: textSubtitles,
                videoSize: subtitleVideoSize
            )

            if isShowingControls {
                ExamplePlayerControls(
                    player: player,
                    mediaCatalog: mediaCatalog,
                    media: playbackSource.bundledMedia,
                    mediaTitle: playbackSource.title,
                    isScrubbing: $isScrubbing,
                    scrubPosition: $scrubPosition,
                    requestedSidecarID: $requestedSidecarID,
                    selectMedia: selectMedia,
                    openLocalFile: openLocalFile,
                    showInfo: { isShowingInspector = true },
                    hideOverlay: hideControls,
                    loadSidecar: loadSidecar,
                    disableSubtitles: disableSubtitles
                )
                .safeAreaPadding(12)
                .transition(.opacity)
            }
        }
        .background(.black)
        #if os(macOS)
            .background(MacWindowAspectRatioView(videoSize: videoPresentationSize))
        #elseif os(iOS)
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false,
                onCompletion: importLocalFiles
            )
        #endif
            .exampleStatusBarHidden(true)
                .examplePlayPauseCommand(player.togglePlayback)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("playerView")
                .task(id: playbackSource) {
                    let subtitles = player.textSubtitleStream()
                    textSubtitles = TextSubtitleSnapshot()
                    loadCurrentMedia()

                    for await snapshot in subtitles {
                        guard !Task.isCancelled else { return }
                        textSubtitles = snapshot
                    }
                }
                .sheet(isPresented: $isShowingInspector) {
                    PlayerInspector(
                        media: playbackSource.bundledMedia,
                        mediaTitle: playbackSource.title,
                        localFileURL: playbackSource.localFileURL,
                        player: player
                    )
                }
                .alert(
                    "Resource Unavailable",
                    isPresented: Binding(
                        get: { resourceError != nil },
                        set: { isPresented in
                            if !isPresented {
                                resourceError = nil
                            }
                        }
                    )
                ) {
                    Button("OK", role: .cancel) {
                        resourceError = nil
                    }
                    .accessibilityIdentifier("resourceErrorDismissButton")
                } message: {
                    Text(resourceError ?? "The selected resource could not be loaded.")
                }
    }

    private func selectMedia(_ media: ExampleMedia) {
        let source = PlaybackSource.bundled(media)
        if playbackSource == source {
            loadCurrentMedia()
        } else {
            playbackSource = source
        }
    }

    private func openLocalFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Open Media File"
        panel.message = "Choose a local media file to play."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectLocalFile(url)
        #elseif os(iOS)
        isShowingFileImporter = true
        #endif
    }

    private func selectLocalFile(_ url: URL) {
        let source = PlaybackSource.localFile(url)
        if playbackSource == source {
            loadCurrentMedia()
        } else {
            playbackSource = source
        }
    }

    #if os(iOS)
    private func importLocalFiles(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            selectLocalFile(url)
        case let .failure(error):
            resourceError = "The selected file could not be opened: \(error.localizedDescription)"
        }
    }
    #endif

    private func loadCurrentMedia() {
        requestedSidecarID = nil

        switch playbackSource {
        case let .localFile(url):
            resourceError = nil
            player.load(url)
        case let .bundled(media):
            resourceError = nil
            player.load(media.url)
        case .unavailable:
            resourceError = "No media files were found in the bundled Media resources."
        }
    }

    private func loadSidecar(_ sidecar: ExampleSubtitleSidecar) {
        resourceError = nil
        requestedSidecarID = sidecar.id
        player.loadExternalTrack(sidecar.url, type: .subtitle, select: true)
    }

    private func disableSubtitles() {
        requestedSidecarID = nil
        player.disableTrack(.subtitle)
    }

    private func hideControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isShowingControls = false
        }
    }

    private func showControls() {
        guard !isShowingControls else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            isShowingControls = true
        }
    }

    private var videoPresentationSize: CGSize? {
        guard let dimensions = player.mediaInformation.dimensions else { return nil }

        var width = CGFloat(dimensions.effectiveWidth)
        var height = CGFloat(dimensions.effectiveHeight)
        guard width > 0, height > 0 else { return nil }

        let rotation = ((player.mediaInformation.rotation % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            swap(&width, &height)
        }

        return CGSize(width: width, height: height)
    }

    private var subtitleVideoSize: CGSize? {
        videoPresentationSize
    }
}

#if os(macOS)
private struct MacWindowAspectRatioView: NSViewRepresentable {
    let videoSize: CGSize?

    func makeNSView(context: Context) -> WindowAspectRatioView {
        let view = WindowAspectRatioView()
        view.videoSize = videoSize
        return view
    }

    func updateNSView(_ nsView: WindowAspectRatioView, context: Context) {
        nsView.videoSize = videoSize
    }
}

private final class WindowAspectRatioView: NSView {
    var videoSize: CGSize? {
        didSet {
            applyVideoAspectRatio()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyVideoAspectRatio()
    }

    private func applyVideoAspectRatio() {
        guard let window else { return }
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            window.contentAspectRatio = .zero
            return
        }

        window.contentAspectRatio = videoSize
    }
}
#endif

fileprivate extension View {
    @ViewBuilder
    func exampleStatusBarHidden(_ hidden: Bool) -> some View {
        #if os(iOS)
        statusBarHidden(hidden)
        #else
        self
        #endif
    }

    @ViewBuilder
    func examplePlayPauseCommand(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onPlayPauseCommand(perform: action)
        #else
        self
        #endif
    }
}
