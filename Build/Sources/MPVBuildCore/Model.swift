import Foundation

struct BuildError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    init(_ description: String) {
        self.description = description
    }

    var errorDescription: String? {
        description
    }
}

func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition {
        throw BuildError(message())
    }
}

struct Revision: Codable, Sendable { let url: String
    let ref: String
    let commit: String
}

struct Patch: Codable, Sendable { let id: String
    let path: String
    let sha256: String
}

struct Source: Codable, Sendable {
    let id: String
    let url: String
    let ref: String
    let commit: String
    let version: String
    let patches: [Patch]
}

struct RuntimeAsset: Codable, Sendable {
    let target: String
    let framework: String
    let module: String
    let url: String
    let sha256: String
    var library: String {
        framework == "MoltenVK" ? "libMoltenVK.a" : (framework.hasPrefix("Lib") ? "lib" + framework.dropFirst(3) : "lib" + framework) +
            ".a"
    }
}

struct Dependency: Codable, Sendable {
    let id: String
    let version: String
    let kind: String
    let url: String
    let sha256: String
    let consumers: [String]
    let slices: [String]
    let runtime: [RuntimeAsset]
}

struct Slice: Codable, Sendable, Equatable {
    let id: String
    let platform: String
    let variant: String
    let architectures: [String]
    let sdk: String
    let minimumOS: String
    let machOPlatform: Int
    var identifier: String {
        platform + "-" + architectures.sorted().joined(separator: "_") + (variant.isEmpty ? "" : "-" + variant)
    }

    func triple(_ arch: String) -> String {
        arch + "-apple-" + platform + minimumOS + (variant == "maccatalyst" ? "-macabi" : variant.isEmpty ? "" : "-" + variant)
    }

    func selecting(_ arches: [String]) -> Slice {
        Slice(
            id: id,
            platform: platform,
            variant: variant,
            architectures: arches,
            sdk: sdk,
            minimumOS: minimumOS,
            machOPlatform: machOPlatform
        )
    }
}

struct SDKIdentity: Codable, Sendable, Equatable { let version: String
    let build: String
}

struct XcodeIdentity: Codable, Sendable { let version: String
    let build: String
    let swift: String
    let clang: String
}

struct BootstrapAsset: Codable, Sendable { let id: String
    let kind: String
    let url: String
    let sha256: String
}

struct ToolchainLock: Codable, Sendable { let xcode: XcodeIdentity
    let tools: [String: String]
    let sdks: [String: SDKIdentity]
    let bootstrapAssets: [BootstrapAsset]
}

struct Features: Codable, Sendable { let gpl: Bool
    let libraryOnly: Bool
    let videoToolbox: Bool
    let moltenVK: Bool
    let avfoundation: Bool
}

struct Contracts: Codable, Sendable {
    let minimumMPVBytes: Int
    let mpvMembers: [String]
    let mpvDefinitions: [String]
    let mpvReferences: [String]
    let mpvStrings: [String]
    let macOSSwiftMember: String
}

struct Publication: Codable, Sendable { let repository: String
    let nativePrefix: String
}

struct NativeLock: Codable, Sendable {
    let schemaVersion: Int
    let recipeProvenance: Revision
    let metadataVersion: String
    let sourceDateEpoch: Int
    let epochPolicy: String
    let toolchain: ToolchainLock
    let slices: [Slice]
    let sources: [Source]
    let dependencies: [Dependency]
    let features: Features
    let contracts: Contracts
    let publication: Publication

    func validate(root: URL) throws {
        try require(schemaVersion == 1, "Unsupported native lock schema \(schemaVersion)")
        try require(sourceDateEpoch >= 315_532_800, "Source epoch must be ZIP-representable and explicit")
        try require(
            features.gpl && features.libraryOnly && features.videoToolbox && features.moltenVK && features.avfoundation,
            "Unsupported feature profile"
        )
        try unique(slices.map(\.id), "slice IDs")
        try unique(slices.map(\.identifier), "slice identifiers")
        try require(Set(sources.map(\.id)) == ["mpv", "ffmpeg"], "Exactly mpv and ffmpeg sources are required")
        try unique(sources.map(\.id), "source IDs")
        try unique(dependencies.map(\.id), "dependency IDs")
        for slice in slices {
            let supported: [String: (String, String, String, Int, Set<String>)] = [
                "ios": ("ios", "", "iphoneos", 2, ["arm64"]),
                "isimulator": ("ios", "simulator", "iphonesimulator", 7, ["arm64", "x86_64"]),
                "maccatalyst": ("ios", "maccatalyst", "macosx", 6, ["arm64", "x86_64"]),
                "macos": ("macos", "", "macosx", 1, ["arm64", "x86_64"]),
                "tvos": ("tvos", "", "appletvos", 3, ["arm64", "arm64e"]),
                "tvsimulator": ("tvos", "simulator", "appletvsimulator", 8, ["arm64", "x86_64"]),
                "xros": ("xros", "", "xros", 11, ["arm64"]),
                "xrsimulator": ("xros", "simulator", "xrsimulator", 12, ["arm64"]),
            ]
            guard let allowed = supported[slice.id] else { throw BuildError("Unsupported slice \(slice.id)") }
            try require(
                slice.platform == allowed.0 && slice.variant == allowed.1 && slice.sdk == allowed.2 && slice.machOPlatform == allowed.3,
                "Invalid platform metadata for \(slice.id)"
            )
            try require(
                !slice.architectures.isEmpty && Set(slice.architectures).isSubset(of: allowed.4),
                "Unsupported architectures for \(slice.id)"
            )
            try unique(slice.architectures, "\(slice.id) architectures")
            try require(
                slice.minimumOS.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil,
                "Invalid deployment floor for \(slice.id)"
            )
            try require(toolchain.sdks[slice.sdk] != nil, "Missing SDK lock: \(slice.sdk)")
        }
        for source in sources {
            try hex(source.commit, count: 40)
            try https(source.url)
            try unique(source.patches.map(\.id), "patch IDs")
            for patch in source.patches {
                let file = try contained(root, patch.path)
                try hex(patch.sha256)
                try require(digest(file) == patch.sha256, "Patch checksum drift: \(patch.path)")
            }
            let patchDirectory = root.appendingPathComponent("Build/Patches/\(source.id)")
            let actual = try files(patchDirectory).filter { $0.pathExtension == "patch" }.map { $0.path.replacingOccurrences(
                of: root.path + "/",
                with: ""
            ) }
            try require(Set(actual) == Set(source.patches.map(\.path)), "Missing or unexpected \(source.id) patches")
        }
        for dependency in dependencies {
            try require(dependency.kind == "prebuilt-sdk", "Unsupported dependency asset kind")
            try require(!dependency.runtime.isEmpty, "Dependency \(dependency.id) has no runtime relationship")
            try hex(dependency.sha256)
            try https(dependency.url)
            try require(Set(dependency.slices).isSubset(of: Set(slices.map(\.id))), "Invalid dependency coverage")
            for runtime in dependency.runtime {
                try hex(runtime.sha256)
                try https(runtime.url)
            }
        }
        try unique(dependencies.flatMap { $0.runtime.map(\.target) }, "runtime targets")
        try unique(toolchain.bootstrapAssets.map(\.id), "bootstrap tools")
        for asset in toolchain.bootstrapAssets {
            try hex(asset.sha256)
            try https(asset.url)
            try require(["wheel", "source-tar"].contains(asset.kind), "Unsupported bootstrap asset kind")
        }
    }

    func source(_ id: String) throws -> Source {
        guard let source = sources.first(where: { $0.id == id }) else { throw BuildError("Unknown source \(id)") }
        return source
    }

    func selected(profile: String, sliceNames: String?, archNames: String?, host: String) throws -> [Slice] {
        try require(["dev", "release"].contains(profile), "Profile must be dev or release")
        if profile == "release" {
            try require(sliceNames == nil && archNames == nil, "Release rejects partial --slices/--arch selection")
            return slices
        }
        let names = (sliceNames ?? "macos").components(separatedBy: ",")
        try unique(names, "requested slices")
        return try names.map { name in
            guard let slice = slices.first(where: { $0.id == name }) else { throw BuildError("Unsupported slice \(name)") }
            let arches = (archNames ?? (sliceNames == nil ? host : slice.architectures.joined(separator: ","))).components(separatedBy: ",")
            try unique(arches, "requested architectures")
            try require(
                !arches.isEmpty && Set(arches).isSubset(of: Set(slice.architectures)),
                "Unsupported \(name)/\(arches.joined(separator: ","))"
            )
            return slice.selecting(arches)
        }
    }
}

func unique(_ strings: [String], _ description: String) throws {
    try require(Set(strings).count == strings.count, "Duplicate \(description)")
}

func hex(_ value: String, count: Int = 64) throws {
    try require(
        value.range(of: "^[a-f0-9]{\(count)}$", options: .regularExpression) != nil,
        "Invalid immutable digest: \(value)"
    )
}

func https(_ value: String) throws {
    try require(
        URL(string: value)?.scheme == "https" && URL(string: value)?.host != nil,
        "Expected authoritative HTTPS URL: \(value)"
    )
}
