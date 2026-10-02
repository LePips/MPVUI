#!/usr/bin/env python3
"""Run the generated iOS test project with Xcode and retain its result bundle."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validation import publish_evidence

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / ".build/device-tests/MPVUIRegressionTests.xcodeproj"
DERIVED_DATA = ROOT / ".build/device-tests/DerivedData"


def test_command(*, project, derived_data, platform, device_id, result_bundle, only_testing=None):
    if platform not in ("device", "simulator") or not device_id:
        raise ValueError("Choose a device or simulator and provide its identifier")
    destination = "platform=iOS" if platform == "device" else "platform=iOS Simulator"
    command = [
        "xcodebuild",
        "-project",
        str(project),
        "-scheme",
        "MPVUIRegressionTests",
        "-configuration",
        "Release",
        "-derivedDataPath",
        str(derived_data),
        "-destination",
        f"{destination},id={device_id}",
        "-resultBundlePath",
        str(result_bundle),
        "-parallel-testing-enabled",
        "NO",
        "ENABLE_TESTABILITY=YES",
    ]
    if platform == "device":
        command.append("-allowProvisioningUpdates")
    if only_testing:
        command.append("-only-testing:" + only_testing)
    return command + ["test"]


def result_summary(result_bundle):
    completed = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result_bundle)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    summary = json.loads(completed.stdout)
    counts = {key: summary[key] for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
    if any(type(count) is not int or count < 0 for count in counts.values()):
        raise ValueError("Invalid test counts in Xcode result bundle")
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("device", "simulator"), required=True)
    selector = parser.add_mutually_exclusive_group(required=True)
    selector.add_argument("--device-id")
    selector.add_argument("--simulator-id")
    parser.add_argument("--project", type=Path, default=PROJECT)
    parser.add_argument("--derived-data", type=Path, default=DERIVED_DATA)
    parser.add_argument("--only-testing", help="Xcode test identifier to select")
    args = parser.parse_args(argv)
    if args.platform == "device" and not args.device_id or args.platform == "simulator" and not args.simulator_id:
        parser.error("The identifier must match --platform")
    if not args.project.is_dir():
        parser.error(f"Generate the device test project first: {args.project}")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    bundle = ROOT / ".build/device-tests/Results" / (stamp + ".xcresult")
    bundle.parent.mkdir(parents=True, exist_ok=True)
    command = test_command(
        project=args.project,
        derived_data=args.derived_data,
        platform=args.platform,
        device_id=args.device_id or args.simulator_id,
        result_bundle=bundle,
        only_testing=args.only_testing,
    )
    completed = subprocess.run(command)
    if not bundle.exists():
        raise ValueError(f"Xcode produced no result bundle (exit {completed.returncode})")
    summary = result_summary(bundle)
    tests = dict(
        framework="XCResult",
        count=summary["totalTestCount"],
        failures=summary["failedTests"],
        skippedCount=summary["skippedTests"],
        outcome=summary["result"].lower(),
    )
    publish_evidence(summary=dict(tests=tests), artifacts=dict(testResultBundle=bundle))
    print(f"Xcode tests: {tests['outcome']} ({tests['count']} total, {tests['failures']} failed, {tests['skippedCount']} skipped)")
    return 0 if completed.returncode == 0 and summary["result"] == "Passed" and tests["count"] > 0 and not tests["failures"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
