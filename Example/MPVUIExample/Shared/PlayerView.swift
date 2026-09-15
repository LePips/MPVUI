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
    private var resourceError: String?
    @State
    private var textSubtitles: TextSubtitleSnapshot?
    @State
    private var seekSubtitles = ExampleSeekSubtitles()
    @State
    private var bottomControlsHeight: CGFloat = 0
    @State
    private var bottomSafeAreaInset: CGFloat = 0
    @State
    private var isShowingControls = true
    @State
    private var controlsHideTask: Task<Void, Never>?
    @State
    private var focusedControl: ExampleControlFocus = .media
    @Environment(\.scenePhase)
    private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled)
    private var isVoiceOverEnabled
    #if os(macOS)
    @State
    private var isShowingOpenPanel = false
    #elseif os(tvOS)
    @FocusState
    private var isRemoteSurfaceFocused: Bool
    #endif
    #if os(iOS)
    @State
    private var isShowingFileImporter = false
    #endif

    init(player: MPVPlayer) {
        let mediaCatalog = ExampleMedia.catalog()

        self.player = player
        self.mediaCatalog = mediaCatalog
        _playbackSource = State(
            initialValue: mediaCatalog.first
                .map(PlaybackSource.bundled)
                ?? .unavailable
        )
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            MPVVideoPlayer(player: player)
                .videoOverlay {
                    if player.pictureInPicture.isActive, let textSubtitles = seekSubtitles.snapshot ?? textSubtitles {
                        TextSubtitleOverlay(
                            snapshot: textSubtitles,
                            videoSize: subtitleVideoSize,
                            scalesWithVideo: true,
                            bottomClearance: seekSubtitles.snapshot != nil && isShowingControls
                                ? bottomControlsHeight + bottomSafeAreaInset + 16 : 0
                        )
                    }
                }
                .overlay {
                    if !player.pictureInPicture.isActive, let textSubtitles = seekSubtitles.snapshot ?? textSubtitles {
                        TextSubtitleOverlay(
                            snapshot: textSubtitles,
                            videoSize: subtitleVideoSize,
                            scalesWithVideo: false,
                            bottomClearance: isShowingControls
                                ? bottomControlsHeight + bottomSafeAreaInset + 16 : 0
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .accessibilityIdentifier("exampleVideoPlayer")
                #if os(iOS) || os(macOS)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleControls)
                #endif

            #if os(tvOS)
            if !isShowingControls {
                Color.clear
                    .contentShape(Rectangle())
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isRemoteSurfaceFocused)
                    .onTapGesture(perform: showControls)
                    .onMoveCommand(perform: handleRemoteMove)
                    .accessibilityLabel("Playback")
                    .accessibilityHint("Select to show playback controls.")
                    .onAppear { isRemoteSurfaceFocused = true }
            }
            #endif

            // Keep menu anchors mounted when the overlay fades, so an open
            // SwiftUI Menu is not dismissed by the auto-hide timer.
            ExamplePlayerControls(
                player: player,
                isVisible: isShowingControls,
                mediaCatalog: mediaCatalog,
                media: playbackSource.bundledMedia,
                mediaTitle: playbackSource.title,
                isScrubbing: $isScrubbing,
                focusedControl: $focusedControl,
                selectMedia: selectMedia,
                openLocalFile: openLocalFile,
                showInfo: { isShowingInspector = true },
                onInteraction: showControls,
                hideControls: hideControls,
                loadSidecar: loadSidecar,
                disableSubtitles: disableSubtitles,
                seek: seek,
                jump: jump,
                onBottomControlsHeightChange: { bottomControlsHeight = $0 }
            )
            .opacity(isShowingControls ? 1 : 0)
            .allowsHitTesting(isShowingControls)

            #if os(iOS) || os(macOS)
            if !isShowingControls {
                Button(action: showControls) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show playback controls")
                .accessibilityIdentifier("showControlsButton")
            }
            #endif
        }
        .background(.black)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: {
            bottomSafeAreaInset = $0
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .background(MacWindowAspectRatioView(videoSize: videoPresentationSize))
        #elseif os(iOS)
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false,
            onCompletion: importLocalFiles
        )
        #elseif os(tvOS)
        .onPlayPauseCommand {
            player.togglePlayback()
            showControls()
        }
        #endif
        .exampleStatusBarHidden(true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playerView")
        .accessibilityAction(named: Text(isShowingControls ? "Hide playback controls" : "Show playback controls")) {
            toggleControls()
        }
        .onAppear(perform: scheduleControlsHide)
        .onDisappear {
            controlsHideTask?.cancel()
            controlsHideTask = nil
            seekSubtitles.reset()
        }
        .onChange(of: suspendsControlsHide) { _, _ in scheduleControlsHide() }
        .onChange(of: playbackSource) { _, _ in
            seekSubtitles.reset()
            isScrubbing = false
            showControls()
        }
        .onChange(of: player.state) { _, state in
            if state == .ended || state.error != nil {
                showControls()
            }
            if state == .loading || state == .stopped || state == .idle || state.error != nil {
                seekSubtitles.reset()
            }
        }
        .onChange(of: player.subtitleTracks, initial: true) { _, tracks in
            seekSubtitles.tracksChanged(tracks)
        }
        .task(id: playbackSource) {
            let subtitles = player.textSubtitleStream()
            textSubtitles = nil
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
            "Picture in Picture",
            isPresented: Binding(
                get: { player.pictureInPicture.lastError != nil },
                set: {
                    if !$0 {
                        player.pictureInPicture.clearLastError()
                    }
                }
            )
        ) {
            Button("OK") { player.pictureInPicture.clearLastError() }
        } message: {
            Text(player.pictureInPicture.lastError?.localizedDescription ?? "Picture in picture could not start.")
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
        isShowingOpenPanel = true
        controlsHideTask?.cancel()
        defer {
            isShowingOpenPanel = false
            showControls()
        }
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
        seekSubtitles.reset()

        switch playbackSource {
        case let .localFile(url):
            resourceError = nil
            player.load(url)
        case let .bundled(media):
            resourceError = nil
            player.load(media.url)
        case .unavailable:
            resourceError = "Add media to Shared/Resources/Media, then rebuild the example."
        }
    }

    private func loadSidecar(_ sidecar: ExampleSubtitleSidecar, role: MPVSubtitleRole) {
        seekSubtitles.cancelPresentation()
        resourceError = nil
        player.loadExternalSubtitle(sidecar.url, selecting: role)
    }

    private func disableSubtitles(_ role: MPVSubtitleRole) {
        seekSubtitles.tracksChanged(player.subtitleTracks)
        seekSubtitles.cancelPresentation()
        player.selectSubtitle(nil, for: role)
    }

    private func seek(to target: Duration) {
        seekSubtitles.seek(to: target, player: player)
    }

    private func jump(by offset: Duration) {
        seekSubtitles.jump(by: offset, player: player)
    }

    private func hideControls() {
        guard !suspendsControlsHide else { return }
        controlsHideTask?.cancel()
        controlsHideTask = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            isShowingControls = false
        }
    }

    private func showControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isShowingControls = true
        }
        scheduleControlsHide()
    }

    private func toggleControls() {
        if isShowingControls {
            hideControls()
        } else {
            showControls()
        }
    }

    private var suspendsControlsHide: Bool {
        var suspended = isScrubbing || isShowingInspector
            || resourceError != nil || player.pictureInPicture.lastError != nil
            || scenePhase != .active || isVoiceOverEnabled
        #if os(iOS)
        suspended = suspended || isShowingFileImporter
        #elseif os(macOS)
        suspended = suspended || isShowingOpenPanel
        #endif
        return suspended
    }

    private func scheduleControlsHide() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
        guard isShowingControls, !suspendsControlsHide else { return }
        controlsHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            hideControls()
        }
    }

    #if os(tvOS)
    private func handleRemoteMove(_ direction: MoveCommandDirection) {
        if player.isSeekable {
            switch direction {
            case .left: jump(by: .seconds(-10))
            case .right: jump(by: .seconds(10))
            default: break
            }
        }
        focusedControl = .media
        showControls()
    }
    #endif

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
        guard let videoSize,
              videoSize.width.isFinite, videoSize.height.isFinite,
              videoSize.width > 0, videoSize.height > 0
        else {
            // Resize increments clear the aspect constraint. Assigning a zero
            // aspect ratio can make AppKit trap while restoring the window.
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
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
}
