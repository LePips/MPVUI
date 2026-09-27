"""Separate, provenance-checked diagnostic capture; never a performance baseline."""

import argparse
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor
import json
import math
import os
from pathlib import Path
import plistlib
import statistics
import sys
import time
from types import SimpleNamespace
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Build/Benchmarks"))
import device_playback as device
from benchmark import measurement_lock


def retrieve_completed_report(copy_report, start_poll_at, deadline, *, clock=time.monotonic, sleep=time.sleep):
    """Retrieve independently of trace saving, with an auditable polling interval."""
    sleep(max(0, start_poll_at - clock()))
    poll_times = []
    while clock() < deadline:
        poll_times.append(clock())
        if copy_report():
            return {"rawCopyCompleteMonotonic": clock(), "rawCopyRequestMonotonic": poll_times}
        sleep(1)
    raise ValueError("No completion report")


def host_clock_anchor():
    first = time.monotonic()
    wall = time.time()
    last = time.monotonic()
    return {
        "wallSeconds": wall,
        "monotonicBefore": first,
        "monotonicAfter": last,
        "wallMinusMonotonicMinimum": wall - last,
        "wallMinusMonotonicMaximum": wall - first,
    }


def recorder_time_bounds(toc, timing):
    """Map recorder-generated TOC dates to host monotonic bounds; exclude trace save time."""
    anchors = [timing["hostClockBeforeTrace"], timing["hostClockAfterTrace"]]
    offsets = [(a["wallMinusMonotonicMinimum"], a["wallMinusMonotonicMaximum"]) for a in anchors]
    drift = abs(sum(offsets[0]) / 2 - sum(offsets[1]) / 2)
    if drift > 0.01:
        raise ValueError("Host wall/monotonic offset changed during capture; recorder times are uncertain")
    summary = ET.parse(toc).getroot().find("./run[@number='1']/info/summary")
    if summary is None:
        raise ValueError("Trace TOC has no recorder timing summary")

    def date(key):
        parsed = datetime.fromisoformat(summary.findtext(key))
        if parsed.tzinfo is None:
            raise ValueError("Recorder timestamp has no timezone")
        return parsed.timestamp()

    start_wall, end_wall = date("start-date"), date("end-date")
    duration = float(summary.findtext("duration"))
    if not math.isfinite(duration) or duration <= 0 or abs(end_wall - start_wall - duration) > 0.003:
        raise ValueError("Recorder duration/date evidence disagrees")
    # TOC dates use milliseconds. The complete before/after offset envelope plus
    # one millisecond at each boundary conservatively covers clock-read bracketing.
    minimum_offset = min(pair[0] for pair in offsets)
    maximum_offset = max(pair[1] for pair in offsets)
    start_lower = start_wall - maximum_offset - 0.001
    end_upper = end_wall - minimum_offset + 0.001
    if start_lower < timing["traceInvocationMonotonic"] - 0.003 or end_upper > timing["traceReturnMonotonic"] + 0.003:
        raise ValueError("Recorder dates are incompatible with the host invocation bounds")
    return {
        "traceStartEarliestMonotonic": start_lower,
        "traceEndLatestMonotonic": end_upper,
        "traceRecorderDurationSeconds": duration,
        "hostClockOffsetDriftSeconds": drift,
        "traceRecorderStartDate": summary.findtext("start-date"),
        "traceRecorderEndDate": summary.findtext("end-date"),
        "clockAlignment": "Recorder-generated TOC wall dates mapped using bracketing host clocks; application wall clock is unused",
    }


def validate_steady_window(raw, timing):
    """Bound app start using host monotonic times, without assuming clock agreement.

    All measurement phases are disjoint and follow benchmark begin. Their summed
    duration is a lower bound for begin-to-report time. Report retrieval completes
    after report creation, while this fresh process cannot start before launch.
    Explicit steady timeline points lie inside the steady phase. Reject uncertain
    containment rather than treating a fixed launch delay as proof.
    """
    durations = [phase.get("wallSeconds") for phase in raw.get("phases", {}).values()]
    if not durations or any(
        not isinstance(v, (int, float)) or isinstance(v, bool) or not math.isfinite(v) or v < 0 for v in durations
    ):
        raise ValueError("Missing finite disjoint phase duration evidence")
    points = [point["elapsedSeconds"] for point in raw.get("timeline", []) if point.get("phase") == "steady"]
    if len(points) < 2 or any(not math.isfinite(v) for v in points):
        raise ValueError("Missing explicit steady timeline boundary observations")
    earliest_begin = timing["launchRequestStartMonotonic"]
    latest_begin = timing["rawCopyCompleteMonotonic"] - sum(durations)
    if latest_begin < earliest_begin:
        raise ValueError("Inconsistent launch/report timing bounds")
    safe_start, safe_end = latest_begin + min(points), earliest_begin + max(points)
    record_start = timing.get("traceStartEarliestMonotonic", timing["traceInvocationMonotonic"])
    record_end = timing.get("traceEndLatestMonotonic", timing["traceReturnMonotonic"])
    proof = {
        "method": "host monotonic launch/report bounds and explicit steady timeline points",
        "appBeginEarliestMonotonic": earliest_begin,
        "appBeginLatestMonotonic": latest_begin,
        "appBeginUncertaintySeconds": latest_begin - earliest_begin,
        "measuredPhaseDurationSumSeconds": sum(durations),
        "firstSteadyTimelineElapsedSeconds": min(points),
        "lastSteadyTimelineElapsedSeconds": max(points),
        "guaranteedSteadyStartMonotonic": safe_start,
        "guaranteedSteadyEndMonotonic": safe_end,
        "traceInvocationMonotonic": timing["traceInvocationMonotonic"],
        "traceReturnMonotonic": timing["traceReturnMonotonic"],
        "traceStartEarliestMonotonic": record_start,
        "traceEndLatestMonotonic": record_end,
        "contained": safe_start <= record_start <= record_end <= safe_end,
    }
    return proof


def estimate_overhead(report, reference):
    """Explicit same-protocol comparison; report uncertainty and all raw samples."""
    if report["source"]["sourceSHA256"] != reference["source"]["sourceSHA256"]:
        raise ValueError("Overhead reference source differs")
    if report["runtime"]["appSHA256"] != reference["runtime"]["appSHA256"]:
        raise ValueError("Overhead reference app differs")
    left_key = dict(reference["environment"]["comparisonKey"])
    if left_key.get("instrumentation", {}).get("template") is not None:
        raise ValueError("Overhead reference is itself traced")
    right_key = dict(report["environment"]["comparisonKey"])
    left_key.pop("instrumentation", None)
    right_key.pop("instrumentation", None)
    if left_key != right_key:
        raise ValueError("Overhead reference protocol/device/Xcode/environment differs")
    left = next(w for w in reference["workloads"] if w["parameters"]["player"] == "mpv")
    right = report["workloads"][0]
    for workload in (left, right):
        if workload["parameters"].get("sampleSeconds") != 30 or workload["parameters"].get("warmupSeconds") != 5:
            raise ValueError("Overhead estimate requires the same 30/5-second protocol")
    mismatches = {
        key: [left["parameters"].get(key), right["parameters"].get(key)]
        for key in set(left["parameters"]) | set(right["parameters"])
        if left["parameters"].get(key) != right["parameters"].get(key)
    }
    allowed_context = set(mismatches) <= {"backend"}
    if mismatches and not (
        allowed_context
        and all(
            raw["configuration"].get("resolvedBackend") == "sampleBuffer"
            for raw in left["observations"] + right["observations"]
        )
    ):
        raise ValueError("Overhead reference workload/options differs: " + str(mismatches))
    key = "steadyCpuSecondsPerWallSecond"
    baseline = left["metrics"][key]["samples"]
    observed = right["metrics"][key]["samples"]
    before, after = statistics.median(baseline), statistics.median(observed)
    return {
        "kind": "instrumentation overhead estimate",
        "referenceLabel": reference["label"],
        "protocolVerified": True,
        "sampleSeconds": 30,
        "warmupSeconds": 5,
        "referenceCPUSamplesPerCore": baseline,
        "diagnosticCPUSamplesPerCore": observed,
        "referenceMedianPerCore": before,
        "referenceMinPerCore": min(baseline),
        "referenceMaxPerCore": max(baseline),
        "diagnosticMedianPerCore": after,
        "deltaPerCore": after - before,
        "deltaPercentagePointsOfOneCore": 100 * (after - before),
        "relativeChangePercent": 100 * (after - before) / before if before else None,
        "requestedConfigurationDifferences": mismatches,
        "strictlyMatchingRequestedConfiguration": not mismatches,
        "limitations": [
            "Single diagnostic runs do not establish an exact causal overhead or statistical significance.",
            "CPU covers the same entire 30-second steady phase, including trace attachment; the trace covers only its contained subinterval.",
            "An explicit versus default native backend is contextual comparison evidence and remains disclosed, not silently normalized.",
        ],
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--device", required=True)
    p.add_argument("--media", type=Path, required=True)
    p.add_argument("--host")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--derived-data", type=Path, default=ROOT / ".build/device-benchmark")
    p.add_argument("--template", default="Time Profiler")
    p.add_argument("--option", action="append", default=[])
    p.add_argument("--no-trace", action="store_true")
    p.add_argument(
        "--reference", type=Path, required=True, help="Matching uninstrumented aggregate JSON for overhead estimate"
    )
    a = p.parse_args()
    if any("=" not in v or not v.split("=", 1)[0] for v in a.option):
        p.error("--option requires key=value")
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    developer = Path(os.environ.get("DEVELOPER_DIR") or device.command(["xcode-select", "-p"]).stdout.strip())
    dev = developer / "usr/bin"
    xcode = plistlib.loads((developer.parent / "version.plist").read_bytes())["ProductBuildVersion"]
    app_dir = a.derived_data.resolve() / "Build/Products/Release-iphoneos/MPVUIExample.app"
    app = app_dir / "MPVUIExample"
    before = device.source_identity()
    stamp = json.loads((a.derived_data / "mpvui-benchmark-build.json").read_text())
    app_hash = device.digest(app)
    if stamp != {"source": before["sourceSHA256"], "xcode": xcode, "appSHA256": app_hash}:
        raise ValueError("Build is stale; build the performance harness first")
    identity = device.media_identity(a.media)
    reference = json.loads(a.reference.read_text())
    timing = {}
    with measurement_lock(), device.serve_media(a.media.resolve(), a.host) as url:
        device.command(
            [
                dev / "devicectl",
                "device",
                "info",
                "details",
                "--device",
                a.device,
                "--json-output",
                out / "device.json",
            ],
            log=out / "device.log",
        )
        details = json.loads((out / "device.json").read_text())["result"]
        hardware = details["hardwareProperties"]
        if hardware["reality"] != "physical":
            raise ValueError("Requires physical device")
        import hashlib

        measured_device = {
            "idHash": hashlib.sha256(hardware["udid"].encode()).hexdigest()[:16],
            "model": hardware["productType"],
            "os": details["deviceProperties"]["osVersionNumber"],
            "osBuild": details["deviceProperties"]["osBuildUpdate"],
        }
        # Install/copy the exact stamped app and fixture, rather than trusting a prior run's container.
        device.mcp("install", {"deviceId": a.device, "appPath": str(app_dir)}, out / "install.json")
        if not url:
            device.command(
                [
                    dev / "devicectl",
                    "device",
                    "copy",
                    "to",
                    "--device",
                    a.device,
                    "--source",
                    a.media.resolve(),
                    "--destination",
                    "Documents/" + a.media.name,
                    "--domain-type",
                    "appDataContainer",
                    "--domain-identifier",
                    device.BUNDLE,
                ],
                log=out / "media-copy.log",
            )
        device.command(
            [
                dev / "devicectl",
                "device",
                "info",
                "processes",
                "--device",
                a.device,
                "--search",
                "MPVUIExample",
                "--json-output",
                out / "processes.json",
            ],
            log=out / "processes.log",
        )
        for process in json.loads((out / "processes.json").read_text())["result"]["runningProcesses"]:
            if process.get("executable", "").endswith("/MPVUIExample.app/MPVUIExample"):
                device.mcp("stop", {"deviceId": a.device, "processId": process["processIdentifier"]}, out / "stop.json")
        name = "profile-" + str(uuid.uuid4()) + ".json"
        args = [
            "--playback-benchmark",
            "--benchmark-player",
            "mpv",
            "--benchmark-media",
            url or a.media.name,
            "--benchmark-output",
            name,
            "--benchmark-seconds",
            "30",
            "--benchmark-warmup",
            "5",
            "--benchmark-backend",
            "sampleBuffer",
            "--benchmark-sdr-output",
            "automatic",
        ]
        for option in a.option:
            args += ["--benchmark-option", option]
        timing["launchRequestStartMonotonic"] = time.monotonic()
        launch = device.mcp(
            "launch", {"deviceId": a.device, "bundleId": device.BUNDLE, "launchArgs": args}, out / "launch.json"
        )
        timing["launchReturnMonotonic"] = time.monotonic()
        pid = launch["data"]["artifacts"]["processId"]
        instrumentation = {
            "template": None if a.no_trace else a.template,
            "allProcesses": not a.no_trace,
            "traceRequestedSeconds": 0 if a.no_trace else 20,
        }
        provenance = {
            "source": before,
            "appSHA256": app_hash,
            "media": identity,
            "pid": pid,
            "xcode": xcode,
            "instrumentation": instrumentation,
            "purpose": "Diagnostic capture; never aggregate with uninstrumented runs",
            "launchArgs": args,
            "timing": timing,
        }
        (out / "provenance.json").write_text(json.dumps(provenance, indent=2))
        # Trace serialization can continue well after app completion. Retrieve the
        # report independently so save time cannot widen the app-start bound.
        # The 45-second start stays outside the nominal 30/5 steady interval;
        # actual poll times are retained to audit unusually delayed startup.
        raw_path = out / "raw.json"

        def copy_report():
            copied = device.command(
                [
                    dev / "devicectl",
                    "device",
                    "copy",
                    "from",
                    "--device",
                    a.device,
                    "--source",
                    "Documents/Benchmarks/" + name,
                    "--destination",
                    raw_path,
                    "--domain-type",
                    "appDataContainer",
                    "--domain-identifier",
                    device.BUNDLE,
                ],
                log=out / "copy.log",
                optional=True,
                timeout=30,
            )
            return copied.returncode == 0 and raw_path.exists()

        with ThreadPoolExecutor(max_workers=1) as report_executor:
            report_future = report_executor.submit(
                retrieve_completed_report,
                copy_report,
                timing["launchRequestStartMonotonic"] + 45,
                timing["launchRequestStartMonotonic"] + 200,
            )
            print(f"Launched PID {pid}; waiting 10 seconds before trace", flush=True)
            time.sleep(10)
            if not a.no_trace:
                timing["hostClockBeforeTrace"] = host_clock_anchor()
                timing["traceInvocationMonotonic"] = time.monotonic()
                device.command(
                    [
                        dev / "xctrace",
                        "record",
                        "--template",
                        a.template,
                        "--device",
                        hardware["udid"],
                        "--all-processes",
                        "--time-limit",
                        "20s",
                        "--output",
                        out / "cpu.trace",
                    ],
                    log=out / "record.log",
                    timeout=180,
                )
                timing["traceReturnMonotonic"] = time.monotonic()
                timing["hostClockAfterTrace"] = host_clock_anchor()
                print("Trace saved; retrieving completed phase evidence", flush=True)
            timing.update(report_future.result())
        raw = json.loads(raw_path.read_text())
        provenance["timing"] = timing
        (out / "provenance.json").write_text(json.dumps(provenance, indent=2))
        if not a.no_trace:
            device.command(
                [dev / "xctrace", "export", "--input", out / "cpu.trace", "--toc", "--output", out / "toc.xml"],
                log=out / "export-toc.log",
            )
            if a.template == "Time Profiler":
                device.command(
                    [
                        dev / "xctrace",
                        "export",
                        "--input",
                        out / "cpu.trace",
                        "--xpath",
                        '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]',
                        "--output",
                        out / "time-profile.xml",
                    ],
                    log=out / "export.log",
                )
            timing.update(recorder_time_bounds(out / "toc.xml", timing))
            provenance["steadyWindow"] = validate_steady_window(raw, timing)
            (out / "provenance.json").write_text(json.dumps(provenance, indent=2))
        if (
            before["sourceSHA256"] != device.source_identity()["sourceSHA256"]
            or identity != device.media_identity(a.media)
            or device.digest(app) != app_hash
        ):
            raise ValueError("Source, media or app changed during diagnostic capture")
        requested = SimpleNamespace(
            players="mpv",
            backend="sampleBuffer",
            seconds=30,
            warmup=5,
            software_decoding=False,
            sdr_output="automatic",
            option=a.option,
            host=a.host,
            label=out.name,
            repetitions=1,
        )
        report = device.aggregate(
            [raw], source=before, media=identity, args=requested, device=measured_device, xcode=xcode, app_hash=app_hash
        )
        report["environment"]["comparisonKey"]["instrumentation"] = instrumentation
        report["runtime"]["diagnosticOnly"] = True
        (out / "diagnostic-report.json").write_text(json.dumps(report, indent=2))
        overhead = estimate_overhead(report, reference)
        (out / "instrumentation-overhead.json").write_text(json.dumps(overhead, indent=2))
        print(json.dumps(overhead, indent=2), flush=True)
        if not a.no_trace and not provenance["steadyWindow"]["contained"]:
            raise ValueError(
                "Trace containment within steady playback is uncertain; reject attribution, see saved timing bounds"
            )


if __name__ == "__main__":
    main()
