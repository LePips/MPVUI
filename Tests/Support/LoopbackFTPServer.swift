import Foundation
import Network

/// Supplies one authenticated file over passive FTP for playback tests.
final class LoopbackFTPServer: @unchecked Sendable {

    private final class Client: @unchecked Sendable {

        let control: NWConnection
        var passive: NWListener?
        var data: NWConnection?
        var received = Data()
        var userAccepted = false
        var authenticated = false
        var offset = 0
        var transferRequested = false

        init(control: NWConnection) {
            self.control = control
        }
    }

    private let queue = DispatchQueue(label: "MPVUI.test.ftp")
    private let restartLock = NSLock()
    private let listener: NWListener
    private let media: Data
    private var clients: [ObjectIdentifier: Client] = [:]
    private var didRestart = false

    var restartedAtNonzeroOffset: Bool {
        restartLock.withLock { didRestart }
    }

    init(media: Data) throws {
        self.media = media
        listener = try Self.localListener()
    }

    private static func localListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        return try NWListener(using: parameters)
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    guard let port = listener?.port else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                        return
                    }

                    continuation.resume(returning: "ftp://fixture:loopback@127.0.0.1:\(port.rawValue)/video.mp4")

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

                let client = Client(control: connection)
                self.clients[ObjectIdentifier(connection)] = client
                connection.start(queue: self.queue)
                self.reply("220 Playback fixture ready", to: client)
                self.receive(from: client)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            let active = Array(clients.values)
            for client in active {
                close(client)
            }
        }
    }

    private func receive(from client: Client) {
        client.control.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak client] data, _, complete, error in
            guard let self, let client else { return }

            client.received.append(data ?? Data())
            let separator = Data("\r\n".utf8)
            while let boundary = client.received.range(of: separator) {
                let line = String(decoding: client.received[..<boundary.lowerBound], as: UTF8.self)
                client.received.removeSubrange(..<boundary.upperBound)
                self.respond(to: line, client: client)
            }
            if complete || error != nil || client.received.count > 4096 {
                self.close(client)
            } else if self.clients[ObjectIdentifier(client.control)] != nil {
                self.receive(from: client)
            }
        }
    }

    private func respond(to command: String, client: Client) {
        if command == "USER fixture" {
            client.userAccepted = true
            reply("331 Password required", to: client)
            return
        }
        if command == "PASS loopback", client.userAccepted {
            client.authenticated = true
            reply("230 Logged in", to: client)
            return
        }
        guard client.authenticated else {
            reply("530 Login required", to: client)
            return
        }

        switch command {
        case "TYPE I":
            reply("200 Binary", to: client)

        case "FEAT":
            reply("211 End", to: client)

        case "PWD":
            reply("257 \"/\"", to: client)

        case "SIZE /video.mp4":
            reply("213 \(media.count)", to: client)

        case "EPSV":
            startPassiveListener(for: client)

        case "RETR /video.mp4":
            guard client.passive != nil else {
                reply("425 Open a passive data connection", to: client)
                return
            }

            client.transferRequested = true
            reply("150 Sending fixture", to: client)
            sendMediaIfReady(to: client)

        case "ABOR":
            stopTransfer(for: client)
            reply("226 Transfer aborted", to: client)

        case "QUIT":
            close(client)

        default:
            if command.hasPrefix("REST "), let offset = Int(command.dropFirst(5)), (0 ... media.count).contains(offset) {
                client.offset = offset
                if offset > 0 {
                    restartLock.withLock { didRestart = true }
                }
                reply("350 Restart accepted", to: client)
            } else {
                reply("502 Unsupported fixture command", to: client)
            }
        }
    }

    private func startPassiveListener(for client: Client) {
        stopTransfer(for: client)
        guard let passive = try? Self.localListener() else {
            reply("425 Passive connection unavailable", to: client)
            return
        }

        client.passive = passive
        passive.stateUpdateHandler = { [weak self, weak client, weak passive] state in
            guard let self, let client, let passive, client.passive === passive else { return }

            if case .ready = state, let port = passive.port {
                self.reply("229 Entering Extended Passive Mode (|||\(port.rawValue)|)", to: client)
            } else if case .failed = state {
                self.reply("425 Passive connection unavailable", to: client)
            }
        }
        passive.newConnectionHandler = { [weak self, weak client, weak passive] connection in
            guard let self, let client, let passive, client.passive === passive, client.data == nil else {
                connection.cancel()
                return
            }

            client.data = connection
            connection.start(queue: self.queue)
            self.sendMediaIfReady(to: client)
        }
        passive.start(queue: queue)
    }

    private func sendMediaIfReady(to client: Client) {
        guard client.transferRequested, let connection = client.data else { return }

        client.transferRequested = false
        let body = media.subdata(in: client.offset ..< media.count)
        client.offset = 0
        connection.send(
            content: body,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self, weak client, weak connection] error in
                guard let self, let client, let connection, client.data === connection else { return }

                self.stopTransfer(for: client)
                if error == nil {
                    self.reply("226 Transfer complete", to: client)
                }
            }
        )
    }

    private func reply(_ line: String, to client: Client) {
        client.control.send(content: Data("\(line)\r\n".utf8), completion: .idempotent)
    }

    private func stopTransfer(for client: Client) {
        client.data?.cancel()
        client.data = nil
        client.passive?.cancel()
        client.passive = nil
        client.transferRequested = false
    }

    private func close(_ client: Client) {
        clients.removeValue(forKey: ObjectIdentifier(client.control))
        stopTransfer(for: client)
        client.control.cancel()
    }
}
