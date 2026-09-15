import Foundation
import MPVUITestResources
import Testing

enum TestPaths {
    // Anchor checkout-only fixtures here so moving a test cannot change its URL.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func media(_ name: String) -> URL {
        // Xcode uses Contents/Resources on macOS; SwiftPM and iOS use flat bundles.
        (TestResources.bundle.resourceURL ?? TestResources.bundle.bundleURL)
            .appendingPathComponent("Media")
            .appendingPathComponent(name)
    }

    static let baselineMedia = media("01-h264-aac-baseline.mp4")

    static let dolbyVisionMedia: URL = {
        if let path = ProcessInfo.processInfo.environment["MPVUI_DOLBY_VISION_FIXTURE"] {
            return URL(fileURLWithPath: path)
        }
        return repositoryRoot.appendingPathComponent(
            "Example/MPVUIExample/Shared/Resources/Media/Mystery Box Dolby Vision Profile 5.mp4"
        )
    }()

    static func testMedia(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Media"))
    }

    static func hasMedia(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: media(name).path)
    }
}
