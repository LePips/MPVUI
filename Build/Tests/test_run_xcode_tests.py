import contextlib
import io
import json
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

from generate_device_test_project import TEAM_ENVIRONMENT
import run_xcode_tests as runner


class XcodeTestRunnerTests(unittest.TestCase):
    def run_main(self, root, arguments, events, team=None, environment=None, operating_system="iOS"):
        output = root / ".build/device-tests" / operating_system.lower()

        def generate(repository, destination, selected, platform):
            self.assertEqual((repository, destination, selected, platform), (root, output, team, operating_system))
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
            patch.object(
                runner,
                "simulators",
                return_value={"SIM-1": {"name": "iPhone", "os": "iOS"}, "TV-SIM-1": {"name": "Apple TV", "os": "tvOS"}},
            ),
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
            patch.object(runner, "simulators", return_value={"SIM-1": {"name": "iPhone", "os": "iOS"}}),
            patch.object(runner.subprocess, "run") as run,
            patch.object(runner, "generate") as generate,
            contextlib.redirect_stdout(io.StringIO()) as stdout,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            with self.assertRaises(SystemExit):
                runner.main([])
        self.assertIn("iPhone (iOS): SIM-1", stdout.getvalue())
        self.assertEqual(run.call_args.args[0], ["xcrun", "devicectl", "list", "devices"])
        generate.assert_not_called()

    def test_tvos_destinations_are_inferred_for_simulators_and_explicit_for_devices(self):
        for device, flags, destination in (
            ("TV-SIM-1", [], "tvOS Simulator"),
            ("TV-1", ["--os", "tvOS"], "tvOS"),
        ):
            with self.subTest(device=device), tempfile.TemporaryDirectory() as directory:
                events = []
                self.assertEqual(self.run_main(Path(directory), ["--device", device, *flags], events, operating_system="tvOS"), 0)
                self.assertIn(f"platform={destination},id={device}", events[2])

    def test_multiple_test_selections_reach_xcode_as_separate_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            events = []
            suites = ["MPVUITests/MPVPlayerDeinitializationTests", "MPVUITests/MPVPiPLifecycleTests"]
            arguments = ["--device", "SIM-1"] + [argument for suite in suites for argument in ("--only-testing", suite)]
            self.assertEqual(self.run_main(Path(directory), arguments, events), 0)
            self.assertEqual([value for value in events[2] if value.startswith("-only-testing:")], ["-only-testing:" + s for s in suites])

    def test_simulator_platform_comes_from_runtime_and_rejects_a_mismatched_override(self):
        devices = {
            "com.apple.CoreSimulator.SimRuntime.tvOS-18-5": [{"udid": "TV-1", "name": "Custom name"}],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [{"udid": "PHONE-1", "name": "Phone"}],
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-0": [{"udid": "WATCH-1", "name": "Watch"}],
        }
        with patch.object(runner.subprocess, "run", return_value=SimpleNamespace(stdout=json.dumps({"devices": devices}))):
            self.assertEqual(
                runner.simulators(),
                {"TV-1": {"name": "Custom name", "os": "tvOS"}, "PHONE-1": {"name": "Phone", "os": "iOS"}},
            )
        with (
            patch.object(runner, "simulators", return_value={"TV-1": {"name": "Custom name", "os": "tvOS"}}),
            patch.object(runner, "generate") as generate,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            with self.assertRaises(SystemExit):
                runner.main(["--device", "TV-1", "--os", "iOS"])
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
