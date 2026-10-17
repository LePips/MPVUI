import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import run_swift_tests as runner


class SwiftTestRunnerTests(unittest.TestCase):
    def test_prepares_fixtures_before_tests_and_preserves_arguments_and_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "project's checkout"
            events = []

            def prepare(output):
                self.assertEqual(output, root / ".build/test-media")
                output.mkdir(parents=True)
                (output / "baseline.mp4").write_bytes(b"fixture")
                events.append("prepare")

            def run(command, **kwargs):
                self.assertTrue((root / ".build/test-media/baseline.mp4").is_file())
                self.assertEqual(command, ["swift", "test", "--package-path", str(root), "--no-parallel", "--filter", "PlaybackTests"])
                self.assertEqual(kwargs["cwd"], root)
                events.append("test")
                return SimpleNamespace(returncode=7)

            with (
                patch.object(runner, "ROOT", root),
                patch.object(runner, "prepare", side_effect=prepare),
                patch.object(runner.subprocess, "run", side_effect=run),
            ):
                self.assertEqual(runner.main(["--filter", "PlaybackTests"]), 7)
            self.assertEqual(events, ["prepare", "test"])

    def test_generation_failure_stops_before_swift_tests(self):
        with (
            patch.object(runner, "prepare", side_effect=RuntimeError("missing ffmpeg")),
            patch.object(runner.subprocess, "run") as run,
        ):
            with self.assertRaisesRegex(RuntimeError, "missing ffmpeg"):
                runner.main([])
            run.assert_not_called()

    def test_help_and_discovery_do_not_generate_media(self):
        for arguments in (["--help"], ["-h"], ["--version"], ["--show-codecov-path"], ["--list-tests"], ["list"]):
            with (
                self.subTest(arguments=arguments),
                patch.object(runner, "prepare") as prepare,
                patch.object(runner.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run,
            ):
                self.assertEqual(runner.main(arguments), 0)
                prepare.assert_not_called()
                self.assertEqual(run.call_args.args[0][-len(arguments) :], arguments)


if __name__ == "__main__":
    unittest.main()
