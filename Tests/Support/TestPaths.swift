import Foundation
import Testing

enum TestPaths {
    // Anchor checkout-only fixtures here so moving a test cannot change its URL.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // Large example clips are optional checkout-local inputs, never package resources.
    static let localMediaDirectory: URL = {
        if let path = ProcessInfo.processInfo.environment["MPVUI_TEST_MEDIA_DIRECTORY"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return repositoryRoot.appendingPathComponent("Example/MPVUIExample/Shared/Resources/Media")
    }()

    static func media(_ name: String) -> URL {
        localMediaDirectory.appendingPathComponent(name)
    }

    static let generatedClips = [
        "quality-01-sdr", "quality-02-hdr10", "quality-03-hlg",
        "quality-04-dv5", "quality-05-dv81", "quality-06-120fps",
    ]

    static var hasGeneratedMedia: Bool {
        generatedClips.allSatisfy { hasMedia($0 + ".mp4") && hasMedia($0 + ".Styled.en.ass") }
    }

    static let baselineMedia = (Bundle.module.resourceURL ?? Bundle.module.bundleURL)
        .appendingPathComponent("01-h264-aac-baseline.mp4")
    static let multitrackMedia = (Bundle.module.resourceURL ?? Bundle.module.bundleURL)
        .appendingPathComponent("02-h264-multitrack.mkv")

    static let dolbyVisionMedia: URL = {
        if let path = ProcessInfo.processInfo.environment["MPVUI_DOLBY_VISION_FIXTURE"] {
            return URL(fileURLWithPath: path)
        }
        return media("quality-04-dv5.mp4")
    }()

    static var hasDolbyVisionMedia: Bool {
        FileManager.default.fileExists(atPath: dolbyVisionMedia.path)
    }

    static func testMedia(_ name: String) throws -> URL {
        // Use only generated root resources. An incremental build may retain
        // the old Media subdirectory, which Bundle's recursive lookup can find.
        let url = (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent(name)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "Missing test media: \(name). The GenerateTestMedia build plugin must run before tests."
        )
        return url
    }

    static func hasMedia(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: media(name).path)
    }
}
