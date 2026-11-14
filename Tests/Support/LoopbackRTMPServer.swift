import Foundation
import Network
import Testing

/// Serves the authored RTMP command replies and media on one local connection.
final class LoopbackRTMPServer: @unchecked Sendable {

    private struct Dialogue {

        let replies: [Data]
        private var received = Data()
        private var handshakeSent = false
        private var handshakeComplete = false
        private var step = 0

        init(replies: [Data]) {
            self.replies = replies
        }

        mutating func receive(_ bytes: Data) -> Data? {
            guard step < replies.count else { return Data() }

            received.append(bytes)
            guard received.count <= 8192 else { return nil }

            let handshakeBytes = LoopbackRTMPServer.handshakeBytes
            let handshake = Data(count: handshakeBytes)
            if !handshakeSent {
                guard received.count >= handshakeBytes + 1 else { return Data() }
                guard received.first == 3 else { return nil }

                let echo = received.dropFirst().prefix(handshakeBytes)
                received.removeFirst(handshakeBytes + 1)
                handshakeSent = true
                return Data([3]) + handshake + echo
            }

            if !handshakeComplete {
                guard received.count >= handshakeBytes else { return Data() }
                guard received.prefix(handshakeBytes) == handshake else { return nil }

                received.removeFirst(handshakeBytes)
                handshakeComplete = true
            }

            let command = LoopbackRTMPServer.commands[step]
            let last = step == replies.count - 1
            guard let match = received.range(of: command),
                  !last || received[match.upperBound...].range(of: LoopbackRTMPServer.amfString("fixture")) != nil
            else { return Data() }

            defer {
                step += 1
                received.removeAll(keepingCapacity: true)
            }
            return replies[step]
        }
    }

    private static let handshakeBytes = 1536
    private static let commands = [
        amfString("connect") + amfNumber(1),
        amfString("createStream") + amfNumber(2),
        amfString("play"),
    ]
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MPVUI.test.rtmp")
    private let scheme: String
    private let tunneled: Bool
    private let replies: [Data]
    private var client: NWConnection?
    private var dialogue: Dialogue?
    private var tunnelSequence: Int?

    init(recording: Data, identity: sec_identity_t? = nil, tunneled: Bool = false) throws {
        var replies = [Data]()
        var offset = 0
        for _ in Self.commands {
            guard offset + 4 <= recording.count else { throw URLError(.cannotDecodeContentData) }

            let length = recording[offset ..< offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard length > 0, length <= recording.count - offset else { throw URLError(.cannotDecodeContentData) }

            replies.append(recording[offset ..< offset + length])
            offset += length
        }
        guard offset == recording.count else { throw URLError(.cannotDecodeContentData) }

        self.replies = replies
        self.tunneled = tunneled
        scheme = "rtmp" + (tunneled ? "t" : "") + (identity == nil ? "" : "s")

        let parameters: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    private static func amfString(_ value: String) -> Data {
        Data([2, 0, UInt8(value.utf8.count)]) + Data(value.utf8)
    }

    private static func amfNumber(_ value: Double) -> Data {
        Data([0]) + withUnsafeBytes(of: value.bitPattern.bigEndian) { Data($0) }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak listener, scheme] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    guard let port = listener?.port,
                          let source = URL(string: "\(scheme)://127.0.0.1:\(port.rawValue)/app/fixture")
                    else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                        return
                    }

                    continuation.resume(returning: source)

                case let .failed(error):
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)

                case .cancelled:
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())

                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }

                self.client?.cancel()
                self.client = connection
                self.dialogue = Dialogue(replies: self.replies)
                self.tunnelSequence = nil
                connection.start(queue: self.queue)
                if self.tunneled {
                    self.receiveTunnelRequest(connection)
                } else {
                    self.receiveRTMP(connection)
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            client?.cancel()
            client = nil
        }
    }

    private func receiveRTMP(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, ended, error in
            guard let self,
                  self.client === connection,
                  let data,
                  error == nil,
                  !ended,
                  let reply = self.dialogue?.receive(data)
            else {
                connection.cancel()
                return
            }

            if reply.isEmpty {
                self.receiveRTMP(connection)
            } else {
                connection.send(content: reply, completion: .contentProcessed { error in
                    guard error == nil else {
                        connection.cancel()
                        return
                    }

                    self.receiveRTMP(connection)
                })
            }
        }
    }

    private func receiveTunnelRequest(_ connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, ended, error in
            guard let self, self.client === connection, let data, error == nil, !ended else {
                connection.cancel()
                return
            }

            let bytes = buffered + data
            guard bytes.count <= 16384 else {
                connection.cancel()
                return
            }
            guard let delimiter = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                self.receiveTunnelRequest(connection, buffered: bytes)
                return
            }

            let lines = String(decoding: bytes[..<delimiter.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let request = lines[0].split(separator: " ")
            guard request.count == 3,
                  request[0] == "POST",
                  let length = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let count = Int(length.dropFirst(15).trimmingCharacters(in: .whitespaces)),
                  (0 ... 8192).contains(count)
            else {
                connection.cancel()
                return
            }

            let body = bytes[delimiter.upperBound...]
            guard body.count >= count else {
                self.receiveTunnelRequest(connection, buffered: bytes)
                return
            }
            guard body.count == count, let reply = self.tunnelReply(request[1], body: Data(body)) else {
                connection.cancel()
                return
            }

            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/x-fcs\r\nContent-Length: \(reply.count)\r\n\r\n"
            connection.send(content: Data(header.utf8) + reply, completion: .contentProcessed { error in
                if error == nil {
                    self.receiveTunnelRequest(connection)
                } else {
                    connection.cancel()
                }
            })
        }
    }

    private func tunnelReply(_ path: Substring, body: Data) -> Data? {
        if path == "/open/1", tunnelSequence == nil, body == Data([0]) {
            tunnelSequence = 0
            return Data("fixture\n".utf8)
        }

        let fields = path.split(separator: "/")
        guard fields.count == 3, fields[1] == "fixture", let sequence = Int(fields[2]), sequence == tunnelSequence else {
            return nil
        }

        tunnelSequence = sequence + 1
        switch fields[0] {
        case "send":
            guard let reply = dialogue?.receive(body) else { return nil }

            return Data([0]) + reply

        case "idle": return body == Data([0]) ? Data([0]) : nil

        case "close":
            tunnelSequence = nil
            return body == Data([0]) ? Data([0]) : nil

        default: return nil
        }
    }
}

#if os(macOS)
/// Starts the loopback fixture for both encrypted RTMP routes.
@MainActor
final class LoopbackEncryptedRTMPServer {

    private let process = Process()
    private var port: UInt16?

    func start(tunneled: Bool) async throws -> URL {
        let script = TestPaths.repositoryRoot.appendingPathComponent("Build/Tests/serve_encrypted_rtmp.py")
        let recording = try TestPaths.testMedia("codecs-rtmp-replies.bin")
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, recording.path] + (tunneled ? ["--tunneled"] : [])
        process.standardOutput = output
        try process.run()

        let reader = Task {
            for try await line in output.fileHandleForReading.bytes.lines {
                self.port = UInt16(line)
                break
            }
        }
        defer { reader.cancel() }
        try await eventually("Encrypted RTMP fixture binds its loopback socket") {
            try #require(process.isRunning)
            return port != nil
        }
        let port = try #require(self.port)
        let scheme = tunneled ? "rtmpte" : "rtmpe"
        return try #require(URL(string: "\(scheme)://127.0.0.1:\(port)/app/fixture"))
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}
#endif
