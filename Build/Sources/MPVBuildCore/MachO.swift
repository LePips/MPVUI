import Foundation

struct ObjectMetadata: Codable {
    let member: String
    let architecture: String
    let platform: Int
    let minimumOS: String
}

enum MachO {
    static func objects(_ data: Data, name: String = "binary", inheritedArchitecture: String? = nil) throws -> [ObjectMetadata] {
        try require(data.count >= 8, "Truncated binary \(name)")
        let magic = try data.uint(0)
        if magic == 0xBEBA_FECA || magic == 0xBFBA_FECA {
            let wide = magic == 0xBFBA_FECA
            let count = try Int(data.uint(4, big: true))
            var output: [ObjectMetadata] = []
            try require(count > 0 && count < 100, "Invalid universal binary")
            for index in 0 ..< count {
                let start = 8 + index * (wide ? 32 : 20)
                let cpu = try data.uint(start, big: true)
                let sub = try data.uint(start + 4, big: true)
                let arch = try architecture(cpu, sub)
                let offset = try Int(data.uint(start + 8, bytes: wide ? 8 : 4, big: true))
                let size = try Int(data.uint(start + (wide ? 16 : 12), bytes: wide ? 8 : 4, big: true))
                try require(offset >= 0 && size >= 0 && offset <= data.count - size, "Truncated fat slice")
                output += try objects(data.subdata(in: offset ..< offset + size), name: name, inheritedArchitecture: arch)
            }
            return output
        }
        if data.prefix(8) == Data("!<arch>\n".utf8) {
            var offset = 8
            var output: [ObjectMetadata] = []
            while offset < data.count {
                try require(offset <= data.count - 60, "Truncated archive header")
                let header = String(decoding: data.subdata(in: offset ..< offset + 60), as: UTF8.self)
                try require(header.hasSuffix("`\n"), "Invalid archive header")
                let raw = String(header.prefix(16)).trimmingCharacters(in: .whitespaces)
                guard let size = Int(String(header.dropFirst(48).prefix(10)).trimmingCharacters(in: .whitespaces))
                else { throw BuildError("Invalid archive member size") }
                var start = offset + 60
                try require(size >= 0 && start <= data.count - size, "Truncated archive member")
                var member = raw
                if raw.hasPrefix("#1/") {
                    guard let length = Int(raw.dropFirst(3)), length <= size else { throw BuildError("Invalid extended archive name") }
                    member = String(decoding: data.subdata(in: start ..< start + length), as: UTF8.self)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                    start += length
                }
                if !member.hasPrefix("__.SYMDEF") && !["/", "//", "/SYM64/"].contains(member) {
                    output += try objects(
                        data.subdata(in: start ..< offset + 60 + size),
                        name: member,
                        inheritedArchitecture: inheritedArchitecture
                    )
                }
                offset += 60 + size + size % 2
            }
            try require(!output.isEmpty, "Empty archive \(name)")
            return output
        }
        try require(magic == 0xFEED_FACF || magic == 0xFEED_FACE, "Unsupported non-Mach-O member \(name)")
        let arch = try architecture(data.uint(4), data.uint(8))
        if let inheritedArchitecture {
            try require(arch == inheritedArchitecture, "Fat architecture disagrees with \(name)")
        }
        let count = try Int(data.uint(16))
        let size = try Int(data.uint(20))
        var offset = magic == 0xFEED_FACF ? 32 : 28
        let limit = offset + size
        try require(limit <= data.count && count < 10000, "Invalid load command table")
        var platform = 0
        var minimum = "0.0"
        for _ in 0 ..< count {
            let command = try data.uint(offset)
            let length = try Int(data.uint(offset + 4))
            try require(length >= 8 && offset <= limit - length, "Invalid load command length")
            if command == 0x32 {
                try require(length >= 24, "Truncated LC_BUILD_VERSION")
                platform = try Int(data.uint(offset + 8))
                minimum = try version(data.uint(offset + 12))
            } else if [0x24, 0x25, 0x2F, 0x30].contains(command) {
                try require(length >= 16, "Truncated deployment load command")
                platform = command == 0x24 ? 1 : command == 0x25 ? (arch == "x86_64" ? 7 : 2) : command == 0x2F ?
                    (arch == "x86_64" ? 8 : 3) : 4
                minimum = try version(data.uint(offset + 8))
            }
            offset += length
        }
        try require(offset == limit, "Load command table length mismatch")
        return [ObjectMetadata(member: name, architecture: arch, platform: platform, minimumOS: minimum)]
    }

    static func architecture(_ cpu: UInt64, _ subtype: UInt64) throws -> String {
        if cpu == 0x0100_000C {
            return subtype & 0xFFFFFF == 2 ? "arm64e" : "arm64"
        }
        if cpu == 0x0100_0007 {
            return "x86_64"
        }
        throw BuildError("Unsupported CPU \(cpu)/\(subtype)")
    }

    static func version(_ value: UInt64) -> String {
        "\(value >> 16).\((value >> 8) & 255).\(value & 255)"
    }

    static func validate(_ binary: URL, slice: Slice, arch: String, allowOtherArchitectures: Bool = false) throws -> [ObjectMetadata] {
        try autoreleasepool {
            let all = try objects(Data(contentsOf: binary, options: .mappedIfSafe))
            let selected = all.filter { $0.architecture == arch }
            try require(!selected.isEmpty, "Missing \(arch) in \(binary.path)")
            if !allowOtherArchitectures {
                try require(all.count == selected.count, "Unexpected architecture in thin product \(binary.path)")
            }
            for object in selected {
                try require(
                    object.platform == slice.machOPlatform,
                    "\(binary.lastPathComponent)(\(object.member)): platform \(object.platform), expected \(slice.machOPlatform) for \(slice.id)"
                )
                try require(
                    object.minimumOS
                        .compare(
                            slice.minimumOS + (slice.minimumOS.components(separatedBy: ".").count == 2 ? ".0" : ""),
                            options: .numeric
                        ) != .orderedDescending,
                    "\(binary.lastPathComponent)(\(object.member)): requires \(object.minimumOS), above \(slice.minimumOS)"
                )
            }
            return selected
        }
    }
}
