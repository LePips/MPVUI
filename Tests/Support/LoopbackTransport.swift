import Darwin
import Foundation

enum LoopbackTransport {

    static let udpLiteProtocol: Int32 = 136

    static var supportsUDPLite: Bool {
        guard let socket = try? openSocket(ipProtocol: udpLiteProtocol) else { return false }

        Darwin.close(socket)
        return true
    }

    static func availablePort(ipProtocol: Int32 = 0) throws -> UInt16 {
        let socket = try openSocket(ipProtocol: ipProtocol)
        defer { Darwin.close(socket) }
        var address = endpoint(0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { endpoint in
                guard Darwin.bind(socket, endpoint, size) == 0,
                      Darwin.getsockname(socket, endpoint, &size) == 0
                else { throw socketError() }
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    static func isUDPPortBound(_ port: UInt16) throws -> Bool {
        let socket = try openSocket(ipProtocol: 0)
        defer { Darwin.close(socket) }
        var address = endpoint(port)
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, size) }
        }
        if result == 0 {
            return false
        }
        if errno == EADDRINUSE {
            return true
        }
        throw socketError()
    }

    static func sessionDescription(port: UInt16) -> String {
        sessionDescription(port: port, media: "video", payload: 33, encoding: "MP2T/90000")
    }

    static func mpegAudioADUSessionDescription(port: UInt16) -> String {
        sessionDescription(port: port, media: "audio", payload: MPEGAudioADUPackets.payloadType, encoding: "mpa-robust/90000")
    }

    static func sessionDescription(port: UInt16, media: String, payload: UInt8, encoding: String) -> String {
        sessionDescription(port: port, media: media, payload: payload, attributes: ["a=rtpmap:\(payload) \(encoding)"])
    }

    static func sessionDescription(port: UInt16, media: String, payload: UInt8, attributes: [String]) -> String {
        """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=Local transport stream
        c=IN IP4 127.0.0.1
        t=0 0
        m=\(media) \(port) RTP/AVP \(payload)
        \(attributes.joined(separator: "\n"))

        """
    }

    static func send(_ transport: Data, to port: UInt16, usesRTP: Bool, ipProtocol: Int32 = 0) async throws {
        var packets = MPEGTransportPackets(transport)
        try await send(to: port, ipProtocol: ipProtocol) {
            (packets.next(usesRTP: usesRTP), .microseconds(MPEGTransportPackets.intervalMicroseconds))
        }
    }

    static func sendMPEGAudioADU(_ encoded: Data, to port: UInt16) async throws {
        var packets = MPEGAudioADUPackets(encoded)
        try await send(to: port) {
            (packets.next(), .milliseconds(MPEGAudioADUPackets.intervalMilliseconds))
        }
    }

    static func send(_ encoded: Data, as audio: RTPAudioFixture, to port: UInt16) async throws {
        var packets = RTPAudioPackets(encoded, format: audio)
        try await send(to: port) { (packets.next(), .milliseconds(audio.packetMs)) }
    }

    static func send(_ recording: Data, as fixture: RTPRecordingFixture, to port: UInt16) async throws {
        var packets = try RTPRecordedPackets(recording, loopTicks: fixture.loopTicks)
        try await send(to: port) {
            let packet = fixture.loopTicks == 0 ? packets.nextRecorded() : packets.next()
            return packet.map { ($0.data, .microseconds($0.delay)) }
        }
    }

    private static func send(to port: UInt16, ipProtocol: Int32 = 0, nextPacket: () -> (Data, Duration)?) async throws {
        let socket = try openSocket(ipProtocol: ipProtocol)
        defer { Darwin.close(socket) }
        var address = endpoint(port)
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        while !Task.isCancelled, let (packet, delay) = nextPacket() {
            let sent = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { endpoint in
                    packet.withUnsafeBytes { Darwin.sendto(socket, $0.baseAddress, $0.count, 0, endpoint, size) }
                }
            }
            guard sent == packet.count else { throw socketError() }

            if delay > .zero {
                try await Task.sleep(for: delay)
            }
        }
    }

    private static func openSocket(ipProtocol: Int32) throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, ipProtocol)
        guard socket >= 0 else { throw socketError() }

        return socket
    }

    private static func endpoint(_ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        return address
    }

    private static func socketError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

struct RTPRecordingFixture: Decodable, Sendable {

    let file: String
    let media: String
    let codec: String
    let decoder: String
    let payloadType: UInt8
    let sdpAttributes: [String]
    let loopTicks: UInt32
    let androidOnly: Bool
    let direct: Bool
    let width: Int?
    let height: Int?
    let inputOptions: String?

    var readers: [String] {
        if loopTicks == 0 {
            return ["sdp"]
        }
        return direct ? ["rtp", "sdp", "rtsp"] : ["sdp", "rtsp"]
    }
}

struct RTPRecordedPackets {

    private let packets: [(data: Data, delay: Int)]
    private let loopTicks: UInt32
    private var index = 0
    private var sequence: UInt16 = 0
    private var timestampOffset: UInt32 = 0

    init(_ recording: Data, loopTicks: UInt32) throws {
        var packets = [(Data, Int)]()
        var offset = 0
        while offset < recording.count {
            guard offset + 6 <= recording.count else { throw CocoaError(.fileReadCorruptFile) }

            let header = recording[offset ..< offset + 6]
            let bytes = header.prefix(2).reduce(0) { ($0 << 8) | Int($1) }
            let delay = header.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
            let start = offset + header.count
            let end = start + bytes
            guard bytes >= 12, end <= recording.count else { throw CocoaError(.fileReadCorruptFile) }

            packets.append((Data(recording[start ..< end]), delay))
            offset = end
        }
        guard !packets.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        self.packets = packets
        self.loopTicks = loopTicks
    }

    mutating func next() -> (data: Data, delay: Int) {
        let entry = packets[index]
        var data = entry.data
        let timestamp = data[4 ..< 8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } &+ timestampOffset
        withUnsafeBytes(of: sequence.bigEndian) { data.replaceSubrange(2 ..< 4, with: $0) }
        withUnsafeBytes(of: timestamp.bigEndian) { data.replaceSubrange(4 ..< 8, with: $0) }
        sequence &+= 1
        index += 1
        if index == packets.count {
            index = 0
            timestampOffset &+= loopTicks
        }
        return (data, entry.delay)
    }

    // SRTP authenticates packet headers, so replay each original packet once.
    mutating func nextRecorded() -> (data: Data, delay: Int)? {
        guard index < packets.count else { return nil }

        defer { index += 1 }
        return packets[index]
    }
}

struct RTPAudioFixture: Decodable, Sendable {

    let file: String
    let codec: String
    let decoder: String
    let payloadType: UInt8
    let encoding: String
    let packetBytes: Int
    let packetTicks: UInt32
    let packetMs: Int
    let androidOnly: Bool
}

struct RTPAudioPackets {

    private let encoded: Data
    private let format: RTPAudioFixture
    private var offset = 0
    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0

    init(_ encoded: Data, format: RTPAudioFixture) {
        precondition(!encoded.isEmpty && encoded.count.isMultiple(of: format.packetBytes))
        self.encoded = encoded
        self.format = format
    }

    mutating func next() -> Data {
        let end = offset + format.packetBytes
        var packet = rtpHeader(payload: format.payloadType, sequence: sequence, timestamp: timestamp)
        packet.append(encoded[offset ..< end])
        offset = end == encoded.count ? 0 : end
        sequence &+= 1
        timestamp &+= format.packetTicks
        return packet
    }
}

struct MPEGTransportPackets {

    static let intervalMicroseconds = packetSize * 8 * 1_000_000 / muxRate
    private static let packetSize = 7 * 188
    private static let muxRate = 256_000
    private static let ticksPerPacket = UInt32(packetSize * 8 * 90000 / muxRate)

    private let transport: Data
    private var offset = 0
    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0

    init(_ transport: Data) {
        self.transport = transport
    }

    mutating func next(usesRTP: Bool) -> Data {
        let end = min(offset + Self.packetSize, transport.count)
        var packet = Data()
        if usesRTP {
            // Static RTP payload type 33 carries complete 188-byte MPEG-TS packets.
            packet = rtpHeader(payload: 33, sequence: sequence, timestamp: timestamp)
            sequence &+= 1
            timestamp &+= Self.ticksPerPacket
        }
        packet.append(transport[offset ..< end])
        offset = end == transport.count ? 0 : end
        return packet
    }
}

private struct MPEGAudioADUPackets {

    static let intervalMilliseconds = 24
    static let payloadType: UInt8 = 96
    private static let frameSize = 384
    private static let ticksPerFrame: UInt32 = 2160

    private let encoded: Data
    private var offset = 0
    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0

    init(_ encoded: Data) {
        precondition(!encoded.isEmpty && encoded.count.isMultiple(of: Self.frameSize))
        self.encoded = encoded
    }

    mutating func next() -> Data {
        var packet = rtpHeader(payload: Self.payloadType, sequence: sequence, timestamp: timestamp)
        let end = offset + Self.frameSize
        // RFC 3119 uses a two-byte descriptor for a complete ADU of this size.
        let descriptor = UInt16(0x4000 | Self.frameSize)
        withUnsafeBytes(of: descriptor.bigEndian) { packet.append(contentsOf: $0) }
        packet.append(encoded[offset ..< end])
        offset = end == encoded.count ? 0 : end
        sequence &+= 1
        timestamp &+= Self.ticksPerFrame
        return packet
    }
}

private func rtpHeader(payload: UInt8, sequence: UInt16, timestamp: UInt32) -> Data {
    var header = Data([0x80, payload])
    withUnsafeBytes(of: sequence.bigEndian) { header.append(contentsOf: $0) }
    withUnsafeBytes(of: timestamp.bigEndian) { header.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(0x4D50_5655).bigEndian) { header.append(contentsOf: $0) }
    return header
}
