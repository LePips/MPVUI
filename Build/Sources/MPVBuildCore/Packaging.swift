import Darwin
import Foundation

struct Artifact: Codable, Sendable {
    let target: String
    let framework: String
    let module: String
    let archive: String
    let url: String
    let sha256: String
    let slices: [Slice]
}

struct ArtifactIndex: Codable, Sendable {
    let schemaVersion: Int
    let releaseID: String
    let nativeInputFingerprint: String
    let provenancePath: String
    let products: [Artifact]
    let dependencies: [RuntimeAsset]
}

struct ProductDefinition: Codable, Sendable {
    let target: String
    let framework: String
    let component: String
    let library: String
    let headerDirectory: String
    var archive: String {
        framework + ".xcframework.zip"
    }

    static let all = [ProductDefinition(
        target: "Libmpv-GPL",
        framework: "Libmpv",
        component: "mpv",
        library: "libmpv.a",
        headerDirectory: "mpv"
    )]
}

struct NativeBuildProvenance: Codable {
    let schemaVersion: Int
    let nativeInputFingerprint: String
    let nativeLockDigest: String
    let componentDigests: [String: String]
    let combinedInputs: [String: [String: String]]
}

struct PackagingKey: Encodable {
    struct Input: Encodable { let component: String
        let slice: Slice
        let architecture: String
        let digest: String
    }

    let products: [Input]
    let slices: [Slice]
    let implementation: String
    let metadataVersion: String
    let epoch: Int
    let nativeInputFingerprint: String
    let notices: String
    let license: String
    let releaseID: String
}

struct Packager {
    let graph: BuildGraph
    func nativeFingerprint() throws -> String {
        struct Identity: Encodable { let lock: NativeLock
            let code: [String: String]
            let support: [String: String]
        }
        let code = try tree(graph.codeRoot).filter { !BuildGraph.operationalFiles.contains($0.key) }
        return try fingerprint(Identity(lock: graph.native, code: code, support: tree(graph.root.appendingPathComponent("Build/Support"))))
    }

    func package(_ products: [ThinProduct], slices: [Slice], profile: String, fresh: Bool, tag: String? = nil) throws -> URL {
        let nativeID = try nativeFingerprint()
        if tag != nil {
            try require(
                profile == "release" && slices == graph.native.slices,
                "Versioned artifacts require the complete release profile"
            )
        }
        let release = try Generator.releaseID(native: graph.native, fingerprint: nativeID, tag: tag)
        let notices = try ReleaseManager(graph: graph).sourceNotices()
        let license = try Data(contentsOf: graph.root.appendingPathComponent("Build/RECIPE_LICENSE"))
        let key = try fingerprint(PackagingKey(
            products: products
                .map { .init(component: $0.component, slice: $0.slice, architecture: $0.architecture, digest: $0.contentDigest) },
            slices: slices,
            implementation: digest(graph.codeRoot.appendingPathComponent("Packaging.swift")),
            metadataVersion: graph.native.metadataVersion,
            epoch: graph.native.sourceDateEpoch,
            nativeInputFingerprint: nativeID,
            notices: hash(notices),
            license: hash(license),
            releaseID: release
        ))
        let store = graph.store
        let runner = graph.runner
        return try store.node(stage: "candidates", name: profile, key: key, fresh: fresh) { output in
            let work = try store.path("work/packaging/\(key)-\(UUID().uuidString)")
            try mkdir(work)
            var artifacts: [Artifact] = []
            var combinedInputs: [String: [String: String]] = [:]
            for thin in products {
                let directory = try store.path(thin.directory)
                let record = try read(StageRecord.self, directory.appendingPathComponent("record.json"))
                try require(
                    record.verify(directory, stage: "products", key: thin.nodeKey, dependencies: record.dependencies),
                    "Invalid thin completion record"
                )
                try require(
                    fingerprint(tree(directory, excluding: ["record.json"])) == thin.contentDigest,
                    "Thin product bytes changed before packaging"
                )
            }
            for product in ProductDefinition.all {
                let xcf = work.appendingPathComponent(product.framework + ".xcframework")
                var frameworks: [URL] = []
                for slice in slices {
                    let selected = products.filter { $0.component == product.component && $0.slice.id == slice.id }
                    try require(
                        Set(selected.map(\.architecture)) == Set(slice.architectures) && selected.count == slice.architectures.count,
                        "Missing/duplicate thin products: \(product.target)/\(slice.id)"
                    )
                    let framework = work.appendingPathComponent("frameworks/\(slice.id)/\(product.framework).framework")
                    try mkdir(framework)
                    let thinPaths = try selected.sorted { $0.architecture < $1.architecture }.map { thin in
                        let combined = work.appendingPathComponent("combined/\(slice.id)/\(thin.architecture)/libmpv.a")
                        combinedInputs[slice.id + "/" + thin.architecture] = try combine(thin, products: products, destination: combined)
                        return combined.path
                    }
                    if thinPaths.count == 1 {
                        try fm.copyItem(
                            at: URL(fileURLWithPath: thinPaths[0]),
                            to: framework.appendingPathComponent(product.framework)
                        )
                    } else {
                        try runner.run(
                            "/usr/bin/lipo",
                            ["-create"] + thinPaths + ["-output", framework.appendingPathComponent(product.framework).path]
                        )
                    }
                    let headerRoots = try selected.map { try (
                        $0.architecture,
                        store.path($0.directory).appendingPathComponent("include/" + product.headerDirectory)
                    ) }
                    try mergeHeaders(headerRoots, destination: framework.appendingPathComponent("Headers"))
                    try mkdir(framework.appendingPathComponent("Modules"))
                    let excluded = Self.excludedHeaders(product.framework).map { "    exclude header \"\($0).h\"\n" }.joined()
                    try put(
                        "framework module \(product.framework) [system] {\n    umbrella \".\"\n\(excluded)    export *\n}\n",
                        framework.appendingPathComponent("Modules/module.modulemap")
                    )
                    let info: [String: Any] = [
                        "CFBundleExecutable": product.framework,
                        "CFBundleIdentifier": "org.mpvui." + product.framework.lowercased(),
                        "CFBundleName": product.framework,
                        "CFBundlePackageType": "FMWK",
                        "CFBundleVersion": "1",
                        "CFBundleShortVersionString": graph.native.metadataVersion.components(separatedBy: "-")[0],
                        "MinimumOSVersion": slice.minimumOS,
                        "CFBundleSupportedPlatforms": [Self.platformName(slice)]
                    ]
                    try put(
                        PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0),
                        framework.appendingPathComponent("Info.plist")
                    )
                    if slice.id == "macos" {
                        try Self.versionFramework(framework, binary: product.framework)
                    }
                    frameworks.append(framework)
                }
                try runner.run(
                    "/usr/bin/xcodebuild",
                    ["-create-xcframework"] + frameworks.flatMap { ["-framework", $0.path] } + ["-output", xcf.path]
                )
                try put(notices, xcf.appendingPathComponent("SOURCE_NOTICES.txt"))
                try put(license, xcf.appendingPathComponent("RECIPE_LICENSE"))
                let components = Dictionary(uniqueKeysWithValues: products.map { (
                    $0.component + "/" + $0.slice.id + "/" + $0.architecture,
                    $0.contentDigest
                ) })
                try write(
                    NativeBuildProvenance(
                        schemaVersion: 1,
                        nativeInputFingerprint: nativeID,
                        nativeLockDigest: fingerprint(graph.native),
                        componentDigests: components,
                        combinedInputs: combinedInputs
                    ),
                    xcf.appendingPathComponent("provenance.json")
                )
                try verify(xcf, product: product, slices: slices)
                try normalize(xcf)
                let archive = output.appendingPathComponent(product.archive)
                let entries = try [xcf.lastPathComponent] + files(xcf).map { String($0.path.dropFirst(work.path.count + 1)) }
                try runner.run(
                    "/usr/bin/zip",
                    ["-X", "-q", "-y", archive.path, "-@"],
                    cwd: work,
                    input: Data((entries.sorted().joined(separator: "\n") + "\n").utf8)
                )
                _ = try Archive.entries(Data(contentsOf: archive, options: .mappedIfSafe))
                let sha = try digest(archive)
                let unpacked = work.appendingPathComponent("verify-" + product.target)
                try Archive.extract(archive, to: unpacked, runner: runner)
                try require(tree(xcf) == tree(unpacked.appendingPathComponent(xcf.lastPathComponent)), "ZIP changed framework bytes")
                artifacts.append(Artifact(
                    target: product.target,
                    framework: product.framework,
                    module: product.framework,
                    archive: archive.lastPathComponent,
                    url: "https://github.com/\(graph.native.publication.repository)/releases/download/\(release)/\(archive.lastPathComponent)",
                    sha256: sha,
                    slices: slices
                ))
            }
            try write(
                ArtifactIndex(
                    schemaVersion: 2,
                    releaseID: release,
                    nativeInputFingerprint: nativeID,
                    provenancePath: "Libmpv.xcframework/provenance.json",
                    products: artifacts,
                    dependencies: []
                ),
                output.appendingPathComponent("Artifacts.lock.json")
            )
            try write(graph.native, output.appendingPathComponent("Inputs.lock.json"))
            try put(
                Data(contentsOf: graph.root.appendingPathComponent("Build/RECIPE_LICENSE")),
                output.appendingPathComponent("RECIPE_LICENSE")
            )
            try write(
                ["profile": profile, "nativeInputFingerprint": nativeID, "artifactSetKey": key],
                output.appendingPathComponent("candidate.json")
            )
            try remove(work)
            return ["exact-slice-inventory", "MachO-platforms", "public-headers", "compiled-contracts", "ZIP-round-trip"]
        }
    }

    /// Merge actual object archives per architecture. Merely putting several frameworks in a ZIP
    /// would still require separate binary targets and transitive package downloads.
    func combine(_ mpv: ThinProduct, products: [ThinProduct], destination: URL) throws -> [String: String] {
        let slice = mpv.slice
        let arch = mpv.architecture
        let ffmpeg = products.filter { $0.component == "ffmpeg" && $0.slice == slice && $0.architecture == arch }
        try require(ffmpeg.count == 1, "Missing/duplicate FFmpeg input for combined library")
        let mpvRoot = try graph.store.path(mpv.directory)
        let ffRoot = try graph.store.path(ffmpeg[0].directory)
        let record = try read(StageRecord.self, mpvRoot.appendingPathComponent("record.json"))
        try require(record.dependencies["ffmpeg"] == ffmpeg[0].contentDigest, "mpv was built against different FFmpeg bytes")
        var libraries = [("mpv", mpvRoot.appendingPathComponent("lib/libmpv.a"))]
        libraries += FFmpegRecipe.libraries.map { ($0, ffRoot.appendingPathComponent("lib/lib" + $0 + ".a")) }
        let builder = DependencyBuilder(inputs: graph.inputs, runner: graph.runner, store: graph.store)
        for dependency in graph.native.dependencies.filter({ $0.slices.contains(slice.id) }).sorted(by: { $0.id < $1.id }) {
            let root = try builder.materialize(dependency, slice: slice, arch: arch)
            try require(
                record.dependencies[dependency.id] == fingerprint(tree(root, excluding: ["record.json"])),
                "Combined dependency differs from mpv build input: \(dependency.id)"
            )
            libraries += dependency.runtime.sorted { $0.target < $1.target }.map { (
                $0.target,
                root.appendingPathComponent("lib/" + $0.library)
            ) }
        }
        try mkdir(destination.deletingLastPathComponent())
        try graph.runner.run("/usr/bin/libtool", ["-static", "-D", "-o", destination.path] + libraries.map(\.1.path))
        let expectedCount = try libraries.reduce(0) { try $0 + MachO.validate($1.1, slice: slice, arch: arch).count }
        try require(MachO.validate(destination, slice: slice, arch: arch).count == expectedCount, "Static merge lost input objects")
        return try Dictionary(uniqueKeysWithValues: libraries.map { try ($0.0, digest($0.1)) })
    }

    func verify(_ xcf: URL, product: ProductDefinition, slices: [Slice]) throws {
        let libraries = try XCFLibrary.all(xcf)
        try require(
            Set(libraries.map(\.identifier)) == Set(slices.map(\.identifier)) && libraries.count == slices.count,
            "Final XCFramework inventory mismatch"
        )
        for slice in slices {
            for arch in slice.architectures {
                let library = try XCFLibrary.select(libraries, slice: slice, arch: arch)
                try require(Set(library.architectures) == Set(slice.architectures), "Final architecture inventory mismatch")
                let binary = library.binary(xcf)
                _ = try MachO.validate(binary, slice: slice, arch: arch, allowOtherArchitectures: true)
                if product.component == "mpv" {
                    let thin = graph.runner.logs.appendingPathComponent("verify-\(slice.id)-\(arch).a")
                    let magic = try Data(contentsOf: binary, options: .mappedIfSafe).uint(0)
                    if [0xBEBA_FECA, 0xBFBA_FECA].contains(magic) {
                        try graph.runner.run(
                            "/usr/bin/lipo",
                            [binary.path, "-thin", arch, "-output", thin.path]
                        )
                    } else {
                        try fm.copyItem(at: binary.resolvingSymlinksInPath(), to: thin)
                    }
                    defer { try? remove(thin) }
                    try verifyMPV(thin, slice: slice, contracts: graph.native.contracts, runner: graph.runner)
                }
            }
        }
    }

    func mergeHeaders(_ roots: [(String, URL)], destination: URL) throws {
        try mkdir(destination)
        let inventories = try roots.map { try ($0.0, $0.1, tree($0.1)) }
        guard let first = inventories.first else { throw BuildError("No header inputs") }
        for other in inventories {
            try require(Set(first.2.keys) == Set(other.2.keys), "Header inventory differs between architectures")
        }
        for name in first.2.keys.sorted() {
            let output = try contained(destination, name)
            if Set(inventories.map { $0.2[name]! }).count == 1 {
                try put(Data(contentsOf: first.1.appendingPathComponent(name)), output)
            } else {
                try require(name.hasSuffix(".h"), "Non-header bytes differ between architectures: \(name)")
                let sorted = inventories.sorted { lhs, rhs in
                    if lhs.0 == rhs.0 {
                        return false
                    }
                    return lhs.0 == "arm64e" ? true : rhs.0 == "arm64e" ? false : lhs.0 < rhs.0
                }
                var conditional = "/* Architecture-specific generated header. */\n"
                for (index, input) in sorted.enumerated() {
                    conditional += "#\(index == 0 ? "if" : "elif") defined(__\(input.0 == "arm64" ? "arm64" : input.0)__)\n"
                    conditional += try String(contentsOf: input.1.appendingPathComponent(name), encoding: .utf8) + "\n"
                }
                conditional += "#else\n#error Unsupported architecture\n#endif\n"
                try put(conditional, output)
            }
        }
    }

    func normalize(_ root: URL) throws {
        try Self.normalizeMetadata(root.appendingPathComponent("Info.plist"))
        for path in try [root] + files(root) {
            let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink != true {
                try fm.setAttributes(
                    [.posixPermissions: values.isDirectory == true ? 0o755 : 0o644],
                    ofItemAtPath: path.path
                )
            } else {
                try require(lchmod(path.path, 0o755) == 0, "Failed to normalize symlink mode: \(path.path)")
            }
            var times = [
                timeval(tv_sec: graph.native.sourceDateEpoch, tv_usec: 0),
                timeval(tv_sec: graph.native.sourceDateEpoch, tv_usec: 0)
            ]
            try require(lutimes(path.path, &times) == 0, "Failed to normalize timestamp: \(path.path)")
        }
    }

    static func normalizeMetadata(_ file: URL) throws {
        var metadata = try plist(file)
        guard let available = metadata["AvailableLibraries"] as? [[String: Any]]
        else { throw BuildError("Missing XCFramework library inventory") }
        var libraries: [[String: Any]] = []
        for var library in available {
            guard library["LibraryIdentifier"] is String,
                  let architectures = library["SupportedArchitectures"] as? [String]
            else { throw BuildError("Invalid XCFramework library metadata") }
            library["SupportedArchitectures"] = architectures.sorted()
            libraries.append(library)
        }
        // xcodebuild uses an unordered internal collection even when its input arguments are sorted.
        metadata["AvailableLibraries"] = libraries.sorted { ($0["LibraryIdentifier"] as! String) < ($1["LibraryIdentifier"] as! String) }
        try put(PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0), file)
    }

    static func platformName(_ slice: Slice) -> String {
        [
            "iphoneos": "iPhoneOS",
            "iphonesimulator": "iPhoneSimulator",
            "appletvos": "AppleTVOS",
            "appletvsimulator": "AppleTVSimulator",
            "macosx": "MacOSX",
            "xros": "XROS",
            "xrsimulator": "XRSimulator"
        ][slice.sdk]!
    }

    static func versionFramework(_ root: URL, binary: String) throws {
        let version = root.appendingPathComponent("Versions/A")
        try mkdir(version.appendingPathComponent("Resources"))
        for name in [binary, "Headers", "Modules"] {
            try fm.moveItem(at: root.appendingPathComponent(name), to: version.appendingPathComponent(name))
            try fm.createSymbolicLink(atPath: root.appendingPathComponent(name).path, withDestinationPath: "Versions/Current/" + name)
        }
        try fm.moveItem(at: root.appendingPathComponent("Info.plist"), to: version.appendingPathComponent("Resources/Info.plist"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")
    }

    static func excludedHeaders(_ framework: String) -> [String] {
        if framework == "Libavcodec" {
            return ["xvmc", "vdpau", "qsv", "dxva2", "d3d11va", "d3d12va"]
        }
        if framework == "Libavutil" {
            return [
                "hwcontext_vulkan",
                "hwcontext_vdpau",
                "hwcontext_vaapi",
                "hwcontext_qsv",
                "hwcontext_opencl",
                "hwcontext_dxva2",
                "hwcontext_d3d11va",
                "hwcontext_d3d12va",
                "hwcontext_cuda",
                "hwcontext_amf"
            ]
        }
        return []
    }
}
