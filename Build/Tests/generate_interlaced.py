#!/usr/bin/env python3
"""Generate short field-coded MPEG-2 samples for each common interlaced format."""

import argparse
from pathlib import Path
import subprocess


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    for name, size, rate, order, color in [
        ("interlaced-480i-bottom", "720x480", "60000/1001", "bottom", "smpte170m"),
        ("interlaced-576i-top", "720x576", "50", "top", "bt470bg"),
        ("interlaced-1080i-top", "1920x1080", "60000/1001", "top", "bt709"),
    ]:
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-nostdin",
                "-y",
                "-f",
                "lavfi",
                "-i",
                f"testsrc2=size={size}:rate={rate}",
                "-t",
                "2",
                "-vf",
                f"tinterlace=mode=interleave_{order}",
                "-c:v",
                "mpeg2video",
                "-flags",
                "+ilme+ildct",
                "-q:v",
                "6",
                "-pix_fmt",
                "yuv420p",
                "-color_range",
                "tv",
                "-colorspace",
                color,
                "-color_primaries",
                color,
                "-color_trc",
                "bt709",
                "-an",
                "-map_metadata",
                "-1",
                str(output / f"{name}.mkv"),
            ],
            check=True,
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
