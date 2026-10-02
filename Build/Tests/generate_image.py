#!/usr/bin/env python3
"""Generate small, synthetic still and animated WebP images with libwebp's CLI tools."""

import argparse
from pathlib import Path
import subprocess
import tempfile


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="image-fixture-") as directory:
        frames = []
        # Frame two changes only the right half, exercising animation composition.
        colors = [(255, 0, 0), (0, 0, 255), (0, 255, 0)]
        for index, color in enumerate(colors):
            pixels = bytearray()
            for y in range(24):
                for x in range(32):
                    pixels.extend((255, 0, 0) if index == 1 and x < 16 else color)
            frame = Path(directory) / f"frame-{index}.ppm"
            frame.write_bytes(b"P6\n32 24\n255\n" + pixels)
            frames.append(frame)
        subprocess.run(["cwebp", "-quiet", "-lossless", str(frames[0]), "-o", str(output / "image-webp-still.webp")], check=True)
        command = ["img2webp", "-loop", "1", "-lossless"]
        for frame, duration in zip(frames, (250, 500, 750)):
            command += ["-d", str(duration), str(frame)]
        subprocess.run(command + ["-o", str(output / "image-webp-animated.webp")], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
