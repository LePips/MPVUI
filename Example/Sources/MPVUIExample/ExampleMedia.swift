import Foundation
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// File access and selection belong to the app, separate from playback controls.
@MainActor
final class ExampleMediaAccess {

    #if !os(Android)
    private var scopedURL: URL?

    func access(_ url: URL) {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    isolated deinit { scopedURL?.stopAccessingSecurityScopedResource() }
    #else
    // Android document permissions are granted to the Activity's ContentResolver.
    func access(_ url: URL) {}
    #endif
}

enum ExamplePlayback {

    static var configuration: MPVPlayerConfiguration {
        var options: [String: String] = [:]
        #if os(macOS)
        for option in [
            "load-scripts",
            "osc",
            "ytdl",
            "load-stats-overlay",
            "load-console",
            "load-auto-profiles",
            "load-select",
            "load-positioning",
            "load-commands",
            "load-context-menu"
        ] {
            options[option] = "no"
        }
        #endif
        #if os(Android)
        return .init(additionalOptions: options, nativeVideoFeaturePolicy: .preferFeatures, videoOutput: .automaticAndroid)
        #else
        let useMetalVideoOutput = ProcessInfo.processInfo.arguments.contains("--metal-video-output")

        return .init(
            additionalOptions: options,
            audio: .init(audioSession: .hostManaged),
            videoOutput: useMetalVideoOutput ? .metal : .sampleBuffer
        )
        #endif
    }
}

struct ExampleMedia {

    let url: URL

    var name: String {
        url.deletingPathExtension().lastPathComponent
    }

    static func bundled() -> [ExampleMedia] {
        #if os(Android)
        // Native AndroidBundle does not override resource URL enumeration.
        let files = ExampleMediaBridge.bundledMedia().compactMap(URL.init(string:))
        #else
        let files = (Bundle.module.urls(forResourcesWithExtension: nil, subdirectory: "Media") ?? [])
            .map(\.absoluteString)
            .compactMap(URL.init(string:))
        #endif
        let extensions = Set(["mp4", "mkv", "mov", "m4v", "webm", "ts", "mp3", "m4a", "aac", "flac", "wav", "ogg", "webp"])

        return files.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { ExampleMedia(url: $0) }
    }
}

extension ExampleMedia: Identifiable {

    var id: String {
        url.absoluteString
    }
}

#if SKIP
/// Enumerates APK media assets through Skip's Kotlin-backed bundle.
// SKIP @bridgeMembers
public enum ExampleMediaBridge {

    /// Returns bundled media-folder URLs for native Swift playback.
    public static func bundledMedia() -> [String] {
        (Bundle.module.urls(forResourcesWithExtension: nil, subdirectory: "Media") ?? [])
            .map(\.absoluteString)
    }
}
#endif

extension View {

    @ViewBuilder
    func exampleFileImporter(isPresented: Binding<Bool>, model: PlayerModel) -> some View {
        #if os(Android)
        self
            .onChange(of: isPresented.wrappedValue) { [model] _, shown in
                if shown {
                    isPresented.wrappedValue = false

                    model.player.bridge.openFile { [weak model] source, name in
                        Task { @MainActor [weak model] in
                            guard !source.isEmpty, let url = URL(string: source) else {
                                model?.selectionError = name
                                return
                            }

                            model?.load(url, name: name)
                        }
                    }
                }
            }
        #elseif os(tvOS)
        self
        #else
        self
            .fileImporter(isPresented: isPresented, allowedContentTypes: [.movie, .audio, .image]) { result in
                switch result {
                case let .success(url): model.load(url)
                case let .failure(error): model.selectionError = error.localizedDescription
                }
            }
        #endif
    }
}
