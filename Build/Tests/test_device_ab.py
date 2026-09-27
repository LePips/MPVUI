"""Alternating device cohort guards using synthetic raw observations only."""

import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Benchmarks"))
import run_device_ab as ab

ROOT = Path(__file__).resolve().parents[2]


class DeviceABTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.harness = ab.load_harness(ROOT)
        self.cohort = {
            "checkout": str(ROOT),
            "derivedData": str(self.directory / "DerivedData"),
            "appSHA256": "synthetic-app",
            "xcode": "synthetic-xcode",
            "stampSHA256": "synthetic-stamp",
            "source": {"sourceSHA256": "synthetic-source", "files": {"Sources/example.swift": "synthetic-file"}},
        }
        self.media = {}
        for workload in ("direct", "hls"):
            path = self.directory / ("direct.mp4" if workload == "direct" else "index.m3u8")
            path.write_text(
                "synthetic fixture" if workload == "direct" else "#EXTM3U\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n"
            )
            if workload == "hls":
                (self.directory / "segment.ts").write_text("synthetic encoded segment")
            self.media[workload] = {
                "path": str(path),
                "media": self.harness.media_identity(path),
                "parameters": {
                    "player": "mpv",
                    "backend": "default",
                    "options": [],
                    "sampleSeconds": 30.0,
                    "warmupSeconds": 5.0,
                    "sdrOutput": "automatic",
                    "softwareDecoding": False,
                    "transport": "file" if workload == "direct" else "http",
                    "mediaSHA256": self.harness.media_identity(path)["sha256"],
                },
            }
        self.key = self.single()["environment"]["comparisonKey"]

    def raw(self, created_at="2026-01-01T00:00:00Z"):
        env = {
            "hardwareModel": "synthetic-iPad",
            "operatingSystem": "synthetic-os",
            "lowPowerMode": False,
            "batteryState": 2,
            "surfaceWidthPoints": 1000,
            "surfaceHeightPoints": 750,
            "screenScale": 2,
            "maximumFramesPerSecond": 60,
            "audioSampleRate": 48000,
            "audioOutputChannels": 2,
            "audioIOBufferSeconds": 0.01,
            "audioRoute": "Speaker",
            "systemOutputVolume": 0,
            "isSimulator": False,
            "thermalState": 0,
        }
        env["after"] = dict(env)

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
            "createdAt": created_at,
            "configuration": {
                "player": "mpv",
                "sampleSeconds": 30,
                "warmupSeconds": 5,
                "options": {},
                "softwareDecoding": False,
                "sdrOutput": "automatic",
                "resolvedBackend": "sampleBuffer",
                "backend": "default",
            },
            "environment": env,
            "metrics": {"steadyCpuSecondsPerWallSecond": 0.04},
            "phases": {"steady": {"wallSeconds": 30, "diagnosticSamples": [diagnostic(101), diagnostic(800)]}},
            "diagnostics": {"steadyStart": diagnostic(100), "steadyEnd": diagnostic(819)},
            "validation": {"steadyProgressSeconds": 30, "steadyProgressPerWallSecond": 1},
        }

    def single(self, workload="direct", created_at="2026-01-01T00:00:00Z"):
        return self.harness.aggregate(
            [self.raw(created_at)],
            source=copy.deepcopy(self.cohort["source"]),
            media=copy.deepcopy(self.media[workload]["media"]),
            args=ab.aggregate_args("synthetic", self.media[workload]["parameters"], 1),
            device={"model": "synthetic-iPad"},
            xcode=self.cohort["xcode"],
            app_hash=self.cohort["appSHA256"],
        )

    def test_repository_root_skips_nested_build_package(self):
        self.assertTrue((ROOT / "Build/Package.swift").is_file())
        self.assertTrue((ROOT / "Build/Benchmarks/device_playback.py").is_file())
        self.assertTrue((ROOT / "Example/MPVUIExample/Shared/PlaybackBenchmark.swift").is_file())
        self.assertEqual(self.harness.ROOT, ROOT)

    def test_raw_progress_fallback_and_metric_claims_are_revalidated(self):
        self.assertEqual(
            ab.validate_single(self.single(), self.cohort, self.media["direct"], self.key, self.harness)["status"],
            "passed",
        )
        for mutate in (
            lambda r: r["workloads"][0]["observations"][0]["validation"].update(steadyProgressSeconds=0),
            lambda r: r["workloads"][0]["observations"][0]["phases"]["steady"]["diagnosticSamples"][0].update(
                fallbackReasons=["fallback"]
            ),
            lambda r: r["workloads"][0]["metrics"]["steadyCpuSecondsPerWallSecond"].update(samples=[0]),
        ):
            report = self.single()
            mutate(report)
            with self.assertRaises(ValueError):
                ab.validate_single(report, self.cohort, self.media["direct"], self.key, self.harness)

    def test_source_app_environment_protocol_and_parameters_cannot_mix(self):
        for mutate in (
            lambda r: r["source"].update(sourceSHA256="different"),
            lambda r: r["runtime"].update(appSHA256="different"),
            lambda r: r["environment"]["comparisonKey"].update(protocol={}),
            lambda r: r["environment"]["comparisonKey"]["playbackEnvironment"].update(systemOutputVolume=1),
            lambda r: r["workloads"][0]["parameters"].update(backend="sampleBuffer"),
            lambda r: r["configuration"].update(repetitions=3),
        ):
            report = self.single()
            mutate(report)
            with self.assertRaises(ValueError):
                ab.validate_single(report, self.cohort, self.media["direct"], self.key, self.harness)

    def plan(self):
        steps = []
        for workload in ("direct", "hls"):
            for position, cohort in enumerate(ab.ORDER, 1):
                ordinal = len(steps) + 1
                name = f"synthetic-{ordinal}.json"
                ab.write_new(self.directory / name, self.single(workload, f"2026-01-01T00:00:{ordinal:02}Z"))
                steps.append({"workload": workload, "cohort": cohort, "position": position, "report": name})
        plan = {
            "procedure": ab.PROCEDURE,
            "steps": steps,
            "cohorts": {"A": self.cohort, "B": self.cohort},
            "comparisonKey": self.key,
            "workloads": self.media,
        }
        path = self.directory / "plan.json"
        ab.write_new(path, plan)
        return path

    def assemble(self, path):
        with patch.object(ab, "checkout_identity", return_value=self.cohort), patch.object(
            ab, "load_harness", return_value=self.harness
        ):
            return ab.assemble(path)

    def test_assembly_preserves_inputs_and_matching_procedure(self):
        path = self.plan()
        before = {p.name: ab.digest(p) for p in self.directory.glob("synthetic-*.json")}
        outputs = self.assemble(path)
        self.assertEqual(len(outputs), 4)
        for output in outputs:
            report = ab.read(output)
            self.assertEqual(report["configuration"]["repetitions"], 3)
            self.assertEqual(len(report["workloads"][0]["observations"]), 3)
            self.assertEqual(report["environment"]["comparisonKey"]["independentInstallationSchedule"], ab.PROCEDURE)
            self.assertEqual(len(report["measurementProcedure"]["inputReports"]), 3)
        self.assertEqual(before, {p.name: ab.digest(p) for p in self.directory.glob("synthetic-*.json")})
        with self.assertRaises(FileExistsError):
            self.assemble(path)

    def test_assembly_rejects_duplicate_processes(self):
        path = self.plan()
        plan = ab.read(path)
        (self.directory / plan["steps"][1]["report"]).write_bytes(
            (self.directory / plan["steps"][0]["report"]).read_bytes()
        )
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.assemble(path)

    def test_assembly_rejects_changed_order_or_frozen_source(self):
        path = self.plan()
        plan = ab.read(path)
        plan["steps"][0]["cohort"] = "B"
        path.write_text(json.dumps(plan))
        with self.assertRaisesRegex(ValueError, "sequence"):
            self.assemble(path)
        changed = copy.deepcopy(self.cohort)
        changed["source"]["files"] = {}
        with self.assertRaisesRegex(ValueError, "source changed"):
            ab.assert_frozen(changed, self.cohort)

    def test_stamp_must_match_actual_executable_and_source(self):
        root = self.directory / "checkout"
        bench = root / "Build/Benchmarks"
        bench.mkdir(parents=True)
        (bench / "device_playback.py").write_text(
            'def source_identity(): return {"sourceSHA256":"synthetic-source","files":{}}\n'
        )
        derived = self.directory / "build"
        app = derived / "Build/Products/Release-iphoneos/MPVUIExample.app/MPVUIExample"
        app.parent.mkdir(parents=True)
        app.write_text("synthetic executable")
        stamp = derived / "mpvui-benchmark-build.json"
        ab.write_new(stamp, {"source": "synthetic-source", "appSHA256": ab.digest(app), "xcode": "synthetic-xcode"})
        self.assertEqual(ab.checkout_identity(root, derived)["appSHA256"], ab.digest(app))
        app.write_text("changed executable")
        with self.assertRaisesRegex(ValueError, "Stale"):
            ab.checkout_identity(root, derived)

    def test_dry_run_contacts_no_device_and_writes_no_output(self):
        refs = {}
        for name in ("direct", "hls"):
            refs[name] = self.directory / (name + "-reference.json")
            ab.write_new(refs[name], self.single(name))
        args = SimpleNamespace(
            output=self.directory / "new-evidence",
            baseline_checkout=ROOT,
            baseline_derived=Path(self.cohort["derivedData"]),
            candidate_checkout=ROOT,
            candidate_derived=Path(self.cohort["derivedData"]),
            direct_reference=refs["direct"],
            hls_reference=refs["hls"],
            direct=Path(self.media["direct"]["path"]),
            hls=Path(self.media["hls"]["path"]),
            execute=False,
            device="unused",
            host="unused",
        )
        with patch.object(ab, "checkout_identity", return_value=self.cohort), patch.object(
            ab, "load_harness", return_value=self.harness
        ), patch.object(
            ab.subprocess, "run", side_effect=AssertionError("Device operation attempted")
        ), contextlib.redirect_stdout(io.StringIO()) as output:
            ab.run(args)
        self.assertIn("validated dry run", output.getvalue())
        self.assertFalse(args.output.exists())


if __name__ == "__main__":
    unittest.main()
