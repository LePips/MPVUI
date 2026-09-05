import Foundation

struct DependencyEvidence: Codable {
    let component: String
    let slice: String
    let architecture: String
    let sdkDigest: String
    let runtimeDigests: [String: String]
    let objectCount: Int
    let headerCount: Int
    let headerOverrides: [String]
    let binarySource: String
}

struct DependencyBuilder: Sendable {
    let inputs: InputStore
    let runner: Runner
    let store: ManagedStore
    func materialize(_ dependency: Dependency, slice: Slice, arch: String) throws -> URL {
        let sdk = try inputs.extracted(url: dependency.url, sha: dependency.sha256)
        let implementation = try Dictionary(uniqueKeysWithValues: ["Dependencies.swift", "Model.swift", "MachO.swift", "Archive.swift"]
            .map { try (
                $0,
                digest(inputs.codeRoot.appendingPathComponent($0))
            ) })
        let key = try fingerprint(DependencyKey(dependency: dependency, slice: slice.selecting([arch]), implementation: implementation))
        var runtimeRoots: [(RuntimeAsset, URL)] = []
        for runtime in dependency.runtime {
            try runtimeRoots.append((runtime, inputs.extracted(url: runtime.url, sha: runtime.sha256)))
        }
        return try store.node(stage: "products", name: "dependencies/\(dependency.id)/\(slice.id)-\(arch)", key: key) { output in
            let headers = sdk.appendingPathComponent("include")
            let pc = sdk.appendingPathComponent("pkgconfig-example/\(slice.id)/\(arch)")
            try require(exists(headers) && exists(pc), "Missing SDK headers/pkg-config: \(dependency.id)/\(slice.id)/\(arch)")
            try fm.copyItem(at: headers, to: output.appendingPathComponent("include"))
            try mkdir(output.appendingPathComponent("lib"))
            try fm.copyItem(at: pc, to: output.appendingPathComponent("lib/pkgconfig"))
            let sdkBinaries: [URL]
            if dependency.id == "vulkan" {
                let xcf = sdk.appendingPathComponent("lib/MoltenVK.xcframework")
                let library = try XCFLibrary.select(XCFLibrary.all(xcf), slice: slice, arch: arch)
                sdkBinaries = [library.binary(xcf)]
            } else {
                let lib = sdk.appendingPathComponent("lib/\(slice.id)/thin/\(arch)/lib")
                try require(exists(lib), "Missing SDK binary coverage: \(dependency.id)/\(slice.id)/\(arch)")
                sdkBinaries = try fm.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil).filter { $0.pathExtension == "a" }
            }
            try require(!sdkBinaries.isEmpty, "Dependency SDK contains no static libraries")
            // Only runtime-linked libraries are required. Extra tools/C++ bindings in SDK bundles are unreachable.
            for runtime in dependency.runtime {
                guard let binary = sdkBinaries.first(where: { $0.lastPathComponent == runtime.library })
                else { throw BuildError("SDK lacks \(runtime.library)") }
                _ = try MachO.validate(binary, slice: slice, arch: arch, allowOtherArchitectures: true)
            }
            let sdkHeaders = try files(headers).filter { $0.pathExtension == "h" }
            var objectCount = 0
            var headerCount = 0
            var headerOverrides: [String] = []
            var runtimeDigests: [String: String] = [:]
            for (runtime, extracted) in runtimeRoots {
                let roots = try fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "xcframework" }
                try require(roots.count == 1, "Unexpected runtime archive root: \(runtime.target)")
                let xcf = roots[0]
                let library = try XCFLibrary.select(XCFLibrary.all(xcf), slice: slice, arch: arch)
                let binary = library.binary(xcf)
                objectCount += try MachO.validate(binary, slice: slice, arch: arch, allowOtherArchitectures: true).count
                let dest = output.appendingPathComponent("lib/\(runtime.library)")
                // Using the public binary as the build input removes any SDK/public binary equivalence assumption.
                if library.architectures.count > 1 {
                    try runner.run("/usr/bin/lipo", [binary.path, "-thin", arch, "-output", dest.path])
                } else {
                    try fm.copyItem(at: binary.resolvingSymlinksInPath(), to: dest)
                }
                runtimeDigests[runtime.target] = try digest(dest)
                let publicHeaders = binary.deletingLastPathComponent().appendingPathComponent("Headers")
                if !exists(publicHeaders) {
                    guard let sdkBinary = sdkBinaries.first(where: { $0.lastPathComponent == runtime.library })
                    else { throw BuildError("Missing paired SDK binary") }
                    try require(
                        digest(sdkBinary) == digest(binary),
                        "Headerless public artifact differs from its locked SDK binary: \(runtime.target)"
                    )
                }
                for header in try (exists(publicHeaders) ? files(publicHeaders) : []) where header.pathExtension == "h" {
                    let candidates = sdkHeaders.filter { $0.lastPathComponent == header.lastPathComponent }
                    let sha = try digest(header)
                    var matching = false
                    for candidate in candidates where try digest(candidate) == sha {
                        matching = true
                        break
                    }
                    if !matching {
                        try require(
                            candidates.count == 1,
                            "Cannot map public header into SDK include layout: \(runtime.target)/\(header.lastPathComponent)"
                        )
                        let relative = String(candidates[0].path.dropFirst(headers.path.count + 1))
                        // Prefer the platform-specific public header paired with the binary over the SDK's generic header.
                        try put(Data(contentsOf: header), output.appendingPathComponent("include/" + relative))
                        headerOverrides.append(runtime.target + "/" + relative)
                    }
                    headerCount += 1
                }
            }
            for file in try files(output.appendingPathComponent("lib/pkgconfig")) where file.pathExtension == "pc" {
                var text = try String(contentsOf: file, encoding: .utf8)
                text = text.replacingOccurrences(
                    of: "/path/to/workdir/\(dependency.id)/\(slice.id)/thin/\(arch)",
                    with: "${pcfiledir}/../.."
                )
                try require(!text.contains("/path/to/workdir"), "Unresolved pkg-config prefix in \(file.lastPathComponent)")
                try put(text, file)
            }
            try write(
                DependencyEvidence(
                    component: dependency.id,
                    slice: slice.id,
                    architecture: arch,
                    sdkDigest: dependency.sha256,
                    runtimeDigests: runtimeDigests,
                    objectCount: objectCount,
                    headerCount: headerCount,
                    headerOverrides: headerOverrides,
                    binarySource: "Published checksum-locked binaries and paired public headers; remaining support headers from checksum-locked SDK"
                ),
                output.appendingPathComponent("coverage.json")
            )
            return ["all-linked-MachO-objects", "platform", "minimum-OS", "public-header-identity", "runtime-binary-as-build-input"]
        }
    }
}

private struct DependencyKey: Encodable { let dependency: Dependency
    let slice: Slice
    let implementation: [String: String]
}
