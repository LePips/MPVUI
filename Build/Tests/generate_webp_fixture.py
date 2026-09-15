#!/usr/bin/env python3
"""Generate small, synthetic WebP playback fixtures with libwebp's CLI tools.

Requires cwebp and img2webp. Regeneration may change bytes across encoder versions;
review the decoded frames and durations with MPVNativeVideoFormatTests.
"""
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / "Tests/Resources/Media"
MEDIA.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="webp-fixture-") as directory:
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
    subprocess.run(["cwebp", "-quiet", "-lossless", str(frames[0]), "-o",
                    str(MEDIA / "webp-still.webp")], check=True)
    command = ["img2webp", "-loop", "1", "-lossless"]
    for frame, duration in zip(frames, (250, 500, 750)):
        command += ["-d", str(duration), str(frame)]
    subprocess.run(command + ["-o", str(MEDIA / "webp-animation.webp")], check=True)

manifest = MEDIA.parent / "Fixtures.lock.json"
fixtures = json.loads(manifest.read_text())
for name in ("webp-still.webp", "webp-animation.webp"):
    fixtures[name] = hashlib.sha256((MEDIA / name).read_bytes()).hexdigest()
manifest.write_text(json.dumps(dict(sorted(fixtures.items())), indent=2) + "\n")
