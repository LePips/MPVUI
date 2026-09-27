#!/usr/bin/env python3
"""Opt-in physical sync probe runner. Defaults to local validation only."""

from __future__ import annotations
import argparse
import contextlib
import functools
import http.server
import importlib.util
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

sys.dont_write_bytecode = True
import threading
from urllib.parse import unquote, urlsplit
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Build/Benchmarks"))
from benchmark import measurement_lock
from device_playback import command, digest, source_identity

HOST_BUNDLE = "com.lepips.MPVUIRegressionTests.Host"
SUITE = "MPVUITests/MPVNativeSynchronizationProbeTests"
NAME = re.compile(r"native-sync-(direct|hls)-(50|500)ms-([0-9a-fA-F-]{36})\.json")
EXPECTED = {(w, i) for w in ("direct", "hls") for i in (50, 500)}


def helper():
    path = ROOT / "Build/Benchmarks/prepare_sync_probe.py"
    if not path.is_file():
        raise FileNotFoundError("Install Build/Benchmarks/prepare_sync_probe.py before running this probe")
    spec = importlib.util.spec_from_file_location("sync_fixture_helper", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_new(path, value):
    with Path(path).open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")


def serve_settings(hls, config, host):
    parsed = urlsplit(config["hlsURL"])
    if (
        parsed.scheme != "http"
        or parsed.hostname != host
        or parsed.port != 8765
        or parsed.query
        or parsed.fragment
        or parsed.username
        or parsed.password
    ):
        raise ValueError("Configuration must use the explicit host and managed HTTP port8765")
    parts = PurePosixPath(unquote(parsed.path)).parts
    if not parts or parts[0] != "/" or ".." in parts:
        raise ValueError("Invalid local playlist URL path")
    relative = Path(*parts[1:])
    hls = Path(hls).resolve()
    if relative.name != hls.name:
        raise ValueError("URL does not name the verified playlist")
    root = hls
    for _ in relative.parts:
        root = root.parent
    if (root / relative).resolve() != hls:
        raise ValueError("URL path does not map to the fixture directory")
    return root


@contextlib.contextmanager
def managed_server(hls, config, host, requests_log):
    directory = serve_settings(hls, config, host)
    allowed = {(Path(hls).parent / name).resolve() for name in config["hostVerification"]["hlsIdentity"]["files"]}

    # Match the benchmark helper's allowlisted HTTP serving. Port8765 is fixed
    # by the already-bundled test configuration. Never adopt or stop another server.
    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, format, *args):
            requests_log.write((format % args) + "\n")
            requests_log.flush()

        def list_directory(self, _):
            self.send_error(403)
            return None

        def send_head(self):
            if Path(self.translate_path(self.path)).resolve() not in allowed:
                self.send_error(404)
                return None
            return super().send_head()

    server = http.server.ThreadingHTTPServer((host, 8765), functools.partial(Handler, directory=str(directory)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def report_names(payload):
    names = set()

    def visit(value):
        if isinstance(value, dict):
            for nested in value.values():
                visit(nested)
        elif isinstance(value, list):
            for nested in value:
                visit(nested)
        elif isinstance(value, str):
            name = PurePosixPath(value).name
            match = NAME.fullmatch(name)
            if match:
                uuid.UUID(match.group(3))
                names.add(name)

    visit(payload.get("result", {}))
    return sorted(names)


def validate_reports(paths, config, config_hash):
    matched = {}
    for path in paths:
        report = json.loads(Path(path).read_text())
        if report.get("configurationSHA256") != config_hash:
            continue
        if report.get("schemaVersion") != 1:
            raise ValueError("Unsupported synchronization report schema")
        key = (report.get("workload"), report.get("queryIntervalMilliseconds"))
        if key not in EXPECTED or key in matched:
            raise ValueError("Unexpected/duplicate sync workload and cadence")
        if report.get("status") != "passed":
            raise ValueError("Sync test report failed: " + Path(path).name)
        expected_hash = config["directMediaSHA256"] if key[0] == "direct" else config["hlsMediaSHA256"]
        if report.get("mediaSHA256") != expected_hash:
            raise ValueError("Sync report media identity differs")
        if key[0] == "direct" and report.get("directBytesVerifiedOnDevice") is not True:
            raise ValueError("Direct device byte hash was not verified")
        framework = report.get("frameworkSamples", [])
        if len(framework) != 2 or [f.get("boundary") for f in framework] != ["beforeSteady", "afterSteady"]:
            raise ValueError("Two independent framework observations are required")
        before, after = framework
        for row in framework:
            if row.get("displayedPixelBufferAvailable") is not True:
                raise ValueError("No displayed pixel buffer")
            for field in (
                "totalNumberOfFrames",
                "numberOfDroppedFrames",
                "numberOfCorruptedFrames",
                "displayedWidth",
                "displayedHeight",
            ):
                if type(row.get(field)) is not int or row[field] < (
                    1 if field in ("totalNumberOfFrames", "displayedWidth", "displayedHeight") else 0
                ):
                    raise ValueError("Missing or invalid framework metric: " + field)
            times = [
                row.get(k)
                for k in ("queryBeginElapsedSeconds", "metricsEndElapsedSeconds", "readbackEndElapsedSeconds")
            ]
            if any(type(v) not in (int, float) or not math.isfinite(v) for v in times) or times != sorted(times):
                raise ValueError("Invalid framework timing bounds")
        delays = [row.get("totalAccumulatedFrameDelaySeconds") for row in framework]
        if any(type(v) not in (int, float) or not math.isfinite(v) or v < 0 for v in delays) or delays[1] < delays[0]:
            raise ValueError("Invalid/reset framework cumulative delay")
        if after["queryBeginElapsedSeconds"] < before["readbackEndElapsedSeconds"]:
            raise ValueError("Framework observations overlap or reverse")
        if after["totalNumberOfFrames"] <= before["totalNumberOfFrames"]:
            raise ValueError("No framework frame progression")
        for field in ("numberOfDroppedFrames", "numberOfCorruptedFrames", "displayedWidth", "displayedHeight"):
            if after[field] != before[field]:
                raise ValueError("Framework drop/corruption/dimensions changed")
        matched[key] = {
            "path": str(path),
            "sha256": digest(path),
            "frameworkFrameDelta": after["totalNumberOfFrames"] - before["totalNumberOfFrames"],
        }
    if set(matched) != EXPECTED:
        raise ValueError("Require four fresh passed direct/HLS ×50/500 ms reports")
    return [{"workload": k[0], "queryIntervalMilliseconds": k[1], **v} for k, v in sorted(matched.items())]


def test_arguments(args):
    return {
        "projectPath": str(args.project.resolve()),
        "scheme": "MPVUIRegressionTests",
        "deviceId": args.device,
        "configuration": "Release",
        "derivedDataPath": str(args.derived_data.resolve()),
        "extraArgs": [
            "-allowProvisioningUpdates",
            "ENABLE_TESTABILITY=YES",
            "-parallel-testing-enabled",
            "NO",
            "-only-testing:" + SUITE,
        ],
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--device", required=True)
    p.add_argument("--host", required=True)
    p.add_argument("--direct", type=Path, required=True)
    p.add_argument("--hls", type=Path, required=True)
    p.add_argument(
        "--configuration", type=Path, default=ROOT / ".build/device-tests/GeneratedMedia/native-sync-configuration.json"
    )
    p.add_argument("--project", type=Path, default=ROOT / ".build/device-tests/MPVUIRegressionTests.xcodeproj")
    p.add_argument("--derived-data", type=Path, default=ROOT / ".build/device-tests/DerivedData")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--execute", action="store_true")
    args = p.parse_args()
    args.output = args.output.resolve()
    fixture = helper()
    if args.output.exists():
        raise FileExistsError("Use a new evidence directory")
    config = json.loads(args.configuration.read_text())
    serve_settings(args.hls, config, args.host)
    before = fixture.recheck(args.direct, args.hls, args.configuration)
    if not args.project.is_dir():
        raise ValueError("Generate the device test project first")
    if not args.execute:
        print(
            json.dumps(
                {
                    "status": "local validation passed; no device, server or file operations",
                    "testArguments": test_arguments(args),
                    "fixture": before,
                },
                indent=2,
            )
        )
        return
    with measurement_lock():
        args.output.mkdir(parents=True)
        # A unique resource nonce prevents prior device reports from passing as
        # this execution; the rebuilt test bundle hashes this exact config.
        (args.output / "configuration-before.json").write_bytes(args.configuration.read_bytes())
        config["probeRunIdentifier"] = str(uuid.uuid4())
        args.configuration.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
        config_hash = digest(args.configuration)
        (args.output / "configuration-used.json").write_bytes(args.configuration.read_bytes())
        write_new(args.output / "fixtures-before.json", fixture.recheck(args.direct, args.hls, args.configuration))
        source = source_identity()
        sync_source = ROOT / "Tests/Integration/Native/MPVNativeSynchronizationProbeTests.swift"
        sync_hash = digest(sync_source)
        write_new(args.output / "source-before.json", {"source": source, "syncTestSHA256": sync_hash})
        developer = Path(os.environ.get("DEVELOPER_DIR") or command(["xcode-select", "-p"]).stdout.strip())
        devicectl = developer / "usr/bin/devicectl"
        details = args.output / "device.json"
        command(
            [devicectl, "device", "info", "details", "--device", args.device, "--json-output", details],
            log=args.output / "device.log",
        )
        if json.loads(details.read_text())["result"]["hardwareProperties"].get("reality") != "physical":
            raise ValueError("Physical device required")
        errors = []
        retrieved = []
        try:
            with (args.output / "http.log").open("x") as server_log, managed_server(
                args.hls, config, args.host, server_log
            ):
                with (args.output / "test.json").open("x") as log:
                    completed = subprocess.run(
                        [
                            "caffeinate",
                            "-disu",
                            "xcodebuildmcp",
                            "device",
                            "test",
                            "--json",
                            json.dumps(test_arguments(args)),
                            "--output",
                            "json",
                        ],
                        stdout=log,
                        stderr=subprocess.STDOUT,
                        timeout=1200,
                    )
                result = json.loads((args.output / "test.json").read_text())
                summary = result.get("data", {}).get("summary", {})
                if (
                    completed.returncode
                    or result.get("didError") is not False
                    or summary.get("status") != "SUCCEEDED"
                    or summary.get("counts", {}).get("failed") != 0
                    or summary.get("counts", {}).get("skipped") != 0
                ):
                    errors.append("Physical test tool did not report an unskipped successful run")
                listing = args.output / "device-files.json"
                command(
                    [
                        devicectl,
                        "device",
                        "info",
                        "files",
                        "--device",
                        args.device,
                        "--domain-type",
                        "appDataContainer",
                        "--domain-identifier",
                        HOST_BUNDLE,
                        "--subdirectory",
                        "Documents",
                        "--no-recurse",
                        "--search",
                        "native-sync-",
                        "--json-output",
                        listing,
                    ],
                    log=args.output / "files.log",
                )
                names = report_names(json.loads(listing.read_text()))
                if not names:
                    raise ValueError("No native-sync report filenames found in device listing")
                reports = args.output / "reports"
                reports.mkdir()
                for name in names:
                    destination = reports / name
                    command(
                        [
                            devicectl,
                            "device",
                            "copy",
                            "from",
                            "--device",
                            args.device,
                            "--source",
                            "Documents/" + name,
                            "--destination",
                            destination,
                            "--domain-type",
                            "appDataContainer",
                            "--domain-identifier",
                            HOST_BUNDLE,
                        ],
                        log=args.output / (name + ".copy.log"),
                    )
                    retrieved.append(destination)
                validated = validate_reports(retrieved, config, config_hash)
                write_new(args.output / "validated-reports.json", validated)
        except Exception as error:
            errors.append(str(error))
        finally:
            try:
                write_new(
                    args.output / "fixtures-after.json", fixture.recheck(args.direct, args.hls, args.configuration)
                )
                if digest(args.configuration) != config_hash:
                    raise ValueError("Probe configuration changed during tests")
                if source_identity()["sourceSHA256"] != source["sourceSHA256"] or digest(sync_source) != sync_hash:
                    raise ValueError("Source changed during tests")
            except Exception as error:
                errors.append(str(error))
            products = args.derived_data / "Build/Products/Release-iphoneos/MPVUITestHost.app"
            binaries = [products / "MPVUITestHost", products / "PlugIns/MPVUITests.xctest/MPVUITests"]
            write_new(
                args.output / "completion.json",
                {
                    "status": "failed" if errors else "passed",
                    "errors": errors,
                    "configurationSHA256": config_hash,
                    "retrievedReports": [str(p) for p in retrieved],
                    "builtBinarySHA256": {str(p.relative_to(products)): digest(p) for p in binaries if p.is_file()},
                    "scope": "diagnostic synchronization and framework progression; separate from performance protocol",
                },
            )
        if errors:
            raise SystemExit("; ".join(errors))
        print("Four physical synchronization cases validated: " + str(args.output), flush=True)


if __name__ == "__main__":
    main()
