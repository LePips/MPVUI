#if os(macOS)
import Darwin
import Foundation
import Testing

/// Feeds an authored transport stream to one local OpenSSL DTLS connection.
@MainActor
final class LoopbackDTLSServer {

    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dtls-\(UUID())")
    private let server = Process()
    private let input = Pipe()
    private let state = Pipe()
    private var sender: Task<Void, Error>?

    func start(transport: Data) async throws -> URL {
        let port = try LoopbackTransport.availablePort()
        let certificate = try TestPaths.testMedia("tls-loopback.pem")
        let identity = try TestPaths.testMedia("tls-loopback.p12")
        let key = directory.appendingPathComponent("key.pem")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        let decode = Process()
        configure(decode, arguments: [
            "pkcs12",
            "-in",
            identity.path,
            "-passin",
            "pass:loopback-only",
            "-nocerts",
            "-nodes",
            "-out",
            key.path,
        ])
        try decode.run()
        decode.waitUntilExit()
        try #require(decode.terminationStatus == 0)

        configure(server, arguments: [
            "s_server",
            "-quiet",
            "-state",
            "-dtls1_2",
            "-accept",
            "127.0.0.1:\(port)",
            "-cert",
            certificate.path,
            "-key",
            key.path,
            "-mtu",
            "1450",
        ])
        server.standardInput = input
        server.standardOutput = FileHandle.nullDevice
        server.standardError = state
        try server.run()
        try await eventually("OpenSSL binds its DTLS socket") {
            try #require(server.isRunning)
            return try LoopbackTransport.isUDPPortBound(port)
        }

        let writer = input.fileHandleForWriting
        let reader = state.fileHandleForReading
        try #require(Darwin.fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) != -1)
        sender = Task.detached {
            for try await line in reader.bytes.lines {
                if line.contains("write finished") {
                    break
                }
            }
            try Task.checkCancellation()
            var packets = MPEGTransportPackets(transport)
            while !Task.isCancelled {
                try writer.write(contentsOf: packets.next(usesRTP: false))
                try await Task.sleep(for: .microseconds(MPEGTransportPackets.intervalMicroseconds))
            }
        }
        return try #require(URL(string: "dtls://127.0.0.1:\(port)"))
    }

    func stop() {
        sender?.cancel()
        if server.isRunning {
            server.terminate()
            server.waitUntilExit()
        }
        try? input.fileHandleForWriting.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func configure(_ process: Process, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["openssl"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = environment
    }
}
#endif
