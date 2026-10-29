import Darwin
import Foundation
import MPVCore
import Network

/// Serves one packaging session's playlists and segments under a random URL token.
/// Uses a LAN address by default so AVPlayer and the receiver can request the same URL.
final class MPVHTTPMediaServer: @unchecked Sendable {

    struct ServerError {

        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    private let directory: URL
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "com.lepips.MPVUI.media-server", qos: .utility)
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var isStopped = false

    init(directory: URL) {
        self.directory = directory
    }

    deinit {
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
    }

    static func response(to request: Data, directory: URL, token: String) -> Data {
        let parts = responseParts(to: request, directory: directory, token: token)
        return parts.header + parts.body
    }

    static func byteRange(_ value: String, count: Int) -> Range<Int>? {
        guard count > 0, value.hasPrefix("bytes=") else { return nil }

        let bounds = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }

        if bounds[0].isEmpty {
            guard let suffix = Int(bounds[1]), suffix > 0 else { return nil }

            return max(0, count - suffix) ..< count
        }

        guard let start = Int(bounds[0]), start >= 0, start < count else { return nil }

        if bounds[1].isEmpty {
            return start ..< count
        }

        guard let end = Int(bounds[1]), end >= start else { return nil }

        return start ..< (min(end, count - 1) + 1)
    }

    static func localAddress() throws -> String {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { throw ServerError("Cannot inspect the local network.") }

        defer { freeifaddrs(addresses) }

        var cursor = addresses
        var ipv6: String?

        while let interface = cursor?.pointee {
            cursor = interface.ifa_next

            guard String(cString: interface.ifa_name).hasPrefix("en"),
                  interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  let address = interface.ifa_addr else { continue }

            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) ==
                0 else { continue }

            let value = String(decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

            if family == AF_INET {
                return value
            }

            if !value.hasPrefix("fe80:") {
                ipv6 = value
            }
        }

        if let ipv6 {
            return ipv6
        }

        throw ServerError("Connect to Wi-Fi or Ethernet so the AirPlay receiver can reach the converted stream.")
    }

    private static func responseParts(to request: Data, directory: URL, token: String) -> (header: Data, body: Data) {
        func response(
            _ status: String,
            headers: [String: String] = [:],
            body: Data = Data(),
            head: Bool = false
        ) -> (header: Data, body: Data) {
            var fields = headers
            fields["Connection"] = "close"
            fields["Content-Length"] = fields["Content-Length"] ?? String(body.count)

            let header = "HTTP/1.1 \(status)\r\n" + fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"

            return (Data(header.utf8), head ? Data() : body)
        }

        guard let text = String(data: request, encoding: .utf8) else { return response("400 Bad Request") }

        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")

        guard first.count == 3, ["GET", "HEAD"].contains(first[0]) else {
            return response("405 Method Not Allowed", headers: ["Allow": "GET, HEAD"])
        }

        let head = first[0] == "HEAD"
        let path = String(first[1]).components(separatedBy: "?")[0]
        let prefix = "/\(token)/"
        guard path.hasPrefix(prefix) else { return response("404 Not Found", head: head) }

        let filename = String(path.dropFirst(prefix.count))

        guard ["stream.m3u8", "media.m3u8", "init.mp4"].contains(filename) || filename.range(
            of: #"^(stream[0-9]+\.ts|media[0-9]+\.m4s)$"#,
            options: .regularExpression
        ) != nil else {
            return response("404 Not Found", head: head)
        }

        let file = directory.appendingPathComponent(filename)

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size <= 512 * 1024 * 1024,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return response("404 Not Found", head: head) }

        var headers = [
            "Content-Type": filename.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : filename
                .hasSuffix("ts") ? "video/mp2t" : "video/mp4",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ]

        let ranges = lines.dropFirst().filter { $0.lowercased().hasPrefix("range:") }

        if !ranges.isEmpty {
            guard ranges.count == 1,
                  let range = byteRange(String(ranges[0].dropFirst(6)).trimmingCharacters(in: .whitespaces), count: data.count)
            else {
                headers["Content-Range"] = "bytes */\(data.count)"
                return response("416 Range Not Satisfiable", headers: headers, head: head)
            }

            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
            return response("206 Partial Content", headers: headers, body: data[range], head: head)
        }

        return response("200 OK", headers: headers, body: data, head: head)
    }

    func start(advertisedHost: String? = nil) async throws -> URL {
        let host = try advertisedHost ?? Self.localAddress()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !isStopped, listener == nil else { continuation.resume(throwing: CancellationError())
                        return
                    }

                    do {
                        let listener = try NWListener(using: .tcp, on: .any)
                        self.listener = listener
                        self.startContinuation = continuation

                        listener.stateUpdateHandler = { [weak self, weak listener] state in
                            guard let self, let listener, let continuation = self.startContinuation else { return }

                            switch state {
                            case .ready:
                                guard let port = listener.port else { return }

                                self.startContinuation = nil

                                var components = URLComponents()
                                components.scheme = "http"
                                components.host = host.contains(":") ? "[\(host)]" : host
                                components.port = Int(port.rawValue)
                                components.path = "/\(self.token)/stream.m3u8"

                                guard let url = components.url else {
                                    continuation.resume(throwing: ServerError("Cannot construct the local media URL."))
                                    return
                                }

                                continuation.resume(returning: url)

                            case let .failed(error):
                                self.startContinuation = nil
                                continuation.resume(throwing: error)

                            case .cancelled:
                                self.startContinuation = nil
                                continuation.resume(throwing: CancellationError())

                            default:
                                break
                            }
                        }

                        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        listener.start(queue: queue)

                        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                            guard let self, let continuation = self.startContinuation else { return }

                            self.startContinuation = nil

                            continuation
                                .resume(throwing: ServerError("The local stream server could not start. Check local network permission."))

                            self.cancelOnQueue()
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.queue.async { [self] in cancelOnQueue() }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                cancelOnQueue()
                continuation.resume()
            }
        }
    }

    private func cancelOnQueue() {
        isStopped = true
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel()
            return
        }

        let id = UUID()
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.close(id)
            }

            if case .cancelled = state {
                self?.connections.removeValue(forKey: id)
            }
        }

        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.close(id) }
        receive(id, bytes: Data())
    }

    private func receive(_ id: UUID, bytes: Data) {
        guard let connection = connections[id] else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384 - bytes.count) { [weak self] data, _, complete, error in
            guard let self else { return }

            var bytes = bytes

            if let data {
                bytes.append(data)
            }

            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(id, request: bytes)
            } else if complete || error != nil || bytes.count >= 16384 {
                self.close(id)
            } else {
                self.receive(id, bytes: bytes)
            }
        }
    }

    private func respond(_ id: UUID, request: Data) {
        guard let connection = connections[id] else { return }

        let response = Self.responseParts(to: request, directory: directory, token: token)

        connection.send(content: response.header, completion: .contentProcessed { [weak self] error in
            guard error == nil else { self?.close(id)
                return
            }

            self?.sendBody(id, body: response.body, offset: response.body.startIndex)
        })
    }

    // Send large segments one chunk at a time to limit queued network data.
    // Retain the file data until sending finishes, even if packaging deletes the segment.
    private func sendBody(_ id: UUID, body: Data, offset: Int) {
        guard let connection = connections[id] else { return }
        guard offset < body.endIndex else { close(id)
            return
        }

        let end = min(offset + 256 * 1024, body.endIndex)

        connection.send(content: body[offset ..< end], completion: .contentProcessed { [weak self] error in
            guard error == nil else { self?.close(id)
                return
            }

            self?.sendBody(id, body: body, offset: end)
        })
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }
}

extension MPVHTTPMediaServer.ServerError: Error {}
