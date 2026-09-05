import CryptoKit
import Darwin
import Foundation

var fm: FileManager {
    FileManager()
}

func canonical(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func fingerprint(_ value: some Encodable) throws -> String {
    try hash(canonical(value))
}

func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func digest(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var sha = SHA256()
    // Foundation may autorelease read buffers. A long-lived CLI must release each chunk
    // immediately instead of retaining every archive read until its outer run loop drains.
    while try autoreleasepool(invoking: { () throws -> Bool in
        guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { return false }
        sha.update(data: chunk)
        return true
    }) {}
    return sha.finalize().map { String(format: "%02x", $0) }.joined()
}

func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
    let value = try JSONDecoder().decode(type, from: data)
    // Codable checks required fields and types; this second pass rejects ignored fields recursively.
    func check(_ original: Any, _ encoded: Any, _ path: String) throws {
        if let a = original as? [String: Any], let b = encoded as? [String: Any] {
            try require(Set(a.keys).isSubset(of: Set(b.keys)), "Unknown fields at \(path): \(Set(a.keys).subtracting(b.keys).sorted())")
            for (key, child) in a {
                if let expected = b[key] {
                    try check(child, expected, path + "." + key)
                }
            }
        } else if let a = original as? [Any], let b = encoded as? [Any] {
            for (index, pair) in zip(a, b).enumerated() {
                try check(pair.0, pair.1, path + "[\(index)]")
            }
        }
    }
    try check(JSONSerialization.jsonObject(with: data), JSONSerialization.jsonObject(with: canonical(value)), "root")
    return value
}

func read<T: Codable>(_ type: T.Type, _ url: URL) throws -> T {
    do { return try decode(type, from: Data(contentsOf: url)) }
    catch let DecodingError.keyNotFound(key, context) {
        throw BuildError(
            "\(url.path): missing required field \((context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: "."))"
        )
    } catch { throw BuildError("\(url.path): \(error)") }
}

func write(_ value: some Encodable, _ url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try put(encoder.encode(value) + Data([10]), url)
}

func put(_ data: Data, _ url: URL) throws {
    try mkdir(url.deletingLastPathComponent())
    try data.write(to: url, options: .atomic)
}

func put(_ text: String, _ url: URL) throws {
    try put(Data(text.utf8), url)
}

func mkdir(_ path: URL) throws {
    try fm.createDirectory(at: path, withIntermediateDirectories: true)
}

func exists(_ path: URL) -> Bool {
    fm.fileExists(atPath: path.path)
}

func remove(_ path: URL) throws {
    if exists(path) || (try? fm.destinationOfSymbolicLink(atPath: path.path)) != nil {
        try fm.removeItem(at: path)
    }
}

func contained(_ root: URL, _ relative: String) throws -> URL {
    try require(
        !relative.isEmpty && !relative.hasPrefix("/") && !relative.components(separatedBy: "/").contains(".."),
        "Unsafe relative path: \(relative)"
    )
    let path = root.appendingPathComponent(relative)
    try require(path.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"), "Path escapes owner: \(relative)")
    return path
}

func files(_ root: URL) throws -> [URL] {
    // Enumerate relative names: URL enumeration may canonicalize /var to /private/var only on returned children.
    // Joining relative names keeps the same root spelling on both sides of a relocatable digest.
    var result: [URL] = []
    func visit(_ directory: URL) throws {
        for name in try fm.contentsOfDirectory(atPath: directory.path).sorted() {
            let child = directory.appendingPathComponent(name)
            result.append(child)
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true && values.isSymbolicLink != true {
                try visit(child)
            }
        }
    }
    try visit(root)
    return result.sorted { $0.path < $1.path }
}

func tree(_ root: URL, excluding: Set<String> = []) throws -> [String: String] {
    let root = root.resolvingSymlinksInPath()
    var result: [String: String] = [:]
    for path in try files(root) {
        try autoreleasepool {
            let relative = String(path.path.dropFirst(root.path.count + 1))
            if excluding.contains(relative) {
                return
            }
            let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                _ = try contained(root, relative)
                result[relative] = try "link:" + (fm.destinationOfSymbolicLink(atPath: path.path))
            } else if values.isRegularFile == true {
                let mode = try (fm.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
                // The executable attribute is semantic; group/other permission bits vary with umask.
                result[relative] = try "\(mode & 0o111 == 0 ? 0 : 1):" + digest(path)
            }
        }
    }
    return result
}

final class FileLock {
    private let fd: Int32
    init(_ file: URL, shared: Bool = false) throws {
        try mkdir(file.deletingLastPathComponent())
        fd = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        try require(fd >= 0, "Cannot open lock: \(file.path)")
        if flock(fd, shared ? LOCK_SH : LOCK_EX) != 0 {
            close(fd)
            throw BuildError("Cannot acquire lock \(file.path)")
        }
    }

    deinit { flock(fd, LOCK_UN)
        close(fd)
    }
}

struct StageRecord: Codable {
    let schemaVersion: Int
    let stage: String
    let input: String
    let dependencies: [String: String]
    let products: [String: String]
    let validations: [String]
    let complete: Bool
    func verify(
        _ directory: URL,
        stage expectedStage: String,
        key: String,
        dependencies expectedDependencies: [String: String]
    ) throws -> Bool {
        guard schemaVersion == 1, complete, stage == expectedStage, input == key, dependencies == expectedDependencies,
              !products.isEmpty else { return false }
        return try products == tree(directory, excluding: ["record.json"])
    }
}

struct ManagedStore: Sendable {
    let root: URL
    let diagnostics: BuildDiagnostics?
    init(root: URL, diagnostics: BuildDiagnostics? = nil) throws {
        self.diagnostics = diagnostics
        self.root = root.standardizedFileURL
        try require(root.path == root.standardizedFileURL.path, "Managed root must not contain parent aliases")
        try require(root.standardizedFileURL == root.resolvingSymlinksInPath(), "Managed root must not contain symlinks")
        let initialization = try FileLock(root.deletingLastPathComponent()
            .appendingPathComponent(".mpvbuild-init-\(hash(Data(root.lastPathComponent.utf8))).lock"))
        defer { withExtendedLifetime(initialization) {} }
        try mkdir(root)
        let marker = root.appendingPathComponent(".mpvbuild-owner")
        if !exists(marker) {
            try require(fm.contentsOfDirectory(atPath: root.path).isEmpty, "Refusing to adopt nonempty unmanaged directory")
            try put("MPVBuild native store v1\n", marker)
        }
        try require(String(contentsOf: marker, encoding: .utf8) == "MPVBuild native store v1\n", "Invalid managed directory owner")
    }

    func path(_ relative: String) throws -> URL {
        try contained(root, relative)
    }

    func node(
        stage: String,
        name: String,
        key: String,
        dependencies: [String: String] = [:],
        fresh: Bool = false,
        build: (URL) throws -> [String]
    ) throws -> URL {
        let started = Date()
        var reason = fresh ? "fresh requested" : "no complete record for these inputs"
        let output = try path("\(stage)/\(name)/\(key)")
        let lock = try FileLock(path("locks/\(stage)-\(hash(Data(name.utf8)))-\(key).lock"))
        defer { withExtendedLifetime(lock) {} }
        // Only the owner of this node can reclaim its interrupted staging directories.
        let parent = output.deletingLastPathComponent()
        if exists(parent) {
            for name in try fm.contentsOfDirectory(atPath: parent.path)
                where name.hasPrefix(".\(key).partial-") || name.hasPrefix(".\(key).replaced-")
            {
                try remove(parent.appendingPathComponent(name))
            }
        }
        if !fresh, exists(output.appendingPathComponent("record.json")) {
            do {
                let record = try read(StageRecord.self, output.appendingPathComponent("record.json"))
                if try record.verify(output, stage: stage, key: key, dependencies: dependencies) {
                    diagnostics?.record(
                        stage: stage,
                        name: name,
                        key: key,
                        action: "reuse",
                        reason: "inputs and product digests verified",
                        since: started
                    )
                    print("reuse \(stage)/\(name) \(key.prefix(12))")
                    return output
                }
                reason = "completion inputs or product digests differ"
                print("invalidate \(stage)/\(name): completion inputs or product digests differ")
            } catch { reason = "invalid completion record: \(error)"
                print("invalidate \(stage)/\(name): \(error)")
            }
        }
        print("build \(stage)/\(name) \(key.prefix(12))")
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(key).partial-\(UUID().uuidString)")
        try mkdir(temporary)
        defer { try? remove(temporary) }
        let validations = try build(temporary)
        let products = try tree(temporary)
        try require(!products.isEmpty, "Node \(stage)/\(name) produced nothing")
        try write(
            StageRecord(
                schemaVersion: 1,
                stage: stage,
                input: key,
                dependencies: dependencies,
                products: products,
                validations: validations,
                complete: true
            ),
            temporary.appendingPathComponent("record.json")
        )
        if exists(output) {
            let backup = output.deletingLastPathComponent().appendingPathComponent(".\(key).replaced-\(UUID().uuidString)")
            try fm.moveItem(at: output, to: backup)
            do { try fm.moveItem(at: temporary, to: output) } catch { try fm.moveItem(at: backup, to: output)
                throw error
            }
            try remove(backup)
        } else {
            try fm.moveItem(at: temporary, to: output)
        }
        diagnostics?.record(stage: stage, name: name, key: key, action: "build", reason: reason, since: started)
        return output
    }

    func clean(cache: Bool) throws {
        let marker = root.appendingPathComponent(".mpvbuild-owner")
        try require(root == root.resolvingSymlinksInPath() && exists(marker), "Unsafe clean owner")
        for name in [
            "work",
            "products",
            "candidates",
            "logs",
            "bundles",
            "test-inputs",
            "test-results",
            "audits",
            "thin-products.json",
            "coverage.json"
        ] + (cache ? ["downloads", "extracted", "prepared", "git", "toolchains"] : []) {
            try remove(path(name))
        }
    }
}
