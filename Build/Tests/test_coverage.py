import tempfile
import contextlib
import io
import json
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import coverage
from validation import EVIDENCE_ENV


class CoverageReportTests(unittest.TestCase):
    def entry(self, path, covered, count):
        return dict(filename=str(path), summary={key: dict(covered=covered, count=count) for key in coverage.METRICS})

    def test_only_production_sources_contribute_and_totals_are_weighted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = {
                "data": [
                    {
                        "files": [
                            self.entry(root / "Sources/Models/Small.swift", 1, 1),
                            self.entry(root / "Sources/Engine/Large.swift", 1, 9),
                            self.entry(root / "Tests/Test.swift", 100, 100),
                            self.entry(root / "SourcesOther/Dependency.swift", 100, 100),
                            self.entry(root / ".build/Generated.swift", 100, 100),
                        ]
                    }
                ]
            }
            result = coverage.summarize(report, root)
            self.assertEqual(result["metrics"]["lines"]["percent"], 20)
            self.assertEqual(len(result["files"]), 2)
            self.assertEqual(result["areas"]["Models"]["lines"]["percent"], 100)

    def test_wrong_checkout_and_empty_reports_fail_instead_of_reporting_success(self):
        with self.assertRaisesRegex(ValueError, "no MPVUI"):
            coverage.summarize({"data": [{"files": []}]}, Path("/project"))

    def test_duplicate_files_fail_instead_of_double_counting(self):
        entry = self.entry(Path("/project/Sources/Player.swift"), 1, 2)
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            coverage.summarize({"data": [{"files": [entry, entry]}]}, Path("/project"))

    def test_gate_uses_unrounded_values_and_equality_passes(self):
        report = {"metrics": {"lines": {"percent": 89.999}, "regions": {"percent": 80}}}
        self.assertEqual(len(coverage.violations(report, dict(lines=90, regions=80))), 1)

    def test_lane_selection_uses_suite_identifiers_and_excludes_helper_types(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "Tests/Unit/Subtitles"
            folder.mkdir(parents=True)
            (folder / "Example.swift").write_text("struct SubtitleTests {\n}\nstruct Helper {}\n")
            self.assertEqual(coverage.suites(root, ["Unit"]), "(SubtitleTests)/")

    def test_runner_publishes_counts_and_failed_coverage_gate_without_raw_success_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Tests/Unit").mkdir(parents=True)
            (root / "Tests/Unit/Example.swift").write_text("struct ExampleTests {}")
            (root / "Build/Tests").mkdir(parents=True)
            (root / "Build/Tests/coverage-thresholds.json").write_text('{"lines":90}')
            export = root / "llvm.json"
            export.write_text(json.dumps({"data": [{"files": [self.entry(root / "Sources/Example.swift", 1, 2)]}]}))
            evidence = root / "evidence.json"

            def run(command, **kwargs):
                kwargs["stdout"].write("noise\n" * 10000 + "Test run with 4 tests in 2 suites passed\n")
                return SimpleNamespace(returncode=0)

            stdout = io.StringIO()
            with (
                patch.object(coverage, "ROOT", root),
                patch.object(coverage, "input_digest", return_value="same"),
                patch.object(coverage.subprocess, "run", side_effect=run),
                patch.object(coverage.subprocess, "check_output", return_value=str(export)),
                patch.dict(os.environ, {EVIDENCE_ENV: str(evidence)}),
                patch("sys.argv", ["coverage.py", "--check"]),
                contextlib.redirect_stdout(stdout),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                status = coverage.main()
            data = json.loads(evidence.read_text())
            self.assertEqual(status, 1)
            self.assertEqual(data["summary"]["tests"]["count"], 4)
            self.assertEqual(data["summary"]["coverageGate"], "failed")
            self.assertTrue(data["summary"]["inputsUnchanged"])
            self.assertLess(len(stdout.getvalue()), 1000)


if __name__ == "__main__":
    unittest.main()
