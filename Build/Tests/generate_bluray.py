#!/usr/bin/env python3
"""Author a clear Blu-ray volume with two distinct play items and chapter marks."""

import argparse
import json
from pathlib import Path
from struct import pack
from subprocess import run
from tempfile import TemporaryDirectory

from generate_subtitles import bitmap_subtitle


DISC = "bluray/BDMV"
VIDEO_PID = 0x1011
AUDIO_PID = 0x1100
SECOND_AUDIO_PID = 0x1101
PGS_PID = 0x1200
CLIP_SECONDS = 2
CLIP_TICKS = 45_000 * CLIP_SECONDS
PACKET_BYTES = 192


def output_names():
    return (
        f"{DISC}/index.bdmv",
        f"{DISC}/MovieObject.bdmv",
        f"{DISC}/PLAYLIST/00000.mpls",
        *(f"{DISC}/CLIPINF/{clip:05d}.clpi" for clip in (1, 2)),
        *(f"{DISC}/STREAM/{clip:05d}.m2ts" for clip in (1, 2)),
    )


def section(data, size="I"):
    return pack(">" + size, len(data)) + data


def clip_info(stream):
    keyframes = json.loads(
        run(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-skip_frame",
                "nokey",
                "-show_entries",
                "frame=pts,pkt_pos",
                "-of",
                "json",
                str(stream),
            ],
            check=True,
            capture_output=True,
        ).stdout
    )["frames"]
    # One coarse entry spans this short clip. The first fine entry starts at the
    # PAT/PMT so a seek to a chapter can initialize the transport reader.
    fine = [(0, 0)] + [(int(key["pts"]) // 512, int(key["pkt_pos"]) // PACKET_BYTES) for key in keyframes[1:]]
    stream_type_and_counts = (1 << 34) | (1 << 18) | len(fine)
    stream_map = pack(">H", VIDEO_PID) + stream_type_and_counts.to_bytes(6, "big") + pack(">I", 14)
    entry_map = pack(">III", 12, 0, 0) + b"".join(pack(">I", pts << 17 | packet) for pts, packet in fine)
    cpi = section(bytes([0, 1, 0, 1]) + stream_map + entry_map)

    size = stream.stat().st_size
    clip = section(pack(">HBBIII", 0, 1, 1, 0, size // CLIP_SECONDS, size // PACKET_BYTES) + bytes(130))
    sequence = section(pack(">BBIBBHI2I", 0, 1, 0, 1, 0, VIDEO_PID, 0, 0, CLIP_TICKS))
    # 720p/24 AVC, two stereo/48 kHz LPCM streams and presentation graphics.
    video = pack(">H", VIDEO_PID) + section(bytes([0x1B, 0x51, 0x30, 0, 0]), "B")
    audio = pack(">H", AUDIO_PID) + section(bytes([0x80, 0x31]) + b"eng", "B")
    alternate = pack(">H", SECOND_AUDIO_PID) + section(bytes([0x80, 0x31]) + b"spa", "B")
    graphics = pack(">H", PGS_PID) + section(bytes([0x90]) + b"eng", "B")
    program = section(pack(">BBIHBB", 0, 1, 0, 0x100, 4, 0) + video + audio + alternate + graphics)
    sequence_offset = 40 + len(clip)
    program_offset = sequence_offset + len(sequence)
    cpi_offset = program_offset + len(program)
    return (
        b"HDMV0200"
        + pack(">5I", sequence_offset, program_offset, cpi_offset, cpi_offset + len(cpi), 0)
        + bytes(12)
        + clip
        + sequence
        + program
        + cpi
        + bytes(4)
    )


def playlist():
    video = section(pack(">BH", 1, VIDEO_PID), "B") + section(bytes([0x1B, 0x51]), "B")
    audio = section(pack(">BH", 1, AUDIO_PID), "B") + section(bytes([0x80, 0x31]) + b"eng", "B")
    alternate = section(pack(">BH", 1, SECOND_AUDIO_PID), "B") + section(bytes([0x80, 0x31]) + b"spa", "B")
    graphics = section(pack(">BH", 1, PGS_PID), "B") + section(bytes([0x90]) + b"eng", "B")
    streams = section(bytes([0, 0, 1, 2, 1]) + bytes(9) + video + audio + alternate + graphics, "H")
    items = [section(f"{item:05d}M2TS".encode() + pack(">HBII", 1, 0, 0, CLIP_TICKS) + bytes(12) + streams, "H") for item in (1, 2)]
    play_items = section(pack(">HHH", 0, len(items), 0) + b"".join(items))
    marks = section(pack(">H", len(items)) + b"".join(pack(">BBHIHI", 0, 1, index, 0, 0xFFFF, 0) for index in range(len(items))))
    app = section(bytes([0, 1]) + bytes(12))
    start = 40 + len(app)
    return b"MPLS0200" + pack(">3I", start, start + len(play_items), 0) + bytes(20) + app + play_items + marks


def generate(output):
    disc = output / DISC
    for directory in ("CLIPINF", "PLAYLIST", "STREAM"):
        (disc / directory).mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory() as temporary:
        subtitle = Path(temporary) / "chapter.sup"
        subtitle.write_bytes(bitmap_subtitle(clear_time=1))
        for index, (color, tone, alternate) in enumerate((("red", 440, 660), ("blue", 880, 1100)), 1):
            stem = f"{index:05d}"
            stream = disc / "STREAM" / f"{stem}.m2ts"
            run(
                [
                    "ffmpeg",
                    "-v",
                    "error",
                    "-nostdin",
                    "-y",
                    "-f",
                    "lavfi",
                    "-i",
                    f"color={color}:size=1280x720:rate=24:d={CLIP_SECONDS}",
                    "-f",
                    "lavfi",
                    "-i",
                    f"sine=frequency={tone}:sample_rate=48000:duration={CLIP_SECONDS}",
                    "-f",
                    "lavfi",
                    "-i",
                    f"sine=frequency={alternate}:sample_rate=48000:duration={CLIP_SECONDS}",
                    "-i",
                    str(subtitle),
                    "-map",
                    "0:v",
                    "-map",
                    "1:a",
                    "-map",
                    "2:a",
                    "-map",
                    "3:s",
                    "-c:v",
                    "libx264",
                    "-preset",
                    "fast",
                    "-tune",
                    "zerolatency",
                    "-g",
                    "24",
                    "-bf",
                    "0",
                    "-profile:v",
                    "high",
                    "-pix_fmt",
                    "yuv420p",
                    "-c:a",
                    "pcm_bluray",
                    "-ac",
                    "2",
                    "-c:s",
                    "copy",
                    "-metadata:s:a:0",
                    "language=eng",
                    "-metadata:s:a:1",
                    "language=spa",
                    "-metadata:s:s:0",
                    "language=eng",
                    "-disposition:a:0",
                    "default",
                    "-disposition:a:1",
                    "0",
                    "-mpegts_m2ts_mode",
                    "1",
                    "-mpegts_copyts",
                    "1",
                    "-muxdelay",
                    "0",
                    "-f",
                    "mpegts",
                    str(stream),
                ],
                check=True,
            )
            (disc / "CLIPINF" / f"{stem}.clpi").write_bytes(clip_info(stream))

    # A single HDMV movie title plays playlist zero. First-play and top-menu are absent.
    app = section(bytes([0, 0x51]) + bytes(32))
    absent = pack(">IHHI", 0x40000000, 0, 0xFFFF, 0)
    title = pack(">IHHI", 0x40000000, 0, 0, 0)
    indexes = section(absent * 2 + pack(">H", 1) + title)
    (disc / "index.bdmv").write_bytes(b"INDX0200" + pack(">2I", 40 + len(app), 0) + bytes(24) + app + indexes)
    play_playlist_zero = pack(">III", 0x22800000, 0, 0)
    objects = section(pack(">IHHH", 0, 1, 0, 1) + play_playlist_zero)
    (disc / "MovieObject.bdmv").write_bytes(b"MOBJ0200" + bytes(32) + objects)
    (disc / "PLAYLIST/00000.mpls").write_bytes(playlist())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
