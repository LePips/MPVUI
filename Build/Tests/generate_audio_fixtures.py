#!/usr/bin/env python3
"""Generate stereo AC-3/E-AC-3 for seek, passthrough, bounded-stream and EOF tests."""
import argparse
from pathlib import Path
import subprocess


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    for codec in ("ac3", "eac3"):
        for kind, seconds in (("short", 6), ("stream", 24)):
            subprocess.run([
                "ffmpeg", "-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
                f"sine=frequency=440:sample_rate=48000:duration={seconds}",
                "-ac", "2", "-c:a", codec, "-b:a", "192k", "-map_metadata", "-1",
                str(output / f"{codec}-{kind}.mka"),
            ], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
