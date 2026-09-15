#!/usr/bin/env python3
"""Generate missing or stale test resources in a build-owned directory."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SCRIPTS = Path(__file__).resolve().parent
GROUPS = {
    "baseline": ("generate_baseline_fixture.py", ("ffmpeg",),
                 ("01-h264-aac-baseline.mp4", "01-h264-aac-baseline.en.srt", "01-h264-aac-baseline.es.srt")),
    "multitrack": ("generate_multitrack_fixture.py", ("ffmpeg", "ffprobe"),
                  ("02-h264-multitrack.mkv",)),
    "audio": ("generate_audio_fixtures.py", ("ffmpeg",),
              ("ac3-short.mka", "ac3-stream.mka", "eac3-short.mka", "eac3-stream.mka")),
    "subtitles": ("generate_subtitle_fixtures.py", ("ffmpeg",), ("subtitle-formats.mkv",)),
    "codecs": ("generate_codec_fixtures.py", ("ffmpeg",),
               ("codec-hevc-8bit.mkv", "codec-hevc-10bit.mkv", "codec-vp9.mkv", "codec-av1.mkv",
                "feature-120fps.mkv", "feature-hdr10.mkv", "feature-hlg.mkv")),
    "webp": ("generate_webp_fixture.py", ("cwebp", "img2webp"),
             ("webp-still.webp", "webp-animation.webp")),
    "interlaced": ("RenderingValidation/generate_interlaced.py", ("ffmpeg", "ffprobe"),
                   ("480i-bottom-59.94.mkv", "576i-top-50.mkv", "1080i-top-59.94.mkv")),
    "native-dovi": ("generate_dovi_fixture.py", ("dovi_tool",), ("profile5.rpu",)),
}
DEFAULT_GROUPS = tuple(group for group in GROUPS if group != "native-dovi")


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def write_json(path, value):
    data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    if path.exists() and path.read_bytes() == data:
        return
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(path)


def prepare(output, groups=DEFAULT_GROUPS):
    unknown = set(groups) - GROUPS.keys()
    if unknown:
        raise ValueError(f"Unknown test media groups: {', '.join(sorted(unknown))}")
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Xcode may omit Homebrew from PATH. Keep an explicitly configured tool first.
    environment = dict(os.environ)
    environment["PATH"] = os.pathsep.join([
        environment.get("PATH", os.defpath), "/opt/homebrew/bin", "/usr/local/bin",
    ])
    state_path = output.parent / (output.name + ".state.json")
    with (output.parent / (output.name + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            state = json.loads(state_path.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            state = {}
        if not isinstance(state, dict):
            state = {}
        for group in groups:
            script_name, tools, names = GROUPS[group]
            script = SCRIPTS / script_name
            recipe = hashlib.sha256(script.read_bytes() + Path(__file__).read_bytes()).hexdigest()
            cached = state.get(group, {})
            if not isinstance(cached, dict) or not isinstance(cached.get("files", {}), dict):
                cached = {}
            valid = cached.get("recipe") == recipe and all(
                (output / name).is_file()
                and (output / name).stat().st_size > 0
                and cached.get("files", {}).get(name) == digest(output / name)
                for name in names
            )
            if not valid:
                missing = [tool for tool in tools if shutil.which(tool, path=environment["PATH"]) is None]
                if missing:
                    raise RuntimeError(
                        f"Cannot generate {group} test media: install {', '.join(missing)} "
                        "on the build host and add it to PATH "
                        "(Homebrew: brew install ffmpeg webp; native Dolby Vision: brew install dovi_tool)."
                    )
                print(f"Generating {group} test media (missing, changed, or stale inputs).", flush=True)
                with tempfile.TemporaryDirectory(prefix=group + "-", dir=output.parent) as temporary:
                    subprocess.run(
                        [sys.executable, str(script), "--output", temporary],
                        check=True, env=environment,
                    )
                    generated = Path(temporary)
                    for name in names:
                        if not (generated / name).is_file() or not (generated / name).stat().st_size:
                            raise RuntimeError(f"Generator did not produce {name}")
                    checksums = {name: digest(generated / name) for name in names}
                    for name in names:
                        (generated / name).replace(output / name)
                cached = {"recipe": recipe, "files": checksums}
                state[group] = cached
                write_json(state_path, state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=SCRIPTS.parents[1] / ".build/test-media")
    parser.add_argument("--group", action="append", choices=GROUPS,
                        help="Generate only this group (repeatable); default: all Swift test media")
    args = parser.parse_args()
    try:
        prepare(args.output, args.group or DEFAULT_GROUPS)
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Test media preparation failed: {error}\n")


if __name__ == "__main__":
    main()
