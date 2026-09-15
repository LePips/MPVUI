#!/usr/bin/env python3
"""Generate ASS and real PGS/DVD/DVB bitmap tracks without source media or fonts."""
import argparse
from pathlib import Path
import struct
import subprocess
import tempfile


def segment(kind, payload, seconds):
    return b"PG" + struct.pack(">IIBH", seconds * 90000, 0, kind, len(payload)) + payload


def bitmap_subtitle():
    # A 160x32 white rectangle at (100, 560) on a 360x640 canvas.
    # PGS display sets: composition, window, palette, RLE object, end;
    # a second empty composition clears it at four seconds.
    window = struct.pack(">BBHHHH", 1, 0, 100, 560, 160, 32)
    rle = (b"\x00\xc0\xa0\x01\x00\x00") * 32
    composition = struct.pack(">HHBHBBBB", 360, 640, 0x20, 0, 0x80, 0, 0, 1)
    composition += struct.pack(">HBBHH", 0, 0, 0, 100, 560)
    obj = struct.pack(">HBB", 0, 0, 0xc0) + (len(rle) + 4).to_bytes(3, "big")
    obj += struct.pack(">HH", 160, 32) + rle
    data = b"".join(segment(kind, payload, 0) for kind, payload in [
        (0x16, composition), (0x17, window),
        (0x14, bytes([0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255])),
        (0x15, obj), (0x80, b""),
    ])
    clear = struct.pack(">HHBHBBBB", 360, 640, 0x20, 1, 0, 0, 0, 0)
    return data + segment(0x16, clear, 4) + segment(0x80, b"", 4)


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="subtitle-fixture-") as directory:
        work = Path(directory)
        (work / "bitmap.sup").write_bytes(bitmap_subtitle())
        (work / "styled.ass").write_text("""[Script Info]
ScriptType: v4.00+
PlayResX: 360
PlayResY: 640
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,28,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,40,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,Styled subtitle sample
""", encoding="utf-8")
        subprocess.run([
            "ffmpeg", "-v", "error", "-nostdin", "-y",
            "-f", "lavfi", "-i", "color=c=0x203040:size=360x640:rate=15:duration=12",
            "-i", str(work / "styled.ass"), "-fix_sub_duration", "-i", str(work / "bitmap.sup"),
            "-map", "0:v", "-map", "1:s", "-map", "2:s", "-map", "2:s", "-map", "2:s",
            "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p", "-g", "15",
            "-c:s:0", "copy", "-c:s:1", "copy", "-c:s:2", "dvdsub", "-c:s:3", "dvbsub",
            "-disposition:s:0", "default", "-map_metadata", "-1",
            str(output / "subtitle-formats.mkv"),
        ], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
