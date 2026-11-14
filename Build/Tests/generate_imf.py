#!/usr/bin/env python3
"""Author a two-resource IMF composition with JPEG 2000 and PCM tracks."""

import argparse
from pathlib import Path
from subprocess import run
from xml.etree.ElementTree import Element, SubElement, ElementTree


DIRECTORY = "imf"
CLIPS = (("red", 440), ("blue", 880))


def output_names():
    return (
        f"{DIRECTORY}/CPL.xml",
        f"{DIRECTORY}/ASSETMAP.xml",
        *(f"{DIRECTORY}/{color}-{media}.mxf" for color, _ in CLIPS for media in ("video", "audio")),
    )


def identifier(number):
    return f"urn:uuid:13767921-6578-4f33-9571-{number:012d}"


def generate(output):
    root = output / DIRECTORY
    root.mkdir(parents=True, exist_ok=True)
    asset_map = Element("AssetMap", xmlns="http://www.smpte-ra.org/schemas/429-9/2007/AM")
    assets = SubElement(asset_map, "AssetList")

    cpl = Element("CompositionPlaylist", xmlns="http://www.smpte-ra.org/schemas/2067-3/2016")
    SubElement(cpl, "Id").text = identifier(1)
    SubElement(cpl, "ContentTitle").text = "Two authored frames and tones"
    SubElement(cpl, "EditRate").text = "24 1"
    segments = SubElement(cpl, "SegmentList")
    segment = SubElement(segments, "Segment")
    SubElement(segment, "Id").text = identifier(2)
    sequences = SubElement(segment, "SequenceList")
    for track, (media, type_name, edit_rate, duration) in enumerate(
        (("video", "MainImageSequence", 24, 24), ("audio", "MainAudioSequence", 48000, 48000)), 3
    ):
        sequence = SubElement(sequences, type_name)
        SubElement(sequence, "TrackId").text = identifier(track)
        resources = SubElement(sequence, "ResourceList")
        for index, (color, frequency) in enumerate(CLIPS, 1):
            filename = f"{color}-{media}.mxf"
            file_id = identifier(track * 10 + index)
            if media == "video":
                source = f"color={color}:size=192x108:rate=24:d=1"
                encoder = ["-c:v", "jpeg2000", "-pix_fmt", "yuv422p"]
            else:
                source = f"sine=frequency={frequency}:sample_rate=48000:duration=1"
                encoder = ["-c:a", "pcm_s24le"]
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
                    source,
                    *encoder,
                    "-f",
                    "mxf_opatom",
                    str(root / filename),
                ],
                check=True,
            )

            resource = SubElement(resources, "Resource")
            SubElement(resource, "EditRate").text = f"{edit_rate} 1"
            SubElement(resource, "IntrinsicDuration").text = str(duration)
            SubElement(resource, "TrackFileId").text = file_id
            asset = SubElement(assets, "Asset")
            SubElement(asset, "Id").text = file_id
            chunk = SubElement(SubElement(asset, "ChunkList"), "Chunk")
            SubElement(chunk, "Path").text = filename

    ElementTree(cpl).write(root / "CPL.xml", encoding="utf-8", xml_declaration=True)
    ElementTree(asset_map).write(root / "ASSETMAP.xml", encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
