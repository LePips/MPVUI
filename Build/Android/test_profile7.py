#!/usr/bin/env python3
"""Run production Profile 7 conversion checks on a connected arm64 Android device."""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_inputs import inputs_for, load

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / ".build/android"


def run(*args):
    subprocess.run(list(map(str, args)), check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="adb device serial")
    args = parser.parse_args()
    sdk = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
    lock = inputs_for(load(ROOT), "android")
    clang = (
        next((sdk / "ndk" / lock["toolchain"]["ndk"] / "toolchains/llvm/prebuilt").iterdir())
        / f"bin/aarch64-linux-android{lock['minimumAPI']}-clang"
    )
    scripts = WORK / "upstream/buildscripts"
    ffmpeg = scripts / "deps/ffmpeg"
    build = ffmpeg / "_build_arm64"
    prefix = scripts / "prefix/arm64"
    output = WORK / "profile7-test"
    output.mkdir(exist_ok=True)
    source = (ffmpeg / "libavcodec/mediacodecdec.c").read_text()
    implementation = re.search(r"// MPVUI_P7_BEGIN.*?\n(.*?)// MPVUI_P7_END", source, re.S)
    if not implementation:
        parser.error("Build native libraries with the current Build/Inputs.lock.json first")
    (output / "profile7-production.inc").write_text(implementation.group(1))
    objects = [build / "libavcodec" / (name + ".o") for name in ("dovi_rpu", "dovi_rpudec", "h2645_parse", "golomb")]
    executable = output / "profile7-test"
    run(
        clang,
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-O1",
        "-g",
        "-UNDEBUG",
        "-include",
        build / "config.h",
        "-include",
        build / "config_components.h",
        f"-I{build}",
        f"-I{ffmpeg}",
        f"-I{ffmpeg}/libavcodec",
        f"-I{prefix}/include",
        f"-I{output}",
        ROOT / "Build/Android/Tests/profile7.c",
        *objects,
        prefix / "lib/libdovi.a",
        f"-L{prefix}/lib",
        "-lavcodec",
        "-lavutil",
        "-ldl",
        "-llog",
        "-lm",
        "-o",
        executable,
    )
    adb = [str(sdk / "platform-tools/adb")] + (["-s", args.device] if args.device else [])
    destination = "/data/local/tmp/mpvui-profile7-test"
    run(*adb, "shell", "mkdir", "-p", destination)
    fixtures = scripts / "deps/libdovi/assets/tests"
    files = [executable, *(prefix / "lib").glob("*.so"), *(fixtures / name for name in ("mel_orig.bin", "fel_orig.bin", "profile5.bin"))]
    run(*adb, "push", *files, destination)
    try:
        run(*adb, "shell", f"cd {destination} && LD_LIBRARY_PATH=. ./profile7-test mel_orig.bin fel_orig.bin profile5.bin")
    finally:
        run(*adb, "shell", "rm", "-rf", destination)


if __name__ == "__main__":
    main()
