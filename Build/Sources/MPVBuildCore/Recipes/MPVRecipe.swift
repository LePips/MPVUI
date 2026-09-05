import Foundation

enum MPVRecipe {
    static func options(_ c: RecipeContext) -> [String] {
        let vision = c.slice.platform == "xros"
        let desktop = c.slice.id == "macos"
        var options = [
            "-Dlibmpv=true",
            "-Dcplayer=false",
            "-Dgpl=true",
            "-Dbuild-date=false",
            "-Dauto_features=disabled",
            "-Diconv=enabled",
            "-Duchardet=enabled",
            "-Dvulkan=enabled",
            "-Dmoltenvk=enabled",
            "-Dlibbluray=enabled",
            "-Dlibavdevice=enabled",
            "-Davfoundation=enabled",
            "-Dvideotoolbox-pl=enabled",
            "-Dgl=\(vision ? "disabled" : "enabled")",
            "-Dplain-gl=\(vision ? "disabled" : "enabled")",
            "-Daudiounit=\(desktop ? "disabled" : "enabled")",
            "-Dcoreaudio=\(desktop ? "enabled" : "disabled")",
            "-Dcocoa=\(desktop ? "enabled" : "disabled")",
            "-Dgl-cocoa=\(desktop ? "enabled" : "disabled")",
            "-Dvideotoolbox-gl=\(desktop ? "enabled" : "disabled")",
            "-Dlua=\(desktop ? "luajit" : "disabled")",
            "-Dios-gl=\(!desktop && !vision && c.slice.variant != "maccatalyst" ? "enabled" : "disabled")",
            "-Dswift-build=\(desktop ? "enabled" : "disabled")"
        ]
        if desktop {
            // Upstream splits this option on whitespace instead of parsing shell quotes.
            // Ninja runs in build/, so a relative response file also supports checkout paths with spaces.
            options.append("-Dswift-flags=@../mpvbuild-swift.rsp")
        }
        return options
    }

    static func build(_ context: RecipeContext) throws {
        let c = context
        try c.prepareDirectories()
        if c.slice.id == "macos" {
            let arguments = [
                "-sdk",
                c.sdk.path,
                "-target",
                c.slice.triple(c.arch),
                "-debug-prefix-map",
                c.work.path + "=/mpvbuild/mpv",
                "-file-prefix-map",
                c.work.path + "=/mpvbuild/mpv",
                "-debug-prefix-map",
                c.root.path + "=/mpvbuild/repository",
                "-file-prefix-map",
                c.root.path + "=/mpvbuild/repository"
            ] + c.dependencies.keys.sorted().flatMap { [
                "-I",
                c.dependencies[$0]!.appendingPathComponent("include").path
            ] }
            try put(
                arguments.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
                    .joined(separator: "\n") + "\n",
                c.work.appendingPathComponent("mpvbuild-swift.rsp")
            )
        }
        let build = c.work.appendingPathComponent("build")
        let cross = c.work.appendingPathComponent("cross.meson")
        let flags = c.flags.map(mesonQuote).joined(separator: ", ")
        let links = c.linkFlags.map(mesonQuote).joined(separator: ", ")
        let content = try """
        [binaries]
        c = '/usr/bin/clang'
        cpp = '/usr/bin/clang++'
        objc = '/usr/bin/clang'
        objcpp = '/usr/bin/clang++'
        ar = \(mesonQuote(c.runner.apple("ar")))
        strip = \(mesonQuote(c.runner.apple("strip")))
        pkg-config = \(mesonQuote(c.runner.executable("pkg-config").path))
        [host_machine]
        system = 'darwin'
        subsystem = \(mesonQuote(c.slice.variant == "simulator" ? c.slice.platform + "-simulator" : c.slice.id))
        kernel = 'xnu'
        cpu_family = '\(c.arch == "x86_64" ? "x86_64" : "aarch64")'
        cpu = '\(c.arch)'
        endian = 'little'
        [built-in options]
        default_library = 'static'
        buildtype = 'release'
        prefix = '/usr/local'
        c_args = [\(flags)]
        cpp_args = [\(flags)]
        objc_args = [\(flags)]
        objcpp_args = [\(flags)]
        c_link_args = [\(links)]
        cpp_link_args = [\(links)]
        objc_link_args = [\(links)]
        objcpp_link_args = [\(links)]
        """
        try put(content, cross)
        let options = options(c)
        try c.runner.run(
            "meson",
            ["setup", build.path, c.source.path, "--cross-file", cross.path, "--wrap-mode=nodownload"] + options,
            cwd: c.work,
            env: c.environment
        )
        // Meson embeds a shell-quoted absolute cross-file path in the public configuration string.
        // Report the declared options with one stable path and quoting policy across all checkout roots.
        let configurationFile = build.appendingPathComponent("config.h")
        let reported = (["-Dwrap_mode=nodownload"] + options + ["--cross-file=/mpvbuild/mpv/cross.meson"]).joined(separator: " ")
        let literal = try String(decoding: canonical(reported), as: UTF8.self)
        let configuration = try String(contentsOf: configurationFile, encoding: .utf8).components(separatedBy: "\n")
            .map { $0.hasPrefix("#define CONFIGURATION ") ? "#define CONFIGURATION " + literal : $0 }.joined(separator: "\n")
        try put(configuration, configurationFile)
        try c.runner.run("meson", ["compile", "-C", build.path, "-j", String(c.jobs)], cwd: c.work, env: c.environment)
        let install = c.work.appendingPathComponent("install")
        try c.runner.run(
            "meson",
            ["install", "-C", build.path, "--no-rebuild"],
            cwd: c.work,
            env: c.environment.merging(["DESTDIR": install.path]) { _, new in new }
        )
        let stagedPrefix = install.appendingPathComponent("usr/local")
        for name in try fm.contentsOfDirectory(atPath: stagedPrefix.path) {
            try fm.copyItem(
                at: stagedPrefix.appendingPathComponent(name),
                to: c.prefix.appendingPathComponent(name)
            )
        }
        try require(exists(c.prefix.appendingPathComponent("lib/libmpv.a")), "mpv install did not produce libmpv.a")
        try c.normalizePkgConfig()
        for file in try files(c.prefix) where file.pathExtension == "pc" {
            let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
                of: "prefix=/usr/local",
                with: "prefix=${pcfiledir}/../.."
            )
            try put(text, file)
        }
        let config = try String(contentsOf: build.appendingPathComponent("config.h"), encoding: .utf8)
        for feature in ["HAVE_AVFOUNDATION", "HAVE_VULKAN", "HAVE_MOLTENVK", "HAVE_VIDEOTOOLBOX_PL"] {
            try require(config.contains("#define \(feature) 1"), "mpv configuration lost required \(feature)")
        }
        if c.slice.platform == "xros" {
            try require(
                config.contains("#define HAVE_GL 0") && config.contains("#define HAVE_COREAUDIO 0"),
                "Unintended visionOS fallback configuration"
            )
        }
        try put(config, c.prefix.appendingPathComponent("configuration.h"))
    }
}
