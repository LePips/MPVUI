#!/usr/bin/env python3
"""Sanitize production audio policy and PCM feeding with deterministic platform inputs."""

import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Build"))
from native_inputs import inputs_for, load
from validation import publish_evidence


def function(source, signature):
    start = source.index(signature)
    return source[start : source.index("\n}", start) + 2]


def main():
    lock = inputs_for(load(ROOT), "apple")
    source = next(item for item in lock["sources"] if item["id"] == "mpv")
    for patch in source["patches"]:
        path = ROOT / patch["path"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != patch["sha256"]:
            raise SystemExit(f"Native patch checksum drift: {path}")

    developer = Path(os.environ["DEVELOPER_DIR"]) if "DEVELOPER_DIR" in os.environ else None
    if developer is None:
        for app in Path("/Applications").glob("Xcode*.app"):
            version = plistlib.loads((app / "Contents/version.plist").read_bytes())
            if version.get("ProductBuildVersion") == lock["toolchain"]["xcode"]["build"]:
                developer = app / "Contents/Developer"
                break
    if developer is None:
        raise SystemExit("Install the pinned Xcode or set DEVELOPER_DIR")
    cache = ROOT / ".build/mpvbuild/git" / (hashlib.sha256(source["url"].encode()).hexdigest() + ".git")
    if not cache.exists():
        raise SystemExit("Run just build first to cache the locked native source")

    with tempfile.TemporaryDirectory(prefix="mpv-native-audio-") as directory:
        work = Path(directory)
        path = work / "audio/out/ao_avfoundation.m"
        path.parent.mkdir(parents=True)
        path.write_bytes(
            subprocess.check_output(["git", "--git-dir", str(cache), "show", f"{source['commit']}:audio/out/ao_avfoundation.m"])
        )
        env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(work.parent))
        for patch in source["patches"]:
            subprocess.run(
                [
                    "git",
                    "apply",
                    "--allow-empty",
                    "--include=audio/out/ao_avfoundation.m",
                    "--include=audio/out/ao_avfoundation_iec.h",
                    str(ROOT / patch["path"]),
                ],
                cwd=work,
                env=env,
                check=True,
            )
        implementation = path.read_text()
        constants = implementation[
            implementation.index("#define IEC61937_HEADER_SIZE") : implementation.index("static char avfoundation_queue_key;")
        ]
        signatures = [
            "static int64_t CMTimeGetNanoseconds(",
            "static void spdif_reload(",
            "static int64_t avp_current_time_ns(",
            "static void avp_apply_volume(",
            "static void avp_update_transport(",
            "static bool avp_stream_tail_drained(",
        ]
        (work / "policy.h").write_text(constants + "\n\n".join(function(implementation, signature) for signature in signatures))
        pcm_signatures = [
            "static int64_t CMTimeGetNanoseconds(",
            "static CMTime CMTimeFromNanoseconds(",
            "static void pcm_request_media_data(",
            "static void pcm_cancel_pending_feed(",
            "static void pcm_pause_feeding(",
            "static void pcm_set_feeding(",
            "static bool pcm_init_feeding(",
            "static void pcm_uninit_feeding(",
            "static int pcm_request_samples(",
            "static void feed(struct ao *ao)\n{",
            "static void pcm_start(",
            "static void pcm_stop(",
            "static void pcm_set_pause(",
        ]
        (work / "pcm.h").write_text(
            constants
            + "\nstatic void feed(struct ao *ao);\n"
            + "\n\n".join(function(implementation, signature) for signature in pcm_signatures)
        )
        for name, file, flags in (
            ("policy", "policy.m", []),
            ("pcm-mobile", "pcm.m", ["-DTEST_MOBILE=1"]),
            ("pcm-desktop", "pcm.m", ["-DTEST_MOBILE=0"]),
        ):
            executable = work / name
            subprocess.run(
                [
                    str(developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"),
                    "-isysroot",
                    str(developer / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"),
                    "-std=c11",
                    "-O1",
                    "-g",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-fsanitize=address,undefined",
                    "-fno-omit-frame-pointer",
                    "-I",
                    str(work),
                    "-framework",
                    "Foundation",
                    "-framework",
                    "AVFoundation",
                    "-framework",
                    "CoreMedia",
                    *flags,
                    str(Path(__file__).with_name(file)),
                    "-o",
                    str(executable),
                ],
                check=True,
            )
            subprocess.run([str(executable)], env=dict(env, ASAN_OPTIONS="detect_leaks=0", UBSAN_OPTIONS="halt_on_error=1"), check=True)
        publish_evidence(
            summary={
                "tests": {"framework": "native", "count": 21, "outcome": "passed", "issues": 0},
                "nativeAudio": {
                    "sanitizers": ["address", "undefined"],
                    "implementationSHA256": hashlib.sha256(implementation.encode()).hexdigest(),
                    "checks": [
                        "IEC periods and malformed data",
                        "loader range overflow",
                        "native clock bounds",
                        "startup recovery",
                        "decoder stalls and source underruns",
                        "EOF tail eligibility",
                        "volume isolation",
                        "PCM route budget and timer allocation failure",
                        "PCM frozen and runaway renderer clocks",
                        "PCM sustained playback with device-clock drift",
                        "PCM partial reads, source starvation and EOF",
                        "PCM pause, resume, seek and timer teardown",
                        "PCM invalid time and fractional queue capacity",
                    ],
                    "scope": "Production functions with simulated Apple clock/status inputs, including mobile and desktop PCM branches. Does not measure audible output or Atmos.",
                },
            }
        )


if __name__ == "__main__":
    main()
