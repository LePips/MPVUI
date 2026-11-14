import Foundation
@testable import MPVBuildCore
import Testing

struct PrivacyManifestTests {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test(arguments: ["ios", "macos", "maccatalyst"])
    func `framework privacy manifests survive platform packaging`(platform: String) throws {
        let native = try read(NativeLock.self, root.appendingPathComponent("Build/Inputs.lock.json"))
        let slice = try #require(native.apple.slices.first { $0.id == platform })
        let manifest = try Data(contentsOf: root.appendingPathComponent("Build/PrivacyInfo.xcprivacy"))
        let directory = fm.temporaryDirectory.appendingPathComponent("privacy-manifest-tests-\(UUID())")
        defer { try? fm.removeItem(at: directory) }

        let framework = directory.appendingPathComponent("Libmpv.framework")
        try mkdir(framework.appendingPathComponent("Headers"))
        try mkdir(framework.appendingPathComponent("Modules"))
        try put(Data(), framework.appendingPathComponent("Libmpv"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.mpvui.libmpv",
            "CFBundleExecutable": "Libmpv",
            "CFBundlePackageType": "FMWK",
        ]
        try put(
            PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0),
            framework.appendingPathComponent("Info.plist")
        )
        try put(manifest, framework.appendingPathComponent("PrivacyInfo.xcprivacy"))

        if platform == "macos" || platform == "maccatalyst" {
            try Packager.versionFramework(framework, binary: "Libmpv")
            #expect(!exists(framework.appendingPathComponent("PrivacyInfo.xcprivacy")))
        }

        try Packager.verifyPrivacyManifest(framework, slice: slice, expected: manifest)
        let bundle = try #require(Bundle(url: framework))
        let resource = try #require(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        #expect(try Data(contentsOf: resource) == manifest)

        try put(Data("invalid manifest".utf8), resource)
        #expect(throws: BuildError.self) { try Packager.verifyPrivacyManifest(framework, slice: slice, expected: manifest) }

        try remove(resource)
        #expect(throws: BuildError.self) { try Packager.verifyPrivacyManifest(framework, slice: slice, expected: manifest) }

        // A manifest at the XCFramework root cannot substitute for the framework resource.
        try put(manifest, directory.appendingPathComponent("PrivacyInfo.xcprivacy"))
        #expect(throws: BuildError.self) { try Packager.verifyPrivacyManifest(framework, slice: slice, expected: manifest) }
    }

    @Test
    func `native libraries reject undeclared disk space APIs`() throws {
        for symbol in ["_statfs", "_fstatfs", "_statvfs", "_fstatvfs", "_fstatfs$INODE64", "_statfs$INODE64"] {
            #expect(throws: BuildError.self) {
                try NativeLibrary.verifyPrivacyAPIReferences(["_mach_absolute_time", "_fstat", symbol])
            }
        }
        try NativeLibrary.verifyPrivacyAPIReferences(["_mach_absolute_time", "_fstat", "_CFURLCopyResourcePropertyForKey"])
    }
}
