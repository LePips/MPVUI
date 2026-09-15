"""Capture comparable local benchmarks without changing Git or binary selections."""
import argparse
import contextlib
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

from comparison import compare_reports, render_markdown

ROOT = Path(__file__).resolve().parents[2]
SUITES = ("micro", "playback", "subtitle", "size")


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def capture(arguments, *, cwd=None, env=None):
    result = subprocess.run(arguments, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError(f"Command failed ({result.returncode}): {arguments[0]}\n"
                         + (result.stderr or result.stdout)[-4000:])
    return result.stdout.strip()


def write_json(path, value):
    """Publish complete JSON without replacing an earlier run."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n"
    descriptor, temporary = tempfile.mkstemp(prefix=".benchmark-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(data)
        os.link(temporary, path)  # fails atomically if another run already exists
    finally:
        os.unlink(temporary)


def source_identity(root):
    files = [root / "Package.swift", root / "Build/Inputs.lock.json"]
    for relative in ("Sources", "Build/Sources", "Build/Patches", "Tests/Benchmarks"):
        directory = root / relative
        if directory.exists():
            files.extend(path for path in directory.rglob("*") if path.is_file()
                         and "__pycache__" not in path.parts)
    entries = {str(path.relative_to(root)): sha256(path)
               for path in sorted(set(files)) if path.is_file()}
    digest = hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()
    return {
        "gitCommit": capture(["git", "rev-parse", "HEAD"], cwd=root),
        "gitDirty": bool(capture(["git", "status", "--porcelain"], cwd=root)),
        "sourceSHA256": digest,
        "files": entries,
    }


def pinned_developer(root):
    lock = json.loads((root / "Build/Inputs.lock.json").read_text())
    expected = lock["toolchain"]["xcode"]["build"]
    override = os.environ.get("DEVELOPER_DIR")
    candidates = [Path(override)] if override else sorted(Path("/Applications").glob("Xcode*.app/Contents/Developer"))
    for developer in candidates:
        version = developer.parent / "version.plist"
        if version.is_file() and plistlib.loads(version.read_bytes()).get("ProductBuildVersion") == expected:
            return developer, expected
    raise ValueError(f"Install the pinned Xcode build {expected}, or set DEVELOPER_DIR to it.")


def power_state():
    battery = capture(["/usr/bin/pmset", "-g", "batt"])
    match = re.search(r"Now drawing from '([^']+)'", battery)
    source = match.group(1) if match else "unknown"
    settings = capture(["/usr/bin/pmset", "-g", "custom"])
    active = False
    modes = {}
    for line in settings.splitlines():
        if line.endswith(":"):
            active = line.strip() == source + ":"
        elif active:
            parts = line.split()
            if len(parts) == 2 and parts[0] in ("powermode", "lowpowermode", "highpowermode"):
                modes[parts[0]] = parts[1]
    return {"source": source, "modes": modes}


def environment_identity(root, developer, xcode_build, suites):
    swift = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    # The runner and comparison rules are part of the measurement protocol,
    # including when --package-path selects an older production checkout.
    protocol_files = [ROOT / "Build/Benchmarks/benchmark.py",
                      ROOT / "Build/Benchmarks/comparison.py"]
    if set(suites) & {"micro", "playback"}:
        swift_protocol = sorted((root / "Tests/Benchmarks").glob("*.swift"))
        if not swift_protocol:
            raise ValueError("Missing Tests/Benchmarks Swift workloads in this checkout.")
        protocol_files += swift_protocol
    if "subtitle" in suites:
        protocol_files.append(ROOT / "Build/Benchmarks/native_subtitles.m")
        protocol_files.append(ROOT / "Build/Benchmarks/native_subtitles.py")
    protocol = {path.name: sha256(path) for path in protocol_files}
    key = {
        "host": hashlib.sha256(platform.node().encode()).hexdigest()[:16],
        "architecture": platform.machine(),
        "hardwareModel": capture(["/usr/sbin/sysctl", "-n", "hw.model"]),
        "logicalCPUs": int(capture(["/usr/sbin/sysctl", "-n", "hw.logicalcpu"])),
        "physicalMemoryBytes": int(capture(["/usr/sbin/sysctl", "-n", "hw.memsize"])),
        "operatingSystem": capture(["/usr/bin/sw_vers", "-productVersion"]),
        "operatingSystemBuild": capture(["/usr/bin/sw_vers", "-buildVersion"]),
        "xcodeBuild": xcode_build,
        "swiftVersion": capture([str(swift), "--version"]),
        "power": power_state(),
        "benchmarkProtocol": protocol,
        "configuration": "release",
    }
    return {"comparisonKey": key, "loadAverageBefore": list(os.getloadavg())}


def selected_framework(root, developer, explicit=None):
    if explicit:
        framework = Path(explicit).resolve()
    else:
        swift = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        manifest = json.loads(capture(
            [str(swift), "package", "--package-path", str(root), "dump-package"],
            env=dict(os.environ, DEVELOPER_DIR=str(developer)),
        ))
        targets = [target for target in manifest["targets"]
                   if target["type"] == "binary" and target.get("name") == "Libmpv-GPL"]
        if len(targets) != 1 or not targets[0].get("path"):
            raise ValueError("Size capture needs a local Libmpv selection or --framework /path/to/Libmpv.xcframework.")
        framework = (root / targets[0]["path"]).resolve()
    if not (framework / "Info.plist").is_file():
        raise ValueError(f"Not an available XCFramework: {framework}")
    return framework


def binary_workloads(framework):
    manifest = plistlib.loads((framework / "Info.plist").read_bytes())
    workloads, binaries = [], []
    for library in manifest["AvailableLibraries"]:
        identifier = library["LibraryIdentifier"]
        relative = library.get("BinaryPath", library["LibraryPath"] + "/Libmpv")
        binary = (framework / identifier / relative).resolve()
        if not binary.is_relative_to(framework.resolve()) or not binary.is_file():
            raise ValueError(f"Invalid framework binary path: {identifier}/{relative}")
        parameters = {"platform": library["SupportedPlatform"],
                      "variant": library.get("SupportedPlatformVariant", ""),
                      "architectures": sorted(library["SupportedArchitectures"])}
        binaries.append({"id": identifier, "path": str(binary), "sha256": sha256(binary),
                         "bytes": binary.stat().st_size, **parameters})
        workloads.append({"id": "binary_size_" + identifier, "parameters": parameters,
                          "metrics": {"binaryBytes": {"unit": "bytes", "direction": "lower",
                                                      "samples": [binary.stat().st_size]}}})
    if not workloads:
        raise ValueError("XCFramework contains no platform binaries.")
    return workloads, binaries


def run_step(arguments, log, *, env):
    with Path(log).open("w") as stream:
        result = subprocess.run(arguments, stdout=stream, stderr=subprocess.STDOUT, env=env)
    if result.returncode:
        raise ValueError(f"Benchmark step failed ({result.returncode}); see {log}")


@contextlib.contextmanager
def measurement_lock():
    """Prevent this harness from timing two checkouts concurrently."""
    import fcntl

    path = Path(tempfile.gettempdir()) / f"mpvui-benchmarks-{os.getuid()}.lock"
    with path.open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Another local MPVUI benchmark is running; wait for it to finish.") from None
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def run_benchmarks(args):
    if sys.platform != "darwin":
        raise ValueError("Runtime capture requires macOS; report comparison works on other platforms.")
    root = args.package_path.resolve()
    suites = list(SUITES) if args.suites == "all" else args.suites.split(",")
    if not suites or len(suites) != len(set(suites)) or set(suites) - set(SUITES):
        raise ValueError("--suites must be all or a comma-separated selection of " + ",".join(SUITES))
    repetitions = 1 if args.quick else args.repetitions
    seconds = 2.0 if args.quick else args.seconds
    warmup = 1.0 if args.quick else args.warmup
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    output = (args.output or root / f".build/benchmarks/{timestamp}-{args.label}.json").resolve()
    if output.exists():
        raise ValueError(f"Report already exists; choose a new --output: {output}")
    developer, xcode_build = pinned_developer(root)
    env = dict(os.environ, DEVELOPER_DIR=str(developer))
    logs = root / f".build/benchmarks/logs/{timestamp}-{args.label}"
    logs.mkdir(parents=True, exist_ok=False)
    with measurement_lock():
        before = source_identity(root)
        environment = environment_identity(root, developer, xcode_build, suites)
        if "playback" in suites and args.media is None:
            subprocess.run([sys.executable, str(root / "Build/Tests/prepare_test_media.py"),
                            "--group", "baseline"], check=True)
        media = (args.media or root / ".build/test-media/01-h264-aac-baseline.mp4").resolve()
        if "playback" in suites and not media.is_file():
            raise ValueError(f"Media does not exist: {media}")
        media_sha = sha256(media) if "playback" in suites else None
        workloads, binaries = [], []
        framework = None
        if "size" in suites:
            framework = selected_framework(root, developer, args.framework)
            sizes, binaries = binary_workloads(framework)
            workloads += sizes
        runtime, native = {}, {}
        swift_suites = [suite for suite in suites if suite in ("micro", "playback")]
        if swift_suites:
            if not shutil.which("xcodebuildmcp"):
                raise ValueError("Install xcodebuildmcp to run the Swift benchmark workloads.")
            raw = logs / "swift-workloads.json"
            print("Swift…", flush=True)
            swift_env = dict(env, MPVUI_RUN_PERFORMANCE_BENCHMARKS="1", MPVUI_PERF_OUTPUT=str(raw),
                             MPVUI_PERF_MEDIA=str(media), MPVUI_PERF_REPETITIONS=str(repetitions),
                             MPVUI_PERF_SAMPLE_SECONDS=str(seconds), MPVUI_PERF_WARMUP_SECONDS=str(warmup),
                             MPVUI_PERF_NATIVE_READBACK=args.native_readback,
                             MPVUI_PERF_SUITES=",".join(swift_suites))
            step_log = logs / "swift-tool.json"
            run_step(["xcodebuildmcp", "swift-package", "test", "--package-path", str(root),
                      "--configuration", "release", "--filter", "MPVPerformanceBenchmarkTests",
                      "--output", "json"], step_log, env=swift_env)
            result = json.loads(step_log.read_text())
            if result.get("didError") or result.get("data", {}).get("summary", {}).get("status") != "SUCCEEDED":
                raise ValueError(f"Swift benchmark failed; see {step_log}")
            if not raw.is_file():
                raise ValueError(f"Swift workloads produced no report. Check the benchmark opt-in/test source; see {step_log}")
            measured = json.loads(raw.read_text())
            workloads += measured["workloads"]
            runtime = measured.get("runtime", {})
            if binaries and runtime.get("libraryKind") == "dynamic-library":
                mac = [binary for binary in binaries if binary["platform"] == "macos"]
                if len(mac) != 1 or mac[0]["sha256"] != runtime.get("librarySHA256"):
                    raise ValueError("The measured libmpv differs from the size artifact. Select the same artifact or omit --framework.")
        if "subtitle" in suites:
            print("Subtitles…", flush=True)
            raw = logs / "subtitle-workloads.json"
            command = [sys.executable, str(ROOT / "Build/Benchmarks/native_subtitles.py"),
                       "--source-root", str(root), "--output", str(raw),
                       "--repetitions", str(repetitions), "--warmup", "1",
                       "--cold-iterations", "2", "--cached-iterations", "100000",
                       "--width", str(args.subtitle_width), "--height", str(args.subtitle_height)]
            if args.libplacebo_include:
                command += ["--libplacebo-include", str(args.libplacebo_include.resolve())]
            run_step(command, logs / "subtitle-build.log", env=env)
            measured = json.loads(raw.read_text())
            workloads += measured["workloads"]
            native = measured.get("native", {})
        after = source_identity(root)
        if before["sourceSHA256"] != after["sourceSHA256"]:
            raise ValueError("Sources changed during capture. Rerun without editing or switching artifacts.")
        after_environment = environment_identity(root, developer, xcode_build, suites)
        if environment["comparisonKey"] != after_environment["comparisonKey"]:
            raise ValueError("Benchmark harness or environment changed during capture; rerun with fixed inputs.")
        if media_sha is not None and sha256(media) != media_sha:
            raise ValueError("Media changed during capture; no mixed report was saved.")
        if framework and binary_workloads(framework)[1] != binaries:
            raise ValueError("Native artifact changed during capture; rerun on a fixed selection.")
        if environment["comparisonKey"]["power"] != power_state():
            raise ValueError("Power source/mode changed during capture; rerun with stable power settings.")
        environment["loadAverageAfter"] = list(os.getloadavg())
        report = {"label": args.label, "createdAt": timestamp,
                  "environment": environment, "source": {**before, "binaries": binaries},
                  "configuration": {"suites": suites, "repetitions": repetitions,
                                    "sampleSeconds": seconds, "warmupSeconds": warmup,
                                    "nativeReadbackPolicy": args.native_readback,
                                    "mediaPath": str(media) if media_sha else None, "mediaSHA256": media_sha},
                  "runtime": runtime, "native": native, "workloads": workloads, "logs": str(logs),
                  "limitations": "Local sampled process CPU/RSS and focused microbenchmarks. No energy or statistical significance claim. Run on the same display with other workloads idle."}
        compare_reports(report, report)  # reject incomplete/non-finite workload data
        write_json(output, report)
    print(f"Saved {output}")
    return 0


def finite_range(low, high):
    def parse(text):
        value = float(text)
        if not math.isfinite(value) or not low <= value <= high:
            raise argparse.ArgumentTypeError(f"must be between {low} and {high}")
        return value
    return parse


def bounded_int(low, high):
    def parse(text):
        value = int(text)
        if not low <= value <= high:
            raise argparse.ArgumentTypeError(f"must be between {low} and {high}")
        return value
    return parse


def label(text):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", text):
        raise argparse.ArgumentTypeError("use 1–64 letters, digits, dots, underscores or hyphens")
    return text


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="Capture the current checkout and selected native artifact")
    run.add_argument("--label", required=True, type=label)
    run.add_argument("--package-path", type=Path, default=ROOT)
    run.add_argument("--output", type=Path)
    run.add_argument("--suites", default="all", help="all or comma-separated micro,playback,subtitle,size")
    run.add_argument("--quick", action="store_true", help="One repetition and two-second playback samples; smoke checks only")
    run.add_argument("--repetitions", type=bounded_int(1, 20), default=3)
    run.add_argument("--seconds", type=finite_range(1, 60), default=3.0)
    run.add_argument("--warmup", type=finite_range(0.5, 30), default=1.0)
    run.add_argument("--media", type=Path)
    run.add_argument("--native-readback", choices=("required", "optional"), default="required",
                     help="Require native pixels (default), or record unavailable readback explicitly without rejecting CPU/counter capture")
    run.add_argument("--framework", type=Path, help="Explicit XCFramework for size capture")
    run.add_argument("--libplacebo-include", type=Path)
    run.add_argument("--subtitle-width", type=bounded_int(128, 4096), default=1920)
    run.add_argument("--subtitle-height", type=bounded_int(72, 2160), default=1080)
    compare = commands.add_parser("compare", help="Compare medians with compatibility checks")
    compare.add_argument("baseline", type=Path)
    compare.add_argument("candidate", type=Path)
    compare.add_argument("--output", type=Path, help="Save comparison JSON (does not overwrite)")
    compare.add_argument("--markdown", type=Path, help="Save the displayed Markdown table")
    compare.add_argument("--allow-mismatch", action="store_true", help="Diagnostic comparisons; clearly marks incompatible results")
    compare.add_argument("--fail-regression-percent", type=finite_range(0, 10000))
    args = parser.parse_args(argv)
    try:
        if args.command == "run":
            return run_benchmarks(args)
        result = compare_reports(json.loads(args.baseline.read_text()), json.loads(args.candidate.read_text()),
                                 allow_mismatch=args.allow_mismatch,
                                 regression_percent=args.fail_regression_percent)
        markdown = render_markdown(result)
        if args.output:
            write_json(args.output, result)
        if args.markdown:
            args.markdown.parent.mkdir(parents=True, exist_ok=True)
            with args.markdown.open("x") as stream:
                stream.write(markdown + "\n")
        print(markdown)
        return 2 if result["hasRegressions"] else 0
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
