import Foundation
import Testing

enum TestPaths {
    // Resolve benchmark output paths from a stable checkout root.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let generatedMediaDirectory = Bundle.module.resourceURL ?? Bundle.module.bundleURL

    static let baselineMedia = generatedMediaDirectory.appendingPathComponent("baseline.mp4")
    static let multitrackMedia = generatedMediaDirectory.appendingPathComponent("multitrack.mkv")

    static func testMedia(_ name: String) throws -> URL {
        let url = generatedMediaDirectory.appendingPathComponent(name)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "Missing test media: \(name). The GenerateTestMedia build plugin must run before tests."
        )
        return url
    }
}
