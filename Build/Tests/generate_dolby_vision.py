#!/usr/bin/env python3
"""Generate playable Dolby Vision samples with per-frame CM v4.0 RPUs.

Profile 5 has no compatible base layer, so its colors are not meaningful; it
exercises detection and output decisions. Profile 8.4 uses the 23.976 fps film
rate for display matching; the others use a high rate for per-frame delivery. MPEG-TS variants carry a DOVI video
stream descriptor, which FFmpeg cannot write. One declares extended metadata
compression over standalone RPUs; the other carries RPUs that reference earlier
RPUs. The first RPU of each Profile 5 and 8.1 clip is also written as an
unescaped payload for the native parser tests in NativeHDR.
"""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

FRAMES = 240
RATE = "120"
FILM_RATE = "24000/1001"
HDR10 = ("smpte2084", "hdr10=1:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,50):max-cll=1000,400")
HLG = ("arib-std-b67", "")
IPT = (None, "")  # Profile 5 carries no base-layer color description.
# Synthetic identity-mapped P7 MEL metadata, regenerated and checked by NativeHDR/dovi.c.
# This exercises metadata conversion, not enhancement-layer image reconstruction.
P7_RPU = bytes.fromhex(
    "1908090840613650af003ff801ffc00ffc001fffa000001000000d0000030080000068000004000003000040000020000020"
    "000003000400000302000003020000030000400000200000200000344acc00006bd44acdf3f9d6384acc8994000003020000"
    "030010000003001000000300386c4486030c14bc611c0a28000003034c7cb5fffe0000030000030000030000c040fb9c02a2"
    "80120c07d0006407d00320601000af05780180504300100100100100080002014000000300000300000a7fc0004603800800"
    "80004120050b01100000f93f951a80"
)


def run(*command):
    subprocess.run(command, check=True)


def mpeg2_crc(data):
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = (crc << 1) ^ 0x04C11DB7 if crc & 0x80000000 else crc << 1
            crc &= 0xFFFFFFFF
    return crc


def add_dovi_descriptor(path, profile, level, compatibility, compression, enhancement=False):
    """Append registration and DOVI descriptors to every HEVC PMT entry."""
    flags = (profile << 9) | (level << 3) | 0b101 | (int(enhancement) << 1)
    # Reserved trailing bits are set, as in broadcast-muxed streams.
    descriptors = b"\x05\x04DOVI" + bytes([0xB0, 5, 1, 0, flags >> 8, flags & 0xFF, compatibility << 4 | compression << 2 | 0b11])
    data = bytearray(path.read_bytes())
    pmt_pid, patched = None, 0
    for offset in range(0, len(data), 188):
        packet = data[offset : offset + 188]
        pid = (packet[1] & 0x1F) << 8 | packet[2]
        if packet[0] != 0x47 or not packet[1] & 0x40 or (pid != 0 and pid != pmt_pid):
            continue
        start = 4 + (1 + packet[4] if packet[3] & 0x20 else 0)
        section = start + 1 + packet[start]
        length = (packet[section + 1] & 0x0F) << 8 | packet[section + 2]
        end = section + 3 + length - 4
        if pid == 0:
            pmt_pid = (packet[section + 10] & 0x1F) << 8 | packet[section + 11]
            continue
        cursor = section + 12 + ((packet[section + 10] & 0x0F) << 8 | packet[section + 11])
        while cursor < end:
            info = (packet[cursor + 3] & 0x0F) << 8 | packet[cursor + 4]
            if packet[cursor] == 0x24:
                info_end = cursor + 5 + info
                packet[info_end:info_end] = descriptors
                info += len(descriptors)
                packet[cursor + 3 : cursor + 5] = bytes([0xF0 | info >> 8, info & 0xFF])
                length += len(descriptors)
                end += len(descriptors)
                patched += 1
            cursor += 5 + info
        packet[section + 1 : section + 3] = bytes([0xB0 | length >> 8, length & 0xFF])
        packet[end : end + 4] = mpeg2_crc(packet[section:end]).to_bytes(4, "big")
        if any(byte != 0xFF for byte in packet[188:]):
            raise RuntimeError("PMT descriptors do not fit in one transport packet")
        data[offset : offset + 188] = packet[:188]
    if not patched:
        raise RuntimeError(f"No HEVC PMT entry in {path.name}")
    path.write_bytes(data)


def dolby_vision_mp4(work, name, profile, transfer, rate=RATE):
    transfer_name, x265_hdr = transfer
    x265 = "log-level=error:pools=2:frame-threads=1:repeat-headers=1:keyint=60"
    color = []
    if transfer_name:
        x265 += f":colorprim=bt2020:transfer={transfer_name}:colormatrix=bt2020nc" + (":" + x265_hdr if x265_hdr else "")
        color = ["-color_primaries", "bt2020", "-color_trc", transfer_name, "-colorspace", "bt2020nc", "-color_range", "tv"]
    base = work / f"{name}.hevc"
    run(
        "ffmpeg",
        "-v",
        "error",
        "-nostdin",
        "-y",
        "-f",
        "lavfi",
        "-i",
        f"testsrc2=size=320x180:rate={rate}",
        "-frames:v",
        str(FRAMES),
        "-c:v",
        "libx265",
        "-pix_fmt",
        "yuv420p10le",
        "-preset",
        "ultrafast",
        "-x265-params",
        x265,
        *color,
        "-threads",
        "2",
        "-f",
        "hevc",
        str(base),
    )
    # Two shots exercise per-frame dynamic L1/L2/L3/L8 changes and a scene refresh.
    config = {
        "cm_version": "V40",
        "profile": profile,
        "length": FRAMES,
        "source_min_pq": 62,
        "source_max_pq": 3696,
        "level5": {
            "active_area_left_offset": 0,
            "active_area_right_offset": 0,
            "active_area_top_offset": 0,
            "active_area_bottom_offset": 0,
        },
        "level6": {
            "max_display_mastering_luminance": 1000,
            "min_display_mastering_luminance": 50,
            "max_content_light_level": 1000,
            "max_frame_average_light_level": 400,
        },
        "default_metadata_blocks": [
            {"Level9": {"source_primary_index": 0}},
            {"Level11": {"content_type": 1, "whitepoint": 0, "reference_mode_flag": True}},
        ],
        "shots": [
            {
                "start": 0,
                "duration": FRAMES // 2,
                "metadata_blocks": [
                    {"Level1": {"min_pq": 0, "max_pq": 2800, "avg_pq": 1400}},
                    {
                        "Level2": {
                            "target_max_pq": 2081,
                            "trim_slope": 2048,
                            "trim_offset": 2048,
                            "trim_power": 2048,
                            "trim_chroma_weight": 2048,
                            "trim_saturation_gain": 2048,
                            "ms_weight": 2048,
                        }
                    },
                ],
            },
            {
                "start": FRAMES // 2,
                "duration": FRAMES // 2,
                "metadata_blocks": [
                    {"Level1": {"min_pq": 0, "max_pq": 3079, "avg_pq": 1700}},
                    {"Level3": {"min_pq_offset": 2048, "max_pq_offset": 2048, "avg_pq_offset": 1900}},
                    {
                        "Level8": {
                            "target_display_index": 1,
                            "trim_slope": 2100,
                            "trim_offset": 2000,
                            "trim_power": 2048,
                            "trim_chroma_weight": 2048,
                            "trim_saturation_gain": 2048,
                            "ms_weight": 2048,
                        }
                    },
                ],
            },
        ],
    }
    (work / f"{name}.json").write_text(json.dumps(config))
    run("dovi_tool", "generate", "-j", str(work / f"{name}.json"), "-o", str(work / f"{name}.rpu"))
    run("dovi_tool", "inject-rpu", "-i", str(base), "--rpu-in", str(work / f"{name}.rpu"), "-o", str(work / f"{name}-dv.hevc"))
    # Raw HEVC has no timestamps; mux once before the RPU filter adds dvvC.
    run(
        "ffmpeg",
        "-v",
        "error",
        "-nostdin",
        "-y",
        "-fflags",
        "+genpts",
        "-f",
        "hevc",
        "-framerate",
        rate,
        "-i",
        str(work / f"{name}-dv.hevc"),
        "-c",
        "copy",
        str(work / f"{name}-raw.mp4"),
    )
    output = work / f"{name}.mp4"
    run(
        "ffmpeg",
        "-v",
        "error",
        "-nostdin",
        "-y",
        "-i",
        str(work / f"{name}-raw.mp4"),
        "-c",
        "copy",
        "-bsf:v",
        "dovi_rpu=compression=none",
        "-tag:v",
        "dvh1",
        "-strict",
        "unofficial",
        "-map_metadata",
        "-1",
        str(output),
    )
    return output


def first_rpu(work, name, output):
    """Write the first generated RPU without its start code or emulation prevention."""
    units = (work / f"{name}.rpu").read_bytes().split(b"\x00\x00\x00\x01")
    rpu = next(unit for unit in units if unit)
    if rpu[0] != 0x19:
        raise RuntimeError(f"Unexpected generated RPU NAL framing in {name}")
    # dovi_tool writes RPUs without a HEVC NAL header. FFmpeg's parser takes unescaped RBSP bytes.
    output.write_bytes(rpu.replace(b"\x00\x00\x03", b"\x00\x00"))


def untagged_mp4(source, output):
    """Remux intact RPUs into fragmented MP4 without a Dolby Vision config box."""
    run(
        "ffmpeg",
        "-v",
        "error",
        "-nostdin",
        "-y",
        "-i",
        str(source),
        "-map",
        "0:v",
        "-c",
        "copy",
        "-tag:v",
        "hvc1",
        "-strict",
        "normal",
        "-map_metadata",
        "-1",
        "-movflags",
        "empty_moov+frag_keyframe",
        str(output),
    )


def transport_stream(source, output, compression_filter, compatibility):
    stream = json.loads(
        subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_streams",
                "-of",
                "json",
                str(source),
            ]
        )
    )["streams"][0]
    record = next(entry for entry in stream["side_data_list"] if "dv_profile" in entry)
    run(
        "ffmpeg",
        "-v",
        "error",
        "-nostdin",
        "-y",
        "-i",
        str(source),
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:sample_rate=48000",
        "-shortest",
        "-map",
        "0:v",
        "-map",
        "1:a",
        "-c:v",
        "copy",
        "-bsf:v",
        f"dovi_rpu=compression={compression_filter}",
        "-c:a",
        "aac",
        "-ac",
        "1",
        "-b:a",
        "64k",
        "-map_metadata",
        "-1",
        "-f",
        "mpegts",
        str(output),
    )
    add_dovi_descriptor(output, record["dv_profile"], record["dv_level"], compatibility, compression=3)


def profile7_mp4(work):
    """Pair synthetic P7 MEL RPUs with the generated HDR10 test pattern."""
    name = "dolby-vision-p7"
    rpu = work / f"{name}.rpu"
    rpu.write_bytes((b"\x00\x00\x00\x01" + P7_RPU) * FRAMES)
    hevc = work / f"{name}.hevc"
    run("dovi_tool", "inject-rpu", "-i", str(work / "dolby-vision-p81.hevc"), "--rpu-in", str(rpu), "-o", str(hevc))
    raw = work / f"{name}-raw.mp4"
    run(
        "ffmpeg",
        "-v",
        "error",
        "-nostdin",
        "-y",
        "-fflags",
        "+genpts",
        "-f",
        "hevc",
        "-framerate",
        RATE,
        "-i",
        str(hevc),
        "-c",
        "copy",
        str(raw),
    )
    # FFmpeg's RPU encoder deliberately does not infer P7 configuration. Carry
    # an explicit P7 descriptor through TS to write a truthful MP4 record.
    transport = work / f"{name}.ts"
    run("ffmpeg", "-v", "error", "-nostdin", "-y", "-i", str(raw), "-c", "copy", "-f", "mpegts", str(transport))
    add_dovi_descriptor(transport, 7, 1, 6, compression=0, enhancement=True)
    output = work / f"{name}.mp4"
    run(
        "ffmpeg",
        "-v",
        "error",
        "-nostdin",
        "-y",
        "-i",
        str(transport),
        "-c",
        "copy",
        "-tag:v",
        "dvh1",
        "-strict",
        "unofficial",
        "-map_metadata",
        "-1",
        str(output),
    )
    return output


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dolby-vision-fixtures-") as directory:
        work = Path(directory)
        p5 = dolby_vision_mp4(work, "dolby-vision-p5", "5", IPT)
        p81 = dolby_vision_mp4(work, "dolby-vision-p81", "8.1", HDR10)
        p84 = dolby_vision_mp4(work, "dolby-vision-p84", "8.4", HLG, FILM_RATE)
        p5_hls = dolby_vision_mp4(work, "dolby-vision-p5-hls", "5", IPT, FILM_RATE)
        p81_hls = dolby_vision_mp4(work, "dolby-vision-p81-hls", "8.1", HDR10, FILM_RATE)
        p7 = profile7_mp4(work)
        for source in (p5, p7, p81, p84):
            untagged_mp4(source, output / f"{source.stem}-untagged.mp4")
        # A P7 RPU cannot establish its required HDR10 base when the SPS says HLG.
        run(
            "ffmpeg",
            "-v",
            "error",
            "-nostdin",
            "-y",
            "-i",
            str(output / "dolby-vision-p7-untagged.mp4"),
            "-c",
            "copy",
            "-bsf:v",
            "hevc_metadata=transfer_characteristics=18",
            "-color_trc",
            "arib-std-b67",
            "-tag:v",
            "hvc1",
            "-strict",
            "normal",
            "-map_metadata",
            "-1",
            "-movflags",
            "empty_moov+frag_keyframe",
            str(output / "dolby-vision-p7-invalid-base.mp4"),
        )
        declared = work / "dolby-vision-p81-declared-extended.ts"
        extended = work / "dolby-vision-p81-extended.ts"
        transport_stream(p81, declared, "none", compatibility=1)
        transport_stream(p81, extended, "extended", compatibility=1)
        for path in (p5, p7, p81, p84, p5_hls, p81_hls, declared, extended):
            shutil.move(path, output / path.name)
        for path in (p5, p7, p81):
            first_rpu(work, path.stem, output / f"{path.stem}.rpu")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
