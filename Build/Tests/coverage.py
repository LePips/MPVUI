#!/usr/bin/env python3
"""Run a test lane and report coverage of the active MPVUI Swift sources only."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
METRICS = ("lines", "functions", "regions")


def input_digest(root):
    inputs = [root / "Package.swift"]
    for folder in ("Sources", "Tests", "Example/MPVUIExample/Shared/Resources"):
        inputs.extend(path for path in (root / folder).rglob("*") if path.is_file())
    digest = hashlib.sha256()
    for path in sorted(inputs):
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


@contextmanager
def build_lock():
    directory = ROOT / ".build"
    directory.mkdir(exist_ok=True)
    with (directory / "coverage.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def summarize(document, root):
    source = (root / "Sources").resolve()
    files = {}
    for data in document["data"]:
        for entry in data["files"]:
            path = Path(entry["filename"]).resolve()
            if not path.is_relative_to(source):
                continue
            relative = str(path.relative_to(root.resolve()))
            if relative in files:
                raise ValueError(f"Duplicate coverage entry: {relative}; merge profiles before exporting")
            files[relative] = entry["summary"]
    if not files:
        raise ValueError("Coverage contains no MPVUI Sources entries")

    def aggregate(entries):
        result = {}
        for metric in METRICS:
            count = sum(e[metric]["count"] for e in entries)
            covered = sum(e[metric]["covered"] for e in entries)
            if count <= 0 or not 0 <= covered <= count:
                raise ValueError(f"Invalid {metric} coverage totals")
            result[metric] = dict(count=count, covered=covered, percent=100 * covered / count)
        return result

    areas = {}
    for name, metrics in files.items():
        area = str(Path(name).parent.relative_to("Sources"))
        areas.setdefault(area, []).append(metrics)
    return dict(
        scope="Active compiled Sources only; excludes tests, helpers, generated code and prebuilt Libmpv. "
              "Inactive platform branches and native patches require separate validation.",
        metrics=aggregate(list(files.values())),
        areas={name: aggregate(entries) for name, entries in sorted(areas.items())},
        files=files,
    )


def violations(summary, minimums):
    return [f"{metric}: {summary['metrics'][metric]['percent']:.2f}% < {minimum:.2f}%"
            for metric, minimum in minimums.items()
            if summary["metrics"][metric]["percent"] < minimum]


def suites(root, folders):
    names = []
    for folder in folders:
        for file in (root / "Tests" / folder).rglob("*.swift"):
            names.extend(re.findall(r"^struct (\w+Tests)\s*\{", file.read_text(), re.MULTILINE))
    if not names:
        raise ValueError(f"No suites discovered in {folders}")
    return "(" + "|".join(sorted(set(names))) + ")/"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lane", choices=["default", "unit", "integration", "system", "benchmarks"], default="default")
    parser.add_argument("--check", action="store_true", help="Enforce default-lane coverage floors")
    parser.add_argument("--report", type=Path, help="Summarize an existing LLVM JSON export without running tests")
    args = parser.parse_args()
    if args.check and args.lane != "default":
        parser.error("--check requires the complete default lane")
    if args.check and args.report:
        parser.error("--check requires a fresh passing test run, not an unverified export")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    output = ROOT / ".build" / "coverage" / stamp
    output.mkdir(parents=True)
    if args.report:
        report = args.report
    else:
        before = input_digest(ROOT)
        # Own a dedicated build directory. Remove earlier raw counters so a
        # filtered or failed run cannot inflate this run's report.
        scratch = ROOT / ".build" / "coverage-build"
        for old in scratch.glob("*/debug/codecov"):
            shutil.rmtree(old)
        command = ["swift", "test", "--scratch-path", str(scratch), "--enable-code-coverage", "--no-parallel"]
        folders = ["Unit", "Integration"] if args.lane == "default" else [{
            "unit": "Unit", "integration": "Integration", "system": "System", "benchmarks": "Benchmarks",
        }[args.lane]]
        command += ["--filter", suites(ROOT, folders)]
        if sys.platform == "darwin" and args.lane != "unit":
            # AVFoundation readback and system PiP need an awake display. Keep
            # the assertion scoped to this test process, without changing the
            # user's persistent power settings or weakening frame assertions.
            command = ["/usr/bin/caffeinate", "-disu", *command]
        print(f"Running {args.lane} lane; log: {output / 'tests.log'}", flush=True)
        with (output / "tests.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        after = input_digest(ROOT)
        (output / "run.json").write_text(json.dumps(dict(
            command=command, exitCode=result.returncode, inputDigestBefore=before, inputDigestAfter=after,
        ), indent=2) + "\n")
        if result.returncode:
            print("Tests failed; no passing coverage report was produced.", file=sys.stderr)
            print((output / "tests.log").read_text()[-12000:], file=sys.stderr)
            return result.returncode
        if before != after:
            raise ValueError("Sources, tests, manifest or fixtures changed during validation; run again")
        logs = (output / "tests.log").read_text()
        match = re.search(r"Test run with (\d+) tests.*passed", logs)
        if not match or int(match[1]) == 0:
            raise ValueError("Test selection did not execute any Swift Testing tests")
        report = Path(subprocess.check_output([
            "swift", "test", "--scratch-path", str(scratch), "--show-codecov-path",
        ], cwd=ROOT, text=True).strip())

    document = json.loads(report.read_text())
    summary = summarize(document, ROOT)
    summary["lane"] = args.lane
    if not args.report:
        summary["testResult"] = match[0]
        summary["skippedTests"] = [line.strip() for line in logs.splitlines() if "skipped" in line]
    shutil.copyfile(report, output / "llvm-coverage.json")
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    for metric, value in summary["metrics"].items():
        print(f"{metric}: {value['covered']}/{value['count']} ({value['percent']:.2f}%)")
    print(f"Report: {output / 'summary.json'}")
    if args.check:
        failures = violations(summary, json.loads((ROOT / "Build/Tests/coverage-thresholds.json").read_text()))
        if failures:
            print("Coverage gate failed: " + "; ".join(failures), file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    # Cover profile cleanup and export as well as the SwiftPM invocation. The
    # SwiftPM build lock alone cannot prevent another run deleting counters.
    with build_lock():
        sys.exit(main())
