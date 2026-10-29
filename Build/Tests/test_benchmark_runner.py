"""Filesystem and input guards for local benchmark capture."""

import argparse
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Benchmarks"))
import benchmark
from test_benchmark_comparison import report


class RunnerTests(unittest.TestCase):
    def test_capture_summary_preserves_units_ranges_and_sample_counts(self):
        measured = report([8, 10, 12])
        summary = benchmark.measurement_summary(benchmark.compare_reports(measured, measured))
        self.assertEqual(
            summary["metrics"], [dict(workload="decode", metric="elapsed", unit="ms", median=10, min=8, max=12, sampleCount=3)]
        )

    def test_comparison_summary_keeps_gate_validity_and_prioritizes_regressions(self):
        before, after = report(), report()
        for index in range(25):
            for document in (before, after):
                workload = copy.deepcopy(document["workloads"][0])
                workload["id"] = f"workload-{index}"
                document["workloads"].append(workload)
        after["workloads"][-1]["metrics"]["elapsed"]["samples"] = [100, 100, 100]
        result = benchmark.compare_reports(before, after, regression_percent=5)
        summary = benchmark.comparison_summary(result)
        self.assertTrue(summary["thresholdsEvaluated"])
        self.assertTrue(summary["hasRegressions"])
        self.assertTrue(summary["metrics"][0]["regression"])
        self.assertEqual(summary["omittedMetrics"], 6)
        unchecked = benchmark.comparison_summary(benchmark.compare_reports(before, after))
        self.assertFalse(unchecked["thresholdsEvaluated"])
        self.assertIsNone(unchecked["metrics"][0]["regression"])

    def test_compare_publishes_full_json_and_returns_nonzero_for_regression(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            before, after, evidence = (root / name for name in ("before.json", "after.json", "evidence.json"))
            before.write_text(json.dumps(report([10, 10, 10])))
            after.write_text(json.dumps(report([20, 20, 20], label="candidate")))
            with patch.dict(os.environ, {benchmark.EVIDENCE_ENV: str(evidence)}), contextlib.redirect_stdout(io.StringIO()):
                status = benchmark.main(["compare", str(before), str(after), "--fail-regression-percent", "5"])
            result = json.loads(evidence.read_text())
            self.assertEqual(status, 2)
            self.assertEqual(result["summary"]["benchmarkComparison"]["metrics"][0]["percentChange"], 100)
            self.assertTrue(Path(result["artifacts"]["benchmarkComparison"]).is_file())

    def test_manifest_evaluation_uses_the_selected_xcode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            framework = root / "Libmpv.xcframework"
            framework.mkdir()
            (framework / "Info.plist").write_bytes(plistlib.dumps({}))
            developer = root / "PinnedXcode.app/Contents/Developer"
            manifest = {"targets": [{"type": "binary", "name": "Libmpv-GPL", "path": "Libmpv.xcframework"}]}
            with patch.object(benchmark, "capture", return_value=json.dumps(manifest)) as capture:
                self.assertEqual(benchmark.selected_framework(root, developer), framework.resolve())
            self.assertEqual(capture.call_args.kwargs["env"]["DEVELOPER_DIR"], str(developer))

    def test_report_publication_never_replaces_a_previous_run(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "run.json"
            benchmark.write_json(report, {"value": 1})
            with self.assertRaises(FileExistsError):
                benchmark.write_json(report, {"value": 2})
            self.assertEqual(json.loads(report.read_text()), {"value": 1})
            self.assertEqual(list(report.parent.glob(".benchmark-*")), [])

    def test_nonfinite_report_is_not_published(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "run.json"
            with self.assertRaises(ValueError):
                benchmark.write_json(report, {"time": float("nan")})
            self.assertFalse(report.exists())

    def test_versioned_framework_counts_the_actual_binary_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "Libmpv.xcframework"
            framework = root / "macos-arm64/Libmpv.framework"
            binary = framework / "Versions/A/Libmpv"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"native binary")
            (framework / "Libmpv").symlink_to("Versions/A/Libmpv")
            (root / "Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "AvailableLibraries": [
                            {
                                "LibraryIdentifier": "macos-arm64",
                                "LibraryPath": "Libmpv.framework",
                                "SupportedPlatform": "macos",
                                "SupportedArchitectures": ["arm64"],
                            }
                        ]
                    }
                )
            )
            workloads, identities = benchmark.binary_workloads(root)
            self.assertEqual(len(workloads), 1)
            self.assertEqual(workloads[0]["metrics"]["binaryBytes"]["samples"], [13])
            self.assertEqual(identities[0]["path"], str(binary.resolve()))

    def test_framework_cannot_measure_a_path_outside_its_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "Libmpv.xcframework"
            root.mkdir()
            (root.parent / "unrelated").write_bytes(b"unrelated")
            (root / "Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "AvailableLibraries": [
                            {
                                "LibraryIdentifier": "macos-arm64",
                                "LibraryPath": "Libmpv.framework",
                                "BinaryPath": "../../unrelated",
                                "SupportedPlatform": "macos",
                                "SupportedArchitectures": ["arm64"],
                            }
                        ]
                    }
                )
            )
            with self.assertRaisesRegex(ValueError, "Invalid framework binary path"):
                benchmark.binary_workloads(root)

    def test_labels_and_intervals_reject_ambiguous_or_unbounded_input(self):
        for value in ("../outside", "", "label/child", "$(command)"):
            with self.subTest(label=value), self.assertRaises(argparse.ArgumentTypeError):
                benchmark.label(value)
        for value in ("NaN", "inf", "-1", "61"):
            with self.subTest(seconds=value), self.assertRaises(argparse.ArgumentTypeError):
                benchmark.finite_range(1, 60)(value)


if __name__ == "__main__":
    unittest.main()
