import Foundation

enum TestPaths {
    static func media(_ name: String) -> URL {
        Bundle.module.bundleURL
            .appendingPathComponent("Media")
            .appendingPathComponent(name)
    }

    static let baselineMedia = media("01-h264-aac-baseline.mp4")

    static func hasMedia(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: media(name).path)
    }
}
