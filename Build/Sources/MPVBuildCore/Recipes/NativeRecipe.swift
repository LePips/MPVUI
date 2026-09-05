import Foundation

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func mesonQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "'",
        with: "\\'"
    ) + "'"
}

func relativePath(from base: URL, to destination: URL) -> String {
    let a = base.standardizedFileURL.pathComponents
    let b = destination.standardizedFileURL.pathComponents
    var common = 0
    while common < min(a.count, b.count) && a[common] == b[common] {
        common += 1
    }
    return (Array(repeating: "..", count: a.count - common) + b.dropFirst(common)).joined(separator: "/")
}

struct RecipeContext: Sendable {
    let component: String
    let slice: Slice
    let arch: String
    let source: URL
    let work: URL
    let prefix: URL
    let sdk: URL
    let dependencies: [String: URL]
    let root: URL
    let runner: Runner
    let jobs: Int
    let version: String
    var flags: [String] {
        var flags = [
            "-arch",
            arch,
            "-isysroot",
            sdk.path,
            "-target",
            slice.triple(arch),
            "-ffile-prefix-map=\(work.path)=/mpvbuild/\(component)",
            "-ffile-prefix-map=\(root.path)=/mpvbuild/repository"
        ]
        if ["tvos", "xros"].contains(slice.platform) {
            flags.append("-DHAVE_FORK=0")
        }
        if slice.variant == "maccatalyst" {
            flags += [
                "-iframework",
                sdk.appendingPathComponent("System/iOSSupport/System/Library/Frameworks").path
            ]
        }
        flags += ["-I" + sdk.appendingPathComponent("usr/include/libxml2").path]
        for id in dependencies.keys.sorted() {
            let path = dependencies[id]!
            flags += ["-ffile-prefix-map=\(path.path)=/mpvbuild/dependencies/\(id)"]
            flags +=
                ["-ffile-prefix-map=\(relativePath(from: work.appendingPathComponent("build"), to: path))=/mpvbuild/dependencies/\(id)"]
            flags += ["-I" + path.appendingPathComponent("include").path]
            if id == "libsmbclient" {
                flags += ["-I" + path.appendingPathComponent("include/samba-4.0").path]
            }
        }
        return flags
    }

    var linkFlags: [String] {
        var result = ["-arch", arch, "-isysroot", sdk.path, "-target", slice.triple(arch), "-lc++"]
        if slice.variant == "maccatalyst" {
            result += [
                "-iframework",
                sdk.appendingPathComponent("System/iOSSupport/System/Library/Frameworks").path
            ]
        }
        for id in dependencies.keys.sorted() {
            result.append("-L" + dependencies[id]!.appendingPathComponent("lib").path)
        }
        // Samba's per-target pkg-config bundles do not consistently carry its private static dependencies.
        // Keep the same explicit GnuTLS/GMP/nettle and Apple system linkage as the imported recipes.
        for (id, libraries) in [("gmp", ["gmp"]), ("nettle", ["nettle", "hogweed"]), ("gnutls", ["gnutls"])] where dependencies[id] != nil {
            result += libraries.map { "-l" + $0 }
        }
        if dependencies["gnutls"] != nil {
            result += ["-framework", "Security", "-framework", "CoreFoundation"]
        }
        if dependencies["libsmbclient"] != nil {
            result += ["-lresolv", "-lpthread", "-lz", "-liconv"]
        }
        return result
    }

    var environment: [String: String] {
        let pc = dependencies.keys.sorted()
            .map { dependencies[$0]!.appendingPathComponent("lib/pkgconfig").path } +
            [root.appendingPathComponent("Build/Support/apple-system").path]
        let flags = flags.map(shellQuote).joined(separator: " ")
        return [
            "CC": "/usr/bin/clang",
            "CXX": "/usr/bin/clang++",
            "CFLAGS": flags,
            "CPPFLAGS": flags,
            "CXXFLAGS": flags,
            "ASMFLAGS": flags,
            "LDFLAGS": linkFlags.map(shellQuote).joined(separator: " "),
            "PKG_CONFIG_LIBDIR": pc.joined(separator: ":"),
            "PKG_CONFIG_PATH": "",
            "CURRENT_ARCH": arch,
            "TMPDIR": work.appendingPathComponent("tmp").path
        ]
    }

    func prepareDirectories() throws {
        try mkdir(work.appendingPathComponent("tmp"))
        try mkdir(work.appendingPathComponent("build"))
        try mkdir(prefix)
    }

    func normalizePkgConfig() throws {
        for file in try files(prefix) where file.pathExtension == "pc" {
            var text = try String(contentsOf: file, encoding: .utf8)
            text = text.replacingOccurrences(of: prefix.path, with: "${pcfiledir}/../..")
            text = text.replacingOccurrences(of: "/usr/local", with: "${pcfiledir}/../..")
            for dependency in dependencies.values.sorted(by: { $0.path.count > $1.path.count }) {
                let destination = "${pcfiledir}/../../" + relativePath(from: prefix, to: dependency)
                text = text.replacingOccurrences(of: dependency.path, with: destination)
                text = text.replacingOccurrences(
                    of: relativePath(from: work.appendingPathComponent("build"), to: dependency),
                    with: destination
                )
                // The consuming recipe supplies every locked dependency's current include/library path.
                // Keep transitive library/framework flags, but never bake a previous cache node's location
                // into these internal pkg-config products (including after a verifier-only key change).
                let pattern = "(?:-L|-I)" + NSRegularExpression.escapedPattern(for: destination) + "[^\\s]*"
                let expression = try NSRegularExpression(pattern: pattern)
                text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
            try put(text, file)
        }
    }
}

enum FFmpegRecipe {
    static let libraries = ["avcodec", "avdevice", "avfilter", "avformat", "avutil", "swresample", "swscale"]
    static func build(_ context: RecipeContext) throws {
        let c = context
        try c.prepareDirectories()
        let build = c.work.appendingPathComponent("build")
        // FFmpeg supports a relative src/ tree even when the checkout path contains whitespace.
        try fm.createSymbolicLink(atPath: build.appendingPathComponent("src").path, withDestinationPath: "../source")
        // FFmpeg expands flag variables without reparsing shell quotes. Clang response files preserve path arguments.
        try put(c.flags.map(shellQuote).joined(separator: "\n") + "\n", build.appendingPathComponent("mpvbuild-cflags.rsp"))
        try put(c.linkFlags.map(shellQuote).joined(separator: "\n") + "\n", build.appendingPathComponent("mpvbuild-ldflags.rsp"))
        // pkg-config preserves relative search paths in its output. FFmpeg expands that output as
        // shell words, so relative paths avoid backslash-escaped spaces being split a second time.
        let pkgPaths = c.dependencies.keys.sorted().map { relativePath(
            from: build,
            to: c.dependencies[$0]!.appendingPathComponent("lib/pkgconfig")
        ) } + [c.root.appendingPathComponent("Build/Support/apple-system").path]
        let environment = c.environment.merging([
            "CFLAGS": "@mpvbuild-cflags.rsp",
            "CPPFLAGS": "",
            "CXXFLAGS": "@mpvbuild-cflags.rsp",
            "ASFLAGS": "@mpvbuild-cflags.rsp",
            "LDFLAGS": "@mpvbuild-ldflags.rsp",
            "TMPDIR": "../tmp",
            "PKG_CONFIG_LIBDIR": pkgPaths.joined(separator: ":")
        ]) { _, new in new }
        var args = FFmpegFlags.configureFlags + [
            "--prefix=/usr/local", "--arch=\(c.arch == "x86_64" ? "x86_64" : "aarch64")", "--target-os=darwin",
            "--cc=/usr/bin/clang", "--cxx=/usr/bin/clang++", "--disable-debug", "--enable-stripping", "--enable-gpl",
            "--disable-programs", "--disable-autodetect", "--disable-sdl2", "--disable-large-tests", "--ignore-tests=TESTS",
            "--enable-audiotoolbox", "--enable-videotoolbox",
            "--disable-securetransport",
        ]
        args += c.slice.variant == "maccatalyst" || c.arch == "x86_64" ? ["--disable-neon", "--disable-asm"] : [
            "--enable-neon",
            "--enable-asm"
        ]
        for id in [
            "gmp",
            "gnutls",
            "libfreetype",
            "libharfbuzz",
            "libfribidi",
            "libass",
            "vulkan",
            "libshaderc",
            "lcms2",
            "libplacebo",
            "libdav1d",
            "libuavs3d",
            "libsmbclient"
        ] {
            try require(c.dependencies[id] != nil, "Missing explicit FFmpeg dependency \(id)")
            args.append("--enable-" + id)
        }
        args += [
            "--enable-protocol=libsmbclient",
            "--enable-decoder=libdav1d",
            "--enable-decoder=libuavs3d",
            "--enable-filter=ass",
            "--enable-filter=subtitles",
            "--enable-filter=libplacebo"
        ]
        try c.runner.run(build.appendingPathComponent("src/configure").path, args, cwd: build, env: environment)
        // configure embeds its invocation. Normalize only the reported string; compilation still uses actual paths.
        let config = build.appendingPathComponent("config.h")
        var text = try String(contentsOf: config, encoding: .utf8)
        let lines = text.components(separatedBy: "\n").map { line in
            line.hasPrefix("#define FFMPEG_CONFIGURATION ") ? line.replacingOccurrences(of: c.prefix.path, with: "/mpvbuild/install")
                .replacingOccurrences(
                    of: c.work.path,
                    with: "/mpvbuild/ffmpeg"
                ).replacingOccurrences(of: c.root.path, with: "/mpvbuild/repository") : line
        }
        text = lines.joined(separator: "\n")
        try put(text, config)
        try c.runner.run("/usr/bin/make", ["-j\(c.jobs)"], cwd: build, env: environment)
        let install = c.work.appendingPathComponent("install")
        try c.runner.run("/usr/bin/make", ["-j\(c.jobs)", "install", "DESTDIR=" + install.path], cwd: build, env: environment)
        let stagedPrefix = install.appendingPathComponent("usr/local")
        for name in try fm.contentsOfDirectory(atPath: stagedPrefix.path) {
            try fm.copyItem(
                at: stagedPrefix.appendingPathComponent(name),
                to: c.prefix.appendingPathComponent(name)
            )
        }
        for lib in libraries {
            try require(exists(c.prefix.appendingPathComponent("lib/lib\(lib).a")), "FFmpeg did not produce \(lib)")
        }
        try c.normalizePkgConfig()
        // Resolved options are evidence, with paths normalized independently of their local invocation.
        try put(
            args.map { $0.replacingOccurrences(of: c.prefix.path, with: "/mpvbuild/install") }.joined(separator: "\n") + "\n",
            c.prefix.appendingPathComponent("configuration.txt")
        )
    }
}
