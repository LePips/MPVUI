import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVHTTPMediaServerTests {

    @Test
    @MainActor
    func `cancelling startup closes delivery before a listener can escape`() async throws {
        let files = try TemporaryTestDirectory()
        defer { files.remove() }
        let server = MPVHTTPMediaServer(directory: files.url)
        let task = Task { @MainActor in try await server.start(advertisedHost: "127.0.0.1") }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled startup returned a listening URL")
        } catch { #expect(error is CancellationError) }
        await server.stop()
    }

    @Test(arguments: ["bytes=0-3", "bytes=0-999", "bytes=4-", "bytes=-3"])
    func `single ranges are clipped to available bytes`(_ value: String) {
        let expected: Range<Int> = switch value {
        case "bytes=0-3": 0 ..< 4
        case "bytes=0-999": 0 ..< 10
        case "bytes=4-": 4 ..< 10
        default: 7 ..< 10
        }

        #expect(MPVHTTPMediaServer.byteRange(value, count: 10) == expected)
    }

    @Test(arguments: ["bytes=10-", "bytes=4-2", "bytes=-0", "bytes=0-1,3-4", "bytes=0-999999999999999999999999", "items=0-1"])
    func `invalid ranges are rejected`(_ value: String) {
        #expect(MPVHTTPMediaServer.byteRange(value, count: 10) == nil)
    }

    @Test
    func `server confines requests and honors HEAD and range semantics`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("0123456789".utf8).write(to: directory.appendingPathComponent("stream0.ts"))
        try Data("secret".utf8).write(to: directory.appendingPathComponent("private.txt"))
        func request(_ path: String, method: String = "GET", range: String? = nil) -> String {
            let headers = range.map { "Range: \($0)\r\n" } ?? ""
            return String(decoding: MPVHTTPMediaServer.response(
                to: Data("\(method) \(path) HTTP/1.1\r\n\(headers)\r\n".utf8),
                directory: directory,
                token: "session"
            ), as: UTF8.self)
        }
        for name in ["init.mp4", "media0.m4s"] {
            try Data("fragment".utf8).write(to: directory.appendingPathComponent(name))

            #expect(request("/session/\(name)").contains("Content-Type: video/mp4"))
            #expect(request("/session/\(name)", range: "bytes=0-3").hasSuffix("frag"))
            #expect(request("/session/\(name).tmp").contains("404 Not Found"))
        }
        #expect(request("/session/stream0.ts").hasSuffix("0123456789"))
        let partial = request("/session/stream0.ts", range: "bytes=2-4")

        #expect(partial.contains("206 Partial Content"))
        #expect(partial.contains("Content-Range: bytes 2-4/10"))
        #expect(partial.hasSuffix("234"))
        let head = request("/session/stream0.ts", method: "HEAD")

        #expect(head.contains("Content-Length: 10\r\n"))
        #expect(head.hasSuffix("\r\n\r\n"))
        for path in [
            "/wrong/stream0.ts",
            "/session/private.txt",
            "/session/../private.txt",
            "/session/%2e%2e/private.txt",
            "/session/stream0.ts.tmp"
        ] {
            #expect(request(path).contains("404 Not Found"))
        }
        #expect(request("/session/stream0.ts", range: "bytes=20-").contains("Content-Range: bytes */10"))
    }

    @Test(arguments: ["127.0.0.1", "::1"])
    func `listener serves an actual HTTP request and closes cleanly`(_ host: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let playlist = Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8)
        try playlist.write(to: directory.appendingPathComponent("stream.m3u8"))
        let server = MPVHTTPMediaServer(directory: directory)
        do {
            let url = try await server.start(advertisedHost: host)
            let (body, response) = try await URLSession.shared.data(from: url)

            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(body == playlist)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test
    func `malformed requests cannot read nonregular oversized or unlisted files`() throws {
        let files = try TemporaryTestDirectory()
        defer { files.remove() }
        let regular = try files.write("stream0.ts", contents: "0123456789")
        _ = try files.write("media0.m4s", contents: "")
        try FileManager.default.createSymbolicLink(at: files.url.appendingPathComponent("stream1.ts"), withDestinationURL: regular)
        try FileManager.default.createDirectory(at: files.url.appendingPathComponent("stream2.ts"), withIntermediateDirectories: false)
        let oversized = try files.write("stream3.ts", contents: "")
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 512 * 1024 * 1024 + 1)
        try handle.close()
        func response(_ request: Data) -> String {
            String(decoding: MPVHTTPMediaServer.response(to: request, directory: files.url, token: "session"), as: UTF8.self)
        }
        #expect(response(Data([0xFF])).contains("400 Bad Request"))
        for text in ["", "GET", "POST /session/stream0.ts HTTP/1.1\r\n\r\n"] {
            #expect(response(Data(text.utf8)).contains("405 Method Not Allowed"))
        }
        for name in ["stream1.ts", "stream2.ts", "stream3.ts", "stream4.ts"] {
            #expect(response(Data("GET /session/\(name) HTTP/1.1\r\n\r\n".utf8)).contains("404 Not Found"))
        }
        #expect(response(Data("GET /session/stream0.ts?cache=1 HTTP/1.1\r\n\r\n".utf8)).hasSuffix("0123456789"))
        #expect(response(Data("GET /session/stream0.ts HTTP/1.1\r\nRange: bytes=0-1\r\nrange: bytes=2-3\r\n\r\n".utf8))
            .contains("416 Range Not Satisfiable"))
        #expect(response(Data("GET /session/media0.m4s HTTP/1.1\r\nRange: bytes=0-\r\n\r\n".utf8))
            .contains("Content-Range: bytes */0"))
        #expect(MPVHTTPMediaServer.byteRange("bytes=-20", count: 10) == 0 ..< 10)
        #expect(MPVHTTPMediaServer.byteRange("bytes=0", count: 10) == nil)
        #expect(MPVHTTPMediaServer.byteRange("bytes=0-1", count: 0) == nil)
    }

    @Test
    func `listener teardown prevents restart and preserves complete large responses`() async throws {
        let files = try TemporaryTestDirectory()
        defer { files.remove() }
        let bytes = Data(repeating: 0x5A, count: 700_000)
        try bytes.write(to: files.url.appendingPathComponent("stream0.ts"))
        let server = MPVHTTPMediaServer(directory: files.url)
        do {
            let playlist = try await server.start(advertisedHost: "127.0.0.1")
            let media = playlist.deletingLastPathComponent().appendingPathComponent("stream0.ts")
            let (body, response) = try await URLSession.shared.data(from: media)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(body == bytes)
            do {
                _ = try await server.start(advertisedHost: "127.0.0.1")
                Issue.record("An active listener started a second server")
            } catch { #expect(error is CancellationError) }
            await server.stop()
            await server.stop()
            do {
                _ = try await server.start(advertisedHost: "127.0.0.1")
                Issue.record("A stopped listener restarted")
            } catch { #expect(error is CancellationError) }
        } catch {
            await server.stop()
            throw error
        }
    }
}
