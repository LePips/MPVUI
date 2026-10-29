"""Check how make commands and options route to tools."""

import contextlib
import io
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import commands

ROOT = Path(__file__).resolve().parents[2]


def route(*argv):
    name, options, _ = commands.parse(list(argv))
    return [step.command[1:] if step.command[0] == commands.PYTHON else step.command for step in commands.resolve(name, options)]


class CommandRoutingTests(unittest.TestCase):
    def test_defaults_choose_the_everyday_tool_for_each_platform(self):
        self.assertEqual(route("build"), [("Build/mpvbuild", "build", "--profile", "dev")])
        self.assertEqual(route("build", "PLATFORM=android", "PROFILE=release")[0], ("Build/Android/build.py",))
        self.assertEqual(route("test"), [("Build/Tests/coverage.py", "--lane", "default")])
        self.assertEqual(route("test", "PLATFORM=android")[0][-2:], (":mpvui:testDebugUnitTest", ":mpvui:lintRelease"))
        self.assertEqual(route("release"), [("Build/mpvbuild", "release", "candidate", "--profile", "release")])
        self.assertEqual(route("release", "PLATFORM=android"), [("Build/Android/release.py",)])
        self.assertEqual(route("benchmark"), [("Build/Benchmarks/benchmark.py", "run")])

    def test_selectors_and_options_choose_variants(self):
        self.assertEqual(route("test", "SUITE=core"), [("Build/Tests/coverage.py", "--lane", "core")])
        self.assertEqual(route("test", "FILTER=PlaybackTests"), [("Build/Tests/run_swift_tests.py", "--filter", "PlaybackTests")])
        self.assertEqual(route("benchmark", "DEVICE=phone"), [("Build/Benchmarks/benchmark.py", "device")])
        self.assertEqual(route("release", "STEP=repro", "PROFILE=release")[0][-2:], ("--profile", "release"))
        example = route("test", "PLATFORM=android", "SUITE=example", "PROFILE=release")
        self.assertEqual(example[0], ("Build/Tests/prepare_test_media.py",))
        self.assertEqual(example[1][-2:], (":app:connectedReleaseAndroidTest", "-PmpvuiTestBuildType=release"))
        self.assertEqual(route("format", "CHECK=1")[0][-2:], ("--hook-stage", "manual"))
        self.assertEqual(len(route("test", "SUITE=tools")), 2)

    def test_every_tool_script_exists(self):
        for name, command in commands.COMMANDS.items():
            for selections in command.table.values():
                for _, build in selections.values():
                    for step in build(commands.Options(device="id")):
                        for part in step.command:
                            if part.startswith("Build/") and part.endswith((".py", "mpvbuild")):
                                self.assertTrue((ROOT / part).is_file(), f"make {name}: {part}")

    def test_invalid_usage_explains_the_valid_choices(self):
        cases = (
            (("test", "SUIT=unit"), "accepts PLATFORM, SUITE"),
            (("test", "SUITE=nope"), "must be one of: core, unit"),
            (("test", "SUITE=unit", "DEVICE=phone"), "DEVICE does not apply"),
            (("test", "PLATFORM=android", "FILTER=Name"), "FILTER runs Apple package tests"),
            (("select", "PLATFORM=android"), "accepts JSON, not PLATFORM"),
            (("release", "PLATFORM=android", "STEP=publish"), "takes no STEP"),
            (("build", "PROFILE=fast"), "PROFILE must be one of dev, release"),
        )
        for argv, message in cases:
            with self.subTest(argv=argv), self.assertRaisesRegex(commands.UsageError, message):
                name, options, _ = commands.parse(list(argv))
                commands.resolve(name, options)

    def test_steps_receive_arguments_device_and_json_as_declared(self):
        calls = []
        with patch.object(commands.validation, "main", side_effect=lambda argv: calls.append(argv) or 0), patch.dict(os.environ):
            status = commands.main(["test", "PLATFORM=android", "SUITE=integration", "DEVICE=emulator-5554", "JSON=1", "--", "--info"])
            self.assertEqual(os.environ["ANDROID_SERIAL"], "emulator-5554")
        self.assertEqual(status, 0)
        self.assertEqual([call[:3] for call in calls], [["--kind", "command", "--json"], ["--kind", "test", "--json"]])
        self.assertEqual(calls[0][-1], "Build/Tests/prepare_test_media.py")
        self.assertEqual(calls[1][-2:], [":mpvui:connectedDebugAndroidTest", "--info"])
        calls.clear()
        with patch.object(commands.validation, "main", side_effect=lambda argv: calls.append(argv) or 0):
            commands.main(["test", "SUITE=device", "DEVICE=phone", "--", "--team", "ABCDE12345"])
        self.assertEqual(calls[0][-5:], ["Build/Tests/run_xcode_tests.py", "--team", "ABCDE12345", "--device", "phone"])

    def test_a_failed_step_stops_the_command(self):
        with patch.object(commands.validation, "main", return_value=3) as run:
            self.assertEqual(commands.main(["test", "SUITE=tools"]), 3)
        run.assert_called_once()

    def test_tool_help_bypasses_validation(self):
        with patch.object(commands.subprocess, "run", return_value=type("Done", (), {"returncode": 0})) as run:
            self.assertEqual(commands.main(["release", "STEP=publish", "--", "--help"]), 0)
        self.assertEqual(run.call_args.args[0][1:], ["Build/mpvbuild", "release", "publish", "--help"])

    def test_help_lists_every_command_and_selection(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(commands.main(["help"]), 0)
        for name, command in commands.COMMANDS.items():
            self.assertIn(f"  {name} ", stdout.getvalue())
            for selections in command.table.values() if command.selector else ():
                for value in filter(None, selections):
                    self.assertIn(f"    {value} ", stdout.getvalue())
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(commands.main(["deploy"]), 2)
        self.assertIn("Unknown command deploy", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
