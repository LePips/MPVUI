#!/usr/bin/env python3
"""Generate audio decoder, container, and output-route fixtures.

Layout fixtures use a distinct tone per channel. The DTS video uses a distinct tone per track.
Dolby 5.1 samples are long enough to outlast native output buffering.
"""

import argparse
from pathlib import Path
import struct
import subprocess

LAYOUTS = {"mono": 1, "stereo": 2, "5.1": 6, "7.1": 8}


def encode(output, filename, codec, layout, seconds, *options):
    tones = "|".join(f"0.05*sin(2*PI*{220 + index * 110}*t)" for index in range(LAYOUTS[layout]))
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
            f"aevalsrc={tones}:s=48000:d={seconds}:c={layout}",
            "-c:a",
            codec,
            *options,
            "-map_metadata",
            "-1",
            str(output / filename),
        ],
        check=True,
    )


def generate_gapless_album(output):
    samples = struct.Struct("<hh")
    tracks = []
    # Split at a nonaligned sample so any dropped or repeated samples change the waveform.
    for index, frames in enumerate((range(27001), range(27001, 60000)), start=1):
        track = f"audio-flac-gapless-{index:02d}.flac"
        tracks.append(track)
        pcm = b"".join(samples.pack((i * 97 + i // 9) % 28001 - 14000, (i * 251 + i // 17) % 21001 - 10500) for i in frames)
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-nostdin",
                "-y",
                "-f",
                "s16le",
                "-ar",
                "48000",
                "-ac",
                "2",
                "-i",
                "pipe:0",
                "-c:a",
                "flac",
                output / track,
            ],
            input=pcm,
            check=True,
        )
    (output / "audio-flac-gapless.m3u").write_text("#EXTM3U\n" + "\n".join(tracks) + "\n", encoding="utf-8")


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    generate_gapless_album(output)
    for codec in ("ac3", "eac3"):
        encode(output, f"audio-{codec}-stereo.mka", codec, "stereo", 6, "-b:a", "192k")
        encode(output, f"audio-{codec}-5.1.mka", codec, "5.1", 24, "-b:a", "448k")
    for layout in LAYOUTS:
        encode(output, f"audio-pcm-{layout}.mka", "pcm_s16le", layout, 6)
    for filename, encoder, *options in [
        ("audio-flac.flac", "flac"),
        ("audio-alac.m4a", "alac"),
        ("audio-mp3.mp3", "libmp3lame"),
        ("audio-vorbis.ogg", "vorbis", "-strict", "experimental"),
        ("audio-opus.ogg", "libopus"),
        ("audio-pcm.wav", "pcm_s16le"),
        ("audio-adts.aac", "aac"),
    ]:
        encode(output, filename, encoder, "stereo", 4, *options)
    # Match the reported bitrate/layout pair without mislabeling a normal
    # FFmpeg E-AC-3 encode as JOC/Atmos material.
    for bitrate in (256, 768):
        encode(output, f"audio-eac3-{bitrate}k-5.1.mka", "eac3", "5.1", 6, "-b:a", f"{bitrate}k")

    # Keep each DTS track playing past 30 seconds on either side of a live switch.
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
            "testsrc2=size=160x90:rate=24",
            "-f",
            "lavfi",
            "-i",
            "aevalsrc=0.05*sin(2*PI*440*t):s=48000:c=5.1(side)",
            "-f",
            "lavfi",
            "-i",
            "aevalsrc=0.05*sin(2*PI*660*t):s=48000:c=stereo",
            "-t",
            "72",
            "-map",
            "0:v",
            "-map",
            "1:a",
            "-map",
            "2:a",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-threads:v",
            "2",
            "-c:a",
            "dca",
            "-strict",
            "experimental",
            "-b:a:0",
            "768k",
            "-b:a:1",
            "384k",
            "-disposition:a:0",
            "default",
            "-disposition:a:1",
            "0",
            "-map_metadata",
            "-1",
            str(output / "audio-dts-multitrack.mkv"),
        ],
        check=True,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
