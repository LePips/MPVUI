"""Package known encoded pictures and tones in additional broadcast readers."""

import re
import struct

from generate_dolby_vision import mpeg2_crc
from generate_legacy_audio import chunk, tone
from generate_legacy_wrappers import elementary_packets, g711


GXF_VIDEO = {
    "mjpeg": (3, "codecs-mjpeg.avi", 24),
    "mpeg1video": (22, "codecs-mpeg1.m1v", 24),
    "h264": (29, "codecs-h264.h264", 24),
    "dnxhd": (30, "codecs-dnxhr.dnxhd", 25),
}
GXF_AUDIO = ("ac3", "pcm_s24le")
MXF_PCM = ("pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be")
MXF_FILL = bytes.fromhex("060e2b34010101020301021001000000")
MXF_WAVE_ESSENCE = bytes.fromhex("060e2b34010201010d01030116010100")
MXF_BIG_ENDIAN_PCM = bytes.fromhex("060e2b3404010107040202017e000000")
WTV_MEDIA_BASE = bytes.fromhex("00001000800000aa00389b71")
WTV_MPEG2_VIDEO = bytes.fromhex("26806de046dbcf11b4d100805f6cbbea")
WTV_MPEG1_PAYLOAD = bytes.fromhex("81eb36e44f52ce119f530020af0ba770")
WTV_MPEG2_PES = bytes.fromhex("20806de046dbcf11b4d100805f6cbbea")
WTV_DVB_SUBTITLE = bytes.fromhex("c3cbff34b3d571419002d4c60301697f")
WTV_FORMAT_NONE = bytes.fromhex("d617640f18c3d011a43f00a0c9223196")
WTV_TIMESTAMP = bytes.fromhex("5b05e61b97a9494388171a655a298a97")
WTV_DATA = bytes.fromhex("95c3d2c27e9ada118bf70007e95ead8d")
WTV_SYNC = bytes.fromhex("97c3d2c27e9ada118bf70007e95ead8d")


def wtv_offsets(media, guid):
    return [match.start() for match in re.finditer(re.escape(guid), media)]


def wtv_track_records(media, track):
    def records(guid):
        return {
            struct.unpack_from("<Q", media, position + 24)[0]: position
            for position in wtv_offsets(media, guid)
            if struct.unpack_from("<I", media, position + 20)[0] & 0x7FFF == track
        }

    data, timestamps = records(WTV_DATA), records(WTV_TIMESTAMP)
    assert data and data.keys() == timestamps.keys()
    return [(position, timestamps[serial]) for serial, position in data.items()]


def replace_wtv_packet(media, position, packet):
    original_size = struct.unpack_from("<I", media, position + 16)[0]
    size = 32 + len(packet)
    padded = packet + bytes(-size % 8)
    gap = (original_size + 7) // 8 * 8 - 32 - len(padded)
    assert gap >= 32
    # Preserve the physical offsets referenced by the timeline and sector tables.
    padding = struct.pack("<16sIIQ", WTV_SYNC, gap, 0, 0).ljust(gap, b"\0")
    struct.pack_into("<I", media, position + 16, size)
    start = position + 32
    media[start : start + len(padded) + gap] = padded + padding


def wtv_mjpeg(template, pictures):
    media = bytearray(template)
    descriptions = wtv_offsets(media, WTV_MPEG2_VIDEO)
    assert len(descriptions) == 2
    for position in descriptions:
        media[position : position + 16] = b"MJPG" + WTV_MEDIA_BASE
    records = wtv_track_records(media, 2)
    for index, (position, _) in enumerate(records):
        replace_wtv_packet(media, position, pictures[index * len(pictures) // len(records)])
    return media


def wtv_mp1(template, packets):
    media = bytearray(template)
    descriptions = wtv_offsets(media, b"auds" + WTV_MEDIA_BASE)
    assert len(descriptions) == 2
    for position in descriptions:
        body = position + 64
        assert struct.unpack_from("<I", media, position + 60)[0] == 72
        wave = struct.pack("<HHIIHHH", 0x50, 1, 48000, 16000, 128, 0, 22)
        wave += struct.pack("<HIHHHHII", 1, 128000, 8, 0, 1, 0x10, 0, 0)
        media[body : body + 56] = wave + WTV_MPEG1_PAYLOAD
    records = wtv_track_records(media, 2)
    assert len(records) == len(packets)
    for (position, _), packet in zip(records, packets, strict=True):
        replace_wtv_packet(media, position, packet)
    return media


def wtv_dvb(template, cues):
    media = bytearray(template)
    descriptions = wtv_offsets(media, b"auds" + WTV_MEDIA_BASE)
    assert len(descriptions) == 2
    for position in descriptions:
        end = position + 64 + struct.unpack_from("<I", media, position + 60)[0]
        media[position : position + 16] = WTV_MPEG2_PES
        media[end - 32 : end] = WTV_DVB_SUBTITLE + WTV_FORMAT_NONE
    records = wtv_track_records(media, 3)
    selected = {}
    for ticks, packet in cues:
        position, _ = min(records, key=lambda pair: abs(struct.unpack_from("<q", media, pair[1] + 40)[0] - ticks))
        assert position not in selected
        selected[position] = packet
    for position, timestamp in records:
        if position in selected:
            replace_wtv_packet(media, position, selected[position])
        else:
            # Stream ID zero suppresses the remaining audio placeholders.
            struct.pack_into("<I", media, position + 20, 0)
            struct.pack_into("<I", media, timestamp + 20, 0)
    return media


def jpeg2000_program_map(transport):
    data = bytearray(transport)
    pmt_pid = None
    updated = 0
    for position in range(0, len(data), 188):
        packet = data[position : position + 188]
        pid = (packet[1] & 0x1F) << 8 | packet[2]
        if not packet[1] & 0x40 or pid not in (0, pmt_pid):
            continue
        pointer = 4 + (1 + packet[4] if packet[3] & 0x20 else 0)
        section = pointer + 1 + packet[pointer]
        length = (packet[section + 1] & 0x0F) << 8 | packet[section + 2]
        crc_at = section + 3 + length - 4
        if pid == 0:
            pmt_pid = (packet[section + 10] & 0x1F) << 8 | packet[section + 11]
            continue
        program_info = (packet[section + 10] & 0x0F) << 8 | packet[section + 11]
        stream_type = section + 12 + program_info
        # The temporary mux has only the JPEG 2000 track, marked as private data.
        assert packet[stream_type] == 0x06 and crc_at < len(packet)
        assert mpeg2_crc(packet[section : crc_at + 4]) == 0
        packet[stream_type] = 0x21
        struct.pack_into(">I", packet, crc_at, mpeg2_crc(packet[section:crc_at]))
        data[position : position + 188] = packet
        updated += 1
    assert updated > 0
    return data


def ogg_dirac(packets):
    sequence = packets[0][0]
    assert sequence[:5] == b"BBCD\0"
    sequence = sequence[: struct.unpack_from(">I", sequence, 5)[0]]
    packets = [sequence, *(packet for packet, _ in packets)]
    pages = bytearray()
    page_index = 0
    for index, packet in enumerate(packets):
        whole, tail = divmod(len(packet), 255)
        lacing = bytes((255,)) * whole + bytes((tail,))
        cursor = 0
        for start in range(0, len(lacing), 255):
            segments = lacing[start : start + 255]
            continued = start != 0
            complete = start + len(segments) == len(lacing)
            flags = (1 if continued else 0) | (2 if index == 0 else 0)
            if complete and index == len(packets) - 1:
                flags |= 4
            # Progressive pictures advance two fields on the Dirac granule clock.
            granule = max(0, index - 1) << 32 if complete else (1 << 64) - 1
            payload = packet[cursor : cursor + sum(segments)]
            page = bytearray(struct.pack("<4sBBQII4xB", b"OggS", 0, flags, granule, 0x4D505655, page_index, len(segments)))
            page.extend(segments + payload)
            struct.pack_into("<I", page, 22, mpeg2_crc(page, initial=0))
            pages.extend(page)
            cursor += len(payload)
            page_index += 1
    return pages


def gxf_packet(kind, body):
    padding = bytes(-len(body) % 4)
    return struct.pack(">4xBBI4xBB", 1, kind, 16 + len(body) + len(padding), 0xE1, 0xE2) + body + padding


def gxf(output, codec):
    if codec in GXF_VIDEO:
        tag, name, rate = GXF_VIDEO[codec]
        packets = [packet for packet, _ in elementary_packets(output / name, "v:0")]
        fields_per_packet, samples_per_packet = 2, 0
    elif codec == "ac3":
        tag, rate, fields_per_packet, samples_per_packet = 17, 25, 1.6, 0
        packets = [packet for packet, _ in elementary_packets(output / "codecs-ac3.ac3")]
    else:
        assert codec == "pcm_s24le"
        tag, rate, fields_per_packet, samples_per_packet = 9, 25, 2, 1920
        pcm = b"".join(round(value * 0x160000).to_bytes(3, "little", signed=True) for value in tone(48000, 32 * samples_per_packet))
        size = samples_per_packet * 3
        packets = [pcm[offset : offset + size] for offset in range(0, len(pcm), size)]

    def tag_value(number, value):
        return struct.pack(">BBI", number, 4, value)

    duration = round(len(packets) * fields_per_packet)
    material = tag_value(0x41, 0) + tag_value(0x42, duration)
    track = tag_value(0x50, {24: 7, 25: 6}[rate]) + tag_value(0x52, 2)
    mapping = b"\xe0\xff" + struct.pack(">H", len(material)) + material
    mapping += struct.pack(">HBBH", 4 + len(track), 0x80 | tag, 0xC0, len(track)) + track

    # The track map establishes the clock. The optional UMF repeats that rate.
    umf = bytes(53) + struct.pack("<I", {24: 0x100, 25: 0x200}[rate])
    media = bytearray(gxf_packet(0xBC, mapping) + gxf_packet(0xFD, umf))
    for index, packet in enumerate(packets):
        field = round(index * fields_per_packet)
        info = samples_per_packet or len(packet)
        preamble = struct.pack(">BBIIIBx", tag, 0, field, info, field, 1)
        media.extend(gxf_packet(0xBF, preamble + packet))
    return media + gxf_packet(0xFB, b"")


def mxf_elements(data):
    position = 0
    while position < len(data):
        key = bytes(data[position : position + 16])
        assert key.startswith(b"\x06\x0e\x2b\x34")
        length = data[position + 16]
        count = length & 0x7F if length >= 128 else 0
        start = position + 17 + count
        length = int.from_bytes(data[position + 17 : start], "big") if count else length
        end = start + length
        assert end <= len(data)
        yield key, position, start, end
        position = end


def mxf_pcm(template, codec):
    assert codec in MXF_PCM and codec != "pcm_s24le"
    media = bytearray(template)
    width = 4 if "32" in codec else 3
    order = "big" if codec.endswith("be") else "little"
    elements = tuple(mxf_elements(media))
    replacements = {0x3D01: width * 8, 0x3D0A: width, 0x3D09: width * 48000, 0x3F05: width}
    duration_fields = {0x0202, 0x3002, 0x3F0D}
    sound_descriptor = None
    filled_essence = False
    for index, (key, position, start, end) in enumerate(elements):
        if key == MXF_WAVE_ESSENCE:
            assert (end - start) % width == 0
            scale = (1 << (8 * width - 1)) // 5
            samples = tone(48000, (end - start) // width)
            media[start:end] = b"".join(round(sample * scale).to_bytes(width, order, signed=True) for sample in samples)
            filled_essence = True
        if key[5] != 0x53:
            continue
        if key[14] == 0x48:
            sound_descriptor = (index, position, start, end)
        cursor = start
        while cursor < end:
            tag, size = struct.unpack_from(">HH", media, cursor)
            cursor += 4
            field = slice(cursor, cursor + size)
            if tag in replacements:
                media[field] = replacements[tag].to_bytes(size, "big")
            elif width == 4 and tag in duration_fields:
                # The 16-bit template carries the same byte count in twice as many samples.
                value = int.from_bytes(media[field], "big")
                assert value % 2 == 0
                media[field] = (value // 2).to_bytes(size, "big")
            cursor += size
        assert cursor == end
    assert filled_essence and sound_descriptor is not None
    if order == "big":
        index, position, start, end = sound_descriptor
        label = struct.pack(">HH", 0x3D06, len(MXF_BIG_ENDIAN_PCM)) + MXF_BIG_ENDIAN_PCM
        _, fill_position, fill_start, fill_end = next(element for element in elements[index + 1 :] if element[0] == MXF_FILL)
        # Extend the Wave descriptor into its next fill item while keeping the partition offsets intact.
        assert media[position + 16] == 0x83 and media[fill_position + 16] == 0x83
        media[position + 17 : start] = (end - start + len(label)).to_bytes(3, "big")
        padding = (fill_end - fill_start - len(label)).to_bytes(3, "big")
        fill_header = MXF_FILL + b"\x83" + padding
        media[end : fill_start + len(label)] = label + media[end:fill_position] + fill_header
    return media


def flic(width, height):
    # The game variant starts with unsigned PCM. Full palette and pixel chunks
    # make each authored picture independent of previous frames.
    rate, samples_per_picture, frames = 22050, 1470, 19
    samples = bytes(128 + round(value * 28) for value in tone(rate, frames * samples_per_picture))
    palette = struct.pack("<HBB6B", 1, 0, 2, 230, 45, 20, 24, 85, 210)
    palette_chunk = struct.pack("<IH", len(palette) + 6, 4) + palette
    picture = bytes(width // 2) + bytes((1,)) * (width // 2)
    pictures = (picture * height, picture[::-1] * height)
    media = bytearray()
    for index in range(frames):
        start = index * samples_per_picture
        media.extend(struct.pack("<IH10x", samples_per_picture, 0xAAAA) + samples[start : start + samples_per_picture])
        pixels = pictures[index >= frames // 2]
        payload = palette_chunk + struct.pack("<IH", len(pixels) + 6, 16) + pixels
        media.extend(struct.pack("<IHH8x", len(payload) + 16, 0xF1FA, 2) + payload)
    return struct.pack("<I5H2xI108x", len(media) + 128, 0xAF12, frames, width, height, 8, 67) + media


def dss_g723(packets):
    header = bytearray(1024)
    header[:4] = b"\x02dss"
    header[0x2A4] = 2  # Long-play G.723.1
    header[0x26:0x3E] = b"240101120000240101120002"
    # Six bytes of recorder metadata precede each 506-byte payload. The
    # codec frames may span that boundary.
    return header + b"".join(bytes(6) + packets[i : i + 506] for i in range(0, len(packets), 506))


def maud(codec):
    if codec in ("pcm_alaw", "pcm_mulaw"):
        bits, rate = 8, 8000
        compression = {"pcm_alaw": 2, "pcm_mulaw": 3}[codec]
        data = g711(codec)
    else:
        rate, compression = 22050, 0
        if codec == "pcm_u8":
            bits = 8
            data = bytes(128 + round(value * 28) for value in tone(rate, rate * 5 // 4))
        else:
            assert codec == "pcm_s16be"
            bits = 16
            data = b"".join(struct.pack(">h", round(value * 7000)) for value in tone(rate, rate * 5 // 4))
    frame_count = len(data) // (bits // 8)
    header = struct.pack(">IHHIHHHH12x", frame_count, bits, bits, rate, 1, 0, 1, compression)
    return chunk(b"FORM", b"MAUD" + chunk(b"MHDR", header) + chunk(b"MDAT", data))
