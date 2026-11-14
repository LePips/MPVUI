#!/usr/bin/env python3
"""Generate ASS and real PGS/DVD/DVB bitmap tracks without source media or fonts."""

import argparse
from fractions import Fraction
import json
from pathlib import Path
import struct
import subprocess
import tempfile

from generate_broadcast_formats import wtv_dvb


def segment(kind, payload, seconds):
    return b"PG" + struct.pack(">IIBH", seconds * 90000, 0, kind, len(payload)) + payload


def bitmap_subtitle(colors=False, clear_time=4):
    # A 160x32 white rectangle at (100, 560) on a 360x640 canvas.
    # PGS display sets: composition, window, palette, RLE object, end;
    # a second empty composition clears it at four seconds.
    window = struct.pack(">BBHHHH", 1, 0, 100, 560, 160, 32)
    rle = (b"\x00\xc0\xa0\x01\x00\x00") * 32
    palette = bytes([0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255])
    if colors:
        # White, red, blue strips expose both missing BGRA textures and swapped channels.
        rle = (b"\x00\xc0\x40\x01\x00\xb0\x02\x00\xb0\x03\x00\x00") * 32
        palette += bytes([2, 63, 240, 102, 255, 3, 32, 118, 240, 255])
    composition = struct.pack(">HHBHBBBB", 360, 640, 0x20, 0, 0x80, 0, 0, 1)
    composition += struct.pack(">HBBHH", 0, 0, 0, 100, 560)
    obj = struct.pack(">HBB", 0, 0, 0xC0) + (len(rle) + 4).to_bytes(3, "big")
    obj += struct.pack(">HH", 160, 32) + rle
    data = b"".join(
        segment(kind, payload, 0)
        for kind, payload in [
            (0x16, composition),
            (0x17, window),
            (0x14, palette),
            (0x15, obj),
            (0x80, b""),
        ]
    )
    clear = struct.pack(">HHBHBBBB", 360, 640, 0x20, 1, 0, 0, 0, 0)
    return data + segment(0x16, clear, clear_time) + segment(0x80, b"", clear_time)


def overlapping_bitmap_subtitle():
    window = struct.pack(">BBHHHH", 1, 0, 100, 520, 180, 40)
    composition = struct.pack(">HHBHBBBB", 360, 640, 0x20, 0, 0x80, 0, 0, 2)
    composition += struct.pack(">HBBHHHBBHH", 1, 0, 0, 160, 520, 0, 0, 0, 100, 520)
    palette = bytes([0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255, 2, 63, 240, 102, 255, 3, 63, 240, 102, 128])

    def bitmap_object(identifier, row):
        rle = row * 40
        header = struct.pack(">HBB", identifier, 0, 0xC0) + (len(rle) + 4).to_bytes(3, "big")
        return header + struct.pack(">HH", 120, 40) + rle

    # The white object overlaps red, with a transparent hole revealing the
    # red beneath. A half-alpha red strip lies directly over the video.
    white = bitmap_object(0, b"\x00\xc0\x5f\x01\x00\x19\x00\x00")
    red = bitmap_object(1, b"\x00\xbc\x02\x00\x94\x03\x00\xa8\x02\x00\x00")
    clear = struct.pack(">HHBHBBBB", 360, 640, 0x20, 1, 0, 0, 0, 0)
    return b"".join(
        segment(kind, payload, time)
        for kind, payload, time in (
            (0x16, composition, 0),
            (0x17, window, 0),
            (0x14, palette, 0),
            (0x15, white, 0),
            (0x15, red, 0),
            (0x80, b"", 0),
            (0x16, clear, 3),
            (0x80, b"", 3),
        )
    )


def generate_positioned_subtitles(output, work):
    ass = work / "positioned.ass"
    header = (work / "styled.ass").read_text(encoding="utf-8").split("Dialogue:", 1)[0]
    ass.write_text(
        header
        + r"Dialogue: 0,0:00:00.50,0:00:02.50,Default,,0,0,0,,{\an7\pos(25,60)\b1\fs34\1c&H00FF00&}Upper cue"
        + "\n"
        + r"Dialogue: 1,0:00:01.50,0:00:03.50,Default,,0,0,0,,{\an3\pos(335,560)\b1\fs34\1c&H00FFFF&}Lower cue"
        + "\n",
        encoding="utf-8",
    )
    bitmap = work / "overlap.sup"
    bitmap.write_bytes(overlapping_bitmap_subtitle())
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-nostdin",
            "-y",
            "-i",
            output / "subtitles.mkv",
            "-i",
            ass,
            "-i",
            bitmap,
            "-map",
            "0:v:0",
            "-map",
            "1:s:0",
            "-map",
            "2:s:0",
            "-c",
            "copy",
            "-t",
            "5",
            output / "subtitles-positioned.mkv",
        ],
        check=True,
    )


def raw_dvb_sidecar(container):
    display = subprocess.run(
        ["ffmpeg", "-v", "error", "-nostdin", "-i", str(container), "-map", "0:s:3", "-frames:s", "1", "-c", "copy", "-f", "data", "-"],
        check=True,
        capture_output=True,
    ).stdout
    segments = []
    offset = 0
    while offset < len(display):
        sync, kind, page, length = struct.unpack_from(">BBHH", display, offset)
        payload = display[offset + 6 : offset + 6 + length]
        if sync != 0x0F or len(payload) != length:
            raise ValueError("Invalid authored DVB display set")
        if kind == 0x12:
            # The monochrome object uses only palette entries 0 and 1. Keep the
            # complete display set in one raw demuxer packet.
            payload = payload[:14]
        segments.append(struct.pack(">BBHH", sync, kind, page, len(payload)) + payload)
        offset += 6 + length
    return b"".join(segments) + bytes([0xFF])


def generate_additional_containers(output):
    source = output / "subtitles.mkv"
    text_input = ("-i", output / "subtitles-cues.mpl2")
    for name, inputs, track, codec in (
        ("subtitles-ascii.mkv", text_input, "1:s:0", "srt"),
        ("subtitles-text.nut", text_input, "1:s:0", "text"),
        ("subtitles-ass.nut", (), "0:s:0", "copy"),
        ("subtitles-dvd.nut", (), "0:s:2", "copy"),
        ("subtitles-dvb.nut", (), "0:s:3", "copy"),
    ):
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-nostdin",
                "-y",
                "-i",
                source,
                *inputs,
                "-map",
                "0:v:0",
                "-map",
                track,
                "-c:v",
                "copy",
                "-c:s",
                codec,
                "-strict",
                "experimental",
                output / name,
            ],
            check=True,
        )
    # FFmpeg writes the UTF8 codec tag for both text and SubRip. The ASCII
    # variant uses the same plain packets and selects the raw text decoder.
    subprocess.run(
        ["mkvpropedit", output / "subtitles-ascii.mkv", "--edit", "track:s1", "--set", "codec-id=S_TEXT/ASCII"],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def generate_wtv_subtitles(output, work):
    source = output / "subtitles-dvb.nut"
    packet_table = json.loads(
        subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "s:0",
                "-show_entries",
                "packet=pts_time,pos,size",
                "-of",
                "json",
                source,
            ]
        )
    )["packets"]
    data = source.read_bytes()
    cues = []
    for row in packet_table:
        start = int(row["pos"])
        packet = data[start : start + int(row["size"])]
        assert packet.startswith(b"\x0f")
        cues.append((round(Fraction(row["pts_time"]) * 10_000_000), packet))
    assert len(cues) == 2

    carrier = work / "bitmap-carrier.wtv"
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
            "color=black:size=320x180:rate=25:duration=5",
            "-f",
            "lavfi",
            "-i",
            "anullsrc=r=48000:cl=mono:d=5",
            "-c:v",
            "mpeg2video",
            "-g",
            "1",
            "-c:a",
            "ac3",
            "-b:a",
            "640k",
            carrier,
        ],
        check=True,
    )
    (output / "subtitles-dvb.wtv").write_bytes(wtv_dvb(carrier.read_bytes(), cues))


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    (output / "subtitles-cues.mpl2").write_text("[10][20]First cue\n[25][35]Second cue\n[40][50]Third cue\n", encoding="utf-8")
    (output / "subtitles-external.sup").write_bytes(bitmap_subtitle())
    with tempfile.TemporaryDirectory(prefix="subtitle-fixture-") as directory:
        work = Path(directory)
        (work / "bitmap.sup").write_bytes(bitmap_subtitle())
        (work / "colors.sup").write_bytes(bitmap_subtitle(colors=True))
        (work / "styled.ass").write_text(
            """[Script Info]
ScriptType: v4.00+
PlayResX: 360
PlayResY: 640
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,28,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,40,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,Styled subtitle sample
""",
            encoding="utf-8",
        )
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
                "color=c=0x203040:size=360x640:rate=15:duration=12",
                "-i",
                str(work / "styled.ass"),
                "-fix_sub_duration",
                "-i",
                str(work / "bitmap.sup"),
                "-i",
                str(work / "colors.sup"),
                "-map",
                "0:v",
                "-map",
                "1:s",
                "-map",
                "2:s",
                "-map",
                "2:s",
                "-map",
                "2:s",
                "-map",
                "3:s",
                "-c:v",
                "libx264",
                "-preset",
                "fast",
                "-pix_fmt",
                "yuv420p",
                "-g",
                "15",
                "-c:s:0",
                "copy",
                "-c:s:1",
                "copy",
                "-c:s:2",
                "dvdsub",
                "-c:s:3",
                "dvbsub",
                "-c:s:4",
                "copy",
                "-disposition:s:0",
                "default",
                "-map_metadata",
                "-1",
                "-metadata:s:s:4",
                "title=Color channel order",
                str(output / "subtitles.mkv"),
            ],
            check=True,
        )
        generate_positioned_subtitles(output, work)
        generate_additional_containers(output)
        generate_wtv_subtitles(output, work)
        (output / "subtitles-external.dvb").write_bytes(raw_dvb_sidecar(output / "subtitles.mkv"))
        for filename, track, options in (
            ("subtitles-dvb.ts", 3, ()),
            ("subtitles-pgs.m2ts", 1, ("-mpegts_m2ts_mode", "1")),
        ):
            subprocess.run(
                [
                    "ffmpeg",
                    "-v",
                    "error",
                    "-nostdin",
                    "-y",
                    "-i",
                    output / "subtitles.mkv",
                    "-map",
                    "0:v:0",
                    "-map",
                    f"0:s:{track}",
                    "-c",
                    "copy",
                    *options,
                    "-f",
                    "mpegts",
                    output / filename,
                ],
                check=True,
            )
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-nostdin",
                "-y",
                "-i",
                str(output / "subtitles.mkv"),
                "-map",
                "0:s:2",
                "-c:s",
                "copy",
                "-f",
                "vob",
                str(output / "subtitles-vobsub.sub"),
            ],
            check=True,
        )
        palette = ", ".join(["000000"] + ["ffffff"] * 15)
        (output / "subtitles-vobsub.idx").write_text(
            "# VobSub index file, v7 (do not modify this line!)\n"
            f"size: 360x640\npalette: {palette}\n"
            "langidx: 0\nid: en, index: 0\ntimestamp: 00:00:00:500, filepos: 000000000\n",
            encoding="ascii",
        )
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-nostdin",
                "-y",
                "-i",
                str(output / "subtitles.mkv"),
                "-map",
                "0:v:0",
                "-map",
                "0:s:2",
                "-c",
                "copy",
                str(output / "subtitles-dvd.mp4"),
            ],
            check=True,
        )
        # Reuse the timed, four-color DVD bitmap for the XSUB encode in AVI.
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-nostdin",
                "-y",
                "-i",
                str(output / "subtitles.mkv"),
                "-map",
                "0:v",
                "-map",
                "0:s:2",
                "-c:v",
                "mpeg4",
                "-threads",
                "1",
                "-c:s",
                "xsub",
                "-t",
                "6",
                str(output / "subtitles-xsub.avi"),
            ],
            check=True,
        )
        # Matroska ContentCompression is distinct from the subtitle codec.
        # Use the muxer that commonly enables PGS zlib compression in real files.
        source = work / "compression-source.mkv"
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-nostdin",
                "-y",
                "-i",
                str(output / "subtitles.mkv"),
                "-map",
                "0:v",
                "-map",
                "0:s:0",
                "-map",
                "0:s:1",
                "-c",
                "copy",
                str(source),
            ],
            check=True,
        )
        for compression in ("none", "zlib"):
            subprocess.run(
                [
                    "mkvmerge",
                    "--quiet",
                    "--output",
                    str(output / f"subtitles-{compression}.mkv"),
                    *[value for track in (1, 2) for value in ("--compression", f"{track}:{compression}")],
                    str(source),
                ],
                check=True,
            )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
