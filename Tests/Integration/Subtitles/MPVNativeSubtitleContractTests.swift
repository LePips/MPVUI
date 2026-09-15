import Foundation
import Libmpv
@testable import MPVUI
import Observation
import Testing

#if os(iOS) || os(tvOS)
import UIKit
#endif

@Suite(.tags(.integration, .subtitles), .serialized)
struct MPVNativeSubtitleContractTests {
    @Test
    func `bundled mpv exposes text subtitle snapshot property`() throws {
        let handle = try #require(mpv_create())
        var initialized = false
        defer {
            if initialized {
                mpv_terminate_destroy(handle)
            } else {
                mpv_destroy(handle)
            }
        }

        #expect(mpv_set_option_string(handle, "vo", "null") >= 0)
        #expect(mpv_set_option_string(handle, "ao", "null") >= 0)
        #expect(mpv_set_option_string(handle, "idle", "yes") >= 0)
        #expect(mpv_set_option_string(handle, "sub-text-intercept", "yes") >= 0)
        let initializeStatus = mpv_initialize(handle)
        #expect(initializeStatus >= 0)
        guard initializeStatus >= 0 else { return }
        initialized = true

        var node = mpv_node()
        #expect(mpv_get_property(handle, "sub-text-snapshot", MPV_FORMAT_NODE, &node) >= 0)
        defer { mpv_free_node_contents(&node) }

        #expect(MPVNodeValue(copying: node) == .array([]))
    }

    #if os(macOS)
    @Test
    func `bundled mpv text subtitle snapshot contract`() throws {
        let handle = try #require(mpv_create())
        var initialized = false
        defer {
            if initialized {
                mpv_terminate_destroy(handle)
            } else {
                mpv_destroy(handle)
            }
        }

        for (name, value) in [
            ("vo", "null"),
            ("ao", "null"),
            ("idle", "yes"),
            ("sub-text-intercept", "yes"),
        ] {
            #expect(mpv_set_option_string(handle, name, value) >= 0)
        }
        let initializeStatus = mpv_initialize(handle)
        #expect(initializeStatus >= 0)
        guard initializeStatus >= 0 else { return }
        initialized = true

        let video = TestPaths.baselineMedia
        #expect(FileManager.default.fileExists(atPath: video.path))

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MPVUI-subtitle-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let webVTT = temporaryDirectory.appendingPathComponent("overlap.vtt")
        try """
        WEBVTT

        00:00.000 --> 00:30.000 position:25%,line-left line:80% size:40%
        positioned

        00:00.000 --> 00:30.000
        default

        """.write(to: webVTT, atomically: true, encoding: .utf8)

        let ass = temporaryDirectory.appendingPathComponent("native.ass")
        try """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 384
        PlayResY: 288

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,24,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:30.00,Default,,0,0,0,,native ASS

        """.write(to: ass, atomically: true, encoding: .utf8)

        let srt = temporaryDirectory.appendingPathComponent("automatic.srt")
        try """
        1
        00:00:00,000 --> 00:00:30,000
        automatic

        """.write(to: srt, atomically: true, encoding: .utf8)

        #expect(mpv_command_string(handle, "loadfile \(video.path) replace") >= 0)
        #expect(waitForMPVEvent(handle, id: MPV_EVENT_FILE_LOADED, timeout: 10))

        #expect(mpv_command_string(handle, "sub-add \(webVTT.path) select") >= 0)
        #expect(waitForSelectedSubtitleCodec(handle, "webvtt", timeout: 5))
        let webVTTSnapshot = try #require(
            waitForSubtitleSnapshot(
                handle,
                timeout: 5,
                where: { $0.arrayValue?.count == 2 }
            )
        )
        let webVTTRegions = try #require(webVTTSnapshot.arrayValue)
        #expect((webVTTRegions[0].mapValue?["text"]?.stringValue) == "positioned")
        #expect((webVTTRegions[0].mapValue?["format"]?.stringValue) == "webvtt")
        #expect(
            (webVTTRegions[0].mapValue?["settings"]?.stringValue)
                == "position:25%,line-left line:80% size:40%"
        )
        #expect((webVTTRegions[1].mapValue?["text"]?.stringValue) == "default")
        #expect((webVTTRegions[1].mapValue?["settings"]?.stringValue) == "")

        #expect(mpv_set_property_string(handle, "sub-visibility", "no") >= 0)
        #expect(
            waitForSubtitleSnapshot(
                handle,
                timeout: 5,
                where: { $0.arrayValue?.isEmpty == true }
            ) != nil
        )
        #expect(mpv_set_property_string(handle, "sub-visibility", "yes") >= 0)
        #expect(
            waitForSubtitleSnapshot(
                handle,
                timeout: 5,
                where: { $0.arrayValue?.count == 2 }
            ) != nil
        )

        #expect(mpv_command_string(handle, "sub-add \(ass.path) select") >= 0)
        #expect(waitForSelectedSubtitleCodec(handle, "ass", timeout: 5))
        #expect(
            waitForSubtitleSnapshot(
                handle,
                timeout: 5,
                where: { $0.arrayValue?.isEmpty == true }
            ) != nil
        )

        #expect(mpv_command_string(handle, "sub-add \(srt.path) select") >= 0)
        #expect(waitForSelectedSubtitleCodec(handle, "subrip", timeout: 5))
        let automaticSnapshot = try #require(
            waitForSubtitleSnapshot(
                handle,
                timeout: 5,
                where: { $0.arrayValue?.count == 1 }
            )
        )
        let automaticRegion = try #require(automaticSnapshot.arrayValue?.first?.mapValue)
        #expect((automaticRegion["text"]?.stringValue) == "automatic")
        #expect(automaticRegion["format"] == nil)

        #expect(mpv_set_property_string(handle, "sub-forced-events-only", "yes") >= 0)
        #expect(
            waitForSubtitleSnapshot(
                handle,
                timeout: 5,
                where: { $0.arrayValue?.isEmpty == true }
            ) != nil
        )
    }
    #endif
}

#if os(macOS)
fileprivate extension MPVNativeSubtitleContractTests {
    func waitForMPVEvent(
        _ handle: OpaquePointer,
        id: mpv_event_id,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let event = mpv_wait_event(handle, 0.05) else { continue }
            if event.pointee.event_id == id {
                return true
            }
        }
        return false
    }

    func waitForSelectedSubtitleCodec(
        _ handle: OpaquePointer,
        _ expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let tracks = MPVEngine.parseTracks(copiedMPVNode(handle, property: "track-list"))
            if tracks.contains(where: {
                $0.type == .subtitle && $0.isSelected && $0.codec == expected
            }) {
                return true
            }
            _ = mpv_wait_event(handle, 0.05)
        }
        return false
    }

    func waitForSubtitleSnapshot(
        _ handle: OpaquePointer,
        timeout: TimeInterval,
        where predicate: (MPVNodeValue) -> Bool
    ) -> MPVNodeValue? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let node = copiedMPVNode(handle, property: "sub-text-snapshot"),
               predicate(node)
            {
                return node
            }
            _ = mpv_wait_event(handle, 0.05)
        }
        return nil
    }

    func copiedMPVNode(
        _ handle: OpaquePointer,
        property: String
    ) -> MPVNodeValue? {
        var node = mpv_node()
        guard mpv_get_property(handle, property, MPV_FORMAT_NODE, &node) >= 0 else {
            return nil
        }
        defer { mpv_free_node_contents(&node) }
        return MPVNodeValue(copying: node)
    }
}
#endif
