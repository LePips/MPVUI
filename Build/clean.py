#!/usr/bin/env python3
"""Remove build outputs and test results, including the native build store.

--cache also removes downloaded inputs, build tools, and generated test media.
Benchmark and performance reports are kept.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

from validation import EVIDENCE_ENV

ROOT = Path(__file__).resolve().parents[1]
OUTPUTS = (
    "validation",
    "coverage",
    "coverage-build",
    "device-tests",
    "build-tools",
    "updates",
    "android/native",
    "android/swift",
    "android/releases",
    "android/consumer",
    "android/profile7-test",
    "android/dovi-gpu-test",
)
CACHES = (
    "test-media",
    "test-media.state.json",
    "android/downloads",
    "android/upstream",
    "android/tools",
    "android/venv",
    "android/rust-vendor",
    "android/rust-vendor.sha256",
)


def remove(path, keep):
    """Remove a file or tree, descending only to preserve the paths in keep."""
    if path in keep or not (path.exists() or path.is_symlink()):
        return False
    if path.is_dir() and not path.is_symlink():
        if any(kept.is_relative_to(path) for kept in keep):
            return any([remove(child, keep) for child in path.iterdir()])
        shutil.rmtree(path)
    else:
        path.unlink()
    return True


def clean(root, *, cache, keep=frozenset()):
    """Remove managed outputs below root/.build and return the relative paths removed."""
    build = root / ".build"
    return [name for name in OUTPUTS + (CACHES if cache else ()) if remove(build / name, keep)]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", action="store_true", help="Also remove downloads, build tools, and generated test media")
    args = parser.parse_args(argv)
    # The validation runner writes this run's result after cleaning finishes.
    running = os.environ.get(EVIDENCE_ENV)
    keep = frozenset([Path(running).resolve().parent]) if running else frozenset()
    for name in clean(ROOT, cache=args.cache, keep=keep):
        print(f"Removed .build/{name}")
    if (ROOT / ".build/mpvbuild").exists():
        command = [sys.executable, str(ROOT / "Build/mpvbuild"), "clean"] + (["--cache"] if args.cache else [])
        return subprocess.run(command).returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
