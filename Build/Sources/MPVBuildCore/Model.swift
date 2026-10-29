import Foundation

package struct BuildError: Error {

    package let description: String

    package var localizedDescription: String {
        description
    }

    init(_ description: String) {
        self.description = description
    }
}

extension BuildError: CustomStringConvertible {}

func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition {
        throw BuildError(message())
    }
}

struct Revision: Codable {

    let url: String
    let ref: String
    let commit: String
}

struct Patch: Codable {

    let id: String
    let path: String
    let sha256: String
}

struct Source: Codable {

    let id: String
    let url: String
    let ref: String
    let commit: String
    let version: String
    let patches: [Patch]
}

enum NativePlatform: String, Codable, CaseIterable {

    case apple
    case android
}

struct ScopedPatch: Codable {

    let id: String
    let path: String
    let sha256: String
    let platforms: [NativePlatform]

    var patch: Patch {
        Patch(id: id, path: path, sha256: sha256)
    }
}

struct LockedSource: Codable {

    let id: String
    let url: String
    let ref: String
    let commit: String
    let version: String
    let patches: [ScopedPatch]

    func resolved(for platform: NativePlatform) -> Source {
        Source(
            id: id,
            url: url,
            ref: ref,
            commit: commit,
            version: version,
            patches: patches.filter { $0.platforms.contains(platform) }.map(\.patch)
        )
    }
}

struct RuntimeAsset: Codable {

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

struct Dependency: Codable {

    let id: String
    let version: String
    let kind: String
    let url: String
    let sha256: String
    let consumers: [String]
    let slices: [String]
    let runtime: [RuntimeAsset]
}

struct Slice: Codable, Equatable {

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

struct SDKIdentity: Codable, Equatable {

    let version: String
    let build: String
}

struct XcodeIdentity: Codable {

    let version: String
    let build: String
    let swift: String
    let clang: String
}

struct BootstrapAsset: Codable {

    let id: String
    let kind: String
    let url: String
    let sha256: String
}

struct ToolchainLock: Codable {

    let xcode: XcodeIdentity
    let tools: [String: String]
    let sdks: [String: SDKIdentity]
    let bootstrapAssets: [BootstrapAsset]
}

struct Features: Codable {

    let gpl: Bool
    let libraryOnly: Bool
    let videoToolbox: Bool
    let moltenVK: Bool
    let avfoundation: Bool
}

struct Contracts: Codable {

    let minimumMPVBytes: Int
    let mpvMembers: [String]
    let mpvDefinitions: [String]
    let mpvReferences: [String]
    let mpvStrings: [String]
    let macOSSwiftMember: String
}

struct Publication: Codable {

    let repository: String
    let nativePrefix: String
}

struct AppleInputs: Codable {

    let recipeSource: Revision
    let metadataVersion: String
    let sourceDateEpoch: Int
    let epochPolicy: String
    let toolchain: ToolchainLock
    let slices: [Slice]
    let dependencies: [Dependency]
    let features: Features
    let contracts: Contracts
    let publication: Publication
}

struct SourcePin: Codable {

    let url: String
    let commit: String
    let patches: [Patch]?
}

struct ArchivePin: Codable {

    let url: String
    let sha256: String
}

struct AndroidToolchain: Codable {

    let ndk: String
    let rust: String
    let cargoC: String
}

struct AndroidSwiftCompiler: Codable {

    let url: String
    let files: [String: String]
}

struct AndroidSwiftInputs: Codable {

    let version: String
    let sdk: String
    let abis: [String]
    let sdkArchive: ArchivePin
    let compiler: [String: AndroidSwiftCompiler]
    let sdkFiles: [String: String]
    let sdkResources: [String: String]
    let runtime: [String: [String: String]]
    let licenses: [String: ArchivePin]
}

struct AndroidInputs: Codable {

    let minimumAPI: Int
    let recipe: String
    let swift: AndroidSwiftInputs
    let toolchain: AndroidToolchain
    let git: [String: SourcePin]
    let archives: [String: ArchivePin]
}

struct NativeLock: Codable {

    struct ResolvedAppleInputs: Encodable {

        let configuration: AppleInputs
        let sources: [Source]
    }

    let schemaVersion: Int
    let sources: [LockedSource]
    let apple: AppleInputs
    let android: AndroidInputs

    var appleBuildInputs: ResolvedAppleInputs {
        ResolvedAppleInputs(configuration: apple, sources: sources(for: .apple))
    }

    func sources(for platform: NativePlatform) -> [Source] {
        sources.map { $0.resolved(for: platform) }
    }

    func validate(root: URL) throws {
        try require(schemaVersion == 1, "Unsupported native input schema")
        try require(apple.sourceDateEpoch >= 315_532_800, "Source epoch must be ZIP-representable and explicit")

        try require(
            apple.features.gpl && apple.features.libraryOnly && apple.features.videoToolbox && apple.features.moltenVK && apple.features
                .avfoundation,
            "Unsupported feature profile"
        )

        try unique(apple.slices.map(\.id), "slice IDs")
        try unique(apple.slices.map(\.identifier), "slice identifiers")
        try require(Set(sources.map(\.id)) == ["mpv", "ffmpeg"], "Exactly mpv and ffmpeg sources are required")
        try unique(sources.map(\.id), "source IDs")
        try unique(apple.dependencies.map(\.id), "dependency IDs")

        for slice in apple.slices {
            let supported: [String: (String, String, String, Int, Set<String>)] = [
                "ios": ("ios", "", "iphoneos", 2, ["arm64"]),
                "isimulator": ("ios", "simulator", "iphonesimulator", 7, ["arm64", "x86_64"]),
                "maccatalyst": ("ios", "maccatalyst", "macosx", 6, ["arm64", "x86_64"]),
                "macos": ("macos", "", "macosx", 1, ["arm64", "x86_64"]),
                // tvOS is outside Apple's Enhanced Security adoption path. Ship its standard device ABI.
                "tvos": ("tvos", "", "appletvos", 3, ["arm64"]),
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

            try require(apple.toolchain.sdks[slice.sdk] != nil, "Missing SDK lock: \(slice.sdk)")
        }

        for source in sources {
            try hex(source.commit, count: 40)
            try https(source.url)
            try unique(source.patches.map(\.id), "patch IDs")
            try unique(source.patches.map(\.path), "patch paths")

            for patch in source.patches {
                try require(!patch.platforms.isEmpty, "Patch has no platform: \(patch.path)")
                try unique(patch.platforms.map(\.rawValue), "patch platforms")

                let file = try contained(root, patch.path)

                try hex(patch.sha256)
                try require(digest(file) == patch.sha256, "Patch checksum drift: \(patch.path)")
            }

            let patchDirectory = root.appendingPathComponent("Build/Patches/\(source.id)")

            let actual = try files(patchDirectory).filter { $0.pathExtension == "patch" }.map { $0.path.replacingOccurrences(
                of: root.path + "/",
                with: ""
            ) }
            try require(Set(actual) == Set(source.resolved(for: .apple).patches.map(\.path)), "Missing or unexpected \(source.id) patches")
        }

        let androidPatches = try files(root.appendingPathComponent("Build/Android/Patches"))
            .filter { $0.pathExtension == "patch" }
            .map { String($0.path.dropFirst(root.path.count + 1)) }

        let registeredAndroidPatches = sources.flatMap(\.patches)
            .filter { $0.platforms == [.android] }
            .map(\.path)
            + android.git.values.flatMap { ($0.patches ?? []).map(\.path) }
        try require(Set(androidPatches) == Set(registeredAndroidPatches), "Missing or unexpected Android patches")
        try require(Set(android.git.keys).isDisjoint(with: sources.map(\.id)), "Android dependencies must not override shared source pins")
        try hex(android.recipe, count: 40)

        for source in android.git.values {
            try https(source.url)
            try hex(source.commit, count: 40)

            let patches = source.patches ?? []
            try unique(patches.map(\.id), "Android dependency patch IDs")
            try unique(patches.map(\.path), "Android dependency patch paths")

            for patch in patches {
                let file = try contained(root, patch.path)

                try hex(patch.sha256)
                try require(digest(file) == patch.sha256, "Patch checksum drift: \(patch.path)")
            }
        }

        for archive in android.archives.values {
            try https(archive.url)
            try hex(archive.sha256)
        }

        for dependency in apple.dependencies {
            try require(dependency.kind == "prebuilt-sdk", "Unsupported dependency asset kind")
            try require(!dependency.runtime.isEmpty, "Dependency \(dependency.id) has no runtime relationship")
            try hex(dependency.sha256)
            try https(dependency.url)
            try require(Set(dependency.slices).isSubset(of: Set(apple.slices.map(\.id))), "Invalid dependency coverage")

            for runtime in dependency.runtime {
                try hex(runtime.sha256)
                try https(runtime.url)
            }
        }

        try unique(apple.dependencies.flatMap { $0.runtime.map(\.target) }, "runtime targets")
        try unique(apple.toolchain.bootstrapAssets.map(\.id), "bootstrap tools")

        for asset in apple.toolchain.bootstrapAssets {
            try hex(asset.sha256)
            try https(asset.url)
            try require(["wheel", "source-tar"].contains(asset.kind), "Unsupported bootstrap asset kind")
        }
    }

    func source(_ id: String, platform: NativePlatform = .apple) throws -> Source {
        guard let source = sources.first(where: { $0.id == id }) else { throw BuildError("Unknown source \(id)") }

        return source.resolved(for: platform)
    }

    func selected(profile: String, sliceNames: String?, archNames: String?, host: String) throws -> [Slice] {
        try require(["dev", "release"].contains(profile), "Profile must be dev or release")

        if profile == "release" {
            try require(sliceNames == nil && archNames == nil, "Release rejects partial --slices/--arch selection")
            return apple.slices
        }

        let names = (sliceNames ?? "macos").components(separatedBy: ",")
        try unique(names, "requested slices")

        return try names.map { name in
            guard let slice = apple.slices.first(where: { $0.id == name }) else { throw BuildError("Unsupported slice \(name)") }

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
