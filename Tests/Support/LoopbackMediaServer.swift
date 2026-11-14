import Foundation
@testable import MPVUI
import Network

/// Serves the exact fixture bytes on loopback for incoming playback tests.
final class LoopbackMediaServer: @unchecked Sendable {

    struct ResponseCutoff {

        let offset: Int
        let resume: Bool
    }

    struct ResourceVersion {

        let afterRequests: Set<String>
        let bytes: Data?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "MPVUI.test.http")
    private let requestedNames = NSLock()
    private let scheme: String
    private let authorization: String?
    private let redirects: [String: String]
    private let cutoffs: [String: ResponseCutoff]
    private let versions: [String: [ResourceVersion]]
    private let rawStream: Data?
    private let gopherSelector: String?
    private let socketPath: String?
    private var resources: [String: Data]
    private var heldFilename: String?
    private var heldResponses: [ObjectIdentifier: Data] = [:]
    private var requests: Set<String> = []
    private var rangedRequests: [String: Set<Int>] = [:]
    private var requestPragmas: [String: Set<String>] = [:]
    private var failureResponses: Set<Int> = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(
        resources: [String: Data] = [:],
        hold: String? = nil,
        identity: sec_identity_t? = nil,
        authorization: String? = nil,
        redirects: [String: String] = [:],
        cutoffs: [String: ResponseCutoff] = [:],
        versions: [String: [ResourceVersion]] = [:],
        rawStream: Data? = nil,
        gopherSelector: String? = nil,
        socketPath: String? = nil
    ) throws {
        self.resources = resources
        self.authorization = authorization
        self.redirects = redirects
        self.cutoffs = cutoffs
        self.versions = versions
        self.rawStream = rawStream
        self.gopherSelector = gopherSelector
        self.socketPath = socketPath
        heldFilename = hold
        let parameters: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            parameters = NWParameters(tls: tls)
            scheme = gopherSelector != nil ? "gophers" : (rawStream == nil ? "https" : "tls")
        } else {
            parameters = .tcp
            scheme = gopherSelector != nil ? "gopher" : (rawStream == nil ? "http" : "tcp")
        }
        parameters.requiredLocalEndpoint = socketPath.map(NWEndpoint.unix(path:))
            ?? .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak listener, scheme, socketPath] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    let source = if let socketPath {
                        "ffmpeg://unix:\(socketPath)"
                    } else if let port = listener?.port {
                        "\(scheme)://127.0.0.1:\(port.rawValue)/"
                    } else {
                        ""
                    }
                    guard !source.isEmpty, let url = URL(string: source) else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                        return
                    }

                    continuation.resume(returning: url)

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

                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue)
                if let stream = self.rawStream, self.gopherSelector == nil {
                    self.send(stream, on: connection)
                } else {
                    self.receive(on: connection)
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
            heldResponses.removeAll()
        }
    }

    func requested(_ filename: String) -> Bool {
        requestedNames.withLock { requests.contains(filename) }
    }

    func requestedNonzeroRange(_ filename: String) -> Bool {
        requestedNames.withLock { rangedRequests[filename]?.isEmpty == false }
    }

    func requestedRange(_ filename: String, startingAt offset: Int) -> Bool {
        requestedNames.withLock { rangedRequests[filename]?.contains(offset) == true }
    }

    func pragmas(for filename: String) -> Set<String> {
        requestedNames.withLock { requestPragmas[filename, default: []] }
    }

    func respondedWithError(_ status: Int) -> Bool {
        requestedNames.withLock { failureResponses.contains(status) }
    }

    func replace(_ filename: String, with bytes: Data) {
        queue.async { [self] in resources[filename] = bytes }
    }

    func releaseHeldResponse() {
        queue.async { [self] in
            heldFilename = nil
            for (id, data) in heldResponses {
                if let connection = connections[id] {
                    send(data, on: connection)
                }
            }
            heldResponses.removeAll()
        }
    }

    private func receive(on connection: NWConnection, header: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }

            let collected = header + (data ?? Data())
            let delimiter = self.gopherSelector == nil ? "\r\n\r\n" : "\r\n"
            if collected.range(of: Data(delimiter.utf8)) != nil {
                let (filename, data) = self.response(to: collected)
                if let filename, filename == self.heldFilename {
                    self.heldResponses[ObjectIdentifier(connection)] = data
                } else {
                    self.send(data, on: connection)
                }
            } else if complete || error != nil || collected.count >= 8192 {
                self.close(connection)
            } else {
                self.receive(on: connection, header: collected)
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private func response(to header: Data) -> (String?, Data) {
        if let gopherSelector, let rawStream {
            guard header == Data("/\(gopherSelector)\r\n".utf8) else { return (nil, Data()) }

            _ = requestedNames.withLock { requests.insert(gopherSelector) }
            return (nil, rawStream)
        }

        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        if request.count == 3,
           request[0] == "CONNECT",
           request[2] == "HTTP/1.1",
           let transport = resources[String(request[1])]
        {
            _ = requestedNames.withLock { requests.insert(String(request[1])) }
            return (nil, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8) + transport)
        }

        guard request.count == 3,
              ["GET", "HEAD"].contains(request[0]),
              let path = request[1].split(separator: "?").first,
              path.hasPrefix("/")
        else { return failure(404, "Not Found") }

        if let authorization {
            let value = lines.first { $0.lowercased().hasPrefix("authorization:") }?
                .dropFirst("authorization:".count)
                .trimmingCharacters(in: .whitespaces)
            if value != authorization {
                return failure(401, "Unauthorized", headers: "WWW-Authenticate: Basic realm=\"Playback fixture\"\r\n")
            }
        }

        let name = String(path.dropFirst())
        if let target = redirects[name] {
            _ = requestedNames.withLock { requests.insert(name) }
            let response = "HTTP/1.1 302 Found\r\nLocation: /\(target)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            return (name, Data(response.utf8))
        }
        let version = requestedNames.withLock {
            versions[name]?.last { $0.afterRequests.isSubset(of: requests) }
        }
        if let version, version.bytes == nil {
            return failure(410, "Gone")
        }

        guard let asset = version?.bytes ?? resources[name] else { return failure(404, "Not Found") }

        let pragmas = lines.compactMap { line in
            line.lowercased().hasPrefix("pragma:") ? line.dropFirst(7).trimmingCharacters(in: .whitespaces) : nil
        }
        requestedNames.withLock {
            requests.insert(name)
            if !pragmas.isEmpty {
                requestPragmas[name, default: []].formUnion(pragmas)
            }
        }
        let contentType = switch URL(fileURLWithPath: name).pathExtension {
        case "m3u8": "application/vnd.apple.mpegurl"
        case "mpd": "application/dash+xml"
        case "ts": "video/mp2t"
        case "wmsp": "application/x-mms-framed"
        default: "video/mp4"
        }
        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
        let range = rangeHeader.flatMap {
            MPVHTTPMediaServer.byteRange($0.dropFirst(6).trimmingCharacters(in: .whitespaces), count: asset.count)
        }
        let status: String
        let fields: String
        let body: Data
        if let range {
            if range.lowerBound > 0 {
                _ = requestedNames.withLock { rangedRequests[name, default: []].insert(range.lowerBound) }
            }
            status = "206 Partial Content"
            fields = "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(asset.count)\r\n"
            body = asset[range]
        } else if rangeHeader != nil {
            status = "416 Range Not Satisfiable"
            fields = "Content-Range: bytes */\(asset.count)\r\n"
            body = Data()
        } else {
            status = "200 OK"
            fields = ""
            body = asset
        }
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nAccept-Ranges: bytes\r\n"
            + "Content-Length: \(body.count)\r\n\(fields)Connection: close\r\n\r\n"
        if request[0] == "HEAD" {
            return (name, Data(response.utf8))
        }

        // Keep the advertised length so the client observes a premature end of the response.
        let start = range?.lowerBound ?? 0
        let deliveredBytes: Int = if let cutoff = cutoffs[name], !cutoff.resume || start < cutoff.offset {
            max(0, cutoff.offset - start)
        } else {
            body.count
        }
        return (name, Data(response.utf8) + body.prefix(deliveredBytes))
    }

    private func failure(_ status: Int, _ reason: String, headers: String = "") -> (String?, Data) {
        _ = requestedNames.withLock { failureResponses.insert(status) }
        let response = "HTTP/1.1 \(status) \(reason)\r\n\(headers)Content-Length: 0\r\nConnection: close\r\n\r\n"
        return (nil, Data(response.utf8))
    }
}
