import Foundation

extension Data {
    func uint(_ offset: Int, bytes: Int = 4, big: Bool = false) throws -> UInt64 {
        try require(offset >= 0 && offset <= count - bytes, "Truncated binary metadata")
        return (0 ..< bytes).reduce(UInt64(0)) { $0 | UInt64(self[offset + $1]) << (8 * (big ? bytes - 1 - $1 : $1)) }
    }
}

struct ZipEntry { let name: String
    let symlink: Bool
}

enum Archive {
    static func entries(_ data: Data) throws -> [ZipEntry] {
        try require(data.count >= 22, "Truncated ZIP")
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try data.uint(i) == 0x0605_4B50, try i + 22 + Int(data.uint(i + 20, bytes: 2)) == data.count {
                end = i
                break
            }
        }
        guard let end else { throw BuildError("ZIP end record missing") }
        try require(data.uint(end + 4) == 0, "Multipart ZIP is unsupported")
        let count = try Int(data.uint(end + 10, bytes: 2))
        let size = try Int(data.uint(end + 12))
        var position = try Int(data.uint(end + 16))
        let limit = position + size
        try require(count < 65535 && limit == end, "ZIP64 or malformed directory is unsupported")
        var result: [ZipEntry] = []
        for _ in 0 ..< count {
            try require(data.uint(position) == 0x0201_4B50, "Malformed ZIP directory")
            let length = try Int(data.uint(position + 28, bytes: 2))
            let extra = try Int(data.uint(position + 30, bytes: 2))
            let comment = try Int(data.uint(position + 32, bytes: 2))
            try require(position + 46 + length + extra + comment <= limit, "Truncated ZIP entry")
            guard let name = String(data: data.subdata(in: position + 46 ..< position + 46 + length), encoding: .utf8)
            else { throw BuildError("Non-UTF8 ZIP path") }
            try validatePath(name)
            let local = try Int(data.uint(position + 42))
            try require(
                data.uint(local) == 0x0403_4B50 && data.uint(local + 26, bytes: 2) == UInt64(length),
                "ZIP local header differs from directory"
            )
            try require(
                local + 30 + length <= data.count && data.subdata(in: local + 30 ..< local + 30 + length) == Data(name.utf8),
                "ZIP local path differs from directory"
            )
            try require(
                data.uint(local + 6, bytes: 2) == data.uint(position + 8, bytes: 2) && data.uint(local + 8, bytes: 2) == data.uint(
                    position + 10,
                    bytes: 2
                ),
                "ZIP local flags differ from directory"
            )
            let mode = try (data.uint(position + 38)) >> 16
            try require((data.uint(position + 8, bytes: 2)) & 1 == 0, "Encrypted ZIP is unsupported")
            try require([0, 0o100000, 0o040000, 0o120000].contains(mode & 0o170000), "Unsupported ZIP file type")
            result.append(ZipEntry(name: name, symlink: mode & 0o170000 == 0o120000))
            position += 46 + length + extra + comment
        }
        try require(position == limit, "ZIP directory length mismatch")
        try unique(result.map { $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }, "ZIP paths")
        return result
    }

    static func validatePath(_ path: String) throws {
        try require(!path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":"), "Unsafe ZIP path: \(path)")
        try require(!path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), "Control character in ZIP path")
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        try require(!parts.dropLast().contains("") && !parts.contains("..") && !parts.contains("."), "Unsafe ZIP components: \(path)")
    }

    static func extract(_ archive: URL, to destination: URL, runner: Runner) throws {
        try require(
            !exists(destination) ||
                (destination == destination.resolvingSymlinksInPath() && (fm.contentsOfDirectory(atPath: destination.path)).isEmpty),
            "ZIP extraction requires a new or empty directory"
        )
        let inventory = try entries(Data(contentsOf: archive, options: .mappedIfSafe))
        let links = inventory.filter(\.symlink)
        for link in links {
            let target = try runner.run("/usr/bin/unzip", ["-p", archive.path, link.name])
            try require(!target.isEmpty && !target.hasPrefix("/") && !target.contains("\\"), "Unsafe ZIP symlink")
            let resolved = destination.appendingPathComponent(link.name).deletingLastPathComponent().appendingPathComponent(target)
                .standardizedFileURL
            try require(resolved.path.hasPrefix(destination.standardizedFileURL.path + "/"), "Escaping ZIP symlink \(link.name)")
            try require(
                !inventory.contains(where: { $0.name != link.name && $0.name.hasPrefix(link.name + "/") }),
                "ZIP writes through symlink \(link.name)"
            )
        }
        try mkdir(destination)
        try runner.run("/usr/bin/unzip", ["-q", archive.path, "-d", destination.path])
        for path in try files(destination) {
            _ = try contained(destination, String(path.path.dropFirst(destination.path.count + 1)))
        }
    }
}

struct XCFLibrary {
    let identifier: String
    let libraryPath: String
    let architectures: [String]
    let platform: String
    let variant: String
    static func all(_ root: URL) throws -> [XCFLibrary] {
        guard let entries = try plist(root.appendingPathComponent("Info.plist"))["AvailableLibraries"] as? [[String: Any]]
        else { throw BuildError("Missing XCFramework inventory") }
        return try entries.map { entry in
            guard let id = entry["LibraryIdentifier"] as? String, let path = entry["LibraryPath"] as? String,
                  let arches = entry["SupportedArchitectures"] as? [String],
                  let platform = entry["SupportedPlatform"] as? String else { throw BuildError("Malformed XCFramework library") }
            _ = try contained(root, id)
            _ = try contained(root.appendingPathComponent(id), path)
            return XCFLibrary(
                identifier: id,
                libraryPath: path,
                architectures: arches,
                platform: platform,
                variant: entry["SupportedPlatformVariant"] as? String ?? ""
            )
        }
    }

    static func select(_ libraries: [XCFLibrary], slice: Slice, arch: String) throws -> XCFLibrary {
        let matching = libraries.filter { $0.platform == slice.platform && $0.variant == slice.variant && $0.architectures.contains(arch) }
        try require(matching.count == 1, "Expected one XCFramework library for \(slice.id)/\(arch), found \(matching.count)")
        return matching[0]
    }

    func binary(_ root: URL) -> URL {
        let path = root.appendingPathComponent(identifier).appendingPathComponent(libraryPath)
        return path.pathExtension == "framework" ? path.appendingPathComponent(path.deletingPathExtension().lastPathComponent) : path
    }
}
