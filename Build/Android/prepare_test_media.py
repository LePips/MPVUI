#!/usr/bin/env python3
"""Prepare shared fixtures and optional raw Dolby Vision for Android device tests."""

import importlib.util
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("shared_media", ROOT / "Build/Tests/prepare_test_media.py")
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
output = ROOT / ".build/test-media"
shared.prepare(output)
source = Path(os.environ.get("MPVUI_DOLBY_VISION_CHART", ROOT / "Example/Sources/MPVUIExample/Resources/Media/dolby-vision-p5-chart.mp4"))
if source.exists():
    # Keep the chart's RGB primaries but remove all container DV configuration.
    # RPU remains in the HEVC NAL units, as it does in untagged transport streams.
    target = output / "dolby-vision-inband.hevc"
    temporary = target.with_suffix(".tmp.hevc")
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-nostdin",
            "-y",
            "-ss",
            "25",
            "-i",
            str(source),
            "-map",
            "0:v:0",
            "-frames:v",
            "3",
            "-c:v",
            "copy",
            "-an",
            "-map_metadata",
            "-1",
            "-bsf:v",
            "hevc_mp4toannexb",
            "-f",
            "hevc",
            str(temporary),
        ],
        check=True,
    )
    temporary.replace(target)
else:
    (output / "dolby-vision-inband.hevc").unlink(missing_ok=True)
    print(
        "Optional Dolby Vision raw-stream test skipped: add dolby-vision-p5-chart.mp4 to the shared Media folder or set MPVUI_DOLBY_VISION_CHART."
    )
