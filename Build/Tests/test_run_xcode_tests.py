import contextlib
import io
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

from generate_device_test_project import TEAM_ENVIRONMENT
import run_xcode_tests as runner


class XcodeTestRunnerTests(unittest.TestCase):
    def run_main(self, root, arguments, events, team=None, environment=None):
        output = root / ".build/device-tests"

        def generate(repository, destination, selected):
            self.assertEqual((repository, destination, selected), (root, output, team))
            events.append("generate")
            return destination / "MPVUIRegressionTests.xcodeproj"

        def prepare(media):
            self.assertEqual(media, output / "GeneratedMedia")
            events.append("prepare")

        def run(command):
            events.append(command)
            Path(command[command.index("-resultBundlePath") + 1]).mkdir(parents=True)
            return SimpleNamespace(returncode=0)

        with (
            patch.object(runner, "ROOT", root),
            patch.object(runner, "simulators", return_value={"SIM-1": "iPhone"}),
            patch.object(runner, "generate", side_effect=generate),
            # Ignore a team set in the developer's shell so each case controls it.
            patch.dict(os.environ, {k: v for k, v in os.environ.items() if k != TEAM_ENVIRONMENT} | (environment or {}), clear=True),
            patch.object(runner, "prepare", side_effect=prepare),
            patch.object(runner, "keep_awake", side_effect=lambda command: command),
            patch.object(runner.subprocess, "run", side_effect=run),
            patch.object(runner, "publish_evidence"),
            patch.object(
                runner,
                "result_summary",
                return_value=dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0, result="Passed"),
            ),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            return runner.main(arguments)

    def test_generates_the_project_and_prepares_media_before_simulator_or_device_tests(self):
        environment = {TEAM_ENVIRONMENT: "ENVTEAM001"}
        cases = (
            ("SIM-1", [], {}, None, True),
            ("PHONE-1", ["--team", "ABCDE12345"], environment, "ABCDE12345", False),
            ("PHONE-1", [], environment, "ENVTEAM001", False),
        )
        for device, flags, variables, team, simulator in cases:
            with self.subTest(device=device, flags=flags), tempfile.TemporaryDirectory() as directory:
                events = []
                arguments = ["--device", device, *flags]
                self.assertEqual(self.run_main(Path(directory).resolve(), arguments, events, team, variables), 0)
                self.assertEqual(events[:2], ["generate", "prepare"])
                command = events[2]
                self.assertEqual("ONLY_ACTIVE_ARCH=YES" in command, simulator)
                self.assertIn(("platform=iOS Simulator" if simulator else "platform=iOS") + f",id={device}", command)

    def test_missing_device_lists_choices_without_running_tests(self):
        with (
            patch.object(runner, "simulators", return_value={"SIM-1": "iPhone"}),
            patch.object(runner.subprocess, "run") as run,
            patch.object(runner, "generate") as generate,
            contextlib.redirect_stdout(io.StringIO()) as stdout,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            with self.assertRaises(SystemExit):
                runner.main([])
        self.assertIn("iPhone: SIM-1", stdout.getvalue())
        self.assertEqual(run.call_args.args[0], ["xcrun", "devicectl", "list", "devices"])
        generate.assert_not_called()

    def test_missing_tools_stop_before_xcode_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            with (
                patch.object(runner, "ROOT", Path(directory)),
                patch.object(runner, "simulators", return_value={}),
                patch.object(runner, "generate", return_value=Path(directory) / "Tests.xcodeproj"),
                patch.object(runner, "prepare", side_effect=RuntimeError("missing ffmpeg")),
                patch.object(runner.subprocess, "run") as run,
            ):
                with self.assertRaisesRegex(RuntimeError, "missing ffmpeg"):
                    runner.main(["--device", "PHONE-1"])
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
