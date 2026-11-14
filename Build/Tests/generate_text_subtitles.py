#!/usr/bin/env python3
"""Generate timed text sidecars with two cues and explicit clear intervals."""

import argparse
import json
from pathlib import Path


FIRST = "First legacy cue"
SECOND = "Second legacy cue"
CATALOG = "text-subtitles.json"

ASS = f"""[Script Info]
ScriptType: v4.00+
PlayResX: 360
PlayResY: 640
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,28,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,40,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{FIRST}
Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,{{\\an8}}{SECOND}
"""

FORMATS = {
    "ass": ("ass", "ass", ASS),
    "aqtitle": ("aqt", "text", f"-->> 25\n{FIRST}\n-->> 50\n\n-->> 75\n{SECOND}\n-->> 100\n"),
    "srt": ("srt", "subrip", f"1\n00:00:01,000 --> 00:00:02,000\n{FIRST}\n\n2\n00:00:03,000 --> 00:00:04,000\n{SECOND}\n"),
    "jacosub": ("jss", "jacosub", f"#TIMERES 30\n@30 @60 JC {FIRST}\n@90 @120 JC {SECOND}\n"),
    "lrc": ("lrc", "text", f"[00:01.00]{FIRST}\n[00:02.00]\n[00:03.00]{SECOND}\n[00:04.00]\n"),
    "microdvd": ("sub", "microdvd", f"{{1}}{{1}}25.000\n{{25}}{{50}}{FIRST}\n{{75}}{{100}}{SECOND}\n"),
    "mpsub": ("sub", "text", f"FORMAT=TIME\n\n1.0 1.0\n{FIRST}\n\n1.0 1.0\n{SECOND}\n\n"),
    "pjs": ("pjs", "pjs", f'10,20,"{FIRST}"\n30,40,"{SECOND}"\n'),
    "realtext": (
        "rt",
        "realtext",
        f'<window>\n<time begin="0:01.00" end="0:02.00"/>{FIRST}\n<time begin="0:03.00" end="0:04.00"/>{SECOND}\n</window>\n',
    ),
    "sami": (
        "smi",
        "sami",
        (
            f"<SAMI>\n<BODY>\n<SYNC Start=1000><P Class=ENCC>{FIRST}\n<SYNC Start=2000><P Class=ENCC>&nbsp;\n"
            f"<SYNC Start=3000><P Class=ENCC>{SECOND}\n<SYNC Start=4000><P Class=ENCC>&nbsp;\n</BODY>\n</SAMI>\n"
        ),
    ),
    "stl": ("stl", "stl", f"$FontName = Arial\n00:00:01:00 , 00:00:02:00 , {FIRST}\n00:00:03:00 , 00:00:04:00 , {SECOND}\n"),
    "subviewer": (
        "sub",
        "subviewer",
        (
            f"[INFORMATION]\n[TITLE]Timed text fixture\n[END INFORMATION]\n[SUBTITLE]\n"
            f"00:00:01.00,00:00:02.00\n{FIRST}\n\n00:00:03.00,00:00:04.00\n{SECOND}\n"
        ),
    ),
    "subviewer1": (
        "sub",
        "subviewer1",
        (f"******** START SCRIPT ********\n[00:00:01]\n{FIRST}\n[00:00:02]\n\n[00:00:03]\n{SECOND}\n[00:00:04]\n\n"),
    ),
    "tedcaptions": (
        "json",
        "text",
        json.dumps(
            {
                "captions": [
                    {"startOfParagraph": True, "startTime": 1000, "duration": 1000, "content": FIRST},
                    {"startOfParagraph": True, "startTime": 3000, "duration": 1000, "content": SECOND},
                ]
            }
        ),
    ),
    "vplayer": ("txt", "vplayer", f"0:00:01:{FIRST}\n0:00:02:\n0:00:03:{SECOND}\n0:00:04:\n"),
}


def filename(reader, suffix):
    return f"text-subtitles-{reader}.{suffix}"


def output_names():
    return (CATALOG, *(filename(reader, clip[0]) for reader, clip in FORMATS.items()))


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    cases = []
    for reader, (extension, codec, text) in FORMATS.items():
        name = filename(reader, extension)
        (output / name).write_text(text, encoding="utf-8")
        case = {"file": name, "format": reader, "codec": codec, "androidOnly": reader not in {"ass", "srt"}}
        if reader == "tedcaptions":
            # The reader offsets the authored speech cues by a 15-second preamble.
            case.update({"timeOffset": 15, "video": "multitrack.mkv"})
        cases.append(case)
    (output / CATALOG).write_text(json.dumps({"cases": cases, "first": FIRST, "second": SECOND}, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
