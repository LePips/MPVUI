#!/usr/bin/env python3
"""Copy the local playback library without re-encoding its HDR/Dolby Vision signal."""

import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "Example/MPVUIExample/Shared/Resources"
CLIPS = (
    "quality-01-sdr", "quality-02-hdr10", "quality-03-hlg",
    "quality-04-dv5", "quality-05-dv81", "quality-06-120fps",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("harness", type=Path, nargs="?", default=Path.home() / "Developer/video-test-harness")
    args = parser.parse_args()
    harness = args.harness.expanduser().resolve()
    names = [clip + suffix for clip in CLIPS for suffix in (".mp4", ".Styled.en.ass")]
    names.append("ATTRIBUTION.md")
    # Check the complete library before updating the destination.
    for name in names:
        if not (harness / "videos" / name).is_file():
            raise SystemExit(f"Missing harness media: {name}")
    destination = RESOURCES / "Media"
    destination.mkdir(parents=True, exist_ok=True)
    for name in names:
        shutil.copy2(harness / "videos" / name, destination / name)
    print(f"Imported {len(CLIPS)} clips, {len(CLIPS)} subtitle sidecars and attribution into {destination}")


if __name__ == "__main__":
    main()
