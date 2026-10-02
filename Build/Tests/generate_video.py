#!/usr/bin/env python3
"""Generate compact SDR samples for each decoder, bit depth and frame-rate class.

Baseline covers 8-bit H.264 at a typical rate. 10-bit HEVC is covered by the
color group's HDR samples.
"""

import argparse
from pathlib import Path
import subprocess


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    for name, codec, pixel_format, rate, options in [
        ("video-hevc-8bit", "libx265", "yuv420p", 24, ["-preset", "ultrafast", "-x265-params", "log-level=error:pools=2:frame-threads=1"]),
        ("video-vp9", "libvpx-vp9", "yuv420p", 24, ["-deadline", "realtime", "-cpu-used", "8"]),
        ("video-av1-10bit", "libsvtav1", "yuv420p10le", 24, ["-preset", "12", "-svtav1-params", "lp=2"]),
        ("video-h264-120fps", "libx264", "yuv420p", 120, ["-preset", "ultrafast"]),
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
                f"testsrc2=size=320x180:rate={rate}:duration=2",
                "-an",
                "-c:v",
                codec,
                "-pix_fmt",
                pixel_format,
                *options,
                "-threads",
                "2",
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
