#!/usr/bin/env python3
"""Route make commands and their options to the build, test, release, and benchmark tools.

Make passes the command, then OPTION=value settings, then tool arguments after --.
Each selected step runs through validation.py, which streams output and saves logs and results.
"""

from dataclasses import dataclass
import os
import subprocess
import sys

import validation

PYTHON = sys.executable
PLATFORMS = ("apple", "android")
PROFILES = ("dev", "release")
OPTIONS = {
    "PLATFORM": "apple|android, default apple",
    "PROFILE": "dev|release, default dev. Native build profile and Android example variant",
    "SUITE": "Test suite, listed under make test",
    "STEP": "Release or benchmark step, listed under each command",
    "DEVICE": "Device or simulator identifier, or Android serial",
    "FILTER": "Run matching Swift tests without coverage",
    "CHECK": "1 checks formatting without changing files",
    "JSON": "1 prints one JSON result per step instead of tool output",
}


class UsageError(ValueError):
    pass


@dataclass(frozen=True)
class Step:
    """One validated tool run. device is "flag" for --device or "env" for ANDROID_SERIAL."""

    kind: str
    command: tuple
    device: str = ""
    args: bool = True


@dataclass(frozen=True)
class Options:
    platform: str = "apple"
    profile: str = "dev"
    suite: str = ""
    step: str = ""
    device: str = ""
    filter: str = ""
    check: bool = False
    json: bool = False


@dataclass(frozen=True)
class Command:
    summary: str
    options: tuple
    table: dict
    selector: str = ""


def python(kind, *arguments, device="", args=True):
    return Step(kind, (PYTHON, *arguments), device, args)


def fixed(*steps):
    return lambda options: list(steps)


def lane(name):
    return fixed(python("test", "Build/Tests/coverage.py", "--lane", name))


def gradle(project, *tasks, device=""):
    return Step("test", (f"{project}/gradlew", "-p", project, *tasks), device)


def android_example(options):
    release = options.profile == "release"
    variant = "Release" if release else "Debug"
    flags = ("-PmpvuiTestBuildType=release",) if release else ()
    return [MEDIA, gradle("Example/Android", f":app:connected{variant}AndroidTest", *flags, device="env")]


def apple_benchmark(options):
    if options.device:
        return [python("benchmark", "Build/Benchmarks/benchmark.py", "device", device="flag")]
    return [python("benchmark", "Build/Benchmarks/benchmark.py", "run")]


MPVBUILD = "Build/mpvbuild"
MEDIA = python("command", "Build/Tests/prepare_test_media.py", args=False)
TOOLS = fixed(
    Step("test", ("swift", "test", "--package-path", "Build", "--scratch-path", ".build/build-tools", "--no-parallel"), args=False),
    python("test", "-m", "unittest", "discover", "-s", "Build/Tests", "-p", "test_*.py"),
)
SHARED_SUITES = {"tools": ("Build, test, and benchmark script tests", TOOLS)}

# Each table maps a platform, or "any", to its selections. The "" selection is the default.
COMMANDS = {
    "setup": Command(
        "Check requirements, install build tools, and generate test media",
        ("PLATFORM",),
        {
            "apple": {"": ("", fixed(python("command", MPVBUILD, "doctor", "--bootstrap"), MEDIA))},
            "android": {"": ("", fixed(MEDIA))},
        },
    ),
    "build": Command(
        "Build and check native libraries. Apple builds become the latest candidate",
        ("PLATFORM", "PROFILE"),
        {
            "apple": {"": ("", lambda options: [python("build", MPVBUILD, "build", "--profile", options.profile)])},
            "android": {"": ("", fixed(python("build", "Build/Android/build.py")))},
        },
    ),
    "test": Command(
        "Run tests",
        ("PLATFORM", "SUITE", "FILTER", "DEVICE", "PROFILE"),
        {
            "apple": {
                "": ("Core, unit, and integration tests with coverage", lane("default")),
                "core": ("Shared core tests with coverage", lane("core")),
                "unit": ("Core and Apple unit tests with coverage", lane("unit")),
                "integration": ("Integration tests with coverage", lane("integration")),
                "system": ("System tests with coverage. Each needs its opt-in variable", lane("system")),
                "all": ("Every package test lane with coverage", lane("all")),
                "native": ("Native HDR and compositor harnesses with sanitizers", fixed(python("test", "Build/Tests/NativeHDR/run.py"))),
                "device": (
                    "Generated test project on DEVICE, a device or simulator",
                    fixed(python("test", "Build/Tests/run_xcode_tests.py", device="flag")),
                ),
                "consumer": (
                    "Independent package consumer of the selected artifact",
                    fixed(python("test", "Build/Tests/apple_consumer.py")),
                ),
                "regression": (
                    "Playback lifecycle checks on DEVICE",
                    fixed(python("test", "Build/Benchmarks/benchmark.py", "device-regression", device="flag")),
                ),
                "rendering": (
                    "Generate SDR and PQ clips for manual rendering checks",
                    fixed(python("command", "Build/Tests/RenderingValidation/generate.py")),
                ),
                **SHARED_SUITES,
            },
            "android": {
                "": ("Kotlin unit tests and release lint", fixed(gradle("Android", ":mpvui:testDebugUnitTest", ":mpvui:lintRelease"))),
                "core": ("Shared core tests on DEVICE", fixed(python("test", "Build/Android/swift_core.py", "--test", device="flag"))),
                "integration": (
                    "Library instrumentation tests",
                    fixed(MEDIA, gradle("Android", ":mpvui:connectedDebugAndroidTest", device="env")),
                ),
                "example": ("Example instrumentation tests. PROFILE=release tests the optimized build", android_example),
                "native": (
                    "Profile 7 and Dolby Vision GPU checks on arm64",
                    fixed(
                        python("test", "Build/Android/test_profile7.py", device="flag"),
                        python("test", "Build/Android/test_dovi_gpu.py", device="flag"),
                    ),
                ),
                "consumer": (
                    "Independent consumer apps from the Maven bundle, run on DEVICE when set",
                    fixed(python("test", "Build/Android/consumer.py", device="flag")),
                ),
                **SHARED_SUITES,
            },
        },
        "SUITE",
    ),
    "release": Command(
        "Create, check, and publish release artifacts",
        ("PLATFORM", "STEP", "PROFILE"),
        {
            "apple": {
                "": (
                    "Build every slice, run consumer tests, and create a publication bundle",
                    fixed(python("build", MPVBUILD, "release", "candidate", "--profile", "release")),
                ),
                "publish": (
                    "Upload a publication bundle as a native artifact release",
                    fixed(python("command", MPVBUILD, "release", "publish")),
                ),
                "adopt": ("Adopt a published native release into the lock files", fixed(python("command", MPVBUILD, "release", "adopt"))),
                "package": ("Create the package release for a tagged checkout", fixed(python("command", MPVBUILD, "release", "package"))),
                "check": (
                    "Check generated files and the published artifact against the lock files",
                    fixed(python("test", MPVBUILD, "release", "check")),
                ),
                "repro": (
                    "Build twice from separate checkouts and compare native bytes",
                    lambda options: [python("build", MPVBUILD, "release", "repro", "--profile", options.profile)],
                ),
                "audit": (
                    "Record SDK and runtime provenance for native dependencies",
                    fixed(python("build", MPVBUILD, "release", "audit")),
                ),
            },
            "android": {
                "": ("Create a local Maven bundle, AAR, sources, and checksums", fixed(python("build", "Build/Android/release.py"))),
            },
        },
        "STEP",
    ),
    "benchmark": Command(
        "Measure performance",
        ("PLATFORM", "STEP", "DEVICE"),
        {
            "apple": {
                "": ("Host benchmarks, or mpv and AVPlayer playback on DEVICE when set", apple_benchmark),
                "compare": ("Compare two benchmark reports", fixed(python("benchmark", "Build/Benchmarks/benchmark.py", "compare"))),
                "ab": (
                    "Compare two built checkouts on DEVICE",
                    fixed(python("benchmark", "Build/Benchmarks/run_device_ab.py", device="flag")),
                ),
                "profile": (
                    "Record an Instruments trace of playback on DEVICE",
                    fixed(python("benchmark", "Build/Benchmarks/capture_device_profile.py", device="flag")),
                ),
                "analyze": (
                    "Summarize a captured profile with symbols",
                    fixed(python("benchmark", "Build/Benchmarks/analyze_device_profile.py")),
                ),
                "trace": (
                    "Summarize exported System Trace tables",
                    fixed(python("benchmark", "Build/Benchmarks/analyze_device_system_trace.py")),
                ),
                "sync-prepare": (
                    "Prepare synchronization probe resources",
                    fixed(python("benchmark", "Build/Benchmarks/prepare_sync_probe.py")),
                ),
                "sync": (
                    "Run the synchronization probe on DEVICE",
                    fixed(python("benchmark", "Build/Benchmarks/run_device_sync_probe.py", device="flag")),
                ),
            },
            "android": {"": ("Playback on DEVICE", fixed(python("benchmark", "Build/Android/benchmark.py", device="flag")))},
        },
        "STEP",
    ),
    "select": Command(
        "Point Package.swift at the latest candidate. ARGS=--remote restores the published artifact",
        (),
        {"apple": {"": ("", fixed(python("command", MPVBUILD, "select")))}},
    ),
    "update": Command(
        "Update native dependency pins, or stage a recipes review",
        (),
        {"any": {"": ("", fixed(python("command", "Build/update_dependencies.py")))}},
    ),
    "clean": Command(
        "Remove build outputs and test results. ARGS=--cache also removes downloads and tools",
        (),
        {"any": {"": ("", fixed(python("command", "Build/clean.py")))}},
    ),
    "format": Command(
        "Format sources. CHECK=1 checks without changing files",
        ("CHECK",),
        {
            "any": {
                "": (
                    "",
                    lambda options: [
                        Step("command", ("pre-commit", "run", "--all-files", *(("--hook-stage", "manual") if options.check else ())))
                    ],
                )
            }
        },
    ),
}


def parse(argv):
    """Split make's arguments into a command, validated options, and tool arguments."""
    if not argv:
        raise UsageError("Expected a command")
    name, *rest = argv
    if name == "help":
        return name, Options(), []
    command = COMMANDS.get(name)
    if command is None:
        raise UsageError(f"Unknown command {name}")
    settings, arguments = (rest[: rest.index("--")], rest[rest.index("--") + 1 :]) if "--" in rest else (rest, [])
    values = {}
    for setting in settings:
        key, separator, value = setting.partition("=")
        allowed = command.options + ("JSON",)
        if not separator or key not in allowed:
            raise UsageError(f"make {name} accepts {', '.join(allowed)}, not {key}")
        values[key] = value
    for key, choices in (("PLATFORM", PLATFORMS), ("PROFILE", PROFILES), ("CHECK", ("0", "1")), ("JSON", ("0", "1"))):
        if key in values and values[key] not in choices:
            raise UsageError(f"{key} must be one of {', '.join(choices)}")
    options = Options(
        platform=values.get("PLATFORM", "apple"),
        profile=values.get("PROFILE", "dev"),
        suite=values.get("SUITE", ""),
        step=values.get("STEP", ""),
        device=values.get("DEVICE", ""),
        filter=values.get("FILTER", ""),
        check=values.get("CHECK") == "1",
        json=values.get("JSON") == "1",
    )
    return name, options, arguments


def resolve(name, options):
    """Return the steps a command runs for these options."""
    command = COMMANDS[name]
    selections = command.table.get(options.platform, command.table.get("any"))
    if selections is None:
        raise UsageError(f"make {name} does not support PLATFORM={options.platform}")
    if options.filter:
        if options.platform != "apple" or options.suite:
            raise UsageError("FILTER runs Apple package tests and cannot be combined with SUITE")
        steps = [python("test", "Build/Tests/run_swift_tests.py", "--filter", options.filter)]
    else:
        selected = options.suite if command.selector == "SUITE" else options.step
        if selected not in selections:
            values = ", ".join(value for value in selections if value)
            if not values:
                raise UsageError(f"make {name} PLATFORM={options.platform} takes no {command.selector}")
            raise UsageError(f"{command.selector} for make {name} PLATFORM={options.platform} must be one of: {values}")
        steps = selections[selected][1](options)
    if options.device and not any(step.device for step in steps):
        raise UsageError("DEVICE does not apply to this selection")
    return steps


def execute(name, options, arguments):
    steps = resolve(name, options)
    if {"-h", "--help"} & set(arguments):
        step = next(step for step in steps if step.args)
        return subprocess.run([*step.command, *arguments]).returncode
    if options.device and any(step.device == "env" for step in steps):
        os.environ["ANDROID_SERIAL"] = options.device
    for step in steps:
        command = [*step.command, *(arguments if step.args else ())]
        if step.device == "flag" and options.device:
            command += ["--device", options.device]
        code = validation.main(["--kind", step.kind, *(["--json"] if options.json else []), "--", *command])
        if code:
            return code
    return 0


def usage():
    lines = ['Usage: make COMMAND [OPTION=value ...] [ARGS="tool options"]', "", "Commands:"]
    lines += [f"  {name:<10} {command.summary}" for name, command in COMMANDS.items()]
    for name, command in COMMANDS.items():
        if not command.selector:
            continue
        lines += ["", f"make {name} {command.selector}:"]
        for platform, selections in command.table.items():
            lines.append(f"  PLATFORM={platform}")
            lines += [f"    {value or '(default)':<14} {description}" for value, (description, _) in selections.items()]
    lines += ["", "Options:"]
    lines += [f"  {key + '=':<10} {description}" for key, description in OPTIONS.items()]
    lines += [
        f"  {'ARGS=':<10} Tool options. ARGS=--help lists them for the selected tool",
        f"  {'PYTHON=':<10} Python executable",
        "",
        "make build test runs commands in order and stops on failure.",
        "Logs and results are saved in .build/validation. make -C Build accepts the same commands.",
    ]
    return "\n".join(lines)


def main(argv=None):
    try:
        name, options, arguments = parse(sys.argv[1:] if argv is None else argv)
        if name == "help":
            print(usage())
            return 0
        return execute(name, options, arguments)
    except UsageError as error:
        print(f"error: {error}. Run make help.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
