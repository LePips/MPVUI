#!/usr/bin/env python3
"""Repeatable, opt-in Android playback measurements. Native libraries must already be built."""

import argparse
import json
import re
import shlex
import statistics
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / ".build/android/performance"
PACKAGE = "mpvui.test"


def run(*command, **kwargs):
    return subprocess.run([str(value) for value in command], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True, help="Unique result label, e.g. before or after")
    parser.add_argument("--serial", help="adb device serial (required when multiple devices are attached)")
    parser.add_argument("--seconds", type=int, default=10, choices=range(1, 121), metavar="1..120")
    parser.add_argument("--rounds", type=int, default=3, choices=range(1, 21), metavar="1..20")
    parser.add_argument("--apk", type=Path, help="Install a saved benchmark APK instead of building current sources")
    parser.add_argument("--media", type=Path, help="Benchmark this local file instead of the standard four phases")
    parser.add_argument(
        "--hardware-decoding", choices=["AUTOMATIC", "MEDIACODEC", "DISABLED"], default="AUTOMATIC", help="Decoder policy for --media"
    )
    parser.add_argument(
        "--option", action="append", default=[], metavar="KEY=VALUE", help="mpv option for --media; repeat to compare configurations"
    )
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.label):
        parser.error("label may contain only letters, numbers, underscore and hyphen")
    if not args.media and (args.option or args.hardware_decoding != "AUTOMATIC"):
        parser.error("--option and --hardware-decoding require --media")
    options = {}
    for option in args.option:
        key, separator, value = option.partition("=")
        if not key or not separator:
            parser.error("--option must be KEY=VALUE")
        options[key] = value
    OUTPUT.mkdir(parents=True, exist_ok=True)
    report_path = OUTPUT / f"performance-{args.label}.json"
    if report_path.exists():
        parser.error(f"Result already exists: {report_path}; choose another label")
    adb = ["adb"]
    devices = run("adb", "devices", capture_output=True, text=True).stdout.splitlines()[1:]
    serials = [line.split()[0] for line in devices if len(line.split()) >= 2 and line.split()[1] == "device"]
    if args.serial:
        if args.serial not in serials:
            parser.error(f"Device {args.serial} is not connected/authorized")
        adb += ["-s", args.serial]
    elif len(serials) != 1:
        parser.error("Connect exactly one authorized device, or pass --serial")
    else:
        adb += ["-s", serials[0]]
    if args.apk:
        apk = args.apk.resolve(strict=True)
    else:
        media = ROOT / ".build/test-media/performance-1080p60.mp4"
        if not args.media and not media.exists():
            media.parent.mkdir(parents=True, exist_ok=True)
            run(
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                "testsrc2=size=1920x1080:rate=60",
                "-t",
                "12",
                "-c:v",
                "libx264",
                "-preset",
                "fast",
                "-crf",
                "23",
                "-pix_fmt",
                "yuv420p",
                "-movflags",
                "+faststart",
                "-an",
                "-y",
                media,
            )
        run(ROOT / "Android/gradlew", ":mpvui:assembleDebugAndroidTest", cwd=ROOT / "Android")
        apk = ROOT / "Android/mpvui/build/outputs/apk/androidTest/debug/mpvui-debug-androidTest.apk"
    run(*adb, "install", "-r", apk)
    run(*adb, "shell", "input", "keyevent", "KEYCODE_WAKEUP")
    method = "benchmarkMedia" if args.media else "benchmarkPlayback"
    command = [
        "am",
        "instrument",
        "-w",
        "-e",
        "class",
        f"mpvui.PlaybackPerformanceTest#{method}",
        "-e",
        "performanceLabel",
        args.label,
        "-e",
        "performanceSeconds",
        str(args.seconds),
        "-e",
        "performanceRounds",
        str(args.rounds),
    ]
    if args.media:
        # Write as the app UID. Shell-owned files in Android/data can be unreadable
        # to the app under scoped storage, even when adb push succeeds.
        run(*adb, "shell", "run-as", PACKAGE, "mkdir", "-p", "files")
        with args.media.resolve(strict=True).open("rb") as source:
            run(*adb, "exec-in", "run-as", PACKAGE, "dd", "of=files/performance-media", "bs=1048576", stdin=source)
        command += [
            "-e",
            "performanceMedia",
            f"/data/user/0/{PACKAGE}/files/performance-media",
            "-e",
            "performanceOptions",
            json.dumps(options),
            "-e",
            "performanceHardwareDecoding",
            args.hardware_decoding,
        ]
    command += [f"{PACKAGE}/androidx.test.runner.AndroidJUnitRunner"]
    log = OUTPUT / f"{args.label}.log"
    with log.open("w") as output:
        run(*adb, "shell", shlex.join(command), stdout=output, stderr=subprocess.STDOUT)
    # am instrument can return zero even when a test fails.
    if "OK (1 test)" not in log.read_text():
        raise SystemExit(f"Benchmark did not pass; see {log}")
    run(*adb, "pull", f"/sdcard/Android/data/{PACKAGE}/files/performance-{args.label}.json", report_path)
    report = json.loads(report_path.read_text())
    samples = report["samples"]
    if len(samples) != (1 if args.media else 4) * args.rounds:
        raise SystemExit(f"Incomplete benchmark report: {report_path}")
    print(f"\n{report['model']} / API {report['sdk']}; medians per second ({args.rounds} rounds)")
    if args.media:
        print(
            f"media        process CPU {statistics.median(s['processCpuMs'] / s['seconds'] for s in samples):7.2f} ms/s, "
            f"dropped frames {statistics.median(s['droppedFrames'] / s['seconds'] for s in samples):.2f}/s"
        )
    for phase in dict.fromkeys(sample["phase"] for sample in samples if "phase" in sample):
        group = [sample for sample in samples if sample["phase"] == phase]

        def rate(key):
            return statistics.median(sample[key] / sample["seconds"] for sample in group)

        print(
            f"{phase:12s} process CPU {rate('processCpuMs'):7.2f} ms/s, "
            f"workers {rate('workerCpuMs'):6.2f} ms/s, "
            f"context switches {rate('workerContextSwitches'):7.2f}/s, "
            f"allocations {rate('allocatedBytes') / 1024:7.2f} KiB/s"
        )
    if any(sample["thermalStart"] > 0 or sample["thermalEnd"] > 0 for sample in samples):
        print("Thermal throttling was reported; allow the device to cool before comparisons.")
    print(f"Raw samples: {report_path}")


if __name__ == "__main__":
    main()
