#!/usr/bin/env python3
"""Author Matroska lacing and linked ordered chapters with exact PCM references."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
from tempfile import TemporaryDirectory


SAMPLE_RATE = 48000
PACKET_MS = 20
PACKET_FRAMES = SAMPLE_RATE * PACKET_MS // 1000
PACKETS_PER_LACE = 6
TOTAL_PACKETS = 60
SEEK_FRAME = SAMPLE_RATE // 2
LACING = {"xiph": 0x02, "fixed": 0x04, "ebml": 0x06}
COMPRESSED_LACING = ("flac-xiph", "flac-ebml")
LACING_CATALOG = "matroska-lacing.json"
ORDERED_CATALOG = "matroska-ordered.json"
ORDERED_FILE = "matroska-ordered.mka"
LINKED_FILE = "matroska-ordered-linked.mka"


def output_names():
    return (
        *(f"matroska-{mode}.mka" for mode in (*LACING, *COMPRESSED_LACING)),
        LACING_CATALOG,
        ORDERED_CATALOG,
        ORDERED_FILE,
        LINKED_FILE,
    )


def vint(value):
    for width in range(1, 9):
        marker = 1 << (7 * width)
        if value < marker - 1:
            return (marker | value).to_bytes(width, "big")
    raise ValueError("Value does not fit an EBML VINT")


def element(tag, data):
    return bytes.fromhex(tag) + vint(len(data)) + data


def unsigned(tag, value):
    width = max(1, (value.bit_length() + 7) // 8)
    return element(tag, value.to_bytes(width, "big"))


def signed_vint(delta):
    for width in range(1, 9):
        marker = 1 << (7 * width)
        biased = delta + marker // 2 - 1
        if 0 <= biased < marker - 1:
            return (marker | biased).to_bytes(width, "big")
    raise ValueError("Length difference does not fit an EBML lacing VINT")


def lace_header(mode, sizes):
    count = bytes([len(sizes) - 1])
    if mode == "fixed":
        if len(set(sizes)) != 1:
            raise ValueError("Fixed lacing requires equal packet sizes")
        return count
    if mode == "xiph":
        return count + b"".join(b"\xff" * (size // 255) + bytes([size % 255]) for size in sizes[:-1])
    return count + vint(sizes[0]) + b"".join(signed_vint(cur - prev) for prev, cur in zip(sizes, sizes[1:-1]))


def matroska(mode, packets, *, codec=b"A_PCM/INT/LIT", codec_private=b"", uid=b"", chapters=b""):
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
        + element("4489", struct.pack(">d", len(packets) * PACKET_MS))
        + element("4D80", b"MPVUI media tests")
        + element("5741", b"MPVUI media tests")
        + (element("73A4", uid) if uid else b""),
    )
    audio = element("E1", element("B5", struct.pack(">d", SAMPLE_RATE)) + unsigned("9F", 1) + unsigned("6264", 16))
    track = element(
        "AE",
        unsigned("D7", 1)
        + unsigned("73C5", 1)
        + unsigned("83", 2)
        + unsigned("9C", 1)
        + element("86", codec)
        + (element("63A2", codec_private) if codec_private else b"")
        + unsigned("23E383", PACKET_MS * 1000000)
        + audio,
    )
    tracks = element("1654AE6B", track)

    clusters = []
    packets_per_cluster = PACKETS_PER_LACE * 3
    for start in range(0, len(packets), packets_per_cluster):
        blocks = []
        for first in range(start, min(start + packets_per_cluster, len(packets)), PACKETS_PER_LACE):
            lace = packets[first : first + PACKETS_PER_LACE]
            lacing = lace_header(mode, [len(packet) for packet in lace])
            metadata = vint(1) + struct.pack(">hB", (first - start) * PACKET_MS, 0x80 | LACING[mode])
            blocks.append(element("A3", metadata + lacing + b"".join(lace)))
        clusters.append(element("1F43B675", unsigned("E7", start * PACKET_MS) + b"".join(blocks)))
    return header + element("18538067", info + tracks + chapters + b"".join(clusters))


def tones(frequencies):
    frames = PACKET_FRAMES * TOTAL_PACKETS
    pcm = bytearray()
    for frame in range(frames):
        frequency = frequencies[frame // (frames // len(frequencies))]
        pcm.extend(struct.pack("<h", round(12000 * math.sin(math.tau * frequency * frame / SAMPLE_RATE))))
    return bytes(pcm)


def chapter(uid, title, start_ms, end_ms, segment_uid=b""):
    return element(
        "B6",
        unsigned("73C4", uid)
        + unsigned("91", start_ms * 1000000)
        + unsigned("92", end_ms * 1000000)
        + (element("6E67", segment_uid) if segment_uid else b"")
        + element("80", element("85", title.encode("ascii")) + element("437C", b"eng")),
    )


def sample_range(pcm, start_ms, end_ms):
    return pcm[start_ms * SAMPLE_RATE // 1000 * 2 : end_ms * SAMPLE_RATE // 1000 * 2]


def pcm_packets(pcm):
    packet_bytes = PACKET_FRAMES * 2
    return [pcm[start : start + packet_bytes] for start in range(0, len(pcm), packet_bytes)]


def flac_packets(output, pcm):
    with TemporaryDirectory(dir=output) as temporary:
        path = Path(temporary) / "packed.flac"
        subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "s16le",
                "-ar",
                str(SAMPLE_RATE),
                "-ac",
                "1",
                "-i",
                "pipe:0",
                "-c:a",
                "flac",
                "-frame_size",
                str(PACKET_FRAMES),
                str(path),
            ],
            input=pcm,
            check=True,
        )
        info = json.loads(
            subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "packet=pos,size,duration", "-of", "json", str(path)])
        )
        data = path.read_bytes()
    frames = info["packets"]
    if len(frames) != TOTAL_PACKETS or any(int(packet["duration"]) != PACKET_FRAMES for packet in frames):
        raise ValueError("Every laced FLAC packet must contain 20 ms of the authored audio")
    positions = [(int(packet["pos"]), int(packet["size"])) for packet in frames]
    chunks = [data[start : start + length] for start, length in positions]
    if len({len(chunk) for chunk in chunks}) < 2:
        raise ValueError("Expected variable-length FLAC packets for lacing")
    return data[: positions[0][0]], chunks


def manifest(name, pcm, seek_frame):
    return {
        "file": name,
        "sampleRate": SAMPLE_RATE,
        "channels": 1,
        "frames": len(pcm) // 2,
        "sha256": hashlib.sha256(pcm).hexdigest(),
        "seekStartFrame": seek_frame,
        "seekSha256": hashlib.sha256(pcm[seek_frame * 2 :]).hexdigest(),
    }


def generate_ordered(output, pcm):
    main_uid = bytes.fromhex("5f984aef667f4b06a0ddc96495624e1a")
    linked_uid = bytes.fromhex("f47735891ad141c482edc523c5218a45")
    linked_pcm = tones((330, 550, 770))
    chapters = element(
        "1043A770",
        element(
            "45B9",
            unsigned("45BC", 1)
            + unsigned("45DB", 1)
            + unsigned("45DD", 1)
            + chapter(1, "Opening", 0, 360)
            + chapter(2, "Linked", 480, 840, linked_uid)
            + chapter(3, "Return", 840, 1200),
        ),
    )
    (output / ORDERED_FILE).write_bytes(matroska("fixed", pcm_packets(pcm), uid=main_uid, chapters=chapters))
    (output / LINKED_FILE).write_bytes(matroska("fixed", pcm_packets(linked_pcm), uid=linked_uid))
    expected = sample_range(pcm, 0, 360) + sample_range(linked_pcm, 480, 840) + sample_range(pcm, 840, 1200)
    seek_frame = SAMPLE_RATE * 3 // 5
    catalog = manifest(ORDERED_FILE, expected, seek_frame)
    catalog["seekEarlySha256"] = hashlib.sha256(expected[(seek_frame - 1) * 2 :]).hexdigest()
    without_linked = sample_range(pcm, 0, 360) + sample_range(pcm, 840, 1200)
    missing_seek = SAMPLE_RATE * 9 // 20
    missing = manifest(ORDERED_FILE, without_linked, missing_seek)
    missing["seekEarlySha256"] = hashlib.sha256(without_linked[(missing_seek - 1) * 2 :]).hexdigest()
    catalog["withoutLinked"] = missing
    (output / ORDERED_CATALOG).write_text(json.dumps(catalog, indent=2) + "\n")


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    pcm = tones((440, 660, 880))
    packets = pcm_packets(pcm)

    catalog = {}
    for mode in LACING:
        name = f"matroska-{mode}.mka"
        (output / name).write_bytes(matroska(mode, packets))
        catalog[mode] = manifest(name, pcm, SEEK_FRAME)
    private, flac = flac_packets(output, pcm)
    for mode in COMPRESSED_LACING:
        name = f"matroska-{mode}.mka"
        (output / name).write_bytes(matroska(mode.removeprefix("flac-"), flac, codec=b"A_FLAC", codec_private=private))
        catalog[mode] = manifest(name, pcm, SEEK_FRAME)
    (output / LACING_CATALOG).write_text(json.dumps(catalog, indent=2) + "\n")
    generate_ordered(output, pcm)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
