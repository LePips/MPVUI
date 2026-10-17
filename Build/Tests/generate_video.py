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
        ("video-vp9-ac3", "libvpx-vp9", "yuv420p", 24, ["-deadline", "realtime", "-cpu-used", "8"]),
        ("video-av1-10bit", "libsvtav1", "yuv420p10le", 24, ["-preset", "12", "-svtav1-params", "lp=2"]),
        ("video-h264-120fps", "libx264", "yuv420p", 120, ["-preset", "ultrafast"]),
        ("video-h264-long-gop", "libx264", "yuv420p", 24, ["-preset", "fast", "-g", "240", "-keyint_min", "240", "-sc_threshold", "0"]),
    ]:
        duration = 12 if name == "video-h264-long-gop" else 2
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
                f"testsrc2=size=320x180:rate={rate}:duration={duration}",
                *(
                    ["-f", "lavfi", "-i", "aevalsrc=0.05*sin(2*PI*440*t):s=48000:d=2:c=5.1", "-c:a", "ac3", "-b:a", "448k"]
                    if name == "video-vp9-ac3"
                    else ["-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={duration}", "-c:a", "aac"]
                    if name == "video-h264-long-gop"
                    else ["-an"]
                ),
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
