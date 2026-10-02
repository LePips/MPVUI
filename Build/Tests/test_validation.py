"""Contract and regression tests for bounded validation output and subprocess lifecycle."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import validation


class ValidationTests(unittest.TestCase):
    def execute(self, directory, code, *, kind="test", timeout=None):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = validation.run([sys.executable, "-c", code], kind=kind, directory=Path(directory) / "run", timeout=timeout)
        result = json.loads(output.getvalue())
        self.assertEqual(result, json.loads(Path(result["artifacts"]["result"]).read_text()))
        self.assertEqual(status, result["exitCode"])
        self.assertEqual(len(output.getvalue().splitlines()), 1)
        return result, output.getvalue()

    def test_success_keeps_large_output_on_disk_and_retains_test_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.execute(
                directory,
                "print('suite passed\\n' * 30000); print('Executed 0 tests, with 0 failures'); "
                "print('↷ Test example skipped'); print('Test run with 376 tests in 77 suites passed')",
            )
            self.assertEqual(result["status"], "succeeded")
            self.assertEqual(result["summary"]["tests"]["count"], 376)
            self.assertEqual(result["summary"]["tests"]["skippedCount"], 1)
            self.assertGreater(Path(result["artifacts"]["commandLog"]).stat().st_size, 300000)
            self.assertLess(len(output), 2000)

    def test_all_six_early_assertions_survive_a_long_tail_and_exit_code_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            code = "import sys\nfor n in range(1,7): print(f'Test case{n} recorded an issue at Tests.swift:{n}:13: Expectation failed: false')\n"
            code += "print('unrelated suite passed\\n' * 30000)\nsys.exit(7)"
            result, _ = self.execute(directory, code)
            errors = [item for item in result["diagnostics"]["items"] if item["severity"] == "error"]
            self.assertEqual(result["exitCode"], 7)
            self.assertEqual(len(errors), 6)
            self.assertEqual(errors[0]["location"], dict(path="Tests.swift", line=1, column=13))

    def test_duplicate_warnings_are_counted_and_excess_diagnostics_are_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            code = "import sys\nprint('file.swift:1:2: warning: repeated\\n' * 50)\n"
            code += "for n in range(25): print(f'file.swift:{n+1}:2: error: issue{n}')\nsys.exit(1)"
            result, _ = self.execute(directory, code)
            self.assertEqual(result["diagnostics"]["omitted"], 5)
            warning = next(item for item in result["diagnostics"]["items"] if item["severity"] == "warning")
            self.assertEqual(warning["occurrences"], 50)
            self.assertEqual(len(json.loads(Path(result["artifacts"]["diagnostics"]).read_text())), 26)

    def test_failure_without_recognized_errors_retains_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _ = self.execute(directory, "import sys; print('worker terminated unexpectedly'); sys.exit(3)")
            self.assertIn("worker terminated", result["summary"]["failureExcerpt"])

    def test_timeout_returns_terminal_result_and_stops_child(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _ = self.execute(directory, "import os,time; print(os.getpid(), flush=True); time.sleep(60)", timeout=0.2)
            self.assertEqual(result["status"], "timed_out")
            self.assertEqual(result["exitCode"], 124)
            pid = int(Path(result["artifacts"]["commandLog"]).read_text().strip())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_zero_tests_or_semantic_failure_cannot_look_successful(self):
        for message in ("Test run with 0 tests passed", "Test run with 6 tests failed with 1 issue"):
            with self.subTest(message=message), tempfile.TemporaryDirectory() as directory:
                result, _ = self.execute(directory, f"print({message!r})")
                self.assertEqual(result["status"], "failed")

    def test_structured_test_failure_with_zero_process_exit_is_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            code = f"import sys; sys.path.insert(0, {str(validation.ROOT / 'Build')!r}); from validation import publish_evidence; "
            code += "publish_evidence(summary={'tests': {'framework': 'XCResult', 'count': 1, 'failures': 1, 'outcome': 'failed'}})"
            result, _ = self.execute(directory, code)
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["summary"]["tests"]["failures"], 1)

    def test_evidence_is_merged_without_dumping_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "full.json"
            artifact.write_text("{}")
            code = f"import sys; sys.path.insert(0, {str(validation.ROOT / 'Build')!r}); from validation import publish_evidence; "
            code += f"publish_evidence(summary={{'coverageGate':'passed'}}, artifacts={{'coverageReport':{str(artifact)!r}}})"
            result, _ = self.execute(directory, code)
            self.assertEqual(result["summary"]["coverageGate"], "passed")
            self.assertEqual(result["artifacts"]["coverageReport"], str(artifact.resolve()))

    def test_malformed_evidence_cannot_be_reported_as_success(self):
        for evidence in ("{bad json", '{"summary":{"value":NaN},"artifacts":{}}', '{"summary":{},"artifacts":{"path":42}}', "[]"):
            with self.subTest(evidence=evidence), tempfile.TemporaryDirectory() as directory:
                code = f"import os; from pathlib import Path; Path(os.environ['MPVUI_VALIDATION_EVIDENCE']).write_text({evidence!r})"
                result, _ = self.execute(directory, code)
                self.assertEqual(result["status"], "failed")
                self.assertIn("Cannot collect", result["summary"]["runnerError"])

    def test_sigterm_publishes_interruption_and_stops_child(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "run"
            command = [
                sys.executable,
                str(validation.ROOT / "Build/validation.py"),
                "--kind",
                "test",
                "--output-dir",
                str(run),
                "--",
                sys.executable,
                "-c",
                "import os,time; print(os.getpid(), flush=True); time.sleep(60)",
            ]
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 5
                log = run / "command.log"
                while time.monotonic() < deadline and (not log.exists() or not log.read_text().strip()):
                    time.sleep(0.01)
                child = int(log.read_text().strip())
                process.terminate()
                stdout, stderr = process.communicate(timeout=10)
                result = json.loads(stdout)
                self.assertEqual(process.returncode, 143, stderr)
                self.assertEqual(result["status"], "interrupted")
                with self.assertRaises(ProcessLookupError):
                    os.kill(child, 0)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.communicate(timeout=10)

    def test_missing_executable_and_existing_run_directory_are_not_success(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            destination = Path(directory) / "run"
            self.assertEqual(validation.run(["/missing/validation-command"], kind="build", directory=destination), 127)
            with self.assertRaises(FileExistsError):
                validation.run(["true"], kind="build", directory=destination)

    def test_nonfinite_json_is_never_published(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            with self.assertRaises(ValueError):
                validation.write_json(path, {"duration": float("nan")})
            self.assertFalse(path.exists())
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
