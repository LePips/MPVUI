from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import run_xcode_tests as runner


class XcodeTestRunnerTests(unittest.TestCase):
    def test_prepares_resources_before_building_device_or_simulator_tests(self):
        for platform, selector in (("device", "--device-id"), ("simulator", "--simulator-id")):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                project = root / "custom tests/MPVUIRegressionTests.xcodeproj"
                project.mkdir(parents=True)
                events = []

                def prepare(output):
                    self.assertEqual(output, project.parent / "GeneratedMedia")
                    output.mkdir()
                    (output / "baseline.mp4").write_bytes(b"fixture")
                    events.append("prepare")

                def run(command):
                    self.assertTrue((project.parent / "GeneratedMedia/baseline.mp4").is_file())
                    self.assertEqual("ONLY_ACTIVE_ARCH=YES" in command, platform == "simulator")
                    bundle = Path(command[command.index("-resultBundlePath") + 1])
                    bundle.mkdir(parents=True)
                    events.append("test")
                    return SimpleNamespace(returncode=0)

                with (
                    patch.object(runner, "ROOT", root),
                    patch.object(runner, "prepare", side_effect=prepare),
                    patch.object(runner.subprocess, "run", side_effect=run),
                    patch.object(runner, "publish_evidence"),
                    patch.object(
                        runner,
                        "result_summary",
                        return_value=dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0, result="Passed"),
                    ),
                ):
                    self.assertEqual(runner.main(["--platform", platform, selector, "example", "--project", str(project)]), 0)
                self.assertEqual(events, ["prepare", "test"])

    def test_missing_tools_stop_before_xcode_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "Tests.xcodeproj"
            project.mkdir()
            with (
                patch.object(runner, "prepare", side_effect=RuntimeError("missing ffmpeg")),
                patch.object(runner.subprocess, "run") as run,
            ):
                with self.assertRaisesRegex(RuntimeError, "missing ffmpeg"):
                    runner.main(["--platform", "simulator", "--simulator-id", "example", "--project", str(project)])
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
