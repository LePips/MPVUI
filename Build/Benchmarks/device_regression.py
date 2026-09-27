"""Repeatable functional playback checks on an explicitly selected physical device.

The separate app scenario checks stop/replay and seeking. It is not a performance
protocol and does not establish displayed-pixel correctness or audible lip sync.
"""

import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import time
from urllib.parse import unquote, urlsplit

from device_playback import BUNDLE, ROOT, command, digest, mcp, media_identity, serve_media, source_identity


def add_arguments(commands):
    parser = commands.add_parser("device-regression", help="Check playback lifecycle on a physical device")
    parser.add_argument("--device", required=True, help="Explicit physical UDID/CoreDevice identifier")
    parser.add_argument("--media", type=Path, required=True, help="Local MP4 or captured self-contained HLS playlist")
    parser.add_argument("--host", help="Mac LAN address reachable by the device; required for HLS")
    parser.add_argument("--backend", choices=("default", "sampleBuffer", "metal"), default="default")
    parser.add_argument("--software-decoding", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--derived-data", type=Path, default=ROOT / ".build/device-regression")
    parser.add_argument(
        "--skip-build", action="store_true", help="Reuse only the current source/Xcode/app-stamped build"
    )


def launch_arguments(args, media, filename):
    result = [
        "--playback-regression",
        "--regression-media",
        media,
        "--regression-output",
        filename,
        "--regression-backend",
        args.backend,
    ]
    if args.software_decoding:
        result.append("--regression-software-decoding")
    return result


def validate_report(raw, args, media, served_url):
    """Reject stale/wrong-scenario evidence even when the app reports success."""
    if raw.get("schemaVersion") != 2 or raw.get("status") != "passed":
        raise ValueError(f"Device regression failed: {raw.get('error') or 'unknown report schema/status'}")
    config = raw.get("configuration", {})
    requested = args.backend
    resolved = config.get("resolvedBackend")
    if (
        config.get("backend") != requested
        or config.get("softwareDecoding") is not args.software_decoding
        or config.get("cycles") != 3
        or resolved not in ("sampleBuffer", "metal")
        or (requested != "default" and resolved != requested)
    ):
        raise ValueError("On-device regression configuration differs from the request")
    reported_media = config.get("media", "")
    if (served_url and reported_media != served_url) or (
        not served_url and unquote(Path(urlsplit(reported_media).path).name) != media.name
    ):
        raise ValueError("On-device regression used different media")
    all_checks = raw.get("checks", [])
    checks = {check.get("stage"): check for check in all_checks}
    for cycle in range(1, 4):
        prefix = f"cycle-{cycle}"
        for phase in ("start", "resume", "replay"):
            # Replay has a separate initial-position check followed by the
            # settled segment, so select the segment's final entry.
            check = checks.get(f"{prefix}-{phase}", {})
            if not valid_segment(check, resolved):
                raise ValueError(f"Missing or failed settled playback evidence: {prefix}-{phase}")
        replay_positions = [
            check.get("replayInitialPositionSeconds")
            for check in all_checks
            if check.get("stage") == f"{prefix}-replay" and "replayInitialPositionSeconds" in check
        ]
        if len(replay_positions) != 1 or not finite_positive(replay_positions[0]) or replay_positions[0] >= 1.5:
            raise ValueError(f"Replay did not establish playback from zero: {prefix}")
        stopped = checks.get(f"{prefix}-stop-retained", {})
        if not all(
            stopped.get(key) is True
            for key in ("stateRemainedStopped", "publishedActivityUnchanged", "publishedNativeSamplesUnchanged")
        ):
            raise ValueError(f"Missing stopped-player evidence: {prefix}")
        pause = checks.get(f"{prefix}-pause", {}).get("positionDeltaSeconds")
        if not finite_nonnegative(pause) or pause >= 0.15:
            raise ValueError(f"Missing stable pause evidence: {prefix}")
        seek = checks.get(f"{prefix}-seek", {})
        target, observed = seek.get("targetSeconds"), seek.get("observedPositionSeconds")
        if not finite_positive(target) or not finite_nonnegative(observed) or abs(target - observed) >= 0.15:
            raise ValueError(f"Missing exact-seek evidence: {prefix}")
        if resolved == "sampleBuffer" and (
            seek.get("nativeSampleResetObserved") is not True
            or seek.get("nativeResetBaseline") != 0
            or not finite_positive(seek.get("nativePostSeekSampleBuildCount"))
            or not finite_positive(seek.get("nativePreSeekSampleBuildCount"))
            or seek["nativePostSeekSampleBuildCount"] >= seek["nativePreSeekSampleBuildCount"]
        ):
            raise ValueError(f"Missing native seek-generation evidence: {prefix}")
    typed = checks.get("typed-load-resume", {})
    if not valid_segment(typed, resolved):
        raise ValueError("Missing typed-load resume evidence")
    for name, rate in (("slow", 0.5), ("fast", 1.5), ("normal", 1.0)):
        if not valid_segment(checks.get(f"rate-{name}", {}), resolved, expected_rate=rate):
            raise ValueError(f"Missing settled playback-rate evidence: {name}")
    if checks.get("release", {}).get("playerDeallocated") is not True:
        raise ValueError("Player deallocation was not established")
    for checkpoint in raw.get("checkpoints", []):
        if checkpoint.get("state") != "released" and checkpoint.get("effectiveBackend") != resolved:
            raise ValueError("Unexpected video backend fallback")


def finite_nonnegative(value):
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value) and value >= 0


def finite_positive(value):
    return finite_nonnegative(value) and value > 0


def valid_segment(check, backend, expected_rate=1):
    counters = ("maximumAllowedDroppedFrames", "decoderDroppedFramesDelta", "outputDroppedFramesDelta")
    if any(type(check.get(key)) is not int or check[key] != 0 for key in counters):
        return False
    elapsed, progress = check.get("observationSeconds"), check.get("playbackProgressSeconds")
    return (
        finite_positive(check.get("expectedPlaybackRate"))
        and finite_positive(check.get("observedPlaybackRate"))
        and check["expectedPlaybackRate"] == expected_rate
        and check["observedPlaybackRate"] == expected_rate
        and finite_positive(elapsed)
        and elapsed >= 3
        and finite_positive(progress)
        and 0.8 <= progress / elapsed / expected_rate <= 1.2
        and (backend != "sampleBuffer" or finite_positive(check.get("nativeSampleBuildCountDelta")))
    )


def validate_build(saved, expected, app):
    if (
        any(saved.get(key) != value for key, value in expected.items())
        or not app.is_dir()
        or not (app / "MPVUIExample").is_file()
        or saved.get("appSHA256") != digest(app / "MPVUIExample")
    ):
        raise ValueError("Stale or missing device regression build; omit --skip-build")


def run(args):
    from benchmark import measurement_lock, write_json

    media = args.media.resolve()
    identity = media_identity(media)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    output = (args.output or ROOT / f".build/benchmarks/{stamp}-device-regression.json").resolve()
    if output.exists():
        raise ValueError(f"Report already exists: {output}")
    logs = ROOT / f".build/benchmarks/logs/{stamp}-device-regression"
    logs.mkdir(parents=True)
    developer = Path(os.environ.get("DEVELOPER_DIR") or command(["xcode-select", "-p"]).stdout.strip())
    devicectl = developer / "usr/bin/devicectl"
    xcode = plistlib.loads((developer.parent / "version.plist").read_bytes())["ProductBuildVersion"]
    details_path = logs / "device.json"
    command(
        [devicectl, "device", "info", "details", "--device", args.device, "--json-output", details_path],
        log=logs / "device.log",
    )
    details = json.loads(details_path.read_text())["result"]
    hardware = details["hardwareProperties"]
    if hardware.get("reality") != "physical":
        raise ValueError("This command requires a physical device")
    device = {
        "idHash": hashlib.sha256(hardware["udid"].encode()).hexdigest()[:16],
        "model": hardware["productType"],
        "os": details["deviceProperties"]["osVersionNumber"],
        "osBuild": details["deviceProperties"]["osBuildUpdate"],
    }
    with measurement_lock(), serve_media(media, args.host) as url:
        before = source_identity()
        derived = args.derived_data.resolve()
        build_stamp = derived / "mpvui-regression-build.json"
        app = derived / "Build/Products/Release-iphoneos/MPVUIExample.app"
        build_identity = {"source": before["sourceSHA256"], "xcode": xcode}
        if args.skip_build:
            saved = json.loads(build_stamp.read_text()) if build_stamp.exists() else {}
            validate_build(saved, build_identity, app)
        else:
            print("Building Release device regression…", flush=True)
            mcp(
                "build",
                {
                    "projectPath": str(ROOT / "Example/MPVUIExample/MPVUIExample.xcodeproj"),
                    "scheme": "iOS",
                    "configuration": "Release",
                    "derivedDataPath": str(derived),
                    "extraArgs": ["-allowProvisioningUpdates"],
                },
                logs / "build.json",
            )
            if not (app / "MPVUIExample").is_file():
                raise ValueError(f"Build produced no app: {app}")
            if source_identity()["sourceSHA256"] != before["sourceSHA256"]:
                raise ValueError("Source changed while building; rerun with a stable checkout")
            build_stamp.write_text(json.dumps(dict(build_identity, appSHA256=digest(app / "MPVUIExample"))))
        app_hash = digest(app / "MPVUIExample")
        mcp("install", {"deviceId": args.device, "appPath": str(app)}, logs / "install.json")
        if not url:
            command(
                [
                    devicectl,
                    "device",
                    "copy",
                    "to",
                    "--device",
                    args.device,
                    "--source",
                    media,
                    "--destination",
                    "Documents/" + media.name,
                    "--domain-type",
                    "appDataContainer",
                    "--domain-identifier",
                    BUNDLE,
                ],
                log=logs / "media-copy.log",
            )
        name = f"{stamp}-device-regression.json"
        process_list = logs / "processes.json"
        command(
            [
                devicectl,
                "device",
                "info",
                "processes",
                "--device",
                args.device,
                "--search",
                "MPVUIExample",
                "--json-output",
                process_list,
            ],
            log=logs / "processes.log",
        )
        for process in json.loads(process_list.read_text())["result"]["runningProcesses"]:
            if process.get("executable", "").endswith("/MPVUIExample.app/MPVUIExample"):
                mcp("stop", {"deviceId": args.device, "processId": process["processIdentifier"]}, logs / "stop.json")
        print("Running foreground functional regression…", flush=True)
        mcp(
            "launch",
            {
                "deviceId": args.device,
                "bundleId": BUNDLE,
                "launchArgs": launch_arguments(args, url or media.name, name),
            },
            logs / "launch.json",
        )
        destination = logs / name
        deadline = time.monotonic() + 480
        while time.monotonic() < deadline:
            time.sleep(5)
            copied = command(
                [
                    devicectl,
                    "device",
                    "copy",
                    "from",
                    "--device",
                    args.device,
                    "--source",
                    "Documents/Benchmarks/" + name,
                    "--destination",
                    destination,
                    "--domain-type",
                    "appDataContainer",
                    "--domain-identifier",
                    BUNDLE,
                ],
                log=logs / "report-copy.log",
                optional=True,
                timeout=30,
            )
            if copied.returncode == 0 and destination.exists():
                break
        else:
            raise ValueError(f"No completion report; keep the device unlocked and app foreground. See {logs}")
        raw = json.loads(destination.read_text())
        failure = None
        try:
            if source_identity()["sourceSHA256"] != before["sourceSHA256"] or media_identity(media) != identity:
                raise ValueError("Source/media changed during the regression")
            if digest(app / "MPVUIExample") != app_hash:
                raise ValueError("Built app changed during the regression")
            validate_report(raw, args, media, url)
        except (ValueError, KeyError, TypeError) as error:
            failure = str(error)
        report = {
            "schemaVersion": 1,
            "kind": "physical-device-playback-regression",
            "status": "failed" if failure else "passed",
            "error": failure,
            "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "source": before,
            "media": identity,
            "device": device,
            "xcode": xcode,
            "appSHA256": app_hash,
            "buildConfiguration": "Release",
            "protocol": {
                "hostSHA256": digest(Path(__file__)),
                "appScenarioSHA256": digest(ROOT / "Example/MPVUIExample/Shared/PlaybackRegression.swift"),
            },
            "rawReportPath": str(destination),
            "observation": raw,
        }
        write_json(output, report)
        print(f"Device regression report: {output}", flush=True)
        if failure:
            raise ValueError(f"{failure}; raw evidence retained in {destination}")
    return 0
