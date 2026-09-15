#!/usr/bin/env python3
"""Build and measure the locked production subtitle header without network access.

Compilation, fixture creation, warmup, and output validation are excluded from
samples. This measures CPU conversion/cache lookup, not GPU rendering/playback.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tempfile


HARNESS_ROOT = Path(__file__).resolve().parents[2]
HEADERS = ("video/out/avfoundation_color.h", "video/out/avfoundation_color_math.h")


class BenchmarkError(Exception):
    """A local prerequisite or workload validation failure."""


def bounded_integer(minimum: int, maximum: int):
    def parse(text: str) -> int:
        try:
            value = int(text)
        except ValueError as error:
            raise argparse.ArgumentTypeError("expected an integer") from error
        if not minimum <= value <= maximum:
            raise argparse.ArgumentTypeError(f"must be between {minimum} and {maximum}")
        return value
    return parse


def command(arguments: list[str], *, cwd: Path | None = None,
            env: dict[str, str] | None = None, timeout: int = 120) -> str:
    try:
        result = subprocess.run(arguments, cwd=cwd, env=env, check=True, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.CalledProcessError as error:
        raise BenchmarkError(f"{Path(arguments[0]).name} failed:\n{error.stderr[-12000:]}") from error
    except subprocess.TimeoutExpired as error:
        raise BenchmarkError(f"{Path(arguments[0]).name} exceeded {timeout} seconds") from error
    return result.stdout


def validate_patches(root: Path, lock: dict) -> str:
    records = []
    for source in lock["sources"]:
        for patch in source["patches"]:
            relative = Path(patch["path"])
            path = (root / relative).resolve()
            if relative.is_absolute() or not path.is_relative_to(root):
                raise BenchmarkError(f"Locked patch escapes source root: {relative}")
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            if actual != patch["sha256"]:
                raise BenchmarkError(f"Native patch checksum drift: {relative}; update the lock intentionally first")
            records.append({"source": source["id"], "path": patch["path"], "sha256": actual})
    return hashlib.sha256(json.dumps(records, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def find_toolchain(lock: dict) -> tuple[Path, Path, dict]:
    expected = lock["toolchain"]["xcode"]
    override = os.environ.get("DEVELOPER_DIR")
    candidates = [Path(override).expanduser()] if override else [
        app / "Contents/Developer" for app in sorted(Path("/Applications").glob("Xcode*.app"))]
    developer = None
    for candidate in candidates:
        # DEVELOPER_DIR may name either the application or Contents/Developer.
        if candidate.suffix == ".app":
            candidate = candidate / "Contents/Developer"
        version_file = candidate.parent / "version.plist"
        if version_file.is_file():
            version = plistlib.loads(version_file.read_bytes())
            if version.get("ProductBuildVersion") == expected["build"]:
                developer = candidate.resolve()
                break
    if developer is None:
        suffix = " (DEVELOPER_DIR points to a different or invalid Xcode)" if override else ""
        raise BenchmarkError(f"Install pinned Xcode {expected['version']} ({expected['build']}){suffix}")
    clang = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
    sdk = developer / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    compiler = command([str(clang), "--version"]).splitlines()[0]
    if compiler != expected["clang"]:
        raise BenchmarkError(f"Pinned compiler mismatch: expected {expected['clang']!r}, found {compiler!r}")
    if not sdk.is_dir():
        raise BenchmarkError(f"Pinned macOS SDK is missing: {sdk}")
    return clang, sdk, {"version": compiler, "xcodeBuild": expected["build"],
                        "optimization": "-O3", "sanitizers": False}


def find_libplacebo(source_root: Path, explicit: Path | None) -> tuple[Path, dict]:
    candidates = [explicit.expanduser().resolve()] if explicit else []
    if not explicit:
        target = f"macos-{platform.machine()}"
        for root in dict.fromkeys((source_root, HARNESS_ROOT)):
            cache = root / ".build/mpvbuild/products/dependencies/libplacebo" / target
            candidates.extend(sorted(cache.glob("*/include")))
    include = next((path for path in candidates if (path / "libplacebo/colorspace.h").is_file()), None)
    if include is None:
        raise BenchmarkError("Cached libplacebo headers are missing; build the native macOS slice first "
                             "or pass --libplacebo-include PATH (no download is attempted)")
    digest = hashlib.sha256()
    for header in sorted((include / "libplacebo").rglob("*.h")):
        digest.update(header.relative_to(include).as_posix().encode() + b"\0")
        digest.update(header.read_bytes())
        digest.update(b"\0")
    return include, {"includePath": str(include), "headersSHA256": digest.hexdigest()}


def run(args: argparse.Namespace) -> dict:
    if platform.system() != "Darwin":
        raise BenchmarkError("The native subtitle benchmark requires macOS and the pinned Xcode")
    source_root = args.source_root.expanduser().resolve()
    lock_path = source_root / "Build/Inputs.lock.json"
    lock = json.loads(lock_path.read_text())
    patch_fingerprint = validate_patches(source_root, lock)
    clang, sdk, compiler = find_toolchain(lock)
    include, libplacebo = find_libplacebo(source_root, args.libplacebo_include)
    if args.width * args.height * (args.repetitions * args.cold_iterations + args.warmup) > 2_000_000_000:
        raise BenchmarkError("Requested cold workload exceeds two billion pixel visits; reduce repetitions or iterations")
    if args.repetitions * args.cached_iterations > 50_000_000:
        raise BenchmarkError("Requested cached workload exceeds fifty million frames")
    with tempfile.TemporaryDirectory(prefix="mpv-subtitle-benchmark-") as temporary:
        work = Path(temporary)
        env = dict(os.environ)
        for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
            env.pop(key, None)
        env["GIT_CEILING_DIRECTORIES"] = str(work.parent)
        source = next(item for item in lock["sources"] if item["id"] == "mpv")
        for patch in source["patches"]:
            command(["git", "apply", "--allow-empty", *[f"--include={header}" for header in HEADERS],
                     str(source_root / patch["path"])], cwd=work, env=env)
        header = work / HEADERS[0]
        if not header.is_file() or "avf_cached_subtitle_image(" not in header.read_text():
            raise BenchmarkError("This source revision has no native subtitle cache API; "
                                 "benchmark a revision containing the subtitle image cache patch")
        binary = work / "native_subtitles"
        native_source = Path(__file__).with_suffix(".m")
        build = [str(clang), "-isysroot", str(sdk), "-I", str(header.parent), "-I", str(include),
                 "-O3", "-fno-objc-arc", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations",
                 str(native_source), "-o", str(binary)]
        for framework in ("Foundation", "CoreVideo", "CoreMedia", "CoreGraphics", "CoreImage", "CoreText"):
            build += ["-framework", framework]
        command(build, cwd=work, env=env)
        raw = command([str(binary), str(args.width), str(args.height), str(args.repetitions),
                       str(args.warmup), str(args.cold_iterations), str(args.cached_iterations)],
                      cwd=work, env=env, timeout=300)
        result = json.loads(raw)
        for workload in result["workloads"]:
            for metric in workload["metrics"].values():
                samples = metric["samples"]
                if len(samples) != args.repetitions or any(not math.isfinite(value) or value <= 0 for value in samples):
                    raise BenchmarkError("Native benchmark emitted invalid timing samples")
        result["native"] = {"patchFingerprint": patch_fingerprint, "compiler": compiler,
                            "libplacebo": libplacebo, "sourceCommit": source["commit"],
                            "productionHeaderSHA256": hashlib.sha256(header.read_bytes()).hexdigest(),
                            "harnessSHA256": hashlib.sha256(native_source.read_bytes()).hexdigest(),
                            "helperSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                            "validation": result.pop("validation"),
                            "measurement": "CPU subtitle image conversion/cache lookup including frame autorelease pool; excludes GPU rendering"}
        return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=HARNESS_ROOT)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--libplacebo-include", type=Path)
    parser.add_argument("--width", type=bounded_integer(128, 4096), default=1920)
    parser.add_argument("--height", type=bounded_integer(72, 2160), default=1080)
    parser.add_argument("--repetitions", type=bounded_integer(1, 31), default=3)
    parser.add_argument("--warmup", type=bounded_integer(1, 20), default=1)
    parser.add_argument("--cold-iterations", type=bounded_integer(1, 100), default=2)
    parser.add_argument("--cached-iterations", type=bounded_integer(1, 5000000), default=100000)
    args = parser.parse_args()
    try:
        output = args.output.expanduser().absolute()
        if output.exists() or output.is_symlink():
            raise BenchmarkError(f"Output already exists: {output}; choose a new result path")
        result = run(args)
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", dir=output.parent, prefix=f".{output.name}.",
                                         suffix=".tmp", delete=False) as handle:
            temporary = Path(handle.name)
            try:
                json.dump(result, handle, indent=2, sort_keys=True, allow_nan=False)
                handle.write("\n")
                handle.flush()
                # Publish a complete file atomically, without replacing a result
                # created by another process after the preflight existence check.
                os.link(temporary, output)
            finally:
                temporary.unlink(missing_ok=True)
    except (BenchmarkError, OSError, ValueError, KeyError, StopIteration) as error:
        print(f"Native subtitle benchmark: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
