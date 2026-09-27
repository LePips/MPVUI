"""Release playback measurements made inside the example app on a physical iPad/iPhone.

Build/install/launch use XcodeBuildMCP. File transfer uses devicectl because the
CLI has no app-container transfer operation. Host CPU/RSS are never measured.
"""

import contextlib
import datetime
import functools
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import plistlib
import subprocess
import threading
import time
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = "com.lepips.MPVUIExample"


def add_arguments(commands, *, label, bounded_int, finite_range):
    parser = commands.add_parser("device", help="Profile Release playback on an explicitly selected physical device")
    parser.add_argument("--label", type=label, required=True)
    parser.add_argument(
        "--device", required=True, help="Physical UDID/CoreDevice identifier; never selects a device implicitly"
    )
    parser.add_argument(
        "--media", type=Path, required=True, help="Local MP4, or self-contained HLS playlist served with --host"
    )
    parser.add_argument(
        "--host", help="Mac LAN address reachable by the device; serves only this media directory over HTTP"
    )
    parser.add_argument("--players", default="mpv,avplayer", help="mpv,avplayer or one player")
    parser.add_argument("--backend", choices=("default", "sampleBuffer", "metal"), default="default")
    parser.add_argument("--sdr-output", choices=("automatic", "compatibility8Bit"), default="automatic")
    parser.add_argument("--software-decoding", action="store_true")
    parser.add_argument(
        "--option", action="append", default=[], help="MPV key=value override; repeat for controlled experiments"
    )
    parser.add_argument("--seconds", type=finite_range(2, 300), default=30.0)
    parser.add_argument("--warmup", type=finite_range(1, 60), default=5.0)
    parser.add_argument("--repetitions", type=bounded_int(1, 20), default=3)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--derived-data", type=Path, default=ROOT / ".build/device-benchmark")
    parser.add_argument(
        "--skip-build", action="store_true", help="Reuse only a build stamped with the current source digest"
    )


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def source_identity():
    from benchmark import source_identity as identity

    result = identity(ROOT)
    files = dict(result["files"])
    for directory in (ROOT / "Example/MPVUIExample", ROOT / "Build/Benchmarks"):
        for path in directory.rglob("*"):
            if path.is_file() and path.suffix in (".swift", ".py", ".pbxproj", ".plist", ".xcscheme", ".resolved"):
                files[str(path.relative_to(ROOT))] = digest(path)
    result["files"] = files
    # Local selection paths can stay constant while their binary changes.
    import re

    local = re.search(r'\.binaryTarget\(name: "Libmpv-GPL", path: "([^"]+)"', (ROOT / "Package.swift").read_text())
    if local:
        framework = (ROOT / local.group(1)).resolve()
        manifest = plistlib.loads((framework / "Info.plist").read_bytes())
        for library in manifest["AvailableLibraries"]:
            if library["SupportedPlatform"] == "ios" and not library.get("SupportedPlatformVariant"):
                relative = library.get("BinaryPath", library["LibraryPath"] + "/Libmpv")
                binary = framework / library["LibraryIdentifier"] / relative
                files["selectedNativeBinary:" + library["LibraryIdentifier"]] = digest(binary)
    result["sourceSHA256"] = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    return result


def command(arguments, *, log=None, optional=False, timeout=180):
    result = subprocess.run(
        [str(x) for x in arguments], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout
    )
    if log:
        Path(log).write_text(result.stdout)
    if result.returncode and not optional:
        raise ValueError(f"Command failed ({result.returncode}); {log or result.stdout[-2000:]}")
    return result


def mcp(operation, parameters, log):
    result = command(
        ["xcodebuildmcp", "device", operation, "--json", json.dumps(parameters), "--output", "json"],
        log=log,
        timeout=1200,
    )
    payload = json.loads(result.stdout)
    if payload.get("didError") or payload.get("isError"):
        raise ValueError(f"Device {operation} failed; see {log}")
    return payload


def media_identity(path):
    """Hash every HLS segment/playlist; reject remote/escaping resources."""
    path = path.resolve()
    if not path.is_file():
        raise ValueError(f"Missing media: {path}")
    files, pending = {}, [path]
    while pending:
        current = pending.pop()
        name = str(current.relative_to(path.parent))
        if name in files:
            continue
        if not current.is_file():
            raise ValueError(f"Missing HLS resource: {current}")
        files[name] = digest(current)
        if current.suffix.lower() != ".m3u8":
            continue
        import re

        for line in current.read_text().splitlines():
            line = line.strip()
            refs = re.findall(r'URI="([^"]+)"', line) if line.startswith("#") else [line] if line else []
            for ref in refs:
                if ":" in ref or "?" in ref or "#" in ref:
                    raise ValueError(
                        "Use captured HLS with local segment/key references, without credentials or remote resources"
                    )
                resource = (current.parent / ref).resolve()
                if not resource.is_relative_to(path.parent):
                    raise ValueError("HLS resource escapes the media directory")
                pending.append(resource)
    return {
        "name": path.name,
        "sha256": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest(),
        "files": files,
    }


@contextlib.contextmanager
def serve_media(media, host):
    if not host:
        if media.suffix.lower() == ".m3u8":
            raise ValueError("HLS requires --host <Mac LAN address> for real HTTP playback")
        yield None
        return
    allowed = {(media.parent / name).resolve() for name in media_identity(media)["files"]}

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def list_directory(self, _):
            self.send_error(403)
            return None

        def send_head(self):
            if Path(self.translate_path(self.path)).resolve() not in allowed:
                self.send_error(404)
                return None
            return super().send_head()

    server = http.server.ThreadingHTTPServer((host, 0), functools.partial(Handler, directory=str(media.parent)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://{host}:{server.server_port}/{quote(media.name)}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def metric_unit(name):
    if name.endswith("Bytes"):
        return "bytes"
    if name.endswith("PerWallSecond"):
        return "cpu-seconds/wall-second"
    if name.endswith("Seconds"):
        return "seconds"
    return "count"


def validate_steady_progress(raw):
    """Protocol 4 requires phase observations and bounded steady clock progress."""
    if raw.get("schemaVersion") != 4:
        raise ValueError("Expected on-device benchmark protocol 4")
    phase = raw.get("phases", {}).get("steady", {})
    validation = raw.get("validation", {})
    wall = phase.get("wallSeconds")
    progress = validation.get("steadyProgressSeconds")
    rate = validation.get("steadyProgressPerWallSecond")
    if any(
        isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0
        for value in (wall, progress, rate)
    ):
        raise ValueError("Missing finite steady playback timing evidence")
    if not math.isclose(rate, progress / wall, rel_tol=1e-9, abs_tol=1e-9):
        raise ValueError("Steady playback progress must use observed phase wall time")
    if not 0.85 <= rate <= 1.15:
        raise ValueError("Steady playback progress differs from the expected 1x rate")


def validate_steady_diagnostics(raw):
    """Require runtime session and frame evidence, never cached capability alone."""
    config = raw.get("configuration", {})
    if config.get("player") != "mpv":
        return
    checkpoints = raw.get("diagnostics", {})
    samples = raw.get("phases", {}).get("steady", {}).get("diagnosticSamples", [])
    if len(samples) < 2:
        raise ValueError("Missing newly published steady diagnostic observations")
    evidence = [checkpoints.get("steadyStart", {}), *samples, checkpoints.get("steadyEnd", {})]
    backend = config.get("resolvedBackend")
    if backend not in ("sampleBuffer", "metal"):
        raise ValueError("Missing resolved playback backend")
    for sample in evidence:
        if (
            sample.get("effectiveBackend") != backend
            or sample.get("videoOutputFallbackReason")
            or sample.get("decoderFallbackReason")
            or sample.get("fallbackReasons") != []
        ):
            raise ValueError("Unexpected steady renderer or decoder fallback")
        hardware = sample.get("videoToolboxSessionUsesHardware")
        session = sample.get("decoderSession")
        if config.get("softwareDecoding"):
            pixel_format = sample.get("decodedPixelFormat")
            if (
                session != "software"
                or hardware is True
                or not isinstance(pixel_format, str)
                or not pixel_format
                or "videotoolbox" in pixel_format.lower()
            ):
                raise ValueError("Missing actual software-decoder evidence")
        elif hardware is not True or session in (None, "unknown", "software"):
            raise ValueError("Missing actual hardware-decoder session evidence")
    for key in ("decoderDroppedFrames", "outputDroppedFrames"):
        values = [sample.get(key) for sample in evidence]
        if any(type(value) is not int or value < 0 for value in values):
            raise ValueError("Steady decoder/output drop counters are unavailable")
        if any(value != values[0] for value in values[1:]):
            raise ValueError("Steady decoder/output drop counters increased or reset")
    if backend == "sampleBuffer":
        counts = [sample.get("nativeSampleBuildCount") for sample in evidence]
        if (
            any(type(value) is not int or value < 0 for value in counts)
            or any(last < first for first, last in zip(counts, counts[1:]))
            or counts[-1] <= counts[0]
        ):
            raise ValueError("Steady native sample-build attempts did not progress without reset")


def aggregate(raw_runs, *, source, media, args, device, xcode, app_hash):
    workloads = {}
    environment_keys = []
    stable_environment = None
    for raw in raw_runs:
        if raw.get("status") != "passed":
            raise ValueError(f"On-device validation failed: {raw.get('error')}")
        validate_steady_progress(raw)
        config = raw["configuration"]
        player = config["player"]
        expected_options = dict(option.split("=", 1) for option in args.option) if player == "mpv" else {}
        if (
            player not in args.players.split(",")
            or config.get("sampleSeconds") != args.seconds
            or config.get("warmupSeconds") != args.warmup
            or config.get("options") != expected_options
            or config.get("softwareDecoding") != (args.software_decoding if player == "mpv" else False)
            or config.get("sdrOutput") != (args.sdr_output if player == "mpv" else "automatic")
            or config.get("backend") != (args.backend if player == "mpv" else "AVPlayerLayer")
        ):
            raise ValueError("On-device configuration differs from requested measurement")
        validate_steady_diagnostics(raw)
        stable_fields = (
            "hardwareModel",
            "operatingSystem",
            "lowPowerMode",
            "batteryState",
            "surfaceWidthPoints",
            "surfaceHeightPoints",
            "screenScale",
            "maximumFramesPerSecond",
            "audioSampleRate",
            "audioOutputChannels",
            "audioIOBufferSeconds",
            "audioRoute",
            "systemOutputVolume",
            "isSimulator",
            "thermalState",
        )
        environment = {key: raw["environment"][key] for key in stable_fields}
        if environment["isSimulator"] or environment["thermalState"] != 0:
            raise ValueError("Measurements require a physical device at nominal thermal state; raw report retained")
        if any(point.get("thermalState") != 0 for point in raw.get("timeline", [])):
            raise ValueError("Thermal state changed during measurement; raw report retained")
        after = raw["environment"]["after"]
        if any(after.get(key) != value for key, value in environment.items()):
            raise ValueError("Audio/display/power/thermal environment changed during a run; raw report retained")
        if stable_environment is not None and environment != stable_environment:
            raise ValueError("Audio/display/power/thermal environment changed between runs; raw reports retained")
        stable_environment = environment
        workload = workloads.setdefault(
            player,
            {
                "id": "device_playback_" + player,
                "parameters": {
                    "mediaSHA256": media["sha256"],
                    "transport": "http" if args.host else "file",
                    "sampleSeconds": args.seconds,
                    "warmupSeconds": args.warmup,
                    "player": player,
                    "backend": args.backend if player == "mpv" else "avplayer",
                    "softwareDecoding": args.software_decoding if player == "mpv" else False,
                    "sdrOutput": args.sdr_output if player == "mpv" else "automatic",
                    "options": sorted(args.option) if player == "mpv" else [],
                },
                "metrics": {},
                "observations": [],
            },
        )
        for key, value in raw["metrics"].items():
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                continue
            workload["metrics"].setdefault(key, {"unit": metric_unit(key), "direction": "lower", "samples": []})[
                "samples"
            ].append(value)
        workload["observations"].append(raw)
        environment_keys.append(raw["environment"])
    protocol = {
        p.name: digest(p) for p in (Path(__file__), ROOT / "Example/MPVUIExample/Shared/PlaybackBenchmark.swift")
    }
    return {
        "label": args.label,
        "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source": source,
        "configuration": {"repetitions": args.repetitions, "build": "Release"},
        "environment": {
            "comparisonKey": {
                "device": device,
                "xcode": xcode,
                "configuration": "Release",
                "protocol": protocol,
                "playbackEnvironment": stable_environment,
            },
            "runs": environment_keys,
        },
        "runtime": {
            "appSHA256": app_hash,
            "media": media,
            "limitations": [
                "CPU is app-process CPU; AVPlayer system-service work is not included.",
                "Footprint and resident memory are sampled every 100 ms; shorter transient peaks may be missed.",
                "Same fixture, device, audio route, display, thermal state, and Release configuration are required for comparison.",
                "AVPlayer and MPV counters have different scopes; no VLC baseline is measured by this app.",
            ],
        },
        "workloads": list(workloads.values()),
    }


def run(args):
    from benchmark import measurement_lock, write_json

    players = args.players.split(",")
    if not players or len(players) != len(set(players)) or set(players) - {"mpv", "avplayer"}:
        raise ValueError("--players must be mpv,avplayer or one of those players")
    if any("=" not in option or not option.split("=", 1)[0] for option in args.option):
        raise ValueError("--option requires key=value")
    media = args.media.resolve()
    identity = media_identity(media)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    output = (args.output or ROOT / f".build/benchmarks/{stamp}-{args.label}.json").resolve()
    if output.exists():
        raise ValueError(f"Report already exists: {output}")
    logs = ROOT / f".build/benchmarks/logs/{stamp}-{args.label}"
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
        build_stamp = derived / "mpvui-benchmark-build.json"
        app = derived / "Build/Products/Release-iphoneos/MPVUIExample.app"
        build_identity = {"source": before["sourceSHA256"], "xcode": xcode}
        if args.skip_build:
            saved = json.loads(build_stamp.read_text()) if build_stamp.exists() else {}
            if (
                any(saved.get(key) != value for key, value in build_identity.items())
                or not app.exists()
                or saved.get("appSHA256") != digest(app / "MPVUIExample")
            ):
                raise ValueError("Stale or missing device build; omit --skip-build")
        else:
            print("Building Release device benchmark…", flush=True)
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
            if not app.exists():
                raise ValueError(f"Build produced no app: {app}")
            if source_identity()["sourceSHA256"] != before["sourceSHA256"]:
                raise ValueError("Source changed while building; rerun with a stable checkout")
            build_stamp.write_text(json.dumps(dict(build_identity, appSHA256=digest(app / "MPVUIExample"))))
        mcp("install", {"deviceId": args.device, "appPath": str(app)}, logs / "install.json")
        app_hash = digest(app / "MPVUIExample")
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
        runs = []
        for repetition in range(args.repetitions):
            order = players[repetition % len(players) :] + players[: repetition % len(players)]
            for player in order:
                name = f"{stamp}-{args.label}-{player}-{repetition + 1}.json"
                print(f"{player}: run {repetition + 1}/{args.repetitions}…", flush=True)
                # A fresh process per sample prevents one player's lifetime allocations contaminating another.
                process_list = logs / (name + ".processes.json")
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
                    log=logs / (name + ".processes.log"),
                )
                for process in json.loads(process_list.read_text())["result"]["runningProcesses"]:
                    if process.get("executable", "").endswith("/MPVUIExample.app/MPVUIExample"):
                        mcp(
                            "stop",
                            {"deviceId": args.device, "processId": process["processIdentifier"]},
                            logs / (name + ".stop.json"),
                        )
                launch = [
                    "--playback-benchmark",
                    "--benchmark-player",
                    player,
                    "--benchmark-media",
                    url or media.name,
                    "--benchmark-output",
                    name,
                    "--benchmark-seconds",
                    str(args.seconds),
                    "--benchmark-warmup",
                    str(args.warmup),
                    "--benchmark-backend",
                    args.backend if player == "mpv" else "default",
                    "--benchmark-sdr-output",
                    args.sdr_output if player == "mpv" else "automatic",
                ]
                if player == "mpv" and args.software_decoding:
                    launch.append("--benchmark-software-decoding")
                for option in args.option if player == "mpv" else []:
                    launch += ["--benchmark-option", option]
                mcp(
                    "launch",
                    {"deviceId": args.device, "bundleId": BUNDLE, "launchArgs": launch},
                    logs / (name + ".launch.json"),
                )
                deadline = time.monotonic() + args.seconds + args.warmup + 120
                destination = logs / name
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
                        log=logs / (name + ".copy.log"),
                        optional=True,
                        timeout=30,
                    )
                    if copied.returncode == 0 and destination.exists():
                        break
                else:
                    raise ValueError(
                        f"No on-device completion report (device must remain unlocked and foreground); see {logs}"
                    )
                raw = json.loads(destination.read_text())
                runs.append(raw)
                if raw.get("status") != "passed":
                    raise ValueError(f"Device validation failed: {raw.get('error')}; see {destination}")
                print(f"  {raw['metrics']}", flush=True)
        if source_identity()["sourceSHA256"] != before["sourceSHA256"] or media_identity(media) != identity:
            raise ValueError(f"Source/media changed during measurement; raw evidence kept in {logs}")
        report = aggregate(
            runs, source=before, media=identity, args=args, device=device, xcode=xcode, app_hash=app_hash
        )
        write_json(output, report)
        print(f"Device report: {output}", flush=True)
    return 0
