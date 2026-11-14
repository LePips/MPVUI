"""Exercise the just interface without building native dependencies or using a device."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import commands

ROOT = Path(__file__).resolve().parents[2]


class JustRecipesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "project's checkout"
        (self.root / "Build/Tests").mkdir(parents=True)
        for relative in ("justfile", "Build/commands.py", "Build/validation.py"):
            shutil.copyfile(ROOT / relative, self.root / relative)
        self.python = self.root / "python's stub"
        self.python.write_text(
            f"#!{sys.executable}\n"
            "import json,os,sys\n"
            "from pathlib import Path\n"
            "args=sys.argv[1:]\n"
            "if os.environ.get('CHECK_ORDER'):\n"
            "    marker=Path('build-complete')\n"
            "    if args[1]=='build': marker.touch()\n"
            "    if args[1]=='test' and not marker.exists(): sys.exit(9)\n"
            "leaked={k:os.environ[k] for k in ('MAKEFLAGS','MFLAGS','MAKEOVERRIDES','MAKELEVEL','SUITE','PLATFORM','JSON') if k in os.environ}\n"
            "print(json.dumps({'cwd':os.getcwd(),'args':args,'leaked':leaked}))\n"
            "sys.exit(int(os.environ.get('STUB_EXIT','0')))\n"
        )
        self.python.chmod(0o755)

    def environment(self, extra=None):
        environment = {key: value for key, value in os.environ.items() if not key.startswith("JUST_")}
        environment.update(extra or {})
        return environment

    def just(self, *args, cwd=None, env=None, python=None):
        return subprocess.run(
            ["just", "--set", "python", str(python or self.python), *args],
            cwd=cwd or self.root,
            env=self.environment(env),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def records(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def routed(self, result):
        (record,) = self.records(result)
        self.assertEqual(record["cwd"], str(self.root.resolve()))
        self.assertEqual(record["args"][0], "Build/commands.py")
        self.assertEqual(record["leaked"], {})
        return commands.parse(record["args"][1:])

    def test_every_recipe_preserves_the_router_defaults(self):
        for name in commands.COMMANDS:
            with self.subTest(command=name):
                self.assertEqual(self.routed(self.just(name)), (name, commands.Options(), []))

    def test_named_flags_and_tool_arguments_route_to_the_selected_workflow(self):
        cases = (
            ("setup", ["--platform", "android"], {"platform": "android"}, []),
            ("build", ["--platform", "android", "--profile", "release"], {"platform": "android", "profile": "release"}, ["--clean"]),
            (
                "test",
                ["--platform", "android", "--suite", "example", "--device", "emulator-5554", "--profile", "release"],
                {"platform": "android", "suite": "example", "device": "emulator-5554", "profile": "release"},
                ["--info"],
            ),
            ("test", ["--filter", "PlaybackTests"], {"filter": "PlaybackTests"}, []),
            ("release", ["--step", "repro", "--profile", "release"], {"step": "repro", "profile": "release"}, ["--fresh"]),
            ("benchmark", ["--step", "ab", "--device", "phone"], {"step": "ab", "device": "phone"}, ["run", "--help"]),
            ("select", [], {}, ["--remote"]),
            ("update", [], {}, ["--all"]),
            ("clean", [], {}, ["--cache"]),
            ("format", ["--check"], {"check": True}, []),
        )
        for name, flags, values, arguments in cases:
            with self.subTest(command=name, flags=flags):
                actual = self.routed(self.just(name, *flags, "--json", "--", *arguments))
                self.assertEqual(actual, (name, commands.Options(**values, json=True), arguments))
                self.assertTrue(commands.resolve(actual[0], actual[1]))

    def test_recipe_discovery_from_subdirectories_keeps_the_project_working_directory(self):
        args = ("test", "--suite", "unit", "--json", "--", "--check")
        expected = self.records(self.just(*args))
        for directory in ("Build", "Build/Tests"):
            self.assertEqual(self.records(self.just(*args, cwd=self.root / directory)), expected)

    def test_invalid_recipe_flags_fail_before_a_tool_runs(self):
        for args in (
            ("build", "--platfrom", "android"),
            ("build", "--platform", "other"),
            ("build", "--profile", "fast"),
            ("build", "--suite", "unit"),
            ("format", "--platform", "android"),
            ("select", "--step", "adopt"),
        ):
            with self.subTest(args=args):
                result = self.just(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_invalid_workflow_selections_use_the_public_flag_names(self):
        for args, message in (
            (("test", "--suite", "missing"), "--suite for just test --platform apple must be one of"),
            (("test", "--suite", "unit", "--device", "phone"), "--device does not apply"),
            (("test", "--suite", "core", "--filter", "Name"), "--filter runs Apple package tests"),
            (("release", "--platform", "android", "--step", "publish"), "takes no --step"),
        ):
            with self.subTest(args=args):
                result = self.just(*args, python=sys.executable)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertIn(message, result.stderr)

    def test_shell_sensitive_values_and_argument_boundaries_survive(self):
        device = "my device's id $(touch injected)"
        arguments = ["--label", 'a "quoted" label', "--media", "/tmp/my movie's clip.mp4", "", "$HOME", "test"]
        actual = self.routed(self.just("benchmark", "--device", device, "--", *arguments))
        self.assertEqual(actual, ("benchmark", commands.Options(device=device), arguments))
        self.assertFalse((self.root / "injected").exists())
        self.assertEqual(self.routed(self.just("test", "--suite=unit"))[1].suite, "unit")

    def test_make_jobserver_environment_does_not_reach_native_tools(self):
        environment = {key: "inherited" for key in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "MAKELEVEL")}
        self.routed(self.just("build", "--platform", "android", env=environment))

    def test_shell_chains_run_in_order_and_stop_on_failure(self):
        script = '"$1" --set python "$2" build --platform android && "$1" --set python "$2" test --platform android'

        def chain(extra):
            return subprocess.run(
                ["sh", "-c", script, "just-chain", shutil.which("just"), str(self.python)],
                cwd=self.root,
                env=self.environment({"CHECK_ORDER": "1", **extra}),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

        records = self.records(chain({}))
        self.assertEqual([item["args"][1] for item in records], ["build", "test"])
        self.assertTrue(all("PLATFORM=android" in item["args"] for item in records))
        failed = chain({"STUB_EXIT": "7"})
        self.assertEqual(failed.returncode, 7)
        self.assertEqual(len(failed.stdout.splitlines()), 1)

    def test_tool_arguments_are_owned_by_one_recipe(self):
        self.assertEqual(self.routed(self.just("build", "test"))[2], ["test"])
        self.assertEqual(self.routed(self.just("build", "--", "--help"))[2], ["--help"])

    def test_default_help_and_builtin_discovery(self):
        self.assertEqual(self.records(self.just())[0]["args"], ["Build/commands.py", "help", "--"])
        listing = self.just("--list")
        self.assertEqual(listing.returncode, 0, listing.stderr)
        for name in commands.COMMANDS:
            self.assertIn(f"    {name} ", listing.stdout)
        usage = self.just("--usage", "test")
        self.assertEqual(usage.returncode, 0, usage.stderr)
        for option in (*commands.COMMANDS["test"].options, "JSON"):
            self.assertIn(commands.flag(option), usage.stdout)
        self.assertNotEqual(self.just("test-unit").returncode, 0)


if __name__ == "__main__":
    unittest.main()
