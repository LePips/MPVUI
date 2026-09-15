#!/usr/bin/env python3
"""Generate compact codec, bit-depth, HDR-signaling and high-frame-rate samples.

HDR fixtures test decoding/signaling, not calibrated display appearance.
"""
import argparse
from pathlib import Path
import subprocess


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    hevc = ["-preset", "ultrafast", "-x265-params", "log-level=error:pools=2:frame-threads=1"]
    for name, codec, pixel_format, rate, options in [
        ("codec-hevc-8bit", "libx265", "yuv420p", 24, hevc),
        ("codec-hevc-10bit", "libx265", "yuv420p10le", 24, hevc),
        ("codec-vp9", "libvpx-vp9", "yuv420p", 24, ["-deadline", "realtime", "-cpu-used", "8"]),
        ("codec-av1", "libsvtav1", "yuv420p10le", 24,
         ["-preset", "12", "-svtav1-params", "lp=2"]),
        ("feature-120fps", "libx264", "yuv420p", 120, ["-preset", "ultrafast"]),
        ("feature-hdr10", "libx265", "yuv420p10le", 24, [
            "-preset", "ultrafast", "-x265-params",
            "log-level=error:pools=2:frame-threads=1:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:"
            "master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,50):"
            "max-cll=1000,400", "-color_primaries", "bt2020", "-color_trc", "smpte2084",
            "-colorspace", "bt2020nc", "-color_range", "tv",
        ]),
        ("feature-hlg", "libx265", "yuv420p10le", 24, [
            "-preset", "ultrafast", "-x265-params",
            "log-level=error:pools=2:frame-threads=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc",
            "-color_primaries", "bt2020", "-color_trc", "arib-std-b67",
            "-colorspace", "bt2020nc", "-color_range", "tv",
        ]),
    ]:
        # Pin VUI tags in the encoded SPS as well as the container. Some x265
        # builds omit color-description fields for filter-generated input.
        if name in ("feature-hdr10", "feature-hlg"):
            transfer = 16 if name == "feature-hdr10" else 18
            options += ["-bsf:v", f"hevc_metadata=colour_primaries=9:transfer_characteristics={transfer}:matrix_coefficients=9"]
        subprocess.run([
            "ffmpeg", "-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            f"testsrc2=size=320x180:rate={rate}:duration=2", "-an",
            "-c:v", codec, "-pix_fmt", pixel_format, *options, "-threads", "2",
            "-map_metadata", "-1", str(output / f"{name}.mkv"),
        ], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
