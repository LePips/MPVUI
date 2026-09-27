"""Reject stale app reuse and incomplete/failed physical regression evidence."""

import argparse
import copy
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Benchmarks"))
import device_regression as regression


class DeviceRegressionTests(unittest.TestCase):
    def setUp(self):
        self.args = SimpleNamespace(backend="sampleBuffer", software_decoding=False)
        self.media = Path("fixture.mp4")

    def segment(self, stage, rate=1):
        return {
            "stage": stage,
            "maximumAllowedDroppedFrames": 0,
            "decoderDroppedFramesDelta": 0,
            "outputDroppedFramesDelta": 0,
            "observationSeconds": 3.1,
            "playbackProgressSeconds": 3 * rate,
            "expectedPlaybackRate": rate,
            "observedPlaybackRate": rate,
            "nativeSampleBuildCountDelta": 72,
        }

    def raw(self):
        checks = []
        for cycle in range(1, 4):
            prefix = f"cycle-{cycle}"
            checks.extend(
                [
                    self.segment(prefix + "-start"),
                    self.segment(prefix + "-resume"),
                    {"stage": prefix + "-replay", "replayInitialPositionSeconds": 0.3},
                    self.segment(prefix + "-replay"),
                    {"stage": prefix + "-pause", "positionDeltaSeconds": 0},
                    {
                        "stage": prefix + "-seek",
                        "targetSeconds": 10,
                        "observedPositionSeconds": 10,
                        "nativeSampleResetObserved": True,
                        "nativeResetBaseline": 0,
                        "nativePreSeekSampleBuildCount": 200,
                        "nativePostSeekSampleBuildCount": 1,
                    },
                    {
                        "stage": prefix + "-stop-retained",
                        "stateRemainedStopped": True,
                        "publishedActivityUnchanged": True,
                        "publishedNativeSamplesUnchanged": True,
                    },
                ]
            )
        checks.extend([self.segment("typed-load-resume"), {"stage": "release", "playerDeallocated": True}])
        checks.extend(
            self.segment("rate-" + name, rate) for name, rate in (("slow", 0.5), ("fast", 1.5), ("normal", 1))
        )
        return {
            "schemaVersion": 2,
            "status": "passed",
            "error": None,
            "configuration": {
                "backend": "sampleBuffer",
                "resolvedBackend": "sampleBuffer",
                "softwareDecoding": False,
                "cycles": 3,
                "media": "file:///Documents/fixture.mp4",
            },
            "checks": checks,
            "checkpoints": [{"state": "playing", "effectiveBackend": "sampleBuffer"}],
        }

    def validate(self, raw):
        regression.validate_report(raw, self.args, self.media, None)

    def test_backend_and_software_launch_are_explicit(self):
        parser = argparse.ArgumentParser()
        regression.add_arguments(parser.add_subparsers(dest="command"))
        args = parser.parse_args(
            [
                "device-regression",
                "--device",
                "chosen",
                "--media",
                "fixture.mp4",
                "--backend",
                "sampleBuffer",
                "--software-decoding",
            ]
        )
        launch = regression.launch_arguments(args, "fixture.mp4", "unique.json")
        self.assertEqual(launch[launch.index("--regression-backend") + 1], "sampleBuffer")
        self.assertIn("--regression-software-decoding", launch)
        self.assertNotIn("--playback-benchmark", launch)

    def test_complete_native_report_passes_and_failed_app_report_never_does(self):
        self.validate(self.raw())
        raw = self.raw()
        raw.update(status="failed", error="Native samples stopped")
        with self.assertRaisesRegex(ValueError, "Native samples stopped"):
            self.validate(raw)

    def test_mismatched_config_media_and_backend_cannot_pass(self):
        for key, value in (
            ("backend", "metal"),
            ("resolvedBackend", "metal"),
            ("cycles", 2),
            ("softwareDecoding", True),
            ("media", "file:///Documents/different.mp4"),
        ):
            raw = self.raw()
            raw["configuration"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.validate(raw)
        raw = self.raw()
        raw["checkpoints"][0]["effectiveBackend"] = "metal"
        with self.assertRaisesRegex(ValueError, "fallback"):
            self.validate(raw)

    def test_drop_stall_missing_counter_and_stale_native_counter_fail(self):
        for key, value in (
            ("decoderDroppedFramesDelta", 1),
            ("outputDroppedFramesDelta", 1),
            ("decoderDroppedFramesDelta", None),
            ("outputDroppedFramesDelta", False),
            ("playbackProgressSeconds", 1),
            ("observationSeconds", float("nan")),
            ("nativeSampleBuildCountDelta", 0),
        ):
            raw = self.raw()
            raw["checks"][0][key] = value
            with self.subTest(key=key, value=value), self.assertRaisesRegex(ValueError, "settled playback"):
                self.validate(raw)

    def test_every_cycle_stop_seek_replay_and_release_evidence_is_required(self):
        for stage in (
            "cycle-1-start",
            "cycle-2-stop-retained",
            "cycle-3-seek",
            "typed-load-resume",
            "rate-fast",
            "release",
        ):
            raw = self.raw()
            raw["checks"] = [check for check in raw["checks"] if check["stage"] != stage]
            with self.subTest(stage=stage), self.assertRaises(ValueError):
                self.validate(raw)
        raw = self.raw()
        replay = next(check for check in raw["checks"] if "replayInitialPositionSeconds" in check)
        replay["replayInitialPositionSeconds"] = 5
        with self.assertRaisesRegex(ValueError, "from zero"):
            self.validate(raw)

    def test_rate_changes_require_scaled_clock_progress_and_restoration(self):
        for stage in ("rate-slow", "rate-fast", "rate-normal"):
            for field, value in (
                ("playbackProgressSeconds", 0.1),
                ("playbackProgressSeconds", 20),
                ("expectedPlaybackRate", 2),
                ("observedPlaybackRate", 2),
            ):
                raw = self.raw()
                next(check for check in raw["checks"] if check["stage"] == stage)[field] = value
                with self.subTest(stage=stage, field=field), self.assertRaisesRegex(ValueError, "playback-rate"):
                    self.validate(raw)
        raw = self.raw()
        seek = next(check for check in raw["checks"] if check["stage"] == "cycle-1-seek")
        seek["nativePostSeekSampleBuildCount"] = seek["nativePreSeekSampleBuildCount"]
        with self.assertRaisesRegex(ValueError, "seek-generation"):
            self.validate(raw)

    def test_stale_source_xcode_or_app_prevents_skip_build(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "MPVUIExample.app"
            app.mkdir()
            binary = app / "MPVUIExample"
            binary.write_bytes(b"built app")
            expected = {"source": "current-source", "xcode": "current-xcode"}
            saved = dict(expected, appSHA256=regression.digest(binary))
            regression.validate_build(saved, expected, app)
            for key in ("source", "xcode", "appSHA256"):
                changed = copy.deepcopy(saved)
                changed[key] = "stale"
                with self.subTest(key=key), self.assertRaisesRegex(ValueError, "Stale or missing"):
                    regression.validate_build(changed, expected, app)
            binary.write_bytes(b"changed app")
            with self.assertRaisesRegex(ValueError, "Stale or missing"):
                regression.validate_build(saved, expected, app)


if __name__ == "__main__":
    unittest.main()
