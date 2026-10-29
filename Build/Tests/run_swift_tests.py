#!/usr/bin/env python3
"""Prepare local fixtures, then run the package's Swift tests."""

import os
from pathlib import Path
import subprocess
import sys

from prepare_test_media import prepare

ROOT = Path(__file__).resolve().parents[2]
CAFFEINATE = Path("/usr/bin/caffeinate")


def keep_awake(command, caffeinate=CAFFEINATE):
    """Keep the display awake for AVFoundation readback and picture in picture, scoped to this process."""
    return [str(caffeinate), "-disu", *command] if os.access(caffeinate, os.X_OK) else command


def main(argv=None):
    arguments = list(sys.argv[1:] if argv is None else argv)
    command = ["swift", "test", "--package-path", str(ROOT), "--no-parallel", *arguments]
    inspection = {"-h", "--help", "--version", "--list-tests", "--show-codecov-path"}
    if not inspection.intersection(arguments) and arguments[:1] != ["list"]:
        prepare(ROOT / ".build/test-media")
        command = keep_awake(command)
    return subprocess.run(command, cwd=ROOT).returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"Test preparation failed: {error}")
