#!/usr/bin/env python3
"""Generate neutral, deterministic SDR/PQ validation clips with FFmpeg.

This creates synthetic encoded color values, not measured reference-display
captures. No downloaded media or external font assets are required.
"""
import argparse
from array import array
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def run(arguments):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *arguments], check=True)


def pq(nits):
    m1, m2, c1, c2, c3 = 2610 / 16384, 2523 / 32, 3424 / 4096, 2413 / 128, 2392 / 128
    linear = (nits / 10000) ** m1
    return ((c1 + c2 * linear) / (1 + c3 * linear)) ** m2


def chart(path, hdr=False, width=1920, height=1080):
    # Values are encoded RGB in the explicitly tagged primaries/transfer below.
    # Generate at 16 bits first so the 10-bit output has real precision to keep.
    rows = []
    for band in range(4):
        row = array("H")
        for x in range(width):
            t = x / (width - 1)
            if hdr:
                luminance = ([0, 100, 203, 400, 1000][min(4, int(t * 5))]
                             if band == 0 else (1000 * t if band == 1 else 10 * t))
                v = pq(luminance)
                rgb = (v, v, v) if band < 3 else (pq(203) * t, pq(203) * (1 - t), 0)
            elif band == 0:
                rgb = (t, t, t)
            elif band == 1:
                rgb = (t, 0, 0)  # Display P3 red extends beyond BT.709.
            elif band == 2:
                rgb = (0, t, 0)  # Display P3 green extends beyond BT.709.
            else:
                rgb = (0.08 * t,) * 3
            row.extend(round(max(0, min(1, value)) * 65535) for value in rgb)
        if sys.byteorder == "little":
            row.byteswap()
        rows.append(row.tobytes())
    with path.open("wb") as output:
        output.write(f"P6\n{width} {height}\n65535\n".encode())
        for y in range(height):
            output.write(rows[min(3, y * 4 // height)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(".build/rendering-validation"))
    parser.add_argument("--duration", type=int, default=12)
    parser.add_argument("--only-charts", action="store_true")
    parser.add_argument("--only-benchmark", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.duration <= 600 or (args.only_charts and args.only_benchmark):
        parser.error("Use a duration of 1–600 seconds and at most one --only option.")
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rendering-chart-") as temporary:
        for hdr, name in [(False, "p3-sdr-10bit-gradient"), (True, "pq-hdr10-1000nit-chart")]:
            if args.only_benchmark:
                continue
            ppm = Path(temporary) / f"{name}.ppm"
            chart(ppm, hdr)
            matrix = "bt2020" if hdr else "bt709"
            x265 = "log-level=error:pools=2:repeat-headers=1"
            if hdr:
                x265 += ":master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50):max-cll=1000,400"
            run(["-loop", "1", "-framerate", "24", "-i", str(ppm), "-t", str(args.duration),
                 "-vf", f"scale=out_color_matrix={matrix}:out_range=tv,format=yuv420p10le",
                 "-c:v", "libx265", "-preset", "ultrafast", "-x265-params", x265,
                 "-crf", "10",
                 "-color_primaries", "bt2020" if hdr else "smpte432",
                 "-color_trc", "smpte2084" if hdr else "iec61966-2-1",
                 "-colorspace", "bt2020nc" if hdr else "bt709", "-color_range", "tv",
                 "-bsf:v", "hevc_metadata=colour_primaries=" + ("9:transfer_characteristics=16:matrix_coefficients=9" if hdr else "12:transfer_characteristics=13:matrix_coefficients=1"),
                 "-tag:v", "hvc1", "-map_metadata", "-1", "-metadata", f"title={name}",
                 str(args.output / f"{name}.mp4")])
    if not args.only_charts:
        run(["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=60000/1001",
         "-t", str(args.duration), "-c:v", "libx264", "-preset", "fast", "-crf", "18",
         "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709",
         "-colorspace", "bt709", "-color_range", "tv", "-map_metadata", "-1",
         "-bsf:v", "h264_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1",
         "-metadata", "title=Rendering cost 1080p motion",
         str(args.output / "render-cost-1080p60.mp4")])
    ass = """[Script Info]
Title: HDR overlay validation
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,62,&H00FFFFFF,&H000000FF,&H80000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,30,30,80,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:01:00.00,Default,,0,0,0,,Reference white | {\\c&H0000FF&}Red {\\c&H00FF00&}Green {\\c&HFF0000&}Blue{\\r} | {\\alpha&H80&}Half opacity
"""
    (args.output / "hdr-overlay-validation.ass").write_text(ass)
    metadata = []
    for name in ["p3-sdr-10bit-gradient.mp4", "pq-hdr10-1000nit-chart.mp4", "render-cost-1080p60.mp4"]:
        path = args.output / name
        if not path.exists():
            continue
        probe = subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(path)])
        stream = json.loads(probe)["streams"][0]
        if name.startswith("p3-"):
            assert stream["color_primaries"] == "smpte432" and stream["color_transfer"] == "iec61966-2-1"
        if name.startswith("pq-"):
            assert stream["color_primaries"] == "bt2020" and stream["color_transfer"] == "smpte2084"
        if name.startswith("render-") and not args.only_charts:
            assert stream["color_primaries"] == "bt709" and stream["color_transfer"] == "bt709"
        metadata.append({"filename": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                         "probe": json.loads(probe)})
    (args.output / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Generated media and verified tags: {args.output.resolve()}")


if __name__ == "__main__":
    main()
