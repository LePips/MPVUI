"""Exercise the launcher without compiling Swift or requiring an Xcode installation."""

import fcntl
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

LAUNCHER = Path(__file__).resolve().parents[1] / "mpvbuild"
loader = importlib.machinery.SourceFileLoader("mpvbuild_launcher", str(LAUNCHER))
spec = importlib.util.spec_from_loader(loader.name, loader)
launcher = importlib.util.module_from_spec(spec)
loader.exec_module(launcher)


class LauncherTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.root = self.directory / "project's checkout"
        self.source = self.root / "Build/Sources/MPVBuildCore/Marker.swift"
        self.source.parent.mkdir(parents=True)
        self.source.write_text("original source")
        (self.root / "Build/Tests").mkdir()
        (self.root / "Build/Package.swift").write_text("package manifest")
        (self.root / "Build/Inputs.lock.json").write_text(
            json.dumps({"apple": {"toolchain": {"xcode": {"build": "pinned"}}, "sourceDateEpoch": 12345}})
        )
        shutil.copy2(LAUNCHER, self.root / "Build/mpvbuild")
        self.applications = self.directory / "Applications"
        self.developer = self.xcode("Xcode-pinned.app", "pinned")
        swift = self.developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        binary = (
            f"#!{sys.executable}\n"
            "import json,os,sys\nfrom pathlib import Path\n"
            "keys = ('DEVELOPER_DIR','LC_ALL','TZ','ZERO_AR_DATE','SOURCE_DATE_EPOCH','MPVBUILD_CODE_ROOT')\n"
            "print(json.dumps({'args':sys.argv[1:], 'environment':{k:os.environ[k] for k in keys}, 'umask':os.umask(0), "
            "'source':(Path(os.environ['MPVBUILD_CODE_ROOT'])/'Marker.swift').read_text()}))\n"
            "sys.exit(int(os.environ.get('TEST_BINARY_EXIT', '0')))\n"
        )
        swift.write_text(
            f"#!{sys.executable}\n"
            "import json,os,sys,time\nfrom pathlib import Path\n"
            "if sys.argv[1:] == ['--version']:\n"
            "    print(os.environ.get('TEST_SWIFT_VERSION','Swift test compiler'))\n"
            "    sys.exit(int(os.environ.get('TEST_VERSION_EXIT','0')))\n"
            "with open(os.environ['TEST_BUILD_LOG'],'a') as log:\n"
            "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "print('compiling launcher', flush=True)\n"
            "time.sleep(float(os.environ.get('TEST_BUILD_DELAY','0')))\n"
            "cache = Path(sys.argv[sys.argv.index('--scratch-path')+1])\n"
            "executable = cache/'release/mpvbuild'\n"
            "executable.parent.mkdir(parents=True,exist_ok=True)\n"
            f"executable.write_text({binary!r})\n"
            "executable.chmod(0o755)\n"
            "sys.exit(int(os.environ.get('TEST_BUILD_EXIT','0')))\n"
        )
        self.build_log = self.directory / "compilations.jsonl"
        self.environment = dict(os.environ, DEVELOPER_DIR=str(self.developer), TEST_BUILD_LOG=str(self.build_log))

    def xcode(self, name, build):
        developer = self.applications / name / "Contents/Developer"
        swift = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        swift.parent.mkdir(parents=True)
        swift.write_text("stub")
        swift.chmod(0o755)
        (developer.parent / "version.plist").write_bytes(plistlib.dumps({"ProductBuildVersion": build}))
        return developer

    def run_launcher(self, *arguments, **environment):
        return subprocess.run(
            [sys.executable, str(self.root / "Build/mpvbuild"), *arguments],
            cwd=self.directory,
            env={**self.environment, **environment},
            capture_output=True,
            text=True,
            timeout=15,
        )

    def record(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def compilations(self):
        return self.build_log.read_text().splitlines() if self.build_log.exists() else []

    def test_selects_pinned_xcode_and_ignores_invalid_installations(self):
        self.xcode("Xcode-other.app", "other")
        broken = self.xcode("Xcode-broken.app", "pinned")
        (broken.parent / "version.plist").write_text("invalid plist")
        self.assertEqual(launcher.select_developer("pinned", None, self.applications), self.developer)
        with self.assertRaisesRegex(ValueError, "Xcode missing is required"):
            launcher.select_developer("missing", None, self.applications)

    def test_explicit_developer_override_is_respected_without_falling_back(self):
        custom = self.xcode("Custom.app", "custom")
        self.assertEqual(launcher.select_developer("pinned", str(custom), self.applications), custom)
        with self.assertRaisesRegex(ValueError, "set DEVELOPER_DIR"):
            launcher.select_developer("pinned", str(self.directory / "missing"), self.applications)

    def test_rosetta_uses_arm64_tools_without_requiring_an_arm64_python(self):
        for machine, hardware, expected in (("arm64", "1", []), ("x86_64", "0", []), ("x86_64", "1", ["/usr/bin/arch", "-arm64"])):
            with (
                self.subTest(machine=machine, hardware=hardware),
                patch.object(launcher.platform, "machine", return_value=machine),
                patch.object(launcher.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=hardware)) as probe,
            ):
                self.assertEqual(launcher.native_prefix(), expected)
                if machine == "arm64":
                    probe.assert_not_called()

    def test_builds_once_and_preserves_arguments_environment_and_stdout(self):
        arguments = ["use", "local", "--artifact", "a file's $name;literal"]
        first = self.run_launcher(*arguments)
        record = self.record(first)
        self.assertEqual(record["args"], ["--root", str(self.root), *arguments])
        self.assertEqual(record["umask"], 0o022)
        self.assertEqual(record["source"], "original source")
        environment = record["environment"]
        self.assertEqual(environment["DEVELOPER_DIR"], str(self.developer))
        self.assertEqual(
            {key: environment[key] for key in ("LC_ALL", "TZ", "ZERO_AR_DATE", "SOURCE_DATE_EPOCH")},
            {"LC_ALL": "C", "TZ": "UTC", "ZERO_AR_DATE": "1", "SOURCE_DATE_EPOCH": "12345"},
        )
        self.assertNotEqual(Path(environment["MPVBUILD_CODE_ROOT"]), self.source.parent)
        second = self.run_launcher(*arguments)
        self.assertEqual(self.record(second), record)
        self.assertEqual(len(self.compilations()), 1)
        self.assertIn("compiling launcher", first.stderr)
        self.assertEqual(second.stderr, "")

    def test_native_architecture_is_used_for_compilation_and_execution(self):
        prefix = ["/usr/bin/arch", "-arm64"]
        executable = self.directory / "compiled tool"
        swift = self.developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        with (
            patch.object(launcher, "ROOT", self.root),
            patch.dict(os.environ, self.environment, clear=True),
            patch.object(launcher.os, "umask"),
            patch.object(launcher, "native_prefix", return_value=prefix),
            patch.object(launcher.subprocess, "check_output", return_value="Swift compiler") as version,
            patch.object(launcher, "build_cli", return_value=executable) as build,
            patch.object(launcher.os, "execve") as execute,
        ):
            launcher.main(["status"])
        self.assertEqual(version.call_args.args[0], prefix + [str(swift), "--version"])
        self.assertEqual(build.call_args.args[2:4], (swift, prefix))
        self.assertEqual(execute.call_args.args[0], prefix[0])
        self.assertEqual(execute.call_args.args[1], prefix + [str(executable), "--root", str(self.root), "status"])

    def test_source_and_toolchain_changes_rebuild_the_cli(self):
        self.record(self.run_launcher())
        self.source.write_text("updated source")
        self.assertEqual(self.record(self.run_launcher())["source"], "updated source")
        self.record(self.run_launcher(TEST_SWIFT_VERSION="new compiler"))
        (self.developer.parent / "version.plist").write_bytes(plistlib.dumps({"ProductBuildVersion": "new build"}))
        self.record(self.run_launcher(TEST_SWIFT_VERSION="new compiler"))
        (self.root / "Build/Package.swift").write_text("new package manifest")
        self.record(self.run_launcher(TEST_SWIFT_VERSION="new compiler"))
        self.assertEqual(len(self.compilations()), 5)

    def test_failure_is_forwarded_and_an_incomplete_cache_is_rebuilt(self):
        failed = self.run_launcher(TEST_BUILD_EXIT="7")
        self.assertEqual(failed.returncode, 7)
        self.assertEqual(failed.stdout, "")
        self.assertIn("compiling launcher", failed.stderr)
        self.assertNotIn("Traceback", failed.stderr)
        self.record(self.run_launcher())
        self.assertEqual(len(self.compilations()), 2)
        self.assertEqual(self.run_launcher(TEST_BINARY_EXIT="9").returncode, 9)
        self.assertEqual(len(self.compilations()), 2)

    def test_compiler_version_failure_stops_before_compilation(self):
        failed = self.run_launcher(TEST_VERSION_EXIT="6")
        self.assertEqual(failed.returncode, 6)
        self.assertEqual(failed.stdout, "")
        self.assertIn("Swift test compiler", failed.stderr)
        self.assertEqual(self.compilations(), [])

    def test_concurrent_launches_share_one_compilation(self):
        processes = []
        try:
            for _ in range(2):
                processes.append(
                    subprocess.Popen(
                        [sys.executable, str(self.root / "Build/mpvbuild"), "status"],
                        env={**self.environment, "TEST_BUILD_DELAY": "0.3"},
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                )
            records = []
            for process in processes:
                stdout, stderr = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0, stderr)
                records.append(json.loads(stdout))
            self.assertEqual(records[0], records[1])
            self.assertEqual(len(self.compilations()), 1)
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=15)

    def test_compiler_keeps_the_lock_after_launcher_death_and_retry_succeeds(self):
        process = subprocess.Popen(
            [sys.executable, str(self.root / "Build/mpvbuild")],
            env={**self.environment, "TEST_BUILD_DELAY": "60"},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stderr, selectors.EVENT_READ)
                self.assertTrue(selector.select(timeout=10), "Bootstrap did not start")
                self.assertIn(b"compiling launcher", os.read(process.stderr.fileno(), 4096))
            process.kill()
            process.wait(timeout=15)
            arguments = json.loads(self.compilations()[0])
            cache = Path(arguments[arguments.index("--scratch-path") + 1])
            with cache.with_suffix(".lock").open("a") as lock:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=15)
            self.record(self.run_launcher())
            self.assertEqual(len(self.compilations()), 2)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=15)


if __name__ == "__main__":
    unittest.main()
