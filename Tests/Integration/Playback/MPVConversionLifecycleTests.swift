import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVConversionLifecycleTests {

    @Test(arguments: [false, true])
    func `conversion failures finish delivery and permit repeated teardown`(invalidOption: Bool) async throws {
        let files = try TemporaryTestDirectory()
        defer { files.remove() }

        let converter = MPVMediaTranscoder()
        var failures: [String] = []
        var finished = false

        let delivery = Task {
            for await update in converter.updates {
                if case let .failed(message) = update {
                    failures.append(message)
                }

                if case .finished = update {
                    Issue.record("Failed conversion reported success")
                }
            }

            finished = true
        }
        defer { delivery.cancel() }

        converter.start(.init(
            source: invalidOption ? TestPaths.baselineMedia : files.url.appendingPathComponent("missing.mp4"),
            playlist: files.url.appendingPathComponent("stream.m3u8"),
            startTime: .zero,
            options: invalidOption ? ["mpvui-invalid-option": "yes"] : [:]
        ))

        do {
            try await eventually("failed conversion closes its event stream") { finished }
            #expect(failures.count == 1)
            #expect(failures.first?.isEmpty == false)

            if invalidOption {
                #expect(failures.first?.contains("Configure mpvui-invalid-option") == true)
            }

            await converter.stop()
            await converter.stop()
            converter.setPaused(false, synchronously: true)
            #expect(failures.count == 1)
        } catch {
            await converter.stop()
            throw error
        }
    }

    @Test
    func `paused conversion resumes and closes before its output directory is removed`() async throws {
        let files = try TemporaryTestDirectory()
        defer { files.remove() }

        let converter = MPVMediaTranscoder()
        var progressed = false
        var finished = false

        let delivery = Task {
            for await update in converter.updates {
                switch update {
                case let .progress(position): progressed = progressed || position > 0
                case .finished: break
                case let .failed(message): Issue.record("\(message)")
                }
            }

            finished = true
        }
        defer { delivery.cancel() }

        converter.start(.init(
            source: TestPaths.multitrackMedia,
            playlist: files.url.appendingPathComponent("stream.m3u8"),
            startTime: .zero,
            options: ["sid": "no"],
            initiallyPaused: true
        ))

        converter.setPaused(true, synchronously: true)

        do {
            try await Task.sleep(for: .milliseconds(150))
            #expect(!progressed && !finished)
            converter.setPaused(false)
            try await eventually("resumed converter produces timestamps") { progressed }
            await converter.stop()
            try await eventually("converter teardown finishes delivery") { finished }
            await converter.stop()
            #expect(FileManager.default.fileExists(atPath: files.url.path))
        } catch {
            await converter.stop()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func `HLS startup exposes packaging and renderer failures without hanging`(renderer: Bool) async throws {
        let stream = try MPVHLSStream(startTime: .zero)
        var options = MPVMediaPackagingOptions(mpv: renderer ? ["mpvui-invalid-option": "yes"] : [:])
        options.renderingReasons = renderer ? [.inputOptions] : []

        do {
            _ = try await stream.start(
                source: URL(fileURLWithPath: "/missing-conversion-input.mp4"),
                packaging: options,
                advertisedHost: "127.0.0.1"
            )

            Issue.record("Missing conversion input unexpectedly prepared")
        } catch {
            #expect(error is MPVHTTPMediaServer.ServerError)
            #expect(stream.failure?.isEmpty == false)
        }

        await stream.stop()
        await stream.stop()
    }
}
