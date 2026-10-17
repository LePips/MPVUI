#!/usr/bin/env python3
"""Prepare local fixtures, then run the package's Swift tests."""

from pathlib import Path
import subprocess
import sys

from prepare_test_media import prepare

ROOT = Path(__file__).resolve().parents[2]


def main(argv=None):
    arguments = list(sys.argv[1:] if argv is None else argv)
    inspection = {"-h", "--help", "--version", "--list-tests", "--show-codecov-path"}
    if not inspection.intersection(arguments) and arguments[:1] != ["list"]:
        prepare(ROOT / ".build/test-media")
    return subprocess.run(
        ["swift", "test", "--package-path", str(ROOT), "--no-parallel", *arguments],
        cwd=ROOT,
    ).returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"Test preparation failed: {error}")
