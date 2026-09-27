import contextlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Benchmarks"))
import run_device_sync_probe as runner


class SyncRunnerTests(unittest.TestCase):
    def fixtures(self, directory):
        config = {"directMediaSHA256": "direct", "hlsMediaSHA256": "hls"}
        paths = []
        for workload, cadence in sorted(runner.EXPECTED):
            frame = {
                "boundary": "beforeSteady",
                "queryBeginElapsedSeconds": 2,
                "metricsEndElapsedSeconds": 2.01,
                "readbackEndElapsedSeconds": 2.02,
                "totalNumberOfFrames": 48,
                "numberOfDroppedFrames": 0,
                "numberOfCorruptedFrames": 0,
                "totalAccumulatedFrameDelaySeconds": 0.1,
                "displayedPixelBufferAvailable": True,
                "displayedWidth": 640,
                "displayedHeight": 360,
            }
            after = dict(
                frame,
                boundary="afterSteady",
                queryBeginElapsedSeconds=5,
                metricsEndElapsedSeconds=5.01,
                readbackEndElapsedSeconds=5.02,
                totalNumberOfFrames=120,
            )
            report = {
                "schemaVersion": 1,
                "configurationSHA256": "current",
                "status": "passed",
                "workload": workload,
                "queryIntervalMilliseconds": cadence,
                "mediaSHA256": config[workload + "MediaSHA256"],
                "directBytesVerifiedOnDevice": workload == "direct",
                "frameworkSamples": [frame, after],
            }
            path = directory / f"{workload}-{cadence}.json"
            path.write_text(json.dumps(report))
            paths.append(path)
        return paths, config

    def test_requires_four_fresh_cases_and_filters_old_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, config = self.fixtures(Path(tmp))
            self.assertEqual(len(runner.validate_reports(paths, config, "current")), 4)
            with self.assertRaisesRegex(ValueError, "four fresh"):
                runner.validate_reports(paths[:3], config, "current")
            with self.assertRaisesRegex(ValueError, "four fresh"):
                runner.validate_reports(paths, config, "old")

    def test_framework_drop_missing_readback_and_delay_reset_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, config = self.fixtures(Path(tmp))
            original = paths[0].read_text()
            for field, value in (
                ("numberOfDroppedFrames", 1),
                ("displayedPixelBufferAvailable", False),
                ("totalAccumulatedFrameDelaySeconds", 0),
                ("totalNumberOfFrames", 48),
            ):
                report = json.loads(original)
                report["frameworkSamples"][1][field] = value
                paths[0].write_text(json.dumps(report))
                with self.subTest(field=field), self.assertRaises(ValueError):
                    runner.validate_reports(paths, config, "current")

    def test_duplicate_case_and_wrong_media_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, config = self.fixtures(Path(tmp))
            with self.assertRaisesRegex(ValueError, "duplicate"):
                runner.validate_reports(paths + [paths[0]], config, "current")
            report = json.loads(paths[0].read_text())
            report["mediaSHA256"] = "wrong"
            paths[0].write_text(json.dumps(report))
            with self.assertRaisesRegex(ValueError, "media"):
                runner.validate_reports(paths, config, "current")

    def test_server_path_mapping_and_fixed_port_without_binding(self):
        hls = Path("/fixtures/hls/index.m3u8")
        self.assertEqual(
            runner.serve_settings(hls, {"hlsURL": "http://127.0.0.1:8765/index.m3u8"}, "127.0.0.1"), hls.parent
        )
        self.assertEqual(
            runner.serve_settings(hls, {"hlsURL": "http://127.0.0.1:8765/hls/index.m3u8"}, "127.0.0.1"),
            hls.parent.parent,
        )
        for url in (
            "http://127.0.0.1:80/index.m3u8",
            "http://wrong:8765/index.m3u8",
            "http://127.0.0.1:8765/wrong/index.m3u8",
        ):
            with self.assertRaises(ValueError):
                runner.serve_settings(hls, {"hlsURL": url}, "127.0.0.1")

    def test_device_listing_extracts_only_report_basenames(self):
        name = "native-sync-direct-50ms-12345678-1234-1234-1234-123456789abc.json"
        result = {"result": {"files": [{"name": name}, {"path": "Documents/" + name}, {"name": "unrelated.json"}]}}
        self.assertEqual(runner.report_names(result), [name])

    def test_release_testability_and_only_sync_suite_are_explicit(self):
        args = SimpleNamespace(project=Path("/tmp/project"), derived_data=Path("/tmp/dd"), device="explicit")
        result = runner.test_arguments(args)
        self.assertEqual(result["configuration"], "Release")
        self.assertIn("ENABLE_TESTABILITY=YES", result["extraArgs"])
        self.assertEqual(
            [v for v in result["extraArgs"] if v.startswith("-only-testing:")], ["-only-testing:" + runner.SUITE]
        )

    def test_unknown_schema_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths, config = self.fixtures(Path(tmp))
            report = json.loads(paths[0].read_text())
            report["schemaVersion"] = 99
            paths[0].write_text(json.dumps(report))
            with self.assertRaisesRegex(ValueError, "schema"):
                runner.validate_reports(paths, config, "current")

    def test_dry_run_leaves_config_unchanged_and_never_starts_device_or_server(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            project = root / "tests.xcodeproj"
            project.mkdir()
            config = root / "config.json"
            config.write_text(json.dumps({"hlsURL": "http://127.0.0.1:8765/index.m3u8"}))
            before = config.read_bytes()
            output = root / "new-evidence"
            argv = [
                "run_device_sync_probe.py",
                "--device",
                "unused",
                "--host",
                "127.0.0.1",
                "--direct",
                str(root / "direct.mp4"),
                "--hls",
                str(root / "index.m3u8"),
                "--configuration",
                str(config),
                "--project",
                str(project),
                "--output",
                str(output),
            ]
            fixture = SimpleNamespace(recheck=lambda *_: {"synthetic": "verified"})
            with patch.object(sys, "argv", argv), patch.object(runner, "helper", return_value=fixture), patch.object(
                runner, "command", side_effect=AssertionError("Device command attempted")
            ), patch.object(runner, "managed_server", side_effect=AssertionError("Server started")), patch.object(
                runner, "measurement_lock", side_effect=AssertionError("Measurement lock acquired")
            ), contextlib.redirect_stdout(io.StringIO()) as text:
                runner.main()
            self.assertIn("local validation passed", text.getvalue())
            self.assertFalse(output.exists())
            self.assertEqual(config.read_bytes(), before)

    def test_repository_root_skips_nested_build_package(self):
        device_root = Path(runner.source_identity.__code__.co_filename).resolve().parents[2]
        self.assertTrue((device_root / "Build/Package.swift").is_file())
        self.assertEqual(runner.ROOT, device_root)
        self.assertTrue((runner.ROOT / "Example/MPVUIExample/Shared/PlaybackBenchmark.swift").is_file())

    def test_default_configuration_project_and_products_use_repository_root(self):
        device_root = Path(runner.source_identity.__code__.co_filename).resolve().parents[2]
        with tempfile.TemporaryDirectory() as tmp:
            temp = Path(tmp)
            output = temp / "new-evidence"
            observed = []
            argv = [
                "run_device_sync_probe.py",
                "--device",
                "unused",
                "--host",
                "127.0.0.1",
                "--direct",
                str(temp / "direct.mp4"),
                "--hls",
                str(temp / "index.m3u8"),
                "--output",
                str(output),
            ]

            def recheck(direct, hls, configuration):
                observed.append(configuration)
                return {"synthetic": "verified"}

            fixture = SimpleNamespace(recheck=recheck)
            with patch.object(sys, "argv", argv), patch.object(runner, "helper", return_value=fixture), patch.object(
                Path, "read_text", return_value=json.dumps({"hlsURL": "http://127.0.0.1:8765/index.m3u8"})
            ), patch.object(Path, "is_dir", return_value=True), patch.object(
                runner, "command", side_effect=AssertionError("Device command attempted")
            ), contextlib.redirect_stdout(io.StringIO()) as text:
                runner.main()
            report = json.loads(text.getvalue())
            self.assertEqual(
                observed, [device_root / ".build/device-tests/GeneratedMedia/native-sync-configuration.json"]
            )
            self.assertEqual(
                report["testArguments"]["projectPath"],
                str(device_root / ".build/device-tests/MPVUIRegressionTests.xcodeproj"),
            )
            self.assertEqual(
                report["testArguments"]["derivedDataPath"], str(device_root / ".build/device-tests/DerivedData")
            )
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
