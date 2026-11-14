import Foundation
import Network

final class LoopbackRTSPServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "MPVUI.test.rtsp")
    private let scheme: String
    private let nextPacket: () -> (Data, DispatchTimeInterval)
    private let media: String
    private var connection: NWConnection?
    private var plays = 0

    var playRequests: Int {
        queue.sync { plays }
    }

    convenience init(transport: Data, identity: sec_identity_t? = nil) throws {
        var packets = MPEGTransportPackets(transport)
        try self.init(media: "video 0 RTP/AVP 33\na=rtpmap:33 MP2T/90000", identity: identity) {
            (packets.next(usesRTP: true), .microseconds(MPEGTransportPackets.intervalMicroseconds))
        }
    }

    convenience init(audio: RTPAudioFixture, encoded: Data) throws {
        var packets = RTPAudioPackets(encoded, format: audio)
        let media = "audio 0 RTP/AVP \(audio.payloadType)\na=rtpmap:\(audio.payloadType) \(audio.encoding)"
        try self.init(media: media) { (packets.next(), .milliseconds(audio.packetMs)) }
    }

    convenience init(fixture: RTPRecordingFixture, recording: Data) throws {
        var packets = try RTPRecordedPackets(recording, loopTicks: fixture.loopTicks)
        let media = (["\(fixture.media) 0 RTP/AVP \(fixture.payloadType)"] + fixture.sdpAttributes).joined(separator: "\n")
        try self.init(media: media) {
            let packet = packets.next()
            return (packet.data, .microseconds(packet.delay))
        }
    }

    private init(media: String, identity: sec_identity_t? = nil, nextPacket: @escaping () -> (Data, DispatchTimeInterval)) throws {
        self.media = media
        self.nextPacket = nextPacket
        let parameters: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            parameters = NWParameters(tls: tls)
            scheme = "rtsps"
        } else {
            parameters = .tcp
            scheme = "rtsp"
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak listener, scheme] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    guard let port = listener?.port,
                          let url = URL(string: "\(scheme)://127.0.0.1:\(port.rawValue)/source/")
                    else {
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
                guard let self, self.connection == nil else {
                    connection.cancel()
                    return
                }

                self.connection = connection
                connection.start(queue: self.queue)
                self.receiveRequest(on: connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            connection?.cancel()
            connection = nil
        }
    }

    func disconnect() {
        queue.async { [self] in
            connection?.cancel()
            connection = nil
        }
    }

    private func receiveRequest(on connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }

            let received = buffered + (data ?? Data())
            if received.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(to: received, on: connection)
            } else if complete || received.count >= 8192 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffered: received)
            }
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3,
              let cseq = lines.first(where: { $0.lowercased().hasPrefix("cseq:") })
        else {
            connection.cancel()
            return
        }

        var headers = "RTSP/1.0 200 OK\r\n\(cseq)\r\n"
        var body = ""
        switch requestLine[0] {
        case "OPTIONS":
            headers += "Public: OPTIONS, DESCRIBE, SETUP, PLAY\r\n"

        case "DESCRIBE":
            body = """
            v=0
            o=- 0 0 IN IP4 127.0.0.1
            s=Local transport stream
            c=IN IP4 127.0.0.1
            t=0 0
            a=control:*
            m=\(media)
            a=control:trackID=0

            """.replacingOccurrences(of: "\n", with: "\r\n")
            headers += "Content-Type: application/sdp\r\nContent-Base: \(requestLine[1])\r\n"

        case "SETUP" where lines.contains(where: { $0.contains("RTP/AVP/TCP") }):
            headers += "Session: 12345678\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n"

        case "PLAY" where lines.contains(where: { $0.lowercased() == "session: 12345678" }):
            plays += 1
            headers += "Session: 12345678\r\n"

        default:
            connection.cancel()
            return
        }
        let data = Data((headers + "Content-Length: \(body.utf8.count)\r\n\r\n" + body).utf8)
        let playing = requestLine[0] == "PLAY"
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }

            if playing {
                self.sendPacket(on: connection)
            } else {
                self.receiveRequest(on: connection)
            }
        })
    }

    private func sendPacket(on connection: NWConnection) {
        guard self.connection === connection else { return }

        let (packet, delay) = nextPacket()
        // RTSP interleaved data header. Channel zero carries RTP.
        var framed = Data([0x24, 0])
        withUnsafeBytes(of: UInt16(packet.count).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(packet)
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }

            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sendPacket(on: connection)
            }
        })
    }
}
