import Foundation

struct ExampleSubtitleSidecar: Identifiable, Hashable, Sendable {
    let url: URL

    var id: String {
        url.path
    }

    var fileName: String {
        url.lastPathComponent
    }

    var title: String {
        fileName
    }
}

struct ExampleMedia: Identifiable, Hashable, Sendable {
    let url: URL
    let sidecars: [ExampleSubtitleSidecar]

    var id: String {
        url.path
    }

    var fileName: String {
        url.lastPathComponent
    }

    var title: String {
        fileName
    }
}

extension ExampleMedia {
    static func catalog(in bundle: Bundle = .main) -> [Self] {
        guard let resourceDirectory = bundle.resourceURL else { return [] }

        let mediaDirectory = resourceDirectory.appendingPathComponent(
            "Media",
            isDirectory: true
        )

        guard isDirectory(mediaDirectory) else { return [] }
        return catalog(resourcesAt: mediaDirectory)
    }

    static func catalog(resourcesAt directory: URL) -> [Self] {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let discoveredURLs = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
        else {
            return []
        }

        let resourceURLs = discoveredURLs.filter { url in
            let isRegularFile = try? url.resourceValues(forKeys: resourceKeys).isRegularFile
            return isRegularFile == true
        }
        let subtitleURLs = resourceURLs.filter(isSubtitle)
        let mediaURLs = resourceURLs.filter { !isSubtitle($0) }

        let sidecarsByMedia = Dictionary(grouping: subtitleURLs) { subtitleURL in
            matchingMedia(for: subtitleURL, among: mediaURLs)
        }

        return
            mediaURLs
                .map { mediaURL in
                    Self(
                        url: mediaURL,
                        sidecars: (sidecarsByMedia[mediaURL] ?? [])
                            .sorted {
                                $0.lastPathComponent.localizedStandardCompare(
                                    $1.lastPathComponent
                                ) == .orderedAscending
                            }
                            .map(ExampleSubtitleSidecar.init(url:))
                    )
                }
                .sorted {
                    $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                }
    }

    private static let subtitleExtensions: Set<String> = [
        "ass", "idx", "lrc", "mks", "sami", "smi", "srt", "ssa", "sub",
        "sup", "ttml", "vtt",
    ]

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isSubtitle(_ url: URL) -> Bool {
        subtitleExtensions.contains(url.pathExtension.lowercased())
    }

    private static func matchingMedia(
        for subtitleURL: URL,
        among mediaURLs: [URL]
    ) -> URL? {
        let subtitleName = subtitleURL.lastPathComponent

        return
            mediaURLs
                .compactMap { mediaURL -> (url: URL, prefixLength: Int)? in
                    let fileNamePrefix = mediaURL.lastPathComponent + "."
                    let stemPrefix = mediaURL.deletingPathExtension().lastPathComponent + "."
                    let matchingPrefix = [fileNamePrefix, stemPrefix]
                        .filter(subtitleName.hasPrefix)
                        .max(by: { $0.count < $1.count })

                    guard let matchingPrefix else { return nil }
                    return (mediaURL, matchingPrefix.count)
                }
                .max(by: { $0.prefixLength < $1.prefixLength })?
                .url
    }
}
