"""Wrap an authored AVS3 red-to-blue sequence in each supported reader."""

from base64 import b64decode
from io import BytesIO
from struct import pack
from zlib import decompress

from generate_matroska import element, unsigned


# Authored 128x128 8-bit 4:2:0, 24 fps, GOP 12, QP 28, no B-frames.
# Encoded with uavs3e e1ff0f37a8d67814e1d650f6b49d495c49dde946.
STREAM = """
eJxjYGDcoJTVISCgIJQUwMDEIP///3/NgEVdWoquohKLulpEgkIcp34zNz/BwMC4GSj3n4Hn54
YOBSCP4f+c9QIqD/74P0kuW/iebw1LA1CwH4i3gZQd0OfktJVY0ABW2K/egCrpzSswaYtTE3bJ
fBYXJ++LXRzYZdtZXVxUJlsJMmGXXs/LpbIWp72nWVw0Jn3BZfF7VhenThVcNh9kZ3HiUtnzwg
WHtD6ri8IiT5Mk7IYf9NaY5CuAw10H83Um+WJxNGkxw8YzYVKOwCJY1Ai6qjM3FZgHYETNwfWg
qHHH4Y3ToKhxlFHALvseHDctBdj9cYgdEjkcATjk9cGxg8PqQ97g2MFl96F8SPTgtLwdEj+KTt
il10PiJxGX8adBEYTLae9BEYQpuREA9aE1Ew==
"""
PACKET_SIZES = (80, 29, 29, 30, 31, 30, 30, 31, 31, 31, 29, 29, 81, 29, 30, 31, 32, 30, 31, 32, 31, 32, 29, 33)


def matroska():
    data = decompress(b64decode(STREAM))
    if len(data) != sum(PACKET_SIZES):
        raise ValueError("AVS3 packet sizes do not match the authored bitstream")
    stream = BytesIO(data)
    header = element(
        "1A45DFA3",
        unsigned("4286", 1)
        + unsigned("42F7", 1)
        + unsigned("42F2", 4)
        + unsigned("42F3", 8)
        + element("4282", b"matroska")
        + unsigned("4287", 4)
        + unsigned("4285", 2),
    )
    info = element(
        "1549A966",
        unsigned("2AD7B1", 1000000)
        + element("4489", pack(">d", 1000.0))
        + element("4D80", b"Media tests")
        + element("5741", b"Media tests"),
    )
    video = element("E0", unsigned("B0", 128) + unsigned("BA", 128))
    track = element(
        "AE",
        unsigned("D7", 1) + unsigned("73C5", 1) + unsigned("83", 1) + element("86", b"V_AVS3") + unsigned("23E383", 41666667) + video,
    )
    tracks = element("1654AE6B", track)
    clusters = []
    for start in (0, 12):
        time = round(start * 1000 / 24)
        blocks = []
        for index in range(start, start + 12):
            relative = round(index * 1000 / 24) - time
            flags = 0x80 if index == start else 0
            blocks.append(element("A3", pack(">BhB", 0x81, relative, flags) + stream.read(PACKET_SIZES[index])))
        clusters.append(element("1F43B675", unsigned("E7", time) + b"".join(blocks)))
    return header + element("18538067", info + tracks + b"".join(clusters))
