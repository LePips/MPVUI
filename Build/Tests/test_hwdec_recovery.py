"""Exercise the production native decoder recovery policy with sanitizers."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class HardwareDecoderRecoveryTests(unittest.TestCase):
    def run_checked(self, arguments, **kwargs):
        result = subprocess.run(arguments, capture_output=True, text=True, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_recovery_policy_with_sanitizers(self):
        compiler = shutil.which("clang")
        self.assertIsNotNone(compiler, "Native recovery tests require clang")
        with tempfile.TemporaryDirectory(prefix="mpvui-hwdec-recovery-") as directory:
            work = Path(directory)
            env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(work.parent))
            self.run_checked(
                [
                    "git",
                    "apply",
                    "--include=video/decode/hwdec_recovery.h",
                    str(ROOT / "Build/Patches/mpv/0008-bounded-hardware-decoder-recovery.patch"),
                ],
                cwd=work,
                env=env,
            )
            binary = work / "recovery"
            self.run_checked(
                [
                    compiler,
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-fsanitize=address,undefined",
                    "-I",
                    str(work / "video/decode"),
                    str(ROOT / "Build/Tests/NativeHDR/recovery.c"),
                    "-o",
                    str(binary),
                ],
            )
            result = self.run_checked([str(binary)])
            self.assertIn("explicit overrides passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
