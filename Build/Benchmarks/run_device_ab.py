#!/usr/bin/env python3
"""Guarded fresh-install AB/BA/AB controls; no device work without --execute."""

from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from types import SimpleNamespace

ORDER = ("A", "B", "B", "A", "A", "B")
PROCEDURE = {
    "version": 1,
    "installation": "fresh install and independent process for every sample",
    "orderPerWorkload": list(ORDER),
    "cohortSamplesPerWorkload": 3,
}


def read(path):
    return json.loads(Path(path).read_text())


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def now():
    return datetime.now(timezone.utc).isoformat()


def write_new(path, value):
    with Path(path).open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")


def checkout_identity(checkout, derived):
    checkout, derived = Path(checkout).resolve(), Path(derived).resolve()
    code = "import json,sys;sys.path.insert(0,'Build/Benchmarks');from device_playback import source_identity;print(json.dumps(source_identity()))"
    source = json.loads(
        subprocess.check_output(
            [sys.executable, "-c", code], cwd=checkout, text=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
        )
    )
    stamp = read(derived / "mpvui-benchmark-build.json")
    app = derived / "Build/Products/Release-iphoneos/MPVUIExample.app/MPVUIExample"
    app_hash = digest(app)
    if stamp.get("source") != source["sourceSHA256"] or stamp.get("appSHA256") != app_hash:
        raise ValueError("Stale source/app build stamp: " + str(checkout))
    return {
        "checkout": str(checkout),
        "derivedData": str(derived),
        "source": source,
        "appSHA256": app_hash,
        "xcode": stamp["xcode"],
        "stampSHA256": digest(derived / "mpvui-benchmark-build.json"),
    }


def load_harness(checkout):
    path = Path(checkout) / "Build/Benchmarks/device_playback.py"
    spec = importlib.util.spec_from_file_location("paired_device_playback", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def assert_frozen(actual, expected):
    for field in ("appSHA256", "xcode", "stampSHA256"):
        if actual[field] != expected[field]:
            raise ValueError("Cohort changed: " + field)
    for field in ("sourceSHA256", "files"):
        if actual["source"][field] != expected["source"][field]:
            raise ValueError("Cohort source changed: " + field)


def aggregate_args(label, parameters, repetitions):
    return SimpleNamespace(
        label=label,
        players="mpv",
        repetitions=repetitions,
        seconds=parameters["sampleSeconds"],
        warmup=parameters["warmupSeconds"],
        backend=parameters["backend"],
        software_decoding=parameters["softwareDecoding"],
        sdr_output=parameters["sdrOutput"],
        option=parameters["options"],
        host="verified-server" if parameters["transport"] == "http" else None,
    )


def validate_single(report, expected_cohort, expected_workload, expected_key, harness):
    if report["configuration"] != {"build": "Release", "repetitions": 1}:
        raise ValueError("Each input must be one fresh-process Release invocation")
    if report["runtime"]["appSHA256"] != expected_cohort["appSHA256"]:
        raise ValueError("Input app differs from pinned cohort")
    for field in ("sourceSHA256", "files"):
        if report["source"][field] != expected_cohort["source"][field]:
            raise ValueError("Input source differs from pinned cohort")
    if report["environment"]["comparisonKey"] != expected_key:
        raise ValueError("Input protocol/device/environment key differs")
    if len(report["workloads"]) != 1:
        raise ValueError("Input must have exactly one MPV workload")
    workload = report["workloads"][0]
    if (
        workload["parameters"] != expected_workload["parameters"]
        or report["runtime"]["media"] != expected_workload["media"]
    ):
        raise ValueError("Input media/configuration differs")
    if len(workload["observations"]) != 1:
        raise ValueError("Input must contain exactly one independent observation")
    raw = workload["observations"][0]
    regenerated = harness.aggregate(
        [raw],
        source=report["source"],
        media=report["runtime"]["media"],
        args=aggregate_args(report["label"], workload["parameters"], 1),
        device=expected_key["device"],
        xcode=expected_key["xcode"],
        app_hash=report["runtime"]["appSHA256"],
    )
    if regenerated["workloads"] != report["workloads"] or regenerated["environment"] != report["environment"]:
        raise ValueError("Input aggregate disagrees with strict raw validation")
    return raw


def assemble(plan_path):
    plan_path = Path(plan_path).resolve()
    plan = read(plan_path)
    directory = plan_path.parent
    if (
        plan["procedure"] != PROCEDURE
        or [s["cohort"] for s in plan["steps"]] != list(ORDER) * 2
        or [s["workload"] for s in plan["steps"]] != ["direct"] * 6 + ["hls"] * 6
    ):
        raise ValueError("Plan is not the required direct/HLS AB/BA/AB sequence")
    harness = load_harness(plan["cohorts"]["A"]["checkout"])
    # Recheck source at assembly; do not use a changed parser to validate old raw data.
    for cohort in plan["cohorts"].values():
        assert_frozen(checkout_identity(cohort["checkout"], cohort["derivedData"]), cohort)
    collected = {(w, c): [] for w in ("direct", "hls") for c in ("A", "B")}
    inputs = {key: [] for key in collected}
    seen = set()
    for step in plan["steps"]:
        path = directory / step["report"]
        report = read(path)
        raw = validate_single(
            report, plan["cohorts"][step["cohort"]], plan["workloads"][step["workload"]], plan["comparisonKey"], harness
        )
        identity = (raw["createdAt"], digest(path))
        if raw["createdAt"] in seen:
            raise ValueError("Duplicate raw process observation timestamp")
        seen.add(raw["createdAt"])
        key = (step["workload"], step["cohort"])
        collected[key].append(raw)
        inputs[key].append(
            {
                "report": str(path),
                "sha256": identity[1],
                "order": step["position"],
                "createdAt": report["createdAt"],
                "source": report["source"],
                "appSHA256": report["runtime"]["appSHA256"],
            }
        )
    outputs = []
    for (workload, cohort_name), runs in collected.items():
        cohort, expected = plan["cohorts"][cohort_name], plan["workloads"][workload]
        label = f"device-ab-{workload}-{'control' if cohort_name == 'A' else 'candidate'}"
        output = directory / (label + ".json")
        if output.exists():
            raise FileExistsError("Assembled evidence exists: " + str(output))
        result = harness.aggregate(
            runs,
            source=cohort["source"],
            media=expected["media"],
            args=aggregate_args(label, expected["parameters"], 3),
            device=plan["comparisonKey"]["device"],
            xcode=plan["comparisonKey"]["xcode"],
            app_hash=cohort["appSHA256"],
        )
        result["environment"]["comparisonKey"]["independentInstallationSchedule"] = PROCEDURE
        result["measurementProcedure"] = {
            "procedure": PROCEDURE,
            "planSHA256": digest(plan_path),
            "inputReports": inputs[(workload, cohort_name)],
            "note": "Compare cohorts sharing this installation schedule; do not pool batch-install references without matching procedure evidence.",
        }
        outputs.append((output, result))
    for output, result in outputs:
        write_new(output, result)
    return [str(output) for output, _ in outputs]


def run(args):
    output = args.output.resolve()
    if output.exists():
        raise FileExistsError("Use a new A/B output directory")
    cohorts = {
        "A": checkout_identity(args.baseline_checkout, args.baseline_derived),
        "B": checkout_identity(args.candidate_checkout, args.candidate_derived),
    }
    harness = load_harness(args.baseline_checkout)
    references = {"direct": read(args.direct_reference), "hls": read(args.hls_reference)}
    expected_baseline = references["direct"]
    for reference in references.values():
        if (
            reference["source"]["sourceSHA256"] != cohorts["A"]["source"]["sourceSHA256"]
            or reference["runtime"]["appSHA256"] != cohorts["A"]["appSHA256"]
        ):
            raise ValueError("Control is not the saved baseline source/app")
        if reference["environment"]["comparisonKey"] != expected_baseline["environment"]["comparisonKey"]:
            raise ValueError("Reference environment/protocol differs")
    key = expected_baseline["environment"]["comparisonKey"]
    for cohort in cohorts.values():
        if cohort["xcode"] != key["xcode"]:
            raise ValueError("Cohort Xcode differs from reference")
        for filename, sha in key["protocol"].items():
            path = Path(cohort["checkout"]) / (
                "Build/Benchmarks/" + filename
                if filename.endswith(".py")
                else "Example/MPVUIExample/Shared/" + filename
            )
            if digest(path) != sha:
                raise ValueError("Cohort protocol files differ")
    workloads = {}
    for name, path in (("direct", args.direct), ("hls", args.hls)):
        reference = references[name]
        matches = [w for w in reference["workloads"] if w["parameters"]["player"] == "mpv"]
        if len(matches) != 1:
            raise ValueError("Reference must have one MPV workload")
        params = matches[0]["parameters"]
        if params != {
            "player": "mpv",
            "backend": "default",
            "options": [],
            "sampleSeconds": 30.0,
            "warmupSeconds": 5.0,
            "sdrOutput": "automatic",
            "softwareDecoding": False,
            "transport": "file" if name == "direct" else "http",
            "mediaSHA256": reference["runtime"]["media"]["sha256"],
        }:
            raise ValueError("Reference is not the expected default-native 30/5 workload")
        media = harness.media_identity(path.resolve())
        if media != reference["runtime"]["media"]:
            raise ValueError("Media differs from baseline")
        workloads[name] = {"parameters": params, "media": media, "path": str(path.resolve())}
    steps = []
    for workload in ("direct", "hls"):
        for index, cohort in enumerate(ORDER, 1):
            label = f"device-ab-{workload}-{index:02}-{cohort}"
            steps.append(
                {
                    "workload": workload,
                    "cohort": cohort,
                    "position": index,
                    "report": label + ".json",
                    "log": label + ".runner.log",
                }
            )
    plan = {
        "schemaVersion": 1,
        "createdAt": now(),
        "procedure": PROCEDURE,
        "cohorts": cohorts,
        "comparisonKey": key,
        "workloads": workloads,
        "steps": steps,
        "referenceReports": {
            "direct": {"path": str(args.direct_reference.resolve()), "sha256": digest(args.direct_reference)},
            "hls": {"path": str(args.hls_reference.resolve()), "sha256": digest(args.hls_reference)},
        },
    }
    if not args.execute:
        print(
            json.dumps(
                {
                    "status": "validated dry run; no device operations or files written",
                    "steps": steps,
                    "cohorts": {
                        k: {"sourceSHA256": v["source"]["sourceSHA256"], "appSHA256": v["appSHA256"]}
                        for k, v in cohorts.items()
                    },
                },
                indent=2,
            )
        )
        return
    output.mkdir(parents=True)
    write_new(output / "plan.json", plan)
    for step in steps:
        cohort = cohorts[step["cohort"]]
        assert_frozen(checkout_identity(cohort["checkout"], cohort["derivedData"]), cohort)
        command = [
            str(Path(cohort["checkout"]) / "Build/benchmark"),
            "device",
            "--label",
            Path(step["report"]).stem,
            "--device",
            args.device,
            "--media",
            workloads[step["workload"]]["path"],
            "--players",
            "mpv",
            "--backend",
            "default",
            "--repetitions",
            "1",
            "--seconds",
            "30",
            "--warmup",
            "5",
            "--skip-build",
            "--derived-data",
            cohort["derivedData"],
            "--output",
            str(output / step["report"]),
        ]
        if step["workload"] == "hls":
            command += ["--host", args.host]
        print(f"Starting {step['workload']} position {step['position']}/6 cohort {step['cohort']}", flush=True)
        with (output / step["log"]).open("x") as log:
            subprocess.run(command, cwd=cohort["checkout"], stdout=log, stderr=subprocess.STDOUT, check=True)
        report = read(output / step["report"])
        validate_single(report, cohort, workloads[step["workload"]], key, harness)
        print(report["workloads"][0]["metrics"]["steadyCpuSecondsPerWallSecond"]["samples"], flush=True)
    print(json.dumps(assemble(output / "plan.json"), indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    runner = sub.add_parser("run")
    for name in (
        "baseline-checkout",
        "baseline-derived",
        "candidate-checkout",
        "candidate-derived",
        "direct",
        "hls",
        "direct-reference",
        "hls-reference",
        "output",
    ):
        runner.add_argument("--" + name, type=Path, required=True)
    runner.add_argument("--device", required=True)
    runner.add_argument("--host", required=True)
    runner.add_argument("--execute", action="store_true")
    assembler = sub.add_parser("assemble")
    assembler.add_argument("--plan", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "run":
        run(args)
    else:
        print(json.dumps(assemble(args.plan), indent=2))


if __name__ == "__main__":
    main()
