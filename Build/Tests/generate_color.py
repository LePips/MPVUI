#!/usr/bin/env python3
"""Generate 10-bit HEVC samples with HDR transfer functions and static metadata.

These test decoding and signaling, not calibrated display appearance. They
are long enough for HDR surface changes during continuous playback.
"""

import argparse
from pathlib import Path
import subprocess

X265 = "log-level=error:pools=2:frame-threads=1:colorprim=bt2020:colormatrix=bt2020nc"


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    for name, transfer, code, x265 in [
        (
            "color-hdr10",
            "smpte2084",
            16,
            ":hdr10=1:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,50):max-cll=1000,400",
        ),
        ("color-hlg", "arib-std-b67", 18, ""),
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
                "testsrc2=size=320x180:rate=24:duration=10",
                "-an",
                "-c:v",
                "libx265",
                "-pix_fmt",
                "yuv420p10le",
                "-preset",
                "ultrafast",
                "-x265-params",
                f"{X265}:transfer={transfer}{x265}",
                "-color_primaries",
                "bt2020",
                "-color_trc",
                transfer,
                "-colorspace",
                "bt2020nc",
                "-color_range",
                "tv",
                # Pin VUI tags in the encoded SPS as well as the container. Some x265
                # builds omit color-description fields for filter-generated input.
                "-bsf:v",
                f"hevc_metadata=colour_primaries=9:transfer_characteristics={code}:matrix_coefficients=9",
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
