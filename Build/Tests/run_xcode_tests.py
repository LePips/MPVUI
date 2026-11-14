#!/usr/bin/env python3
"""Generate an Apple test project, run it on a device or simulator, and retain its result bundle."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys
import uuid

from generate_device_test_project import add_team_argument, generate
from prepare_test_media import prepare
from run_swift_tests import keep_awake

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validation import publish_evidence

ROOT = Path(__file__).resolve().parents[2]


def test_command(*, project, derived_data, platform, device_id, result_bundle, only_testing=None, operating_system="iOS"):
    if platform not in ("device", "simulator") or not device_id:
        raise ValueError("Choose a device or simulator and provide its identifier")
    if operating_system not in ("iOS", "tvOS"):
        raise ValueError("Test operating system must be iOS or tvOS")
    destination = f"platform={operating_system}" + (" Simulator" if platform == "simulator" else "")
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
    else:
        # A test run targets one simulator; local native candidates may contain
        # only that simulator's architecture.
        command.append("ONLY_ACTIVE_ARCH=YES")
    command.extend("-only-testing:" + identifier for identifier in only_testing or [])
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


def simulators():
    """Return available iOS and tvOS simulator names and platforms by identifier."""
    listing = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "--json"], check=True, capture_output=True, text=True)
    return {
        device["udid"]: {"name": device["name"], "os": platform}
        for runtime, devices in json.loads(listing.stdout)["devices"].items()
        for platform in ("iOS", "tvOS")
        if f".{platform}-" in runtime
        for device in devices
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="Device or simulator identifier. Omit it to list both")
    parser.add_argument("--os", choices=("iOS", "tvOS"), help="Device platform. Inferred for simulators, otherwise defaults to iOS")
    add_team_argument(parser)
    parser.add_argument("--only-testing", action="append", help="Xcode test identifier to select. Repeat to select multiple suites")
    args = parser.parse_args(argv)
    available = simulators()
    if not args.device:
        subprocess.run(["xcrun", "devicectl", "list", "devices"])
        print(
            "Simulators:\n"
            + "\n".join(
                f"  {device['name']} ({device['os']}): {identifier}"
                for identifier, device in sorted(available.items(), key=lambda item: item[1]["name"])
            )
        )
        parser.error("Choose a device or simulator identifier")
    simulator = available.get(args.device)
    operating_system = simulator["os"] if simulator else args.os or "iOS"
    if simulator and args.os and args.os != operating_system:
        parser.error(f"Simulator runs {operating_system}, not {args.os}")
    output = ROOT / ".build/device-tests" / operating_system.lower()
    project = generate(ROOT, output, args.team, operating_system)
    prepare(output / "GeneratedMedia")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    bundle = ROOT / ".build/device-tests/Results" / (stamp + ".xcresult")
    bundle.parent.mkdir(parents=True, exist_ok=True)
    command = test_command(
        project=project,
        derived_data=output / "DerivedData",
        platform="simulator" if args.device in available else "device",
        device_id=args.device,
        result_bundle=bundle,
        only_testing=args.only_testing,
        operating_system=operating_system,
    )
    completed = subprocess.run(keep_awake(command))
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
