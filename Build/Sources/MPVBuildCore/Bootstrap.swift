import Foundation

enum Bootstrap {
    static func bin(_ store: ManagedStore, _ lock: ToolchainLock) throws -> URL {
        // A new bootstrap layout must not reuse a version-correct but broken launcher.
        try store.path("toolchains/v2-\(fingerprint(lock))/bin")
    }

    static func installMesonLauncher(python: URL, modules: URL, destination: URL) throws {
        // Meson embeds its own entry point in Ninja commands for internal helpers.
        // A real Python file gives it a reusable argv[0]; `python -c` does not.
        let entry = destination.appendingPathExtension("py")
        let modulePath = try String(decoding: canonical(modules.path), as: UTF8.self)
        try put("import sys\nsys.path.insert(0, " + modulePath + ")\nfrom mesonbuild.mesonmain import main\nsys.exit(main())\n", entry)
        try put("#!/bin/sh\nexec " + shellQuote(python.path) + " " + shellQuote(entry.path) + " \"$@\"\n", destination)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    static func run(_ lock: ToolchainLock, inputs: InputStore) throws {
        let runner = inputs.runner
        let store = inputs.store
        let bin = try bin(store, lock)
        try mkdir(bin)
        let lease = try FileLock(store.path("locks/toolchain-bootstrap.lock"))
        defer { withExtendedLifetime(lease) {} }
        for asset in lock.bootstrapAssets {
            guard let expected = lock.tools[asset.id] else { throw BuildError("Bootstrap tool is not locked: \(asset.id)") }
            let destination = bin.appendingPathComponent(asset.id)
            if (try? runner.run(destination.path, ["--version"])) == expected {
                continue
            }
            var located: URL?
            let formula = asset.id == "pkg-config" ? "pkgconf" : asset.id
            for base in ["/opt/homebrew", "/usr/local"] {
                for candidate in ["\(base)/Cellar/\(formula)/\(expected)/bin/\(asset.id)", "\(base)/bin/\(asset.id)"] {
                    if (try? runner.run(candidate, ["--version"])) == expected {
                        located = URL(fileURLWithPath: candidate)
                        break
                    }
                }
                if located != nil {
                    break
                }
            }
            if let located {
                try remove(destination)
                try fm.createSymbolicLink(at: destination, withDestinationURL: located)
                print("Located locked \(asset.id) \(expected)")
                continue
            }
            let archive = try inputs.fetch(url: asset.url, sha: asset.sha256, zip: asset.kind == "wheel")
            let directory = bin.deletingLastPathComponent().appendingPathComponent(asset.id)
            try remove(directory)
            try mkdir(directory)
            if asset.kind == "wheel" {
                try Archive.extract(archive, to: directory, runner: runner)
                if asset.id == "ninja" {
                    let binary = directory.appendingPathComponent("ninja/data/bin/ninja")
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                    try remove(destination)
                    try fm.createSymbolicLink(at: destination, withDestinationURL: binary)
                } else if asset.id == "meson" {
                    let python = try runner.executable("python3")
                    try runner.run(
                        python.path,
                        ["-c", "import sys; assert sys.version_info >= (3, 10), 'Meson 1.12 requires Python 3.10 or newer'"]
                    )
                    try installMesonLauncher(python: python, modules: directory, destination: destination)
                } else {
                    throw BuildError("Unsupported bootstrap wheel")
                }
            } else {
                let list = try runner.run("/usr/bin/tar", ["-tf", archive.path]).components(separatedBy: "\n")
                for name in list {
                    try Archive.validatePath(name.hasPrefix("./") ? String(name.dropFirst(2)) : name)
                }
                let verbose = try runner.run("/usr/bin/tar", ["-tvf", archive.path]).components(separatedBy: "\n")
                try require(
                    verbose.allSatisfy { $0.hasPrefix("-") || $0.hasPrefix("d") },
                    "Bootstrap tar contains unsupported link or special entries"
                )
                try runner.run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path])
                let roots = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                try require(roots.count == 1, "Unexpected bootstrap source root")
                let prefix = directory.appendingPathComponent("install")
                try runner.run(
                    roots[0].appendingPathComponent("configure").path,
                    ["--prefix=" + prefix.path, "--disable-shared"],
                    cwd: roots[0]
                )
                try runner.run("/usr/bin/make", ["-j2"], cwd: roots[0])
                try runner.run("/usr/bin/make", ["install"], cwd: roots[0])
                try remove(destination)
                try fm.createSymbolicLink(at: destination, withDestinationURL: prefix.appendingPathComponent("bin/pkgconf"))
            }
            try require(runner.run(destination.path, ["--version"]) == expected, "Bootstrapped tool version mismatch: \(asset.id)")
            print("Installed locked \(asset.id) \(expected)")
        }
    }
}
