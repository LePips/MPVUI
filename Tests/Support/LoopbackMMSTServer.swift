import Foundation
import Network

/// Performs the Windows Media TCP handshake and relays an authored ASF fixture.
final class LoopbackMMSTServer: @unchecked Sendable {

    private static let commands: [(request: UInt16, reply: UInt16)] = [
        (0x01, 0x01), // Connect
        (0x18, 0x15), // Timing
        (0x02, 0x02), // Select TCP
        (0x05, 0x06), // Describe the requested file
        (0x15, 0x11), // Request the ASF header
        (0x33, 0x21), // Select streams
        (0x07, 0x05), // Start playback
    ]
    private static let commandMarker: UInt32 = 0xB00B_FACE
    private static let filename = "fixture.asf"
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MPVUI.test.mmst")
    private let header: Data
    private let packets: [Data]
    private var client: NWConnection?

    init(wmsp: Data) throws {
        var chunks = [Data]()
        var offset = 0
        while offset + 12 <= wmsp.count {
            let kind = Self.read(UInt16.self, from: wmsp, at: offset)
            if kind == 0x4524 {
                break
            }
            let length = Int(Self.read(UInt16.self, from: wmsp, at: offset + 2))
            let end = offset + 4 + length
            guard kind == (chunks.isEmpty ? 0x4824 : 0x4424), length >= 8, end <= wmsp.count else {
                throw URLError(.cannotDecodeContentData)
            }

            chunks.append(wmsp[(offset + 12) ..< end])
            offset = end
        }
        guard chunks.count > 1, let header = chunks.first else { throw URLError(.cannotDecodeContentData) }

        self.header = header
        packets = Array(chunks.dropFirst())
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    private static func appendPacket(_ packet: Data, id: UInt8, flags: UInt8, sequence: UInt32, to buffer: inout Data) {
        append(sequence, to: &buffer)
        buffer.append(contentsOf: [id, flags])
        append(UInt16(packet.count + 8), to: &buffer)
        buffer.append(packet)
    }

    private static func append(_ value: some FixedWidthInteger, to buffer: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { buffer.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ type: T.Type, from data: Data, at offset: Int) -> T {
        T(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) })
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    guard let port = listener?.port,
                          let source = URL(string: "mmst://127.0.0.1:\(port.rawValue)/\(Self.filename)")
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
                guard let self, self.client == nil else {
                    connection.cancel()
                    return
                }

                self.client = connection
                connection.start(queue: self.queue)
                self.receiveCommand(on: connection, step: 0)
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

    private func receiveCommand(on connection: NWConnection, step: Int, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] bytes, _, ended, error in
            guard let self, error == nil, !ended else {
                connection.cancel()
                return
            }

            let command = buffered + (bytes ?? Data())
            if command.count < 12 {
                self.receiveCommand(on: connection, step: step, buffered: command)
                return
            }
            let length = Int(Self.read(UInt32.self, from: command, at: 8)) + 16
            guard Self.read(UInt32.self, from: command, at: 4) == Self.commandMarker, (40 ... 4096).contains(length) else {
                connection.cancel()
                return
            }

            if command.count < length {
                self.receiveCommand(on: connection, step: step, buffered: command)
                return
            }
            self.reply(to: command, on: connection, step: step)
        }
    }

    private func reply(to command: Data, on connection: NWConnection, step: Int) {
        let (request, response) = Self.commands[step]
        guard Self.read(UInt16.self, from: command, at: 36) == request else {
            connection.cancel()
            return
        }

        if request == 0x05,
           command.count < 56 || String(data: command.dropFirst(56), encoding: .utf16LittleEndian)?
               .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) != Self.filename
        {
            connection.cancel()
            return
        }
        if request == 0x33, command.count < 44 || Self.read(UInt32.self, from: command, at: 40) != 2 {
            connection.cancel()
            return
        }
        var reply = Data()
        for word: UInt32 in [1, Self.commandMarker, 32, 0x2053_4D4D, 4, UInt32(step), 0, 0, 2, 0x40000 | UInt32(response), 0, 0] {
            Self.append(word, to: &reply)
        }
        if request == 0x15 {
            Self.appendPacket(header, id: 2, flags: 8, sequence: 0, to: &reply)
        }
        if request == 0x07 {
            guard command.count >= 72, let packetID = UInt8(exactly: Self.read(UInt32.self, from: command, at: 68)) else {
                connection.cancel()
                return
            }

            for (index, packet) in packets.enumerated() {
                Self.appendPacket(packet, id: packetID, flags: 0, sequence: UInt32(index + 1), to: &reply)
            }
        }
        let last = step + 1 == Self.commands.count
        connection.send(
            content: reply,
            contentContext: last ? .finalMessage : .defaultMessage,
            completion: .contentProcessed { [weak self] error in
                if error != nil {
                    connection.cancel()
                } else if !last {
                    self?.receiveCommand(on: connection, step: step + 1)
                }
            }
        )
    }
}
