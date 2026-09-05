import Foundation
@testable import MPVBuildCore
import Testing

struct NativeLibraryTests {
    @Test
    func `native dependencies cannot bind to a competing framework`() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("MPVUI native isolation \(UUID().uuidString)")
        try mkdir(root)
        defer { try? remove(root) }

        let selection = Process()
        selection.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        selection.arguments = ["-p"]
        let pipe = Pipe()
        selection.standardOutput = pipe
        try selection.run()
        selection.waitUntilExit()
        let developer = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let runner = try Runner(developer: developer, epoch: 1, logs: root.appendingPathComponent("logs"))
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let slice = Slice(
            id: "macos",
            platform: "macos",
            variant: "",
            architectures: [arch],
            sdk: "macosx",
            minimumOS: "15.0",
            machOPlatform: 1
        )
        let target = try ["-target", slice.triple(arch), "-isysroot", runner.sdk(slice.sdk).path]
        let headers = root.appendingPathComponent("headers")
        try put("""
        #define MPV_EXPORT
        // mpv_private() is not an exported declaration.
        MPV_EXPORT int mpv_create(void);
        MPV_EXPORT
        int mpv_initialize(void);
        """, headers.appendingPathComponent("client.h"))
        let exports = try NativeLibrary.publicSymbols(in: headers)
        #expect(exports == ["_mpv_create", "_mpv_initialize"])

        try put(
            "extern int avcodec_version(void); int mpv_create(void) { return avcodec_version(); } int mpv_initialize(void) { return 0; }",
            root.appendingPathComponent("mpv.c")
        )
        // A common definition must also become local, otherwise isolation of
        // the functions alone still leaves shared state in the host namespace.
        try put(
            "int codec_state; int avcodec_version(void) { codec_state = 42; return codec_state; }",
            root.appendingPathComponent("codec.c")
        )
        try put(
            "int codec_state; int avcodec_version(void) { codec_state = 99; return codec_state; }",
            root.appendingPathComponent("foreign.c")
        )
        try put(
            "#include <stdio.h>\nextern int mpv_create(void), avcodec_version(void); int main(void) { printf(\"%d %d\\n\", mpv_create(), avcodec_version()); }",
            root.appendingPathComponent("main.c")
        )
        for name in ["mpv", "codec"] {
            try runner.run(
                "/usr/bin/clang",
                target + [
                    "-fcommon",
                    "-g",
                    "-c",
                    root.appendingPathComponent(name + ".c").path,
                    "-o",
                    root.appendingPathComponent(name + ".o").path
                ]
            )
        }
        let archive = root.appendingPathComponent("unisolated.a")
        try runner.run(
            "/usr/bin/libtool",
            ["-static", "-D", "-o", archive.path, root.appendingPathComponent("mpv.o").path, root.appendingPathComponent("codec.o").path]
        )
        let foreign = root.appendingPathComponent("foreign.dylib")
        try runner.run("/usr/bin/clang", target + ["-dynamiclib", root.appendingPathComponent("foreign.c").path, "-o", foreign.path])
        let isolated = root.appendingPathComponent("isolated.dylib")
        try NativeLibrary.link(
            archive,
            to: isolated,
            exports: exports,
            slice: slice,
            arch: arch,
            runner: runner,
            installName: isolated.path
        )
        try NativeLibrary.verify(isolated, exports: exports, runner: runner)

        // Packaging runs in a fresh directory on each attempt. Debug maps and
        // the content-derived UUID must not encode that temporary location.
        let relocated = root.appendingPathComponent("different build directory")
        try mkdir(relocated)
        let movedArchive = relocated.appendingPathComponent(archive.lastPathComponent)
        let movedLibrary = relocated.appendingPathComponent(isolated.lastPathComponent)
        try fm.copyItem(at: archive, to: movedArchive)
        try NativeLibrary.link(
            movedArchive,
            to: movedLibrary,
            exports: exports,
            slice: slice,
            arch: arch,
            runner: runner,
            installName: isolated.path
        )
        #expect(try digest(isolated) == digest(movedLibrary))

        for (library, expected) in [(archive, "99 99"), (isolated, "42 99")] {
            let executable = root.appendingPathComponent(library.lastPathComponent + "-consumer")
            try runner.run(
                "/usr/bin/clang",
                target + [root.appendingPathComponent("main.c").path, foreign.path, library.path, "-o", executable.path]
            )
            #expect(try runner.run(executable.path) == expected)
        }
        // Definitions in the host executable must also remain independent.
        let executable = root.appendingPathComponent("static-consumer")
        try runner.run(
            "/usr/bin/clang",
            target + [
                root.appendingPathComponent("main.c").path,
                root.appendingPathComponent("foreign.c").path,
                isolated.path,
                "-o",
                executable.path
            ]
        )
        #expect(try runner.run(executable.path) == "42 99")
    }
}
