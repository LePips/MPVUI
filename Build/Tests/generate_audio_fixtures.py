#!/usr/bin/env python3
"""Generate Dolby transport and PCM channel-layout fixtures (no Atmos encoding)."""
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
        tones = "|".join(f"0.05*sin(2*PI*{220 + index * 110}*t)" for index in range(6))
        subprocess.run([
            "ffmpeg", "-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            f"aevalsrc={tones}:s=48000:d=6:c=5.1",
            "-c:a", codec, "-b:a", "448k", "-map_metadata", "-1",
            str(output / f"{codec}-surround51.mka"),
        ], check=True)
    for label, layout, channels in (("mono", "mono", 1), ("stereo", "stereo", 2),
                                     ("surround51", "5.1", 6), ("surround71", "7.1", 8)):
        # Each channel has a distinct frequency for optional physical verification.
        tones = "|".join(f"0.05*sin(2*PI*{220 + index * 110}*t)" for index in range(channels))
        subprocess.run([
            "ffmpeg", "-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
            f"aevalsrc={tones}:s=48000:d=6:c={layout}",
            "-c:a", "pcm_s16le", "-map_metadata", "-1", str(output / f"pcm-{label}.mka"),
        ], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
