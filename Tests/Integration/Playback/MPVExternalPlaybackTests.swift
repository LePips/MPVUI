import AVFoundation
import CoreMedia
import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVExternalPlaybackTests {

    // The simulator checks HDR metadata and compressed packets.
    // HDR playback and GPU tone mapping need capabilities available on physical hardware.
    private nonisolated static let playbackMedia = [
        "video-vp9.mkv",
        "video-av1-10bit.mkv",
        "color-hdr10.mkv",
        "color-hlg.mkv",
        "dolby-vision-p5-hls.mp4",
        "dolby-vision-p81-hls.mp4",
        "dolby-vision-p84.mp4",
        "dolby-vision-p81.mp4",
    ].filter { name in
        #if targetEnvironment(simulator)
        name.hasPrefix("video-")
        #else
        true
        #endif
    }

    @Test
    func `unprepared external playback cannot create a session and does not retain its owner`() async throws {
        weak var owner: MPVPlayer?
        var controller: MPVExternalPlaybackController?
        do {
            let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"]))
            owner = player
            controller = player.externalPlayback
            do {
                try await player.externalPlayback.start()
                Issue.record("External playback accepted an unloaded source")
            } catch {
                guard case .externalPlaybackFailed = error as? MPVPlayerError else { throw error }
            }
            #expect(!player.externalPlayback.controlsPlayback)
            #expect(await player.lifecycleDiagnostics().handlesCreated == 0)
        }
        try await eventually("external controller releases its playback owner") { owner == nil }
        let retained = try #require(controller)
        retained.updateAudio()
        retained.seek(to: .seconds(1))
        retained.setPlaying(true)
        retained.stop()
        #expect(!retained.controlsPlayback && retained.systemPlayer.currentItem == nil)
        controller = nil
    }

    @Test(arguments: playbackMedia)
    func `incompatible codecs convert and compatible HDR remuxes into playable system video`(_ name: String) async throws {
        let stream = try MPVHLSStream(startTime: .seconds(1))
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        do {
            let url = try await stream.start(
                source: TestPaths.testMedia(name),
                options: ["sid": "no"],
                toneMapHDR: name.hasPrefix("color-"),
                advertisedHost: "127.0.0.1"
            )

            #expect(stream.packagingInfo?.videoCopied == (!name.hasPrefix("video-") && name != "dolby-vision-p81.mp4"))
            #expect(stream.packagingInfo?.requiresForeground == (name == "dolby-vision-p81.mp4"))
            let native = AVPlayer(url: url)
            let layer = AVPlayerLayer(player: native)
            layer.frame = fixture.surface.bounds
            #if os(macOS)
            fixture.surface.layer?.addSublayer(layer)
            #else
            fixture.surface.layer.addSublayer(layer)
            #endif
            defer {
                native.pause()
                native.replaceCurrentItem(with: nil)
                layer.removeFromSuperlayer()
            }
            native.isMuted = true
            native.play()
            do {
                try await eventually("converted video advances", timeout: .seconds(15)) { native.currentTime().seconds > 0.3 }
            } catch {
                Issue
                    .record(
                        """
                        System player status=\(String(describing: native.currentItem?.status)), \
                        error=\(String(describing: native.currentItem?.error)), \
                        waiting=\(String(describing: native.reasonForWaitingToPlay)), \
                        log=\(String(describing: native.currentItem?.errorLog()?.events.map(\.errorComment)))
                        """
                    )
                throw error
            }

            #expect(native.currentItem?.status == .readyToPlay)
            await stream.stop()
        } catch {
            await stream.stop()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func `converted handoff preserves source time and can seek before its first segment`(_ remux: Bool) async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused(TestPaths.multitrackMedia, at: .seconds(8))
        let player = fixture.player
        if remux {
            player.disableTrack(.subtitle)
        }
        try await player.externalPlayback.start()

        #expect(player.externalPlayback.isConverting == !remux)
        #expect(player.isPaused)
        #expect(
            abs(player.position.seconds - 8) < 0.2,
            """
            Source position: \(player.position), system time: \(player.externalPlayback.systemPlayer.currentTime()), ranges: \
            \(String(describing: player.externalPlayback.systemPlayer.currentItem?.seekableTimeRanges))
            """
        )
        player.seek(to: .seconds(2))
        try await eventually("conversion restarted for earlier source time", timeout: .seconds(30)) {
            player.externalPlayback.isPrepared && player.isPaused && abs(player.position.seconds - 2) < 0.2
        }
        player.setMuted(true)
        player.play()
        try await eventually("converted source advances", timeout: .seconds(15)) { player.position.seconds > 2.4 }
        player.pause()
        let position = player.position
        player.externalPlayback.stop()
        try await eventually("conversion handed back to mpv") { player.isPaused && abs(player.position.seconds - position.seconds) < 0.2 }
    }

    @Test
    func `cancelling preparation restores local playback`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        let task = Task { try await player.externalPlayback.start() }
        task.cancel()
        do {
            try await task.value

            Issue.record("Cancelled preparation succeeded")
        } catch is CancellationError {} catch { throw error }
        #expect(!player.externalPlayback.isPreparing)
        #expect(!player.externalPlayback.isPrepared)
        #expect(player.externalPlayback.systemPlayer.currentItem == nil)
        #expect(player.externalPlayback.lastError == nil)
        try await eventually("cancelled handoff restored") { player.isPaused && abs(player.position.seconds - 1) < 0.2 }
    }

    @Test
    func `failed alternate rendition restores the original source`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        do {
            try await player.externalPlayback.start(using: URL(fileURLWithPath: "/missing-external-playback.mp4"))

            Issue.record("Missing rendition succeeded")
        } catch { #expect(error is MPVPlayerError) }
        #expect(!player.externalPlayback.isPrepared)
        #expect(player.externalPlayback.lastError != nil)
        try await eventually("failed handoff restored") { player.isPaused && abs(player.position.seconds - 1) < 0.2 }

        #expect(player.mediaInformation.sourceURL == TestPaths.baselineMedia)
        player.externalPlayback.clearLastError()
        #expect(player.externalPlayback.lastError == nil)
        #expect(!player.externalPlayback.isPrepared)
    }

    @Test
    func `route selection defers packaging and disconnect restores custom playback`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused(TestPaths.multitrackMedia, at: .seconds(4))
        fixture.player.disableTrack(.subtitle)
        let playback = fixture.player.externalPlayback
        playback.updateAirPlayRoute(isSelected: false, retry: true)
        await Task.yield()

        #expect(!playback.isPreparing && !playback.isPrepared)
        #expect(playback.systemPlayer.currentItem == nil)

        playback.updateAirPlayRoute(isSelected: true)
        playback.updateAirPlayRoute(isSelected: true, retry: true)
        try await eventually("selected route prepares media", timeout: .seconds(30)) { playback.isPrepared }

        let item = try #require(playback.systemPlayer.currentItem)
        #expect(!playback.isConverting)
        #expect(fixture.player.isPaused)
        playback.updateAirPlayRoute(isSelected: true, retry: true)
        await Task.yield()

        #expect(playback.systemPlayer.currentItem === item)

        playback.updateAirPlayRoute(isSelected: false)

        #expect(!playback.isPreparing && !playback.isPrepared)
        #expect(playback.systemPlayer.currentItem == nil)
        try await eventually("route disconnect restores mpv") {
            fixture.player.isPaused && abs(fixture.player.position.seconds - 4) < 0.2
        }
    }

    @Test(arguments: [false, true])
    func `disconnect cancels queued or running route preparation`(_ running: Bool) async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused(TestPaths.multitrackMedia)
        let playback = fixture.player.externalPlayback
        playback.updateAirPlayRoute(isSelected: true)
        if running {
            try await eventually("route preparation starts") { playback.isPreparing || playback.isPrepared }
        }
        playback.updateAirPlayRoute(isSelected: false)
        // Allow queued cancellation and teardown updates to arrive before checking the final state.
        try await Task.sleep(for: .milliseconds(200))

        #expect(!playback.isPreparing && !playback.isPrepared)
        #expect(playback.systemPlayer.currentItem == nil)
        #expect(playback.lastError == nil)
        #expect(fixture.player.isPaused)
    }

    @Test
    func `media replacement rejects a queued route handoff`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused(TestPaths.multitrackMedia)
        let playback = fixture.player.externalPlayback
        playback.updateAirPlayRoute(isSelected: true)
        try await fixture.loadPaused(TestPaths.baselineMedia)

        #expect(!playback.isPreparing && !playback.isPrepared)
        #expect(playback.systemPlayer.currentItem == nil)
        playback.updateAirPlayRoute(isSelected: true, retry: true)
        try await eventually("a later route selection can prepare the new media", timeout: .seconds(30)) { playback.isPrepared }
        playback.updateAirPlayRoute(isSelected: false)
    }

    @Test
    func `Matroska remuxes to fragmented MP4 HLS with playable segments`() async throws {
        let stream = try MPVHLSStream(startTime: .zero)
        do {
            let url = try await stream.start(source: TestPaths.multitrackMedia, options: ["sid": "no"], advertisedHost: "127.0.0.1")
            let (data, response) = try await URLSession.shared.data(from: url)

            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let playlist = String(decoding: data, as: UTF8.self)

            #expect(playlist.hasPrefix("#EXTM3U"))
            #expect(stream.packagingInfo?.videoCopied == true)
            #expect(stream.packagingInfo?.audioCopied == true)
            #expect(!stream.isTranscoding)
            let mediaURL = url.deletingLastPathComponent().appendingPathComponent("media.m3u8")
            let (mediaData, _) = try await URLSession.shared.data(from: mediaURL)
            let mediaPlaylist = String(decoding: mediaData, as: UTF8.self)

            #expect(mediaPlaylist.contains("#EXT-X-MAP:URI=\"init.mp4\""))
            let name = try #require(mediaPlaylist.split(separator: "\n").first { $0.hasSuffix(".m4s") })
            let segment = try #require(URL(string: String(name), relativeTo: url))
            let (bytes, segmentResponse) = try await URLSession.shared.data(from: segment)

            #expect((segmentResponse as? HTTPURLResponse)?.statusCode == 200)
            #expect(bytes.count > 188)
            #expect(String(decoding: bytes[4 ..< 8], as: UTF8.self) == "styp")
            let asset = AVURLAsset(url: url)

            #expect(try await asset.load(.isPlayable))
            await stream.stop()
        } catch {
            await stream.stop()
            throw error
        }
    }

    @Test
    func `unsupported selected audio converts while video stays compressed`() async throws {
        let stream = try MPVHLSStream(startTime: .zero)
        do {
            var options = MPVMediaPackagingOptions(mpv: ["sid": "no"])
            options.audioIndex = 2 // Stream 2 contains the second audio track, encoded as Opus.
            let url = try await stream.start(source: TestPaths.multitrackMedia, packaging: options, advertisedHost: "127.0.0.1")

            #expect(stream.packagingInfo?.videoCopied == true)
            #expect(stream.packagingInfo?.audioCopied == false)
            let file = try await downloadFirstFragment(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            let audio = try await AVURLAsset(url: file).loadTracks(withMediaType: .audio)

            let track = try #require(audio.first)
            let descriptions = try await track.load(.formatDescriptions)

            #expect(try CMFormatDescriptionGetMediaSubType(#require(descriptions.first)) == kAudioFormatMPEG4AAC)
            #expect(try await AVURLAsset(url: url).load(.isPlayable))
            await stream.stop()
        } catch {
            await stream.stop()
            throw error
        }
    }

    @Test
    func `unsupported video converts while Dolby surround stays compressed`() async throws {
        let stream = try MPVHLSStream(startTime: .zero)
        do {
            let url = try await stream.start(
                source: TestPaths.testMedia("video-vp9-ac3.mkv"),
                options: ["sid": "no"],
                advertisedHost: "127.0.0.1"
            )

            #expect(stream.packagingInfo?.videoCopied == false)
            #expect(stream.packagingInfo?.audioCopied == true)
            let file = try await downloadFirstFragment(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            let tracks = try await AVURLAsset(url: file).loadTracks(withMediaType: .audio)

            let track = try #require(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)

            let format = try #require(descriptions.first)
            let audio = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
            #expect(audio.mChannelsPerFrame == 6)
            #expect(audio.mFormatID == kAudioFormatAC3)
            #expect(try await AVURLAsset(url: url).load(.isPlayable))
            await stream.stop()
        } catch {
            await stream.stop()
            throw error
        }
    }

    @Test(arguments: ["audio-ac3-5.1.mka", "audio-eac3-5.1.mka", "audio-pcm-5.1.mka", "audio-pcm-7.1.mka"])
    func `surround audio is copied or converted without a stereo downmix`(_ name: String) async throws {
        let stream = try MPVHLSStream(startTime: .zero)
        do {
            let url = try await stream.start(source: TestPaths.testMedia(name), options: ["sid": "no"], advertisedHost: "127.0.0.1")

            #expect(stream.packagingInfo?.audioCopied == !name.contains("pcm"))
            let file = try await downloadFirstFragment(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            let tracks = try await AVURLAsset(url: file).loadTracks(withMediaType: .audio)

            let track = try #require(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)

            let format = try #require(descriptions.first)
            let audio = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
            #expect(audio.mChannelsPerFrame == (name.contains("7.1") ? 8 : 6))
            let codec: AudioFormatID = name.contains("pcm") ? kAudioFormatMPEG4AAC : name
                .contains("eac3") ? kAudioFormatEnhancedAC3 : kAudioFormatAC3

            #expect(audio.mFormatID == codec)
            await stream.stop()
        } catch {
            await stream.stop()
            throw error
        }
    }

    @Test(arguments: ["color-hdr10.mkv", "color-hlg.mkv", "dolby-vision-p5-hls.mp4", "dolby-vision-p81-hls.mp4", "dolby-vision-p84.mp4"])
    func `HEVC remux preserves HDR signaling`(_ name: String) async throws {
        let stream = try MPVHLSStream(startTime: .zero)
        do {
            let url = try await stream.start(source: TestPaths.testMedia(name), options: ["sid": "no"], advertisedHost: "127.0.0.1")

            #expect(stream.packagingInfo?.videoCopied == true)
            #expect(!stream.isTranscoding)
            let (data, _) = try await URLSession.shared.data(from: url)
            let master = String(decoding: data, as: UTF8.self)
            let hlg = name.contains("hlg") || name.contains("p84")

            #expect(master.contains("VIDEO-RANGE=\(hlg ? "HLG" : "PQ")"))
            let file = try await downloadFirstFragment(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            let tracks = try await AVURLAsset(url: file).loadTracks(withMediaType: .video)

            let track = try #require(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)

            let format = try #require(descriptions.first)
            #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
            if !name.contains("p5") {
                let transfer = CMFormatDescriptionGetExtension(
                    format,
                    extensionKey: kCMFormatDescriptionExtension_TransferFunction
                ) as? String

                #expect(transfer ==
                    (hlg ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG :
                        kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ) as String)
            }
            let bytes = try Data(contentsOf: file)
            if name == "color-hdr10.mkv" {
                #expect(bytes.range(of: Data("mdcv".utf8)) != nil)
                #expect(bytes.range(of: Data("clli".utf8)) != nil)
            }
            if name.hasPrefix("dolby-") {
                #expect(bytes.range(of: Data((name.contains("p5") ? "dvcC" : "dvvC").utf8)) != nil)
                #expect(master.contains("dvh1."))
            }
            await stream.stop()
        } catch {
            await stream.stop()
            throw error
        }
    }

    @Test
    func `paused native packaging can be cancelled without waiting for playback`() async throws {
        let packager = MPVMediaPackager()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        packager.start(
            source: TestPaths.multitrackMedia,
            playlist: directory.appendingPathComponent("media.m3u8"),
            startTime: .zero,
            options: .init()
        )
        for await update in packager.updates {
            if case .prepared = update {
                break
            }
            if case let .failed(message) = update {
                Issue.record("Preparation failed: \(message)")
                await packager.stop()
                return
            }
        }
        let start = ContinuousClock.now
        await packager.stop()

        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test(arguments: ["baseline.mp4", "dolby-vision-p84.mp4"])
    func `remux copies compressed video packets exactly`(_ name: String) async throws {
        let stream = try MPVHLSStream(startTime: .zero)
        do {
            let url = try await stream.start(source: TestPaths.testMedia(name), options: ["sid": "no"], advertisedHost: "127.0.0.1")
            let file = try await downloadFirstFragment(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            let original = try await compressedSamples(from: TestPaths.testMedia(name))
            let remuxed = try await compressedSamples(from: file)

            #expect(original.count == 5)
            #expect(original == remuxed)
            await stream.stop()
        } catch {
            await stream.stop()
            throw error
        }
    }

    @Test
    func `direct handoff preserves controls and returns to the original source`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        try await player.externalPlayback.start()

        #expect(player.externalPlayback.isPrepared)
        #expect(!player.externalPlayback.isConverting)
        #expect(player.isPaused)
        player.setVolume(23)
        player.setMuted(true)

        #expect(player.externalPlayback.systemPlayer.volume == 0.23)
        #expect(player.externalPlayback.systemPlayer.isMuted)
        player.seek(to: .seconds(2))
        try await eventually("system seek") { abs(player.position.seconds - 2) < 0.2 && player.state == .paused }
        player.externalPlayback.stop()
        try await eventually("local playback restored") { player.isPaused && abs(player.position.seconds - 2) < 0.2 }

        #expect(!player.externalPlayback.isPrepared)
        #expect(player.mediaInformation.sourceURL == TestPaths.baselineMedia)
    }

    @Test
    func `replacing media retires an external session and rejects its observations`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        try await player.externalPlayback.start()
        player.load(TestPaths.multitrackMedia, autoPlay: false)

        #expect(!player.externalPlayback.isPrepared)
        #expect(player.externalPlayback.systemPlayer.currentItem == nil)
        try await eventually("replacement media") {
            player.state == .paused && player.mediaInformation.sourceURL == TestPaths.multitrackMedia
        }
    }

    private func downloadFirstFragment(from url: URL) async throws -> URL {
        let base = url.deletingLastPathComponent()
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("media.m3u8"))
        let playlist = String(decoding: data, as: UTF8.self)

        let name = try #require(playlist.split(separator: "\n").first { $0.hasSuffix(".m4s") })
        var (bytes, _) = try await URLSession.shared.data(from: base.appendingPathComponent("init.mp4"))
        let (fragment, _) = try await URLSession.shared.data(from: base.appendingPathComponent(String(name)))
        bytes.append(fragment)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("packaging-test-\(UUID()).mp4")
        try bytes.write(to: file)
        return file
    }

    private func compressedSamples(from url: URL) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        let track = try #require(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        try #require(reader.startReading())
        defer { reader.cancelReading() }
        var samples: [Data] = []
        while samples.count < 5, let sample = output.copyNextSampleBuffer() {
            // Empty edit markers have no compressed packet to compare.
            guard let buffer = CMSampleBufferGetDataBuffer(sample) else { continue }
            var bytes = Data(count: CMBlockBufferGetDataLength(buffer))
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            try #require(status == noErr)
            samples.append(bytes)
        }
        return samples
    }
}
