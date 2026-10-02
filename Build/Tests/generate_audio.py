#!/usr/bin/env python3
"""Generate Dolby and PCM codec-by-layout fixtures (no Atmos encoding).

Each channel has a distinct frequency for optional physical verification.
Dolby 5.1 samples are long enough to outlast native output buffering.
"""

import argparse
from pathlib import Path
import subprocess

LAYOUTS = {"mono": 1, "stereo": 2, "5.1": 6, "7.1": 8}


def encode(output, name, codec, layout, seconds, *options):
    tones = "|".join(f"0.05*sin(2*PI*{220 + index * 110}*t)" for index in range(LAYOUTS[layout]))
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
            f"aevalsrc={tones}:s=48000:d={seconds}:c={layout}",
            "-c:a",
            codec,
            *options,
            "-map_metadata",
            "-1",
            str(output / f"audio-{name}-{layout}.mka"),
        ],
        check=True,
    )


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    for codec in ("ac3", "eac3"):
        encode(output, codec, codec, "stereo", 6, "-b:a", "192k")
        encode(output, codec, codec, "5.1", 24, "-b:a", "448k")
    for layout in LAYOUTS:
        encode(output, "pcm", "pcm_s16le", layout, 6)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
