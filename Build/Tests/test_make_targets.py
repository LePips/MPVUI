"""Exercise the Make front end without building native dependencies or using a device."""

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
            "if os.environ.get('CHECK_ORDER'):\n"
            "    marker=Path('build-complete')\n"
            "    if args[1]=='build': time.sleep(0.05); marker.touch()\n"
            "    if args[1]=='test' and not marker.exists(): sys.exit(9)\n"
            "leaked={k:os.environ[k] for k in ('MAKEFLAGS','MAKEOVERRIDES','ARGS','SUITE','PLATFORM','JSON') if k in os.environ}\n"
            "print(json.dumps({'cwd':os.getcwd(),'args':args,'leaked':leaked}))\n"
            "sys.exit(int(os.environ.get('STUB_EXIT','0')))\n"
        )
        self.python.chmod(0o755)

    def make(self, *args, env=None):
        # Do not inherit a parent's make flags/jobserver or command-line overrides.
        environment = {key: value for key, value in os.environ.items() if key not in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "MAKELEVEL")}
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

    def test_both_entry_points_forward_the_command_options_and_tool_arguments(self):
        left = self.records(self.make("test", "SUITE=unit", "JSON=1", "ARGS=--check"))
        right = self.records(self.make("-C", "Build", "test", "SUITE=unit", "JSON=1", "ARGS=--check"))
        self.assertEqual(left, right)
        self.assertEqual(left[0]["cwd"], str(self.root.resolve()))
        self.assertEqual(left[0]["args"][:2], ["Build/commands.py", "test"])
        self.assertEqual(sorted(left[0]["args"][2:4]), ["JSON=1", "SUITE=unit"])
        self.assertEqual(left[0]["args"][4:], ["--", "--check"])
        self.assertEqual(left[0]["leaked"], {})

    def test_unknown_options_reach_the_router_for_validation(self):
        args = self.records(self.make("build", "PLATFROM=android"))[0]["args"]
        self.assertEqual(args, ["Build/commands.py", "build", "PLATFROM=android", "--"])

    def test_quoted_values_and_paths_survive(self):
        args = self.records(self.make("benchmark", "DEVICE=my device's id", 'ARGS=--label candidate --media "/tmp/my movie\'s clip.mp4"'))[
            0
        ]["args"]
        self.assertIn("DEVICE=my device's id", args)
        self.assertEqual(args[-5:], ["--", "--label", "candidate", "--media", "/tmp/my movie's clip.mp4"])

    def test_commands_run_in_order_even_with_parallel_make_and_stop_on_failure(self):
        records = self.records(self.make("-j8", "build", "test", "PLATFORM=android", env={"CHECK_ORDER": "1"}))
        self.assertEqual([item["args"][1] for item in records], ["build", "test"])
        self.assertTrue(all("PLATFORM=android" in item["args"] for item in records))
        failed = self.make("build", "test", env={"STUB_EXIT": "7"})
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(len(failed.stdout.splitlines()), 1)

    def test_help_is_the_default_command_and_old_targets_do_not_exist(self):
        self.assertEqual(self.records(self.make())[0]["args"], ["Build/commands.py", "help", "--"])
        self.assertNotEqual(self.make("test-unit").returncode, 0)


if __name__ == "__main__":
    unittest.main()
