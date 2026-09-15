"""Filesystem and input guards for local benchmark capture."""
import argparse
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import benchmark


class RunnerTests(unittest.TestCase):
    def test_manifest_evaluation_uses_the_selected_xcode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            framework = root / "Libmpv.xcframework"
            framework.mkdir()
            (framework / "Info.plist").write_bytes(plistlib.dumps({}))
            developer = root / "PinnedXcode.app/Contents/Developer"
            manifest = {"targets": [{"type": "binary", "name": "Libmpv-GPL",
                                      "path": "Libmpv.xcframework"}]}
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
            (root / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": [{
                "LibraryIdentifier": "macos-arm64", "LibraryPath": "Libmpv.framework",
                "SupportedPlatform": "macos", "SupportedArchitectures": ["arm64"],
            }]}))
            workloads, identities = benchmark.binary_workloads(root)
            self.assertEqual(len(workloads), 1)
            self.assertEqual(workloads[0]["metrics"]["binaryBytes"]["samples"], [13])
            self.assertEqual(identities[0]["path"], str(binary.resolve()))

    def test_framework_cannot_measure_a_path_outside_its_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "Libmpv.xcframework"
            root.mkdir()
            (root.parent / "unrelated").write_bytes(b"unrelated")
            (root / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": [{
                "LibraryIdentifier": "macos-arm64", "LibraryPath": "Libmpv.framework",
                "BinaryPath": "../../unrelated", "SupportedPlatform": "macos",
                "SupportedArchitectures": ["arm64"],
            }]}))
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
