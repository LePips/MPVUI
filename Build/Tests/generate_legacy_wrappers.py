"""Wrap generated streams in formats without an FFmpeg muxer."""

from functools import lru_cache
import json
import re
import struct
import subprocess

from generate_legacy_audio import PSX_RATE, aiff_dpcm, chunk, psx_frames, signed_nibbles, tone, vidc
from generate_wave_adpcm import ima_codes, pack_nibbles


VIDEO_SOURCES = {
    "h264": "codecs-h264.h264",
    "hevc": "codecs-hevc.hevc",
    "mpeg4": "codecs-mpeg4.m4v",
    "mpeg1video": "codecs-mpeg1.m1v",
    "mpeg2video": "codecs-mpeg2.m2v",
    "mjpeg": "codecs-mjpeg.avi",
    "dvvideo": "codecs-dv.dv",
}
WRAPPERS = {
    "3dostr",
    "aax",
    "aix",
    "boa",
    "cdg",
    "dhav",
    "fsb",
    "hxvs",
    "ifv",
    "iv8",
    "kux",
    "laf",
    "lmlm4",
    "luodat",
    "lvf",
    "lxf",
    "mgsts",
    "mtv",
    "musx",
    "nc",
    "pmp",
    "pva",
    "rpl",
    "scd",
    "sdr2",
    "ser",
    "siff",
    "simbiosis_imx",
}
LXF_DEPTHS = {"pcm_s16le_planar": 16, "pcm_lxf": 20, "pcm_s24le_planar": 24, "pcm_s32le_planar": 32}
LXF_PICTURES = {"mjpeg": 0, "mpeg1video": 1, "mpeg2video": 2, "dvvideo": 4}
LAF_QUALITIES = {"pcm_u8": 0, "pcm_s16le": 1, "pcm_f32le": 2, "pcm_s24le": 3}


def riff(tag, payload):
    return chunk(tag, payload, "<I")


def avi_file(main, stream, format_data, packet_tag, packets):
    stream_list = riff(b"LIST", b"strl" + riff(b"strh", stream) + riff(b"strf", format_data))
    header = riff(b"LIST", b"hdrl" + riff(b"avih", main) + stream_list)
    media, index = bytearray(b"movi"), bytearray()
    for packet, key in packets:
        index.extend(struct.pack("<4sIII", packet_tag, 0x10 if key else 0, len(media), len(packet)))
        media.extend(riff(packet_tag, packet))
    return riff(b"RIFF", b"AVI " + header + riff(b"LIST", media) + riff(b"idx1", index))


def video_avi(width, height, tag, bits, packets, extra=b"", *, rate=24):
    packet_size = max(len(packet) for packet, _ in packets)
    count = len(packets)
    main = struct.pack("<14I", 1000000 // rate, 0, 0, 0x10, count, 0, 1, packet_size, width, height, 0, 0, 0, 0)
    stream = struct.pack(
        "<4s4sIHH8I4h",
        b"vids",
        tag,
        0,
        0,
        0,
        0,
        1,
        rate,
        0,
        count,
        packet_size,
        0xFFFFFFFF,
        0,
        0,
        0,
        width,
        height,
    )
    bitmap = struct.pack("<IiiHH4sIiiII", 40 + len(extra), width, height, 1, bits, tag, 0, 0, 0, 0, 0) + extra
    return avi_file(main, stream, bitmap, b"00dc", packets)


def audio_avi(rate, frames_per_packet, tag, packets, *, description=None):
    count = len(packets)
    largest = max(map(len, packets))
    average = sum(map(len, packets)) * rate // (count * frames_per_packet)
    main = struct.pack(
        "<14I",
        1000000 * frames_per_packet // rate,
        0,
        0,
        0x10,
        count,
        0,
        1,
        largest,
        0,
        0,
        0,
        0,
        0,
        0,
    )
    stream = struct.pack(
        "<4s4sIHH8I4h",
        b"auds",
        bytes(4),
        0,
        0,
        0,
        0,
        frames_per_packet,
        rate,
        0,
        count,
        largest,
        0xFFFFFFFF,
        0,
        0,
        0,
        0,
        0,
    )
    if description is None:
        description = struct.pack("<HHIIHHH", tag, 1, rate, average, 1, 0, 0)
    return avi_file(main, stream, description, b"00wb", ((packet, True) for packet in packets))


def wave_container(format_name, description, frames, payload):
    if format_name == "wav":
        return riff(b"RIFF", b"WAVE" + riff(b"fmt ", description) + riff(b"fact", struct.pack("<I", frames)) + riff(b"data", payload))

    def wave64_chunk(tag, body):
        guid = tag + bytes.fromhex("f3acd3118cd100c04f8edb8a")
        return struct.pack("<16sQ", guid, 24 + len(body)) + body + bytes(-len(body) % 8)

    assert format_name == "w64"
    body = (
        bytes.fromhex("77617665f3acd3118cd100c04f8edb8a")
        + wave64_chunk(b"fmt ", description)
        + wave64_chunk(b"fact", struct.pack("<Q", frames))
        + wave64_chunk(b"data", payload)
    )
    return bytes.fromhex("726966662e91cf11a5d628db04c10000") + struct.pack("<Q", 24 + len(body)) + body


@lru_cache
def elementary_packets(path, stream=""):
    select = ["-select_streams", stream] if stream else []
    packet_table = subprocess.check_output(
        ["ffprobe", "-v", "error", *select, "-show_entries", "packet=pos,size,flags", "-of", "json", path]
    )
    data = path.read_bytes()
    packets = []
    for record in json.loads(packet_table)["packets"]:
        start = int(record["pos"])
        end = start + int(record["size"])
        packets.append((data[start:end], "K" in record["flags"]))
    return packets


def g711(codec):
    muxer = "alaw" if codec == "pcm_alaw" else "mulaw"
    return subprocess.check_output(
        [
            "ffmpeg",
            "-nostdin",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=8000:duration=1.25",
            "-c:a",
            codec,
            "-f",
            muxer,
            "-",
        ]
    )


def lmlm4_records(packets, *, video):
    for frame, key in packets:
        size = len(frame) + 8
        frame_type = (0 if key else 1) if video else 4
        yield struct.pack(">HHI", 0, frame_type, size) + frame + bytes(-size % 512)


def lmlm4_av(video, audio):
    # The board can start recording with an audio packet. This also exercises
    # the MPEG audio signature in the reader's automatic probe.
    timeline = [(index * 24, packet) for index, packet in enumerate(lmlm4_records(audio, video=False))]
    timeline += [(index * 1001 / 30, packet) for index, packet in enumerate(lmlm4_records(video, video=True))]
    return b"".join(packet for _, packet in sorted(timeline, key=lambda event: event[0]))


def pes_timestamp(pts):
    return bytes(
        (
            0x21 | ((pts >> 29) & 0x0E),
            (pts >> 22) & 0xFF,
            1 | ((pts >> 14) & 0xFE),
            (pts >> 7) & 0xFF,
            1 | ((pts << 1) & 0xFE),
        )
    )


def sofdec_adx(data):
    header_size = struct.unpack_from(">H", data, 2)[0] + 4
    frame_size, channels, rate = struct.unpack_from(">BxBI", data, 5)
    blocks_per_packet = 64
    samples_per_packet = blocks_per_packet * (frame_size - 2) * 2
    packet_size = blocks_per_packet * frame_size * channels
    # MPEG-2 pack header followed by the Sofdec private stream marker.
    pack = b"\0\0\1\xba\x44\0\x04\0\x04\x01\x00\x0f\xa3\xf8"
    result = bytearray(pack + b"\0\0\1\xbf\x00\x06Sofdec")
    for index, start in enumerate(range(header_size, len(data), packet_size)):
        payload = data[start : start + packet_size]
        if index == 0:
            payload = data[:header_size] + payload
        timestamp = round(index * samples_per_packet * 90000 / rate)
        result.extend(pack + b"\0\0\1\xc0")
        result.extend(struct.pack(">HBBB", len(payload) + 8, 0x80, 0x80, 5))
        result.extend(pes_timestamp(timestamp) + payload)
    result.extend(b"\0\0\1\xb9")
    return result


def aix(adx):
    start = struct.unpack_from(">H", adx, 2)[0] + 4
    block_size, channels, rate, samples = struct.unpack_from(">BxBII", adx, 5)
    block_samples = (block_size - 2) * 2
    block_bytes = block_size * channels
    end = start + ((samples + block_samples - 1) // block_samples) * block_bytes

    def packet(payload, sequence, duration):
        return struct.pack(">4sIBBHI", b"AIXP", len(payload) + 8, 0, 1, duration, sequence) + payload

    header = bytearray(0x60)
    struct.pack_into(">4sIII", header, 0, b"AIXF", len(header) - 8, 0x01000014, 0x00000800)
    struct.pack_into(">H", header, 24, 1)  # One segment.
    struct.pack_into(">III", header, 0x20, len(header), len(adx), samples)
    struct.pack_into(">B7xIB3x", header, 0x40, 1, rate, channels)
    header.extend(packet(adx[:start], 0, 0))
    interval = block_bytes * 64
    for sequence, offset in enumerate(range(start, end, interval), 1):
        payload = adx[offset : min(offset + interval, end)]
        header.extend(packet(payload, sequence, len(payload) // block_bytes * block_samples))
    header.extend(struct.pack(">4sI", b"AIXE", 0))
    return header


def aax(adx):
    strings = b"AAX\0data\0"
    schema = struct.pack(">BI", 0x5B, len(b"AAX\0"))  # Named data column with a value in each row.
    row = struct.pack(">II", 0, len(adx))
    rows_at = 32 + len(schema)
    strings_at = rows_at + len(row)
    data_at = strings_at + len(strings)
    header = struct.pack(">4sIHHIIIHHI", b"@UTF", data_at + len(adx) - 8, 0, rows_at - 8, strings_at - 8, data_at - 8, 0, 1, len(row), 1)
    return header + schema + row + strings + adx


def fsb(codec):
    rate = PSX_RATE
    format_flag = {
        "pcm_s16le": 0x00000100,
        "adpcm_ima_wav": 0x00400000,
        "adpcm_psx": 0x00800000,
        "adpcm_thp": 0x02000000,
    }[codec]
    if codec == "adpcm_psx":
        payload, frames = psx_frames()
    elif codec == "adpcm_ima_wav":
        block_frames = 65
        frames = round(rate * 1.25 / block_frames) * block_frames
        samples = list(round(10000 * value) for value in tone(rate, frames))
        payload = bytearray()
        for start in range(0, frames, block_frames):
            predictor = samples[start]
            payload.extend(struct.pack("<hBB", predictor, 47, 0))
            payload.extend(pack_nibbles(ima_codes(samples[start + 1 : start + block_frames], predictor, 47), low_first=True))
    elif codec == "adpcm_thp":
        block_frames = 14
        frames = round(rate * 1.25 / block_frames) * block_frames
        codes = list(signed_nibbles(tone(rate, frames)))
        payload = b"".join(b"\x0a" + pack_nibbles(iter(codes[i : i + block_frames])) for i in range(0, frames, block_frames))
    else:
        frames = round(rate * 1.25)
        payload = struct.pack(f"<{frames}h", *(round(10000 * value) for value in tone(rate, frames)))
    header = bytearray(0x98 if codec == "adpcm_thp" else 0x68)
    struct.pack_into("<4s4I", header, 0, b"FSB3", 1, len(header) - 0x18, len(payload), 0x30001)
    struct.pack_into("<H", header, 0x18, len(header) - 0x18)
    struct.pack_into("<4xI", header, 52, frames)
    struct.pack_into("<II6xH", header, 72, format_flag, rate, 1)
    # The THP coefficient table in the extended header is all zero for predictor zero.
    return header + payload


def musx(codec):
    data_offset = 0x800
    rate = 32000
    if codec == "adpcm_psx":
        header = bytearray(data_offset)
        struct.pack_into("<4sII", header, 0, b"MUSX", 0, 201)
        struct.pack_into("<I", header, 24, data_offset)
        mono, _ = psx_frames(rate, blocks_per_chunk=8)
        chunk_bytes = 0x80
        payload = b"".join(mono[i : i + chunk_bytes] * 2 for i in range(0, len(mono), chunk_bytes))
    else:
        header = bytearray(data_offset)
        struct.pack_into("<4s3I4s", header, 0, b"MUSX", 0, 10, 0, b"XE__")
        block_frames = 56
        frames = round(rate * 1.25 / block_frames) * block_frames
        codes = pack_nibbles(ima_codes((round(10000 * value) for value in tone(rate, frames)), 0, 0))
        block_bytes = block_frames // 2
        payload = b"".join((bytes(4) + codes[i : i + block_bytes]) * 2 for i in range(0, len(codes), block_bytes))
    struct.pack_into("<I", header, 4, len(header) + len(payload))
    return header + payload


def rpl(codec, rate=8000):
    samples = [round(10000 * value) for value in tone(rate, round(rate * 1.25))]
    kind, depth = {
        "pcm_s16le": ("1", "16"),
        "pcm_u8": ("1", "8 unsigned"),
        "pcm_s8": ("1", "8 linear"),
        "pcm_vidc": ("1", "8"),
        "adpcm_ima_acorn": ("2 ADPCM", "4"),
        "adpcm_ima_escape": ("101", "4"),
    }[codec]
    frames = 500
    if codec == "adpcm_ima_acorn":
        blocks = []
        for start in range(0, len(samples), frames):
            predictor = samples[max(0, start - 1)]
            codes = ima_codes(samples[start : start + frames], predictor, 47)
            blocks.append(struct.pack("<hH", predictor, 47) + pack_nibbles(codes, low_first=True))
    else:
        if codec == "adpcm_ima_escape":
            payload = pack_nibbles(ima_codes(samples, 0, 0, escape=True))
            block_bytes = frames // 2
        elif codec == "pcm_s16le":
            payload = struct.pack(f"<{len(samples)}h", *samples)
            block_bytes = 2 * frames
        else:
            if codec == "pcm_vidc":
                payload = vidc(rate)
            elif codec == "pcm_u8":
                payload = bytes(128 + (sample >> 8) for sample in samples)
            else:
                payload = bytes((sample >> 8) & 255 for sample in samples)
            block_bytes = frames
        blocks = [payload[i : i + block_bytes] for i in range(0, len(payload), block_bytes)]

    data_at = 512
    data = b"".join(blocks)
    fields = [
        "ARMovie",
        "Authored audio",
        "",
        "",
        "0",
        "0",
        "0",
        "0",
        "24",
        kind,
        str(rate),
        "1",
        depth,
        "1",
        str(len(blocks) - 1),
        "0",
        "0",
        str(data_at + len(data)),
        "0",
        "0",
    ]
    header = ("\n".join(fields) + "\n").encode("ascii").ljust(data_at, b"\0")
    index = bytearray()
    position = data_at
    for block in blocks:
        index.extend(f"{position}, 0; {len(block)}\n".encode("ascii"))
        position += len(block)
    return header + data + index


def boa(wave):
    fmt = wave.index(b"fmt ")
    start = wave.index(b"data", fmt + 8)
    channels, rate, block = struct.unpack_from("<HI4xH", wave, fmt + 10)
    size = struct.unpack_from("<I", wave, start + 4)[0]
    payload = wave[start + 8 : start + 8 + size]
    assert channels == 1 and len(payload) % block == 0
    header = bytearray(2096)
    struct.pack_into("<5IBI", header, 0, 1, 0, rate, channels, len(header), 0, block)
    struct.pack_into("<H", header, 25, len(header))
    struct.pack_into("<I", header, 48, len(payload))
    return header + payload


def threedostr():
    aiff = aiff_dpcm(False)
    start = aiff.index(b"SSND")
    size, offset = struct.unpack_from(">II", aiff, start + 4)
    samples = aiff[start + 16 + offset : start + 8 + size]

    def chunk(payload):
        return b"SNDS" + struct.pack(">I", len(payload) + 8) + payload

    header = struct.pack(">8x4s24xII4s4xI", b"SHDR", PSX_RATE, 1, b"SDX2", len(samples) + 1)
    result = bytearray(chunk(header))
    for start in range(0, len(samples), 1024):
        data = samples[start : start + 1024]
        result.extend(chunk(struct.pack(">8x4sI", b"SSMP", len(data)) + data))
    return result


def laf(codec):
    quality = LAF_QUALITIES[codec]
    rate = 48000
    head = struct.pack("<BBIffBIQ", quality, 0, 1, 0, 0, 0, rate, 2 * rate)
    samples = list(tone(rate, rate))
    if quality == 0:
        frame = bytes(128 + round(sample * 90) for sample in samples)
    elif quality == 1:
        frame = struct.pack(f"<{rate}h", *(round(sample * 24000) for sample in samples))
    elif quality == 2:
        frame = struct.pack(f"<{rate}f", *(sample * 0.7 for sample in samples))
    else:
        frame = b"".join(round(sample * 6000000).to_bytes(3, "little", signed=True) for sample in samples)
    # The bitmap in each one-second chunk marks the mono track as present.
    return b"LIMITLESSHEAD" + head + (b"\x01" + frame) * 2


def luodat(packets, width, height):
    header = bytearray(0x2000)
    header[:4] = b"luo "
    header[-4:] = b" oul"
    for index, (data, key) in enumerate(packets):
        block = struct.pack("<4s4I16xI4xI4xQI60x4s", b"liu ", 1, width, height, 24, key, 0, index, len(data), b" uil")
        header.extend(block + data)
    return header


def lvf(packets, width, height, with_audio):
    def chunk(tag, payload):
        return struct.pack("<4sI", tag, len(payload)) + payload

    header = bytearray(0x808)
    struct.pack_into("<4s12xI", header, 0, b"LVFF", 2 if with_audio else 1)
    video = list(packets)
    stream_header = chunk(b"00fm", struct.pack("<4xII4x4s", width, height, b"H264"))
    records = [(round(index * 1000 / 24), b"00dc", 4096 if key else 0, frame) for index, (frame, key) in enumerate(video)]
    if with_audio:
        rate = 8000
        stream_header += chunk(b"01fm", struct.pack("<HHH8xB", 1, 1, rate, 16))
        samples = struct.pack("<10000h", *(round(sample * 10000) for sample in tone(rate, 10000)))
        records.extend((i // 16, b"01wb", 4096, samples[i : i + 640]) for i in range(0, len(samples), 640))
    header[0x408 : 0x408 + len(stream_header)] = stream_header
    for timestamp, tag, flags, frame in sorted(records):
        header.extend(chunk(tag, struct.pack("<II", timestamp, flags) + frame))
    return header


def ifv(packets):
    rate = 8000
    samples = struct.pack("<10000h", *(round(10000 * value) for value in tone(rate, 10000)))
    audio = [samples[i : i + 640] for i in range(0, len(samples), 640)]
    video_index, audio_index = 0xF8, 0x14918
    header = bytearray(audio_index + 24 * len(audio))
    header[:17] = bytes.fromhex("11d2d3abbaa9cf118ee600c00c20536544")
    struct.pack_into("<HH8x4s", header, 0x5C, 176, 144, b"H264")
    struct.pack_into("<I4s", header, 0x98, rate, b"GRAW")
    struct.pack_into("<II", header, 0xE4, len(packets), len(audio))
    payload = bytearray()
    for start, stride, layout, items in (
        (video_index, 28, "<II8xI8x", [(round(i * 1000 / 24), data) for i, (data, _) in enumerate(packets)]),
        (audio_index, 24, "<II8xI4x", [(i * 40, data) for i, data in enumerate(audio)]),
    ):
        for index, (pts, data) in enumerate(items):
            struct.pack_into(layout, header, start + index * stride, len(header) + len(payload), len(data), pts)
            payload.extend(data)
    return header + payload


@lru_cache(maxsize=1)
def simbiosis_imx():
    frames, rate = 30, 22050
    samples = bytes(round(128 + 45 * value) for value in tone(rate, round(rate * 1.25)))
    data = bytearray(struct.pack("<4sIHH10x", b"IMAX", frames, 24, 0x102))

    def chunk(tag, payload):
        data.extend(struct.pack("<II", len(payload), tag))
        data.extend(payload)

    chunk(0xAA98, bytes((0, 0, 0, 63, 0, 0, 0, 0, 63)))
    for i in range(frames):
        start, end = round(i * rate / 24), round((i + 1) * rate / 24)
        chunk(0xAA99, samples[start:end])
        # PAL8 frames use run-length fills of up to 63 pixels.
        index = 1 if i < frames // 2 else 2
        runs, remainder = divmod(320 * 160, 63)
        chunk(0xAA97, bytes((0xBF, index)) * runs + bytes((0x80 | remainder, index)))
    chunk(0xAAFF, b"")
    return bytes(data)


def msp(width, height, compressed, bright_on_left):
    header = bytearray(32)
    struct.pack_into("<4s4H", header, 0, b"LinS" if compressed else b"DanM", width, height, 1, 1)
    checksum = 0
    for (word,) in struct.iter_unpack("<H", header[:24]):
        checksum ^= word
    struct.pack_into("<H", header, 24, checksum)
    halves = (255, 0) if bright_on_left else (0, 255)
    half_width = width // 16
    if compressed:
        row = b"".join(bytes((0, half_width, color)) for color in halves)
        return header + struct.pack("<H", len(row)) * height + row * height
    row = b"".join(bytes([color]) * half_width for color in halves)
    return header + row * height


FRM_MODES = {
    # Pixels for the bright and dark halves. The BGRA file stores inverted alpha.
    "rgb555": (1, b"\xff\x7f", b"\0\0"),
    "rgb0": (2, b"\xff\xff\xff\0", bytes(4)),
    "rgb24": (3, b"\xff\xff\xff", bytes(3)),
    "bgr0": (4, b"\xff\xff\xff\0", bytes(4)),
    "bgra": (5, b"\xff\xff\xff\0", bytes(4)),
}


def frm(width, height, mode, bright_on_left):
    depth, light, dark = FRM_MODES[mode]
    halves = (light, dark) if bright_on_left else (dark, light)
    row = b"".join(pixel * (width // 2) for pixel in halves)
    return struct.pack("<3sBHH", b"FRM", depth, width, height) + row * height


def mgsts(packets, width, height):
    header = bytearray(80)
    struct.pack_into(">4I", header, 0, 0x0E, len(header), 0, 0x34)
    struct.pack_into(">IfII", header, 28, len(packets), 24, width, height)
    header[56:60] = b"2GPM"  # Little-endian MPEG-2 FourCC in this big-endian header.
    data = bytearray(header)
    for frame, _ in packets:
        data.extend(struct.pack(">4I", 0, len(frame) + 16, 0, len(frame)))
        data.extend(frame)
    return data


@lru_cache(maxsize=1)
def mtv():
    width, height, audio_bitrate = 96, 64, 32
    tone = subprocess.check_output(
        [
            "ffmpeg",
            "-nostdin",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=44100:duration=1.25",
            "-c:a",
            "libmp3lame",
            "-b:a",
            "32k",
            "-write_xing",
            "0",
            "-id3v2_version",
            "0",
            "-f",
            "mp3",
            "-",
        ]
    )
    audio_bytes = 500
    frames = (len(tone) + audio_bytes - 1) // audio_bytes
    frame_bytes = width * height * 2
    header = bytearray(512)
    struct.pack_into("<3sII", header, 0, b"AMV", len(header) + frames * (512 + frame_bytes), frames)
    struct.pack_into("<3sH3sB3H4xH", header, 43, b"MP3", audio_bitrate, b"RGB", 16, width, height, frame_bytes, 1)
    for index in range(frames):
        block = tone[index * audio_bytes : (index + 1) * audio_bytes]
        header.extend(bytes(12) + block.ljust(audio_bytes, b"\0"))
        color = b"\xf8\x00" if index < frames // 2 else b"\x00\x1f"
        header.extend(color * (width * height))
    return bytes(header)


def write_kux(path, flv):
    offset = 0xE40000
    first_tag = struct.unpack_from(">I", flv, 5)[0]
    with path.open("wb") as file:
        file.write(b"KDK\0\0")
        file.seek(offset)
        file.write(flv[:5] + struct.pack(">I", offset + first_tag) + flv[9:])


def pmp(packets, codec, width, height):
    codec_id = 1 if codec == "h264" else 0
    header = struct.pack("<4s8IH10x2I", b"pmpm", 1, codec_id, len(packets), width, height, 1, 24, 0, 0, 48000, 0)
    frames = [struct.pack("<B8xI", 1, len(data)) + data for data, _ in packets]
    index = b"".join(struct.pack("<I", len(frame) * 2 + key) for frame, (_, key) in zip(frames, packets, strict=True))
    return header + index + b"".join(frames)


def iv8(packets):
    data = bytearray()
    sequence = 0
    for index, (frame, _) in enumerate(packets):
        # The first 940-byte fragment carries IndigoVision's probe signature.
        cut = 940 if index == 0 else len(frame) // 2
        assert 0 < cut < len(frame)
        for flags, part in ((0x8060, frame[:cut]), (0xE0, frame[cut:])):
            data.extend(struct.pack(">4H2I", 0x101, len(part) + 12, flags, sequence, index * 3750, 0))
            data.extend(part)
            sequence += 1
    return data


def nc(packets):
    return b"".join(b"\0\0\1\xa5\0" + struct.pack("<H9x", len(frame)) + frame for frame, _ in packets)


def scd(payload, codec):
    # Version 3, one track, no auxiliary tables or loop points.
    track_start = 52
    header = struct.pack(">8sIHHI", b"SEDBSSCF", 3, 260, 20, track_start + 32 + len(payload))
    table = struct.pack(">4H6I", 0, 1, 0, 0, 0, 48, 0, 0, 0, track_start)
    codec_tag, rate = (0, 8000) if codec == "pcm_s16be" else (7, 47999)
    track = struct.pack(">8I", len(payload), 1, rate, codec_tag, 0, 0, 0, 0)
    return header + table + track + payload


def sdr2(packets, pcm):
    def record(payload, *, video=False, key=False):
        return struct.pack("<I4xI6xI30x", 4096 if key else 0, 52 + len(payload), video) + payload

    data = bytearray(0xA8)
    struct.pack_into("<4s16x3I", data, 0, b"SRA\1", 24, 176, 144)
    for index, (frame, key) in enumerate(packets):
        data.extend(record(frame, video=True, key=key))
        first = round(index * 8000 / 24) * 2
        last = round((index + 1) * 8000 / 24) * 2
        data.extend(record(pcm[first:last]))
    for offset in range(last, len(pcm), 640):
        data.extend(record(pcm[offset : offset + 640]))
    return data


def siff(body, payload):
    body += b"BODY" + struct.pack(">I", len(payload)) + payload
    return b"SIFF" + struct.pack(">I", len(body)) + body


def siff_video(width, height):
    header = b"VBV1VBHD" + struct.pack(">I", 32) + struct.pack("<3H4x3H16x", 1, width, height, 12, 0, 0)
    packets = bytearray()
    blocks = width * height // 16
    for index in range(12):
        if index in (0, 6):
            # Fill 4×4 blocks with index one, and assign the palette entry red or blue.
            fills = b"\xaa\1\1\1\1" * (blocks // 4)
            rgb = b"\xff\0\0" if index == 0 else b"\0\0\xff"
            packet = struct.pack("<HI", 0x18, len(fills) + 4) + fills + struct.pack("<I", 9) + b"\1\1" + rgb
        else:
            skip = bytes(blocks // 4)
            packet = struct.pack("<HI", 8, len(skip) + 4) + skip
        packets.extend(struct.pack("<I", len(packet) + 4) + packet)
    return siff(header, packets)


def pva(packets, video):
    data = bytearray()
    sequence = 0
    for index, (packet, _) in enumerate(packets):
        if video:
            # Split a picture over multiple transport records. Only the first carries its timestamp.
            parts = [packet[start : start + 4096] for start in range(0, len(packet), 4096)]
            parts[0] = struct.pack(">I", index * 3750) + parts[0]
        else:
            header = b"\0\0\x01\xc0" + struct.pack(">HBBB", len(packet) + 8, 0x80, 0x80, 5)
            parts = [header + pes_timestamp(index * 2160) + packet]
        for part, payload in enumerate(parts):
            flags = 0x10 if video and part == 0 else 0
            data.extend(struct.pack(">2sBBBBH", b"AV", 1 if video else 2, sequence % 256, 0x55, flags, len(payload)))
            data.extend(payload)
            sequence += 1
    return data


def dhav(packets, codec, width, height, *, rate=8000, packet_samples=320):
    video = width > 0
    kind = {
        "h264": 8,
        "hevc": 12,
        "mpeg4": 1,
        "mjpeg": 3,
        "pcm_alaw": 14,
        "pcm_mulaw": 10,
        "pcm_s8": 7,
        "pcm_s16le": 12,
        "aac": 26,
        "mp2": 31,
        "mp3": 33,
        "adpcm_ms": 13,
    }[codec]
    if video:
        fields = bytes((0x80, 0, width // 8, height // 8, 0x81, 0, kind, 24))
        interval = 1000 / 24
    else:
        rate_code = {8000: 2, 48000: 9}[rate]
        fields = bytes((0x83, 1, kind, rate_code))
        interval = 1000 * packet_samples / rate
    data = bytearray()
    for index, (packet, key) in enumerate(packets):
        milliseconds = round(index * interval)
        frame_type = (0xFD if key else 0xFC) if video else 0xF0
        length = len(packet) + 32 + len(fields)
        date = (24 << 26) | (1 << 22) | (1 << 17) | (milliseconds // 1000)
        data.extend(struct.pack("<4sB3xIIIHBx", b"DHAV", frame_type, index, length, date, milliseconds % 1000, len(fields)))
        data.extend(fields)
        data.extend(packet)
        data.extend(struct.pack("<4sI", b"dhav", length))
    return data


def dhav_audio(output, codec):
    if codec in ("pcm_alaw", "pcm_mulaw", "pcm_s8", "pcm_s16le"):
        if codec in ("pcm_alaw", "pcm_mulaw"):
            signal = g711(codec)
            sample_bytes = 1
        else:
            sample_bytes = 1 if codec == "pcm_s8" else 2
            amplitude = ((1 << (8 * sample_bytes - 1)) - 1) * 0.16
            signal = b"".join(round(value * amplitude).to_bytes(sample_bytes, "little", signed=True) for value in tone(8000, 10000))
        size = 320 * sample_bytes
        return dhav(((signal[start : start + size], True) for start in range(0, len(signal), size)), codec, 0, 0)
    if codec == "adpcm_ms":
        wave = (output / "codecs-adpcm-ms.wav").read_bytes()
        fmt = wave.index(b"fmt ")
        audio = wave.index(b"data", fmt + 8) + 8
        rate, _, align = struct.unpack_from("<IIH", wave, fmt + 12)
        length = struct.unpack_from("<I", wave, audio - 4)[0]
        samples = struct.unpack_from("<H", wave, fmt + 26)[0]
        assert align > 0 and length % align == 0
        packets = [(wave[start : start + align], True) for start in range(audio, audio + length, align)]
    else:
        source, samples = {
            "aac": ("codecs-aac-lc.aac", 1024),
            "mp2": ("codecs-mp2.mp2", 1152),
            "mp3": ("codecs-mp3-fixed.mp3", 1152),
        }[codec]
        rate = 48000
        packets = elementary_packets(output / source)
    return dhav(packets, codec, 0, 0, rate=rate, packet_samples=samples)


def hxvs(packets, width, height, video_codec, alaw):
    data = bytearray(struct.pack("<4s2I4x", b"HXVS" if video_codec == "h264" else b"HXVT", width, height))
    records = []
    for index, (packet, key) in enumerate(packets):
        timestamp = round(index * 1000 / 24)
        # The camera's records contain one Annex B NAL unit each.
        for nal in re.findall(rb"\x00\x00\x00?\x01.*?(?=\x00\x00\x00?\x01|$)", packet, re.S):
            records.append((timestamp, struct.pack("<4sIII", b"HXVF", len(nal), timestamp, key) + nal))
    for offset in range(0, len(alaw), 320):
        timestamp = offset // 8
        payload = b"\0\0\0\x01" + alaw[offset : offset + 320]
        records.append((timestamp, struct.pack("<4sIII", b"HXAF", len(payload), timestamp, 0) + payload))
    for _, record in sorted(records, key=lambda pair: pair[0]):
        data.extend(record)
    return data


def lxf_packet(kind, fields, payload):
    header = b"LEITCH\0\0" + struct.pack("<III12x5I4x", 0, 60, kind, *fields)
    checksum = -sum(struct.unpack("<14I", header)) & 0xFFFFFFFF
    return header + struct.pack("<I", checksum) + payload


def lxf(packets, depth, video_codec="mpeg2video"):
    sample_rate = 48000
    frames_per_packet = sample_rate // 25
    packet_count = 31
    header = bytearray(120)
    struct.pack_into("<I", header, 32, packet_count)
    struct.pack_into("<I", header, 40, LXF_PICTURES[video_codec])
    data = bytearray(lxf_packet(2, (0, len(header), 0, 0, 0), header))
    amplitude = ((1 << (depth - 1)) - 1) * 0.16
    samples = [round(amplitude * sample) for sample in tone(sample_rate, packet_count * frames_per_packet)]
    for index in range(packet_count):
        start = index * frames_per_packet
        block = samples[start : start + frames_per_packet]
        if depth == 20:
            mask = (1 << 20) - 1
            channel = b"".join(((a & mask) | ((b & mask) << 20)).to_bytes(5, "little") for a, b in zip(block[::2], block[1::2]))
        else:
            channel = b"".join(value.to_bytes(depth // 8, "little", signed=True) for value in block)
        # The reader derives the PAL clock from the audio block before publishing picture timestamps.
        data.extend(lxf_packet(1, (0, 0, depth << 6 | depth, 3, len(channel)), channel * 2))
        if index < len(packets):
            video, key = packets[index]
            data.extend(lxf_packet(0, (0 if key else 2 << 22, len(video), 0, 0, 0), video))
    return data


def ser(fixture):
    width, height = fixture.width, fixture.height
    bgr = fixture.name.startswith("bgr16-")
    frames = 25
    pixels = subprocess.check_output(
        [
            "ffmpeg",
            "-nostdin",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            fixture.source,
            "-frames:v",
            str(frames),
            "-pix_fmt",
            "bgr48le" if bgr else "rgb24",
            "-f",
            "rawvideo",
            "-",
        ]
    )
    return b"LUCAM-RECORDER" + struct.pack("<7I136x", 0, 101 if bgr else 100, 0, width, height, 16 if bgr else 8, frames) + pixels


def cdg():
    def command(instruction, data):
        return bytes((9, instruction, 0, 0)) + data.ljust(16, b"\0") + bytes(4)

    # Palette entry zero also shows red while the first display buffer is initialized.
    palette = b"".join(bytes((color >> 6, color & 63)) for color in (0xF00, 0xF00, 0x00F))
    return command(30, palette) + command(1, b"\x01") * 149 + command(1, b"\x02") * 150


def generate(output, fixture):
    fmt, codec = fixture.muxer, fixture.codec
    video = fixture.width > 0
    if fmt == "3dostr":
        data = threedostr()
    elif fmt == "aax":
        data = aax((output / "codecs-adpcm-adx.adx").read_bytes())
    elif fmt == "aix":
        data = aix((output / "codecs-adpcm-adx.adx").read_bytes())
    elif fmt == "boa":
        data = boa((output / "codecs-adpcm-ms.wav").read_bytes())
    elif fmt == "kux":
        write_kux(output / fixture.filename, (output / "codecs-spark.flv").read_bytes())
        return
    elif fmt == "scd":
        if codec == "pcm_s16be":
            payload = struct.pack(">10000h", *(round(sample * 10000) for sample in tone(8000, 10000)))
        else:
            payload = b"".join(packet for packet, _ in elementary_packets(output / "codecs-mp3-fixed.mp3"))
        data = scd(payload, codec)
    elif fmt == "sdr2":
        pcm = struct.pack("<10000h", *(round(sample * 10000) for sample in tone(8000, 10000)))
        data = sdr2(elementary_packets(output / VIDEO_SOURCES["h264"]), pcm)
    elif fmt == "siff":
        header = b"SOUNSHDR" + struct.pack(">I", 8) + struct.pack("<IHH", 0, 8000, 8)
        pcm = bytes(round(128 + 80 * sample) for sample in tone(8000, 10000))
        data = siff(header, pcm)
    elif fmt == "cdg":
        data = cdg()
    elif fmt == "ser":
        data = ser(fixture)
    elif fmt == "laf":
        data = laf(codec)
    elif fmt == "mgsts":
        data = mgsts(elementary_packets(output / VIDEO_SOURCES[codec]), fixture.width, fixture.height)
    elif fmt == "mtv":
        data = mtv()
    elif fmt == "ifv":
        data = ifv(elementary_packets(output / VIDEO_SOURCES["h264"]))
    elif fmt == "fsb":
        data = fsb(codec)
    elif fmt == "musx":
        data = musx(codec)
    elif fmt == "rpl":
        data = rpl(codec, 22050 if codec == "pcm_vidc" else 8000)
    elif fmt == "simbiosis_imx":
        data = simbiosis_imx()
    elif fmt in ("luodat", "lvf"):
        packets = elementary_packets(output / VIDEO_SOURCES["h264"])
        data = luodat(packets, fixture.width, fixture.height) if fmt == "luodat" else lvf(packets, 176, 144, with_audio=not video)
    elif fmt == "lxf":
        picture = codec if video else "mpeg2video"
        data = lxf(elementary_packets(output / VIDEO_SOURCES[picture], "v:0"), LXF_DEPTHS.get(codec, 20), picture)
    elif fmt == "hxvs":
        mode = codec if video else "h264"
        records = elementary_packets(output / VIDEO_SOURCES[mode])
        data = hxvs(records, 176, 144, mode, b"" if video else g711(codec))
    elif fmt == "dhav" and not video:
        data = dhav_audio(output, codec)
    else:
        if video:
            packets = elementary_packets(output / VIDEO_SOURCES[codec])
        else:
            # The codecs group generates video fixtures first and the raw MPEG audio source before these audio fixtures.
            packets = elementary_packets(output / "codecs-mp2.mp2")
        if fmt == "dhav":
            data = dhav(packets, codec, fixture.width, fixture.height)
        elif fmt == "iv8":
            data = iv8(packets)
        elif fmt == "nc":
            data = nc(packets)
        elif fmt == "pmp":
            data = pmp(packets, codec, fixture.width, fixture.height)
        elif fmt == "lmlm4":
            if fixture.name.endswith("-av.lmlm4"):
                data = lmlm4_av(packets, elementary_packets(output / "codecs-mp2.mp2"))
            else:
                data = b"".join(lmlm4_records(packets, video=video))
        else:
            data = pva(packets, video)
    (output / fixture.filename).write_bytes(data)
