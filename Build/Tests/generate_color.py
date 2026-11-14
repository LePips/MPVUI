#!/usr/bin/env python3
"""Generate 10-bit HEVC samples with HDR transfer functions and static metadata.

These test decoding and signaling, not calibrated display appearance. They
are long enough for HDR surface changes during continuous playback.
"""

import argparse
from pathlib import Path
import re
import subprocess
from tempfile import TemporaryDirectory

X265 = "log-level=error:pools=2:frame-threads=1:colorprim=bt2020:colormatrix=bt2020nc"


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    for name, transfer, code, x265 in [
        (
            "color-hdr10",
            "smpte2084",
            16,
            ":hdr10=1:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,50):max-cll=1000,400",
        ),
        ("color-hlg", "arib-std-b67", 18, ""),
    ]:
        encode(output, name, "testsrc2=size=320x180:rate=24:duration=10", transfer, code, x265)
        encode(output, f"{name}-luma", moving_luma_bars(), transfer, code, x265 + ":lossless=1:keyint=18:scenecut=0")
        if name == "color-hdr10":
            generate_hdr10plus(output, transfer, code, x265)


def moving_luma_bars():
    rising = "if(lt(X,W/4),64,if(lt(X,W/2),300,if(lt(X,W*3/4),520,740)))"
    falling = rising.replace("X", "(W-X-1)")
    return f"nullsrc=s=320x180:r=12:d=3,format=yuv420p10le,geq=lum='if(lt(T,1.5),{rising},{falling})':cb=512:cr=512"


def hdr10plus_sei(maximum, average):
    # ST 2094-40 application version 1, one window, 1000-nit target, no tone curve or peak grids.
    fields = [(1, 8), (1, 2), (10_000_000, 27), (0, 1)]
    fields += [(round(level * 10), 17) for level in (*maximum, average)]
    fields += [(0, 4), (0, 10), (0, 1), (0, 1), (0, 1)]
    bits = "".join(f"{value:0{width}b}" for value, width in fields)
    bits += "0" * (-len(bits) % 8)
    registered = b"\xb5\x00\x3c\x00\x01\x04" + int(bits, 2).to_bytes(len(bits) // 8, "big")
    rbsp = bytes((4, len(registered))) + registered + b"\x80"
    escaped = bytearray()
    for value in rbsp:
        if value <= 3 and escaped[-2:] == b"\x00\x00":
            escaped.append(3)
        escaped.append(value)
    return b"\x4e\x01" + escaped


def generate_hdr10plus(output, transfer, code, x265):
    ffmpeg = ["ffmpeg", "-v", "error", "-nostdin", "-y"]
    start_code = b"\x00\x00\x00\x01"
    with TemporaryDirectory(prefix="hdr10plus-") as directory:
        work = Path(directory)
        encode(work, "base", moving_luma_bars(), transfer, code, x265 + ":lossless=1:keyint=12:scenecut=0:aud=1:bframes=0")
        encoded = subprocess.check_output(
            [*ffmpeg, "-i", work / "base.mkv", "-c", "copy", "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", "pipe:1"]
        )
        metadata = [
            hdr10plus_sei((400, 300, 200), 130),
            hdr10plus_sei((900, 700, 500), 280),
            hdr10plus_sei((600, 500, 400), 170),
        ]
        stream = work / "scenes.hevc"
        frame = -1
        last_picture = -1
        with stream.open("wb") as target:
            for nal in re.split(rb"\x00\x00(?:\x00)?\x01", encoded)[1:]:
                kind = (nal[0] >> 1) & 63
                if kind == 35:
                    frame += 1
                if kind < 32 and frame != last_picture:
                    target.write(start_code + metadata[frame // 12])
                    last_picture = frame
                target.write(start_code + nal)
        if frame != 35 or last_picture != frame:
            raise RuntimeError("Expected 36 delimited HEVC pictures")
        subprocess.run([*ffmpeg, "-framerate", "12", "-i", stream, "-c", "copy", output / "color-hdr10plus-scenes.mkv"], check=True)


def encode(output, name, source, transfer, code, x265):
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
            source,
            "-an",
            "-c:v",
            "libx265",
            "-pix_fmt",
            "yuv420p10le",
            "-preset",
            "ultrafast",
            "-x265-params",
            f"{X265}:transfer={transfer}{x265}",
            "-color_primaries",
            "bt2020",
            "-color_trc",
            transfer,
            "-colorspace",
            "bt2020nc",
            "-color_range",
            "tv",
            # Pin VUI tags in the encoded SPS as well as the container. Some x265
            # builds omit color-description fields for filter-generated input.
            "-bsf:v",
            f"hevc_metadata=colour_primaries=9:transfer_characteristics={code}:matrix_coefficients=9",
            "-threads",
            "2",
            "-map_metadata",
            "-1",
            str(output / f"{name}.mkv"),
        ],
        check=True,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
