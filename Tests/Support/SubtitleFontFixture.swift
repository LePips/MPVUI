import CoreText
import Foundation
import Testing

/// Supplies local font files without checking fonts into the repository or
/// downloading them. The owning TemporaryTestDirectory removes these copies.
struct SubtitleFontFixture {
    struct Font {
        let family: String
        let postScriptName: String
    }

    let directory: URL
    let authored: Font
    let fallback: Font

    init(in root: URL) throws {
        directory = root.appendingPathComponent("Client Subtitle Fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        authored = try Self.copyInstalledFont("ArialMT", to: directory)
        fallback = try Self.copyInstalledFont("TimesNewRomanPSMT", to: directory)
        try #require(authored.family != fallback.family)
    }

    private static func copyInstalledFont(_ name: String, to directory: URL) throws -> Font {
        let font = CTFontCreateWithName(name as CFString, 24, nil)
        let source = try #require(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
        let destination = directory.appendingPathComponent(name).appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at: source, to: destination)
        return Font(
            family: CTFontCopyFamilyName(font) as String,
            postScriptName: CTFontCopyPostScriptName(font) as String
        )
    }
}
