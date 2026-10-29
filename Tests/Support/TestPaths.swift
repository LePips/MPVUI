import Foundation
import Testing

enum TestPaths {

    // Anchor checkout-only fixtures here so moving a test cannot change its URL.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let baselineMedia = generatedMediaDirectory.appendingPathComponent("baseline.mp4")
    static let multitrackMedia = generatedMediaDirectory.appendingPathComponent("multitrack.mkv")

    /// The only reference media that cannot be generated: a 1080p Dolby Vision
    /// Profile 5 color chart, whose colors depend on a real IPT-PQ-c2 encode. It is
    /// never a package resource; MPVUI_DOLBY_VISION_CHART may point to another copy.
    static let dolbyVisionChart: URL = {
        if let path = ProcessInfo.processInfo.environment["MPVUI_DOLBY_VISION_CHART"] {
            return URL(fileURLWithPath: path)
        }

        return repositoryRoot.appendingPathComponent(
            "Example/Sources/MPVUIExample/Resources/Media/dolby-vision-p5-chart.mp4"
        )
    }()

    #if SWIFT_PACKAGE
    static let generatedMediaDirectory = repositoryRoot.appendingPathComponent(".build/test-media")
    #else
    static let generatedMediaDirectory = (Bundle.module.resourceURL ?? Bundle.module.bundleURL)
        .appendingPathComponent("GeneratedMedia")
    #endif

    static var hasDolbyVisionChart: Bool {
        FileManager.default.fileExists(atPath: dolbyVisionChart.path)
    }

    static func testMedia(_ name: String) throws -> URL {
        let url = generatedMediaDirectory.appendingPathComponent(name)

        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "Missing test media: \(name). Run make test, or run make setup before direct SwiftPM tests."
        )

        return url
    }
}
