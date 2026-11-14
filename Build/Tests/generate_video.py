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
    for filename, codec, pixel_format, rate, options in [
        ("video-mp42.asf", "msmpeg4v2", "yuv420p", 25, ["-tag:v", "MP42"]),
        (
            "video-hevc-8bit.mkv",
            "libx265",
            "yuv420p",
            24,
            ["-preset", "ultrafast", "-x265-params", "log-level=error:pools=2:frame-threads=1"],
        ),
        ("video-vp9.mkv", "libvpx-vp9", "yuv420p", 24, ["-deadline", "realtime", "-cpu-used", "8"]),
        ("video-vp9-ac3.mkv", "libvpx-vp9", "yuv420p", 24, ["-deadline", "realtime", "-cpu-used", "8"]),
        ("video-vp9-opus.mkv", "libvpx-vp9", "yuv420p", 24, ["-deadline", "realtime", "-cpu-used", "8"]),
        ("video-av1-10bit.mkv", "libsvtav1", "yuv420p10le", 24, ["-preset", "12", "-svtav1-params", "lp=2"]),
        ("video-h264-120fps.mkv", "libx264", "yuv420p", 120, ["-preset", "ultrafast"]),
        ("video-h264-long-gop.mkv", "libx264", "yuv420p", 24, ["-preset", "fast", "-g", "240", "-keyint_min", "240", "-sc_threshold", "0"]),
    ]:
        duration = 12 if filename == "video-h264-long-gop.mkv" else 2
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
                    if filename == "video-vp9-ac3.mkv"
                    else ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2", "-c:a", "libopus"]
                    if filename == "video-vp9-opus.mkv"
                    else ["-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={duration}", "-c:a", "aac"]
                    if filename == "video-h264-long-gop.mkv"
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
                str(output / filename),
            ],
            check=True,
        )

    # The same long-GOP payload in indexed and transport containers isolates
    # demuxer seek behavior from codec and timestamp differences.
    for extension in ("mp4", "ts"):
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-nostdin",
                "-y",
                "-i",
                str(output / "video-h264-long-gop.mkv"),
                "-c",
                "copy",
                "-map_metadata",
                "-1",
                str(output / f"video-h264-long-gop.{extension}"),
            ],
            check=True,
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
