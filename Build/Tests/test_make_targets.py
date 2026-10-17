"""Exercise the public Make interface without building native dependencies or using a device."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MakeTargetsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        # Exercise the same two entry points from a checkout with shell-sensitive paths.
        self.root = Path(self.temporary.name) / "project's checkout"
        (self.root / "Build").mkdir(parents=True)
        for relative in ("Makefile", "Build/Makefile"):
            shutil.copyfile(ROOT / relative, self.root / relative)
        self.python = self.root / "python stub"
        self.python.write_text(
            f"#!{sys.executable}\n"
            "import json,os,sys,time\n"
            "from pathlib import Path\n"
            "args=sys.argv[1:]\n"
            "if '--kind' in args:\n"
            "    kind=args[args.index('--kind')+1]\n"
            "    if os.environ.get('CHECK_ORDER'):\n"
            "        marker=Path('build-complete')\n"
            "        if kind=='build': time.sleep(0.05); marker.touch()\n"
            "        if kind=='test' and not marker.exists(): sys.exit(9)\n"
            "leaked={k:os.environ[k] for k in ('MAKEFLAGS','MAKEOVERRIDES','ARGS','PROFILE','TARGET','JSON') if k in os.environ}\n"
            "print(json.dumps({'cwd':os.getcwd(),'args':args,'leaked':leaked}))\n"
            "sys.exit(int(os.environ.get('STUB_EXIT','0')))\n"
        )
        self.python.chmod(0o755)

    def make(self, *args, env=None):
        # Do not inherit a parent's make flags/jobserver or command-line overrides.
        environment = {
            key: value
            for key, value in os.environ.items()
            if key not in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "MAKELEVEL", "ARGS", "PROFILE", "TARGET", "PYTHON", "JSON")
        }
        environment.update(env or {})
        return subprocess.run(
            ["make", f"PYTHON={self.python}", *args],
            cwd=self.root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def records(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_both_entry_points_resolve_paths_from_repository_root(self):
        left = self.records(self.make("test-unit"))
        right = self.records(self.make("-C", "Build", "test-unit"))
        self.assertEqual(left, right)
        self.assertEqual(left[0]["cwd"], str(self.root.resolve()))
        self.assertEqual(left[0]["args"][:4], ["Build/validation.py", "--kind", "test", "--"])
        self.assertEqual(left[0]["args"][-3:], ["Build/Tests/coverage.py", "--lane", "unit"])

    def test_forwarded_options_preserve_quoted_paths(self):
        result = self.records(self.make("benchmark-device", 'ARGS=--label candidate --media "/tmp/my movie\'s clip.mp4"'))[0]
        self.assertEqual(result["args"][-4:], ["--label", "candidate", "--media", "/tmp/my movie's clip.mp4"])
        self.assertEqual(result["args"][2], "benchmark")

    def test_json_option_is_explicit_and_not_forwarded_to_tools(self):
        for entry_point in ((), ("-C", "Build")):
            with self.subTest(entry_point=entry_point):
                default = self.records(self.make(*entry_point, "format"))[0]
                disabled = self.records(self.make(*entry_point, "format", "JSON=0"))[0]
                enabled = self.records(self.make(*entry_point, "format", "JSON=1"))[0]
                self.assertEqual(default, disabled)
                self.assertEqual(default["args"], ["Build/validation.py", "--kind", "command", "--", "pre-commit", "run", "--all-files"])
                self.assertEqual(enabled["args"][:5], ["Build/validation.py", "--kind", "command", "--json", "--"])
                self.assertEqual(enabled["args"][5:], default["args"][4:])
                self.assertEqual(enabled["leaked"], {})
        phases = self.records(self.make("verify", "JSON=1"))
        self.assertEqual([item["args"][3:5] for item in phases], [["--json", "--"], ["--json", "--"]])

    def test_verify_is_serial_even_with_parallel_make_and_does_not_benchmark(self):
        records = self.records(self.make("-j8", "verify", "BUILD_ARGS=--offline", "TEST_ARGS=--lane unit", env={"CHECK_ORDER": "1"}))
        self.assertEqual([item["args"][2] for item in records], ["build", "test"])
        self.assertIn("Build/mpvbuild", records[0]["args"])
        self.assertIn("Build/Tests/coverage.py", records[1]["args"])
        self.assertEqual(records[0]["args"][-1], "--offline")
        self.assertEqual(records[1]["args"][-2:], ["--lane", "unit"])
        self.assertNotIn("--offline", records[1]["args"])
        self.assertNotIn("--lane", records[0]["args"])

    def test_verify_stops_after_a_failed_build(self):
        result = self.make("verify", env={"STUB_EXIT": "7"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertEqual(json.loads(result.stdout)["args"][2], "build")

    def test_help_needs_no_build_tools_and_target_help_is_not_hidden_in_json(self):
        result = self.make("help", "PYTHON=/does/not/exist")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("benchmark-compare", result.stdout)
        self.assertIn("JSON=1", result.stdout)
        details = self.records(self.make("help", "TARGET=benchmark-ab", "ARGS=run"))[0]["args"]
        self.assertEqual(details, ["Build/Benchmarks/run_device_ab.py", "run", "--help"])
        self.assertNotEqual(self.make("help", "TARGET=unknown").returncode, 0)

    def test_build_profile_and_device_test_safety_arguments_are_forwarded(self):
        build = self.records(self.make("build", "PROFILE=release", "ARGS=--offline"))[0]["args"]
        self.assertEqual(build[4:6], [str(self.python), "Build/mpvbuild"])
        self.assertEqual(build[-3:], ["--profile", "release", "--offline"])
        self.assertEqual(self.records(self.make("build", "PROFILE=release", "ARGS=--offline"))[0]["leaked"], {})
        device = self.records(self.make("test-device", "ARGS=--device-id example"))[0]["args"]
        self.assertEqual(device[:7], ["Build/validation.py", "--kind", "test", "--", "caffeinate", "-disu", str(self.python)])
        self.assertEqual(device[7:10], ["Build/Tests/run_xcode_tests.py", "--platform", "device"])
        self.assertEqual(device[-2:], ["--device-id", "example"])

    def test_package_build_has_no_media_step_and_swift_tests_use_fixture_runner(self):
        build = self.records(self.make("build-swift", "ARGS=--arch arm64"))
        self.assertEqual(len(build), 1)
        self.assertEqual(
            build[0]["args"], ["Build/validation.py", "--kind", "build", "--", "swift", "build", "--package-path", ".", "--arch", "arm64"]
        )
        tests = self.records(self.make("test-swift", "ARGS=--filter PlaybackTests"))
        self.assertEqual(len(tests), 1)
        self.assertEqual(tests[0]["args"][-4:], [str(self.python), "Build/Tests/run_swift_tests.py", "--filter", "PlaybackTests"])

    def test_android_candidate_is_local_and_accepts_a_version(self):
        result = self.records(self.make("release-android-candidate", "JSON=1", "ARGS=--version 0.7.0"))[0]
        self.assertEqual(result["args"][2], "build")
        self.assertEqual(result["args"][-4:], [str(self.python), "Build/Android/release.py", "--version", "0.7.0"])


if __name__ == "__main__":
    unittest.main()
