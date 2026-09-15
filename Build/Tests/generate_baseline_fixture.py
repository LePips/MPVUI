#!/usr/bin/env python3
"""Generate portrait H.264/AAC playback and bilingual subtitle sidecars."""
import argparse
from pathlib import Path
import subprocess


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    for language, lines in {
        "en": ["Welcome to the subtitle demo.", "Two languages can appear at the same time.",
               "Choose each language in the Tracks menu."],
        "es": ["Bienvenidos a la demostración de subtítulos.", "Dos idiomas pueden aparecer al mismo tiempo.",
               "Elige cada idioma en el menú de pistas."],
    }.items():
        (output / f"01-h264-aac-baseline.{language}.srt").write_text("\n".join(
            f"{i + 1}\n00:00:{i * 4:02},000 --> 00:00:{(i + 1) * 4:02},000\n{line}\n"
            for i, line in enumerate(lines)
        ), encoding="utf-8")
    subprocess.run([
        "ffmpeg", "-v", "error", "-nostdin", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=360x640:rate=15:duration=12",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=24000:duration=12",
        "-c:v", "libx264", "-preset", "fast", "-crf", "32", "-g", "15",
        "-pix_fmt", "yuv420p", "-profile:v", "baseline",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
        "-c:a", "aac", "-b:a", "32k", "-map_metadata", "-1", "-movflags", "+faststart",
        str(output / "01-h264-aac-baseline.mp4"),
    ], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
