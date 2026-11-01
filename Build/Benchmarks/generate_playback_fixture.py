"""Prepare repeatable progressive and interlaced host playback workloads."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def prepare(output, kind="hevc4k"):
    output.parent.mkdir(parents=True, exist_ok=True)
    version = subprocess.check_output(["ffmpeg", "-version"], text=True).splitlines()[0]
    identity = hashlib.sha256(Path(__file__).read_bytes() + version.encode() + kind.encode()).hexdigest()
    stamp = output.with_suffix(".json")
    if stamp.exists() and output.exists():
        recorded = json.loads(stamp.read_text())
        if recorded.get("recipe") == identity and recorded.get("sha256") == hashlib.sha256(output.read_bytes()).hexdigest():
            return
    temporary = output.with_name(output.stem + ".tmp.mkv")
    if kind == "hevc4k":
        encoding = [
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=3840x2160:rate=60:duration=12",
            "-an",
            "-c:v",
            "libx265",
            "-preset",
            "ultrafast",
            "-crf",
            "28",
            "-pix_fmt",
            "yuv420p10le",
            "-threads",
            "4",
            "-x265-params",
            "log-level=error:pools=4:frame-threads=2:keyint=120:min-keyint=120:scenecut=0",
        ]
    elif kind == "interlaced1080":
        encoding = [
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=1920x1080:rate=60000/1001:duration=12",
            "-an",
            "-vf",
            "tinterlace=mode=interleave_top",
            "-c:v",
            "mpeg2video",
            "-flags",
            "+ilme+ildct",
            "-b:v",
            "15M",
            "-maxrate",
            "20M",
            "-bufsize",
            "40M",
            "-g",
            "15",
            "-pix_fmt",
            "yuv420p",
            "-threads",
            "4",
        ]
    else:
        raise ValueError(f"Unknown fixture kind: {kind}")
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-nostdin",
            "-y",
            *encoding,
            "-color_primaries",
            "bt709",
            "-color_trc",
            "bt709",
            "-colorspace",
            "bt709",
            "-map_metadata",
            "-1",
            str(temporary),
        ],
        check=True,
    )
    temporary.replace(output)
    stamp.write_text(json.dumps({"recipe": identity, "sha256": hashlib.sha256(output.read_bytes()).hexdigest()}, sort_keys=True) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--kind", choices=("hevc4k", "interlaced1080"), default="hevc4k")
    args = parser.parse_args()
    prepare(args.output, args.kind)
