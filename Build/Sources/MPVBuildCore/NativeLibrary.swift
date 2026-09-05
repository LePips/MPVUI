import Foundation

/// Link mpv and its static dependencies into an isolated dynamic framework.
/// A plain archive merge can resolve native symbols against other dependencies,
/// mixing incompatible implementations in the consuming app.
enum NativeLibrary {
    static func publicSymbols(in headers: URL) throws -> Set<String> {
        let declaration = try NSRegularExpression(pattern: #"(?m)^MPV_EXPORT\s+[^;]*?\b(mpv_\w+)\s*\("#)
        var symbols: Set<String> = []
        for header in try files(headers) where header.pathExtension == "h" {
            let text = try String(contentsOf: header, encoding: .utf8)
            for match in declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) {
                    symbols.insert("_" + text[range])
                }
            }
        }
        try require(symbols.contains("_mpv_create") && symbols.contains("_mpv_initialize"), "Missing public libmpv API declarations")
        return symbols
    }

    static func link(
        _ archive: URL,
        to destination: URL,
        exports: Set<String>,
        slice: Slice,
        arch: String,
        runner: Runner,
        installName: String = "@rpath/Libmpv.framework/Libmpv"
    ) throws {
        try require(!exports.isEmpty, "Cannot link a native library without public entry points")
        let interface = destination.deletingLastPathComponent().appendingPathComponent("exports.txt")
        try put(exports.sorted().joined(separator: "\n") + "\n", interface)
        defer { try? remove(interface) }

        // Resolve dependencies within this image, with only libmpv's public API
        // exported. Keep normal archive selection: -all_load would also pull
        // mutually exclusive implementations from some bundled dependencies.
        try runner.run("/usr/bin/clang", linkArguments(slice: slice, arch: arch, runner: runner) + [
            "-dynamiclib", "-Wl,-dead_strip_dylibs",
            "-Xlinker", "-oso_prefix", "-Xlinker", archive.deletingLastPathComponent().path + "/",
            "-Xlinker", "-install_name", "-Xlinker", installName,
            "-Xlinker", "-exported_symbols_list", "-Xlinker", interface.path,
            "-o", destination.path
        ] + exports.sorted().flatMap { ["-Xlinker", "-u", "-Xlinker", $0] } + [archive.path])
        try verify(destination, exports: exports, runner: runner)
        try require(MachO.validate(destination, slice: slice, arch: arch).count == 1, "Expected one native dynamic library")
    }

    static func linkArguments(slice: Slice, arch: String, runner: Runner) throws -> [String] {
        let sdk = try runner.sdk(slice.sdk)
        let system = [
            "AVFoundation", "AudioToolbox", "CoreAudio", "CoreFoundation", "CoreGraphics",
            "CoreMedia", "CoreText", "CoreVideo", "Foundation", "IOSurface", "Metal",
            "QuartzCore", "Security", "VideoToolbox"
        ] + (slice.id == "macos" ? ["AppKit", "OpenGL", "IOKit"] : ["UIKit"]) +
            (["ios", "isimulator", "tvos", "tvsimulator"].contains(slice.id) ? ["OpenGLES"] : []) +
            (slice.variant == "maccatalyst" ? ["IOKit"] : [])
        var args = ["-target", slice.triple(arch), "-isysroot", sdk.path] +
            system.flatMap { ["-framework", $0] } +
            ["-lc++", "-lbz2", "-liconv", "-lexpat", "-lresolv", "-lxml2", "-lz"]
        if slice.variant == "maccatalyst" {
            args += ["-iframework", sdk.appendingPathComponent("System/iOSSupport/System/Library/Frameworks").path]
        }
        if slice.id == "macos" {
            let swiftLib = URL(fileURLWithPath: runner.environment["DEVELOPER_DIR"]!)
                .appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx")
            args += ["-L", swiftLib.path, "-L", sdk.appendingPathComponent("usr/lib/swift").path, "-Wl,-rpath,/usr/lib/swift"]
        }
        return args
    }

    static func verify(_ binary: URL, exports: Set<String>, runner: Runner) throws {
        let actual = try Set(runner.run("/usr/bin/nm", ["-gUj", binary.path]).split(separator: "\n")
            .filter { !$0.hasSuffix(":") }.map(String.init))
        try require(
            actual == exports,
            "Native interface mismatch; missing: \(exports.subtracting(actual).sorted()), leaked: \(actual.subtracting(exports).sorted())"
        )
    }
}
