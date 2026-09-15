#!/usr/bin/env python3
"""Generate the test-only chapter, track-selection and subtitle-seeking sample."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, default=ROOT / ".build/test-media")
output_directory = parser.parse_args().output
output_directory.mkdir(parents=True, exist_ok=True)
NAME = "02-h264-multitrack.mkv"

with tempfile.TemporaryDirectory(prefix="multitrack-fixture-") as directory:
    work = Path(directory)
    overlap = work / "overlap.srt"
    overlap.write_text(
        "1\n00:00:01,000 --> 00:00:05,000\nfirst cue\n\n"
        "2\n00:00:01,000 --> 00:00:18,000\nlong cue\n\n"
        "3\n00:00:03,000 --> 00:00:06,000\noverlap\n\n"
        "4\n00:00:19,000 --> 00:00:20,000\nlast cue\n",
        encoding="utf-8",
    )
    dialogue = work / "dialogue.srt"
    dialogue.write_text(
        "1\n00:00:01,000 --> 00:00:04,000\n[Embedded English] EN track cue 1\n\n"
        "2\n00:00:05,000 --> 00:00:10,000\n[Embedded English] EN track cue 2\n\n"
        "3\n00:00:12,000 --> 00:00:20,000\n[Embedded English] EN track cue 3\n",
        encoding="utf-8",
    )
    japanese = work / "japanese.ass"
    japanese.write_text(
        "[Script Info]\nScriptType: v4.00+\nPlayResX: 320\nPlayResY: 180\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
        "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, "
        "Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
        "Style: Default,Arial,18,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,"
        "0,0,0,0,100,100,0,0,1,1,0,2,10,10,12,1\n"
        "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        "Dialogue: 0,0:00:01.00,0:00:10.00,Default,,0,0,0,,日本語の字幕サンプル\n"
        "Dialogue: 0,0:00:12.00,0:00:20.00,Default,,0,0,0,,二つ目の字幕\n",
        encoding="utf-8",
    )
    metadata = work / "chapters.txt"
    metadata.write_text(";FFMETADATA1\n" + "".join(
        f"[CHAPTER]\nTIMEBASE=1/1000\nSTART={start}\nEND={end}\ntitle={title}\n"
        for start, end, title in [(0, 4000, "Opening"), (4000, 8000, "Middle"), (8000, 21000, "Ending")]
    ))
    output = work / NAME
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=15:duration=21",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=21",
        "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000:duration=21",
        "-i", str(overlap), "-i", str(dialogue), "-i", str(japanese),
        "-f", "ffmetadata", "-i", str(metadata),
        "-map", "0:v", "-map", "1:a", "-map", "2:a",
        "-map", "3:s", "-map", "4:s", "-map", "5:s",
        "-c:v", "libx264", "-preset", "medium", "-crf", "35", "-g", "15",
        "-pix_fmt", "yuv420p", "-c:a:0", "aac", "-b:a:0", "32k",
        "-c:a:1", "libopus", "-b:a:1", "24k", "-c:s", "copy",
        "-map_metadata:g", "-1", "-map_chapters", "6",
        "-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=English AAC",
        "-metadata:s:a:1", "language=spa", "-metadata:s:a:1", "title=Spanish Opus",
        "-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=Overlapping cues",
        "-metadata:s:s:1", "language=eng", "-metadata:s:s:1", "title=English dialogue",
        "-metadata:s:s:2", "language=jpn", "-metadata:s:s:2", "title=Japanese ASS",
        "-disposition:a:0", "default", "-disposition:a:1", "0",
        "-disposition:s:0", "0", "-disposition:s:1", "default", "-disposition:s:2", "0",
        "-avoid_negative_ts", "disabled", "-fflags", "+bitexact", "-flags:v", "+bitexact",
        str(output),
    ], check=True)
    packets = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "s:0", "-show_packets",
        "-show_entries", "packet=pts_time,duration_time", "-of", "json", str(output),
    ]))["packets"]
    assert [(float(p["pts_time"]), float(p["duration_time"])) for p in packets] == [
        (1, 4), (1, 17), (3, 3), (19, 1),
    ], "Subtitle timing changed"
    chapters = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_chapters", "-of", "json", str(output),
    ]))["chapters"]
    assert [(float(c["start_time"]), c["tags"]["title"]) for c in chapters] == [
        (0, "Opening"), (4, "Middle"), (8, "Ending"),
    ], "Chapter names or boundaries changed"
    destination = output_directory / NAME
    destination.write_bytes(output.read_bytes())

print(f"Generated {destination}: {destination.stat().st_size} bytes")
