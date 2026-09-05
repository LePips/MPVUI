import Darwin
import Foundation

enum NativeEnvironment { static let fileCreationMask: mode_t = 0o022 }

struct Runner: Sendable {
    let environment: [String: String]
    let logs: URL
    init(developer: String, epoch: Int, logs: URL, path: String? = nil) throws {
        try mkdir(logs)
        self.logs = logs
        environment = [
            "DEVELOPER_DIR": developer,
            "PATH": path ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
            "LC_ALL": "C", "LANG": "C", "TZ": "UTC", "SOURCE_DATE_EPOCH": String(epoch),
            "ZERO_AR_DATE": "1", "COPYFILE_DISABLE": "1", "GIT_PAGER": "cat", "PAGER": "cat",
            "GIT_TERMINAL_PROMPT": "0", "PYTHONHASHSEED": "0", "PYTHONDONTWRITEBYTECODE": "1",
        ]
    }

    func executable(_ name: String) throws -> URL {
        if name.hasPrefix("/") {
            try require(fm.isExecutableFile(atPath: name), "Missing executable: \(name)")
            return URL(fileURLWithPath: name)
        }
        for directory in environment["PATH", default: ""].components(separatedBy: ":") where !directory.isEmpty {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: path.path) {
                return path
            }
        }
        throw BuildError("Missing tool \(name); run doctor --bootstrap")
    }

    @discardableResult
    func run(
        _ name: String,
        _ arguments: [String] = [],
        cwd: URL? = nil,
        env: [String: String] = [:],
        input: Data? = nil,
        output: URL? = nil,
        combined: Bool = false
    ) throws -> String {
        let command = try executable(name)
        let log = logs.appendingPathComponent("\(command.lastPathComponent)-\(UUID().uuidString).log")
        let out = output ?? log.appendingPathExtension("stdout")
        try put(Data(), log)
        try put(Data(), out)
        let stdout = try FileHandle(forWritingTo: out)
        let stderr = try FileHandle(forWritingTo: log)
        defer { try? stdout.close()
            try? stderr.close()
        }
        try write(
            ["executable": command.path, "arguments": arguments.joined(separator: "\n"), "cwd": cwd?.path ?? ""],
            log.appendingPathExtension("command.json")
        )
        let process = Process()
        process.executableURL = command
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment.merging(env) { _, new in new }
        try require(process.environment?["DEVELOPER_DIR"] == environment["DEVELOPER_DIR"], "Child compiler selection differs from doctor")
        process.standardOutput = stdout
        process.standardError = combined ? stdout : stderr
        // File-backed input/output avoid pipe deadlocks with large native-tool output.
        var inputHandle: FileHandle?
        let inputFile = log.appendingPathExtension("stdin")
        if let input {
            try put(input, inputFile)
            inputHandle = try FileHandle(forReadingFrom: inputFile)
            process.standardInput = inputHandle
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        defer { try? inputHandle?.close()
            try? remove(inputFile)
        }
        let started = Date()
        try process.run()
        process.waitUntilExit()
        try stdout.synchronize()
        try stderr.synchronize()
        struct Completion: Encodable { let seconds: Double
            let exitCode: Int32
        }
        try write(
            Completion(seconds: Date().timeIntervalSince(started), exitCode: process.terminationStatus),
            log.appendingPathExtension("result.json")
        )
        if process.terminationStatus != 0 {
            let diagnostic = ((try? String(contentsOf: out, encoding: .utf8)) ?? "") +
                ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            throw BuildError("\(name) failed (\(process.terminationStatus)); log: \(log.path)\n\(diagnostic.suffix(9000))")
        }
        return try output == nil ? String(decoding: Data(contentsOf: out), as: UTF8.self).trimmingCharacters(in: .newlines) : ""
    }

    func apple(_ name: String) throws -> String {
        try run("/usr/bin/xcrun", ["--find", name])
    }

    func sdk(_ name: String) throws -> URL {
        try URL(fileURLWithPath: run("/usr/bin/xcrun", ["--sdk", name, "--show-sdk-path"]))
    }

    func doctor(_ lock: ToolchainLock) throws -> [String: String] {
        let developer = URL(fileURLWithPath: environment["DEVELOPER_DIR"]!)
        let info = try plist(developer.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let version = try plist(developer.deletingLastPathComponent().appendingPathComponent("version.plist"))
        try require(info["CFBundleShortVersionString"] as? String == lock.xcode.version, "Xcode version differs from lock")
        try require(version["ProductBuildVersion"] as? String == lock.xcode.build, "Xcode build differs from lock")
        let swift = try run("/usr/bin/swiftc", ["--version"], combined: true).components(separatedBy: "\n").first ?? ""
        let clang = try run("/usr/bin/clang", ["--version"]).components(separatedBy: "\n").first ?? ""
        try require(swift == lock.xcode.swift && clang == lock.xcode.clang, "Actual compiler identities differ from lock")
        var identities = ["xcode": lock.xcode.build, "swift": swift, "clang": clang]
        let allowed = Set(["meson", "ninja", "pkg-config", "make", "zip", "gitMinimum"])
        try require(Set(lock.tools.keys) == allowed, "Tool lock has missing or unsupported tools")
        for name in lock.tools.keys.sorted() {
            let expected = lock.tools[name]!
            if name == "gitMinimum" {
                let actual = try run("git", ["--version"]).components(separatedBy: " ")[2]
                try require(actual.compare(expected, options: .numeric) != .orderedAscending, "Git \(actual) is older than \(expected)")
                identities["git"] = actual
                continue
            }
            let raw = try run(name, [name == "zip" || name == "nasm" ? "-v" : "--version"])
            let actual = name == "zip" ? raw.components(separatedBy: "\n").first(where: { $0.hasPrefix("This is Zip") }) ?? "" : raw
                .components(separatedBy: "\n")[0]
            try require(
                name == "nasm" ? actual.hasPrefix(expected + " ") : actual == expected,
                "\(name): expected '\(expected)', found '\(actual)'"
            )
            identities[name] = actual
        }
        for (name, expected) in lock.sdks {
            let path = try sdk(name)
            let settings = try JSONSerialization
                .jsonObject(with: Data(contentsOf: path.appendingPathComponent("SDKSettings.json"))) as? [String: Any]
            let system = try plist(path.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist"))
            try require(
                settings?["Version"] as? String == expected.version && system["ProductBuildVersion"] as? String == expected.build,
                "SDK \(name) differs from lock"
            )
            identities["sdk-" + name] = expected.version + ":" + expected.build
        }
        return identities
    }
}

func plist(_ file: URL) throws -> [String: Any] {
    guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), options: [], format: nil) as? [String: Any]
    else { throw BuildError("Expected plist dictionary: \(file.path)") }
    return value
}
