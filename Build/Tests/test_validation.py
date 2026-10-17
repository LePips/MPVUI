"""Regression tests for readable output, opt-in JSON, and subprocess lifecycle."""

import contextlib
import io
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import validation


class ValidationTests(unittest.TestCase):
    def test_test_names_describing_fatal_errors_do_not_hide_actual_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "tests.log"
            log.write_text(
                'Test "native output reports one fatal error" started.\n'
                'Test "native output reports one fatal error" passed.\n'
                'Test "native output reports one fatal error" recorded an issue: missing callback\n'
                "Player.swift:12: Fatal error: unexpected nil\n"
                "Fatal error during initialization\n"
            )
            items = validation.diagnostics([log])
            self.assertEqual([item["logLine"] for item in items], [3, 4, 5])
            self.assertTrue(all(item["severity"] == "error" for item in items))

    def test_multiple_swift_test_bundles_accumulate_without_masking_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _ = self.execute(
                directory,
                "print('Test run with 255 tests in 40 suites failed with 1 issue'); "
                "print('Executed 0 tests, with 0 failures'); "
                "print('Test run with 6 tests in 1 suite passed')",
            )
            self.assertEqual(result["status"], "failed")
            tests = result["summary"]["tests"]
            self.assertEqual(tests["count"], 261)
            self.assertEqual(tests["suites"], 41)
            self.assertEqual(tests["issues"], 1)

    def execute(self, directory, code, *, kind="test", timeout=None, json_output=True):
        output = io.StringIO()
        destination = Path(directory) / "run"
        with contextlib.redirect_stdout(output):
            status = validation.run(
                [sys.executable, "-c", code], kind=kind, directory=destination, timeout=timeout, json_output=json_output
            )
        result = json.loads((destination / "result.json").read_text())
        self.assertEqual(status, result["exitCode"])
        if json_output:
            self.assertEqual(result, json.loads(output.getvalue()))
            self.assertEqual(len(output.getvalue().splitlines()), 1)
        return result, output.getvalue()

    def test_readable_output_preserves_stdout_stderr_and_full_log(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = b"progress\r" + b"work\n" * 30000 + "done ✓\n".encode() + b"warning: details\ninvalid: \xff\n"
            code = "import os; os.write(1, b'progress\\r' + b'work\\n' * 30000 + 'done ✓\\n'.encode()); "
            code += "os.write(2, b'warning: details\\ninvalid: \\xff\\n')"
            result, output = self.execute(directory, code, kind="command", json_output=False)
            self.assertTrue(output.startswith(payload.decode(errors="replace")))
            self.assertEqual(Path(result["artifacts"]["commandLog"]).read_bytes(), payload)
            self.assertIn("Command succeeded", output)
            self.assertIn(f"Result: {result['artifacts']['result']}", output)
            self.assertEqual(result["diagnostics"]["items"][0]["severity"], "warning")

    def test_readable_failures_show_exit_status_and_runner_errors(self):
        for code, expected, message in (
            ("import sys; print('worker failed'); sys.exit(7)", 7, "worker failed"),
            ("print('Test run with 0 tests passed')", 1, "Test result reports failure or zero executed tests"),
        ):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                result, output = self.execute(directory, code, json_output=False)
                self.assertEqual(result["exitCode"], expected)
                self.assertIn(f"Test failed (exit {expected})", output)
                self.assertIn(message, output)

    def test_default_cli_streams_partial_lines_before_completion_and_decodes_split_utf8(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "run"
            release = Path(directory) / "continue"
            code = "import os,time; from pathlib import Path\nos.write(1, b'working \\xe2')\n"
            code += f"deadline = time.monotonic() + 5\nwhile not Path({str(release)!r}).exists():\n"
            code += "    if time.monotonic() > deadline: raise SystemExit(8)\n    time.sleep(0.01)\n"
            code += "os.write(1, b'\\x9c\\x93\\n')"
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(validation.ROOT / "Build/validation.py"),
                    "--kind",
                    "command",
                    "--output-dir",
                    str(run),
                    "--",
                    sys.executable,
                    "-c",
                    code,
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    self.assertTrue(selector.select(timeout=5), "No output arrived while the child waited")
                    first = os.read(process.stdout.fileno(), 4096)
                self.assertEqual(first, b"working ")
                self.assertIsNone(process.poll())
                release.touch()
                remaining, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertTrue((first + remaining).decode().startswith("working ✓\n"))
                self.assertEqual((run / "command.log").read_text(), "working ✓\n")
                self.assertEqual(json.loads((run / "result.json").read_text())["status"], "succeeded")
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.communicate(timeout=10)

    def test_cli_json_option_prints_only_the_saved_result(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "run"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(validation.ROOT / "Build/validation.py"),
                    "--kind",
                    "command",
                    "--json",
                    "--output-dir",
                    str(run),
                    "--",
                    sys.executable,
                    "-c",
                    "import sys; print('details'); sys.exit(7)",
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(completed.returncode, 7)
            self.assertEqual(len(completed.stdout.splitlines()), 1)
            self.assertEqual(json.loads(completed.stdout), json.loads((run / "result.json").read_text()))
            self.assertEqual((run / "command.log").read_text(), "details\n")
            self.assertEqual(completed.stderr, "")

    def test_readable_output_finishes_when_a_descendant_keeps_the_pipe_open(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "run"
            pid_file = Path(directory) / "child.pid"
            code = "import subprocess,sys; from pathlib import Path; "
            code += "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); "
            code += f"Path({str(pid_file)!r}).write_text(str(child.pid)); print('parent finished')"
            try:
                completed = subprocess.run(
                    [
                        sys.executable,
                        str(validation.ROOT / "Build/validation.py"),
                        "--kind",
                        "command",
                        "--output-dir",
                        str(run),
                        "--",
                        sys.executable,
                        "-c",
                        code,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertIn("parent finished", completed.stdout)
                self.assertEqual(json.loads((run / "result.json").read_text())["status"], "succeeded")
            finally:
                if pid_file.exists():
                    os.kill(int(pid_file.read_text()), signal.SIGTERM)

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
        for json_output in (False, True):
            for close_output in (False, True):
                with self.subTest(json=json_output, close_output=close_output), tempfile.TemporaryDirectory() as directory:
                    code = "import os,time; print(os.getpid(), flush=True); "
                    code += "os.close(1); os.close(2); " if close_output else ""
                    result, output = self.execute(directory, code + "time.sleep(60)", timeout=0.2, json_output=json_output)
                    self.assertEqual(result["status"], "timed_out")
                    self.assertEqual(result["exitCode"], 124)
                    if not json_output:
                        self.assertIn("Command exceeded 0.2 seconds", output)
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

    def test_signals_publish_interruption_and_stop_child_in_both_modes(self):
        for json_output in (False, True):
            for signum in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(json=json_output, signal=signum):
                    self.assert_signal_stops_child(json_output, signum)

    def assert_signal_stops_child(self, json_output, signum):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "run"
            command = [
                sys.executable,
                str(validation.ROOT / "Build/validation.py"),
                "--kind",
                "test",
                *(["--json"] if json_output else []),
                "--output-dir",
                str(run),
                "--",
                sys.executable,
                "-c",
                "import os,signal,time\n"
                "def stop(signum, frame):\n    print('stopping child', flush=True)\n    raise SystemExit(0)\n"
                "signal.signal(signal.SIGTERM, stop)\nprint(os.getpid(), flush=True)\ntime.sleep(60)",
            ]
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 5
                log = run / "command.log"
                while time.monotonic() < deadline and (not log.exists() or not log.read_text().strip()):
                    time.sleep(0.01)
                child = int(log.read_text().strip())
                process.send_signal(signum)
                stdout, stderr = process.communicate(timeout=10)
                result = json.loads((run / "result.json").read_text())
                if json_output:
                    self.assertEqual(json.loads(stdout), result)
                else:
                    self.assertIn(f"Test interrupted (exit {128 + signum})", stdout)
                self.assertEqual(process.returncode, 128 + signum, stderr)
                self.assertEqual(result["status"], "interrupted")
                self.assertIn("stopping child", log.read_text())
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
