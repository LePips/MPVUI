"""Input identity and report guards for physical-device playback measurements."""

from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Benchmarks"))
import benchmark
import device_playback as device


class DeviceBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def test_hls_identity_covers_nested_playlists_keys_maps_and_segments(self):
        master = self.write("master.m3u8", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvideo/stream.m3u8\n")
        self.write(
            "video/stream.m3u8",
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
            '#EXT-X-MAP:URI="init.mp4"\n#EXTINF:2,\nsegment.m4s\n'
            "#EXTINF:2,\nsegment.m4s\n#EXT-X-ENDLIST\n",
        )
        self.write("video/key.bin", "encryption key fixture")
        self.write("video/init.mp4", "initialization fixture")
        segment = self.write("video/segment.m4s", "encoded segment fixture")
        before = device.media_identity(master)
        self.assertEqual(
            set(before["files"]),
            {
                "master.m3u8",
                "video/stream.m3u8",
                "video/key.bin",
                "video/init.mp4",
                "video/segment.m4s",
            },
        )
        self.assertEqual(device.media_identity(master), before)
        segment.write_text("changed encoded segment")
        self.assertNotEqual(device.media_identity(master)["sha256"], before["sha256"])

    def test_hls_cycles_are_hashed_once(self):
        master = self.write("master.m3u8", "#EXTM3U\nchild.m3u8\n")
        self.write("child.m3u8", "#EXTM3U\nmaster.m3u8\n")
        self.assertEqual(set(device.media_identity(master)["files"]), {"master.m3u8", "child.m3u8"})

    def test_hls_rejects_remote_credential_and_outside_directory_references(self):
        master = self.write("media/master.m3u8", "")
        for reference in (
            "https://example.invalid/segment.ts",
            "segment.ts?token=secret",
            "segment.ts#fragment",
            "../outside.ts",
            "/absolute.ts",
        ):
            with self.subTest(reference=reference):
                master.write_text("#EXTM3U\n" + reference + "\n")
                with self.assertRaises(ValueError):
                    device.media_identity(master)
        outside = self.write("outside.ts", "outside fixture")
        (master.parent / "link.ts").symlink_to(outside)
        master.write_text("#EXTM3U\nlink.ts\n")
        with self.assertRaisesRegex(ValueError, "escapes the media directory"):
            device.media_identity(master)

    def test_missing_hls_resource_prevents_a_partial_identity(self):
        master = self.write("master.m3u8", "#EXTM3U\nmissing.ts\n")
        with self.assertRaisesRegex(ValueError, "Missing HLS resource"):
            device.media_identity(master)

    def test_hls_requires_http_transport(self):
        playlist = self.write("master.m3u8", "#EXTM3U\n")
        with self.assertRaisesRegex(ValueError, "HLS requires --host"):
            with device.serve_media(playlist, None):
                self.fail("An HLS benchmark must not silently use local-file transport")
        mp4 = self.write("direct.mp4", "encoded fixture")
        with device.serve_media(mp4, None) as url:
            self.assertIsNone(url)

    def test_build_identity_changes_when_app_or_benchmark_protocol_changes(self):
        app = self.write("Example/MPVUIExample/Shared/PlaybackBenchmark.swift", "app protocol v1")
        runner = self.write("Build/Benchmarks/device_playback.py", "host protocol v1")
        self.write("Package.swift", "// remote binary selection")
        self.write("Example/MPVUIExample/MPVUIExample.xcodeproj/project.pbxproj", "project configuration")
        with patch.object(device, "ROOT", self.root), patch.object(
            benchmark, "source_identity", side_effect=lambda _: {"files": {"Sources/Player.swift": "source"}}
        ):
            initial = device.source_identity()
            app.write_text("app protocol v2")
            changed_app = device.source_identity()
            self.assertNotEqual(initial["sourceSHA256"], changed_app["sourceSHA256"])
            runner.write_text("host protocol v2")
            self.assertNotEqual(changed_app["sourceSHA256"], device.source_identity()["sourceSHA256"])

    def raw(self, player="mpv", **metrics):
        environment = {
            "hardwareModel": "iPad",
            "operatingSystem": "test",
            "lowPowerMode": False,
            "batteryState": 2,
            "surfaceWidthPoints": 1000,
            "surfaceHeightPoints": 750,
            "screenScale": 2,
            "maximumFramesPerSecond": 60,
            "audioSampleRate": 48000,
            "audioOutputChannels": 2,
            "audioIOBufferSeconds": 0.01,
            "audioRoute": "speaker",
            "systemOutputVolume": 0.5,
            "isSimulator": False,
            "thermalState": 0,
        }
        environment["after"] = dict(environment)
        configuration = {
            "player": player,
            "sampleSeconds": 30,
            "warmupSeconds": 5,
            "options": {},
            "softwareDecoding": False,
            "sdrOutput": "automatic",
            "resolvedBackend": "sampleBuffer" if player == "mpv" else "AVPlayerLayer",
            "backend": "sampleBuffer" if player == "mpv" else "AVPlayerLayer",
        }

        def diagnostic(count):
            return {
                "effectiveBackend": "sampleBuffer",
                "videoOutputFallbackReason": None,
                "decoderFallbackReason": None,
                "fallbackReasons": [],
                "decoderSession": "videotoolbox",
                "videoToolboxSessionUsesHardware": True,
                "decoderDroppedFrames": 0,
                "outputDroppedFrames": 0,
                "nativeSampleBuildCount": count,
            }

        return {
            "schemaVersion": 4,
            "status": "passed",
            "configuration": configuration,
            "environment": environment,
            "metrics": metrics,
            "phases": {"steady": {"wallSeconds": 30, "diagnosticSamples": [diagnostic(101), diagnostic(800)]}},
            "diagnostics": {"steadyStart": diagnostic(100), "steadyEnd": diagnostic(819)},
            "validation": {"steadyProgressSeconds": 30, "steadyProgressPerWallSecond": 1},
        }

    def aggregate(self, runs):
        args = SimpleNamespace(
            label="fixture",
            host=None,
            seconds=30,
            warmup=5,
            players="mpv,avplayer",
            repetitions=2,
            backend="sampleBuffer",
            software_decoding=False,
            option=[],
            sdr_output="automatic",
        )
        with patch.object(device, "digest", return_value="protocol digest"):
            return device.aggregate(
                runs,
                source={"sourceSHA256": "source"},
                media={"sha256": "media"},
                args=args,
                device={"model": "iPad"},
                xcode="test",
                app_hash="app",
            )

    def test_progress_rate_uses_actual_elapsed_time_when_sampling_is_delayed(self):
        raw = self.raw(cpuSecondsPerWallSecond=0.1)
        raw["phases"]["steady"]["wallSeconds"] = 33
        raw["validation"].update(steadyProgressSeconds=32, steadyProgressPerWallSecond=32 / 33)
        self.aggregate([raw])
        # A delayed sample can exceed its requested 30-second interval. Using
        # the request would falsely report playback faster than its media clock.
        raw["validation"]["steadyProgressPerWallSecond"] = 32 / 30
        with self.assertRaisesRegex(ValueError, "observed phase wall time"):
            self.aggregate([raw])
        for invalid_wall in (None, 0, float("nan"), True):
            raw["phases"]["steady"]["wallSeconds"] = invalid_wall
            with self.subTest(wall=invalid_wall), self.assertRaisesRegex(ValueError, "finite steady"):
                self.aggregate([raw])
        raw = self.raw()
        raw["schemaVersion"] = 2
        with self.assertRaisesRegex(ValueError, "protocol 4"):
            self.aggregate([raw])

    def test_progress_outside_normal_rate_is_rejected(self):
        for rate in (0.7, 1.3):
            raw = self.raw()
            raw["validation"].update(steadyProgressSeconds=30 * rate, steadyProgressPerWallSecond=rate)
            with self.subTest(rate=rate), self.assertRaisesRegex(ValueError, "expected 1x rate"):
                self.aggregate([raw])

    def test_runtime_decoder_and_transient_published_fallback_evidence_is_required(self):
        for key, value in (
            ("videoToolboxSessionUsesHardware", None),
            ("decoderSession", "software"),
            ("decoderFallbackReason", "hardware fallback"),
            ("fallbackReasons", ["fallback"]),
            ("effectiveBackend", "metal"),
        ):
            raw = self.raw()
            # Endpoints remain healthy: an intervening published state still fails.
            raw["phases"]["steady"]["diagnosticSamples"][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.aggregate([raw])

    def test_drop_missing_reset_and_frame_nonprogress_are_rejected(self):
        for key, value in (
            ("decoderDroppedFrames", 1),
            ("outputDroppedFrames", None),
            ("outputDroppedFrames", False),
            ("nativeSampleBuildCount", 0),
            ("nativeSampleBuildCount", None),
        ):
            raw = self.raw()
            raw["phases"]["steady"]["diagnosticSamples"][1][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.aggregate([raw])
        raw = self.raw()
        raw["phases"]["steady"]["diagnosticSamples"] = []
        with self.assertRaisesRegex(ValueError, "newly published"):
            self.aggregate([raw])

    def test_forced_software_requires_runtime_evidence_and_not_codec_capability(self):
        raw = self.raw()
        raw["configuration"]["softwareDecoding"] = True
        evidence = [*raw["diagnostics"].values(), *raw["phases"]["steady"]["diagnosticSamples"]]
        for sample in evidence:
            sample.update(
                decoderSession="software",
                videoToolboxSessionUsesHardware=False,
                decodedPixelFormat="yuv420p",
                videoToolboxSupportsCodec=True,
            )
        device.validate_steady_diagnostics(raw)
        evidence[1]["videoToolboxSessionUsesHardware"] = True
        with self.assertRaisesRegex(ValueError, "software-decoder"):
            device.validate_steady_diagnostics(raw)

    def test_failed_device_validation_cannot_become_a_comparison_report(self):
        raw = self.raw(cpuSecondsPerWallSecond=0.1)
        raw.update(status="failed", error="Playback stalled")
        with self.assertRaisesRegex(ValueError, "Playback stalled"):
            self.aggregate([raw])

    def test_aggregation_preserves_independent_player_samples_and_unknown_metrics(self):
        report = self.aggregate(
            [
                self.raw(cpuSecondsPerWallSecond=0.1, peakFootprintBytes=120, unknown=None, flag=True),
                self.raw("avplayer", cpuSecondsPerWallSecond=0.02, peakFootprintBytes=100),
                self.raw(cpuSecondsPerWallSecond=0.12, peakFootprintBytes=125, invalid=float("nan")),
                self.raw("avplayer", cpuSecondsPerWallSecond=0.03, peakFootprintBytes=105),
            ]
        )
        workloads = {workload["parameters"]["player"]: workload for workload in report["workloads"]}
        metrics = workloads["mpv"]["metrics"]
        self.assertEqual(metrics["cpuSecondsPerWallSecond"]["samples"], [0.1, 0.12])
        self.assertEqual(metrics["cpuSecondsPerWallSecond"]["unit"], "cpu-seconds/wall-second")
        self.assertEqual(metrics["peakFootprintBytes"]["samples"], [120, 125])
        self.assertEqual(metrics["peakFootprintBytes"]["unit"], "bytes")
        self.assertFalse({"unknown", "invalid", "flag"} & metrics.keys())
        self.assertEqual(workloads["avplayer"]["metrics"]["peakFootprintBytes"]["samples"], [100, 105])
        self.assertEqual(len(workloads["mpv"]["observations"]), 2)
        self.assertEqual(len(report["environment"]["runs"]), 4)

    def test_configuration_mismatch_cannot_be_aggregated_under_requested_settings(self):
        for key, value in (
            ("sampleSeconds", 10),
            ("warmupSeconds", 1),
            ("backend", "metal"),
            ("softwareDecoding", True),
            ("options", {"hwdec": "no"}),
            ("player", "unknown"),
        ):
            raw = self.raw(cpuSecondsPerWallSecond=0.1)
            raw["configuration"][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "configuration differs"):
                self.aggregate([raw])

    def test_changed_route_and_thermal_state_reject_incomparable_measurements(self):
        raw = self.raw(cpuSecondsPerWallSecond=0.1)
        raw["environment"]["after"]["audioRoute"] = "headphones"
        with self.assertRaisesRegex(ValueError, "changed during a run"):
            self.aggregate([raw])
        first, second = self.raw(), self.raw()
        second["environment"]["audioRoute"] = "headphones"
        second["environment"]["after"]["audioRoute"] = "headphones"
        with self.assertRaisesRegex(ValueError, "changed between runs"):
            self.aggregate([first, second])
        for field, value in (("thermalState", 1), ("isSimulator", True)):
            raw = self.raw()
            raw["environment"][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(
                ValueError, "physical device at nominal thermal state"
            ):
                self.aggregate([raw])
        raw = self.raw()
        raw["timeline"] = [{"thermalState": 0}, {"thermalState": 1}, {"thermalState": 0}]
        with self.assertRaisesRegex(ValueError, "Thermal state changed during measurement"):
            self.aggregate([raw])

    def test_local_native_binary_changes_invalidate_build_identity(self):
        import plistlib

        self.write("Package.swift", '.binaryTarget(name: "Libmpv-GPL", path: "Local.xcframework")')
        binary = self.write("Local.xcframework/ios-arm64/Libmpv.framework/Libmpv", "binary version one")
        (self.root / "Local.xcframework/Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "AvailableLibraries": [
                        {
                            "SupportedPlatform": "ios",
                            "LibraryIdentifier": "ios-arm64",
                            "LibraryPath": "Libmpv.framework",
                        }
                    ]
                }
            )
        )
        with patch.object(device, "ROOT", self.root), patch.object(
            benchmark, "source_identity", side_effect=lambda _: {"files": {}}
        ):
            before = device.source_identity()
            binary.write_text("binary version two")
            self.assertNotEqual(before["sourceSHA256"], device.source_identity()["sourceSHA256"])


if __name__ == "__main__":
    unittest.main()
