#!/usr/bin/env python3
"""Create neutral six-second field-motion fixtures for the opt-in Swift tests."""
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[3]
output = root / ".build" / "interlaced-validation"
output.mkdir(parents=True, exist_ok=True)
cases = [
    ("480i-bottom-59.94", "720x480", "60000/1001", "bff", "smpte170m"),
    ("576i-top-50", "720x576", "50", "tff", "bt470bg"),
    ("1080i-top-59.94", "1920x1080", "60000/1001", "tff", "bt709"),
]
manifest = []
for name, size, rate, order, color in cases:
    path = output / f"{name}.mkv"
    subprocess.run([
        "ffmpeg", "-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
        f"testsrc2=size={size}:rate={rate}", "-t", "6", "-vf",
        f"tinterlace=mode=interleave_{'bottom' if order == 'bff' else 'top'}",
        "-c:v", "mpeg2video", "-flags", "+ilme+ildct",
        "-q:v", "3", "-pix_fmt", "yuv420p", "-color_range", "tv",
        "-colorspace", color, "-color_primaries", color, "-color_trc", "bt709",
        "-an", "-map_metadata", "-1", str(path),
    ], check=True)
    info = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=codec_name,width,height,field_order,r_frame_rate,color_space", "-of", "json", str(path),
    ]))
    manifest.append({"file": path.name, "expectedFieldRate": rate, "probe": info})
(output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(output)
