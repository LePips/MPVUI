"""Prepare short, pinned inputs for local reader and decoder tests."""

from fractions import Fraction
from itertools import accumulate, groupby
import json
from pathlib import Path
from struct import pack, pack_into, unpack_from
from subprocess import check_output
from tempfile import TemporaryDirectory

from generate_legacy_audio import aifc, chunk, smacker
from generate_legacy_wrappers import audio_avi, video_avi, wave_container
from generate_matroska import element, unsigned, vint
from generate_packetized_rtp import capture, encode_recording


def packet_bytes(dump):
    return b"".join(bytes.fromhex(line.split(": ", 1)[1].split("  ", 1)[0]) for line in dump.splitlines() if line)


def reference_stream(source: Path, stream: str, *, forced_format="", max_packets=None):
    input_format = ["-f", forced_format] if forced_format else []
    interval = ["-read_intervals", f"%+#{max_packets}"] if max_packets else []
    metadata = json.loads(
        check_output(
            [
                "ffprobe",
                "-v",
                "error",
                *input_format,
                *interval,
                "-select_streams",
                stream,
                "-show_entries",
                "packet=data,size,flags,pts,duration:stream=width,height,r_frame_rate,channels,sample_rate,extradata",
                "-show_data",
                "-of",
                "json",
                str(source),
            ]
        )
    )
    return metadata["streams"][0], metadata["packets"]


def reference_packets(source: Path, stream: str, count: int | None = None):
    stream_info, packet_info = reference_stream(source, stream)
    packets = []
    for packet in packet_info[:count]:
        data = packet_bytes(packet["data"])
        if len(data) != int(packet["size"]):
            raise ValueError(f"Unexpected packet size in {source.name}")
        packets.append((data, "K" in packet["flags"]))
    return stream_info, packets


def atrac3_wave_payload(source: Path):
    wave = source.read_bytes()
    fmt = wave.index(b"fmt ")
    audio = wave.index(b"data", fmt + 8) + 8
    tag, channels, rate, _, block_bytes, _ = unpack_from("<HHIIHH", wave, fmt + 8)
    if tag != 0x270 or channels != 2 or block_bytes != 192:
        raise ValueError(f"Expected two-channel 66 kb/s ATRAC3 in {source.name}")
    return channels, rate, wave[audio : audio + block_bytes * 110]


def ace(source: Path):
    channels, rate, payload = atrac3_wave_payload(source)
    asc_at = 0x44
    header = bytearray(asc_at + 4 + 0xEC + 32)
    header[:4] = b"AAC "
    pack_into(">I4s", header, 0x40, asc_at, b"ASC ")
    pack_into(">IIII", header, asc_at + 4 + 0xEC, 4, channels, len(payload), rate)
    return header + payload


def msf_atrac3(source: Path):
    channels, rate, payload = atrac3_wave_payload(source)
    # Codec four identifies the 96-byte-per-channel joint-stereo mode.
    return pack(">4s4I44x", b"MSF\0", 4, channels, len(payload), rate) + payload


def matroska_atrac3(source: Path):
    channels, rate, payload = atrac3_wave_payload(source)
    wave = source.read_bytes()
    fmt = wave.index(b"fmt ")
    size = unpack_from("<I", wave, fmt + 4)[0]
    codec_private = wave[fmt + 8 : fmt + 8 + size]
    block_size = unpack_from("<H", codec_private, 12)[0]
    assert len(payload) % block_size == 0
    frames = len(payload) // block_size
    header = element("1A45DFA3", unsigned("42F2", 4) + unsigned("42F3", 8) + element("4282", b"matroska") + unsigned("4287", 4))
    info = element("1549A966", unsigned("2AD7B1", 1000000) + element("4489", pack(">d", frames * 1024000 / rate)))
    audio = element("E1", element("B5", pack(">d", rate)) + unsigned("9F", channels))
    track = element(
        "AE",
        unsigned("D7", 1) + unsigned("73C5", 1) + unsigned("83", 2) + element("86", b"A_MS/ACM") + element("63A2", codec_private) + audio,
    )
    packets = []
    for frame in range(frames):
        stamp = round(frame * 1024000 / rate)
        offset = frame * block_size
        packets.append(element("A3", vint(1) + pack(">hB", stamp, 0x80) + payload[offset : offset + block_size]))
    cluster = element("1F43B675", unsigned("E7", 0) + b"".join(packets))
    return header + element("18538067", info + element("1654AE6B", track) + cluster)


def binka(source: Path):
    stream, packets = reference_packets(source, "a:0", 100)
    channels, rate = stream["channels"], int(stream["sample_rate"])
    sample_count = sum(unpack_from("<I", data)[0] // (channels * 2) for data, _ in packets)
    header = pack("<4sBBHI12x", b"1FCB", 1, channels, rate, sample_count)
    return header + b"".join(pack("<HH", 0x9999, len(data) - 4) + data[4:] for data, _ in packets)


def smacker_bink(source: Path, *, transform):
    stream, packets = reference_packets(source, "a:0", 110)
    channels, rate = stream["channels"], int(stream["sample_rate"])
    if channels not in (1, 2):
        raise ValueError(f"Expected mono or stereo Bink audio in {source.name}")
    audio_flags = 0x20 | {"dct": 0x04, "rdft": 0x08}[transform]
    if channels == 2:
        audio_flags |= 0x10
    return smacker([frame for frame, _ in packets], rate, audio_flags)


def legacy_video_container(source: Path, *, codec, muxer):
    fourcc, depth = {"4xm": (b"4XMV", 16), "mss1": (b"MSS1", 24)}[codec]
    stream, packets = reference_packets(source, "v:0", 84)
    # These containers need timestamps even when the source has none.
    media = video_avi(stream["width"], stream["height"], fourcc, depth, packets, packet_bytes(stream["extradata"]))
    if muxer == "avi":
        return media
    assert muxer == "asf"
    with TemporaryDirectory() as directory:
        intermediate = Path(directory) / "timestamped.avi"
        intermediate.write_bytes(media)
        return remux(intermediate, stream="0:v:0", muxer=muxer)


def aifc_reference(source: Path, *, codec):
    if codec == "qdmc":
        stream, packets = reference_packets(source, "a:0", 24)
        extra = packet_bytes(stream["extradata"])
        block_size = unpack_from(">I", extra, 44)[0]
        assert all(len(data) == block_size for data, _ in packets)
        payload = b"".join(data for data, _ in packets)
        return aifc(int(stream["sample_rate"]), b"QDMC", b"QDMC", len(packets), payload, chunk(b"wave", extra), channels=stream["channels"])

    assert codec == "qcelp"
    _, packets = reference_packets(source, "a:0")
    runs = (list(run) for full_rate, run in groupby(packets, key=lambda packet: len(packet[0]) == 34) if full_rate)
    frames = max(runs, key=len)
    # The QCP reader removes the rate byte. AIFF's fixed full-rate frames
    # carry that byte, followed by the original 34-byte speech data.
    payload = b"".join(b"\4" + data for data, _ in frames)
    return aifc(8000, b"Qclp", b"QCELP", len(frames), payload, chunk(b"wave", bytes(24) + b"F"))


def legacy_wave(source: Path, *, codec, muxer):
    if codec == "xan_dpcm":
        stream, packets = reference_packets(source, "a:0", 50)
        block_size = 2942
        assert all(len(data) == block_size for data, _ in packets)
        rate, channels = int(stream["sample_rate"]), stream["channels"]
        frames_per_packet = (block_size - 2 * channels) // channels
        average = round(rate * block_size / frames_per_packet)
        description = pack("<HHIIHHH", 0x594A, channels, rate, average, block_size, 16, 0)
        return wave_container(muxer, description, len(packets) * frames_per_packet, b"".join(data for data, _ in packets))

    assert codec == "avc"
    stream, packets = reference_packets(source, "a:0", 167)
    packets = packets[125:167]  # Skip the silent opening of the source.
    extra = packet_bytes(stream["extradata"])
    rate, channels = int(stream["sample_rate"]), stream["channels"]
    block_size, frames_per_packet = 256, 1024
    assert all(len(data) <= block_size - 2 for data, _ in packets)
    # The length-prefixed AVC variant keeps each subframe's packet boundary
    # even when the WAVE reader returns several fixed-size blocks at once.
    payload = b"".join(pack("<H", block_size - 2) + data.ljust(block_size - 2, b"\0") for data, _ in packets)
    description = pack("<HHIIHHH", 0x501, channels, rate, rate * block_size // frames_per_packet, block_size, 0, len(extra)) + extra
    return wave_container(muxer, description, len(packets) * frames_per_packet, payload)


def xma1_container(source: Path, *, muxer):
    source_data = sdns(source)
    rate, channels = unpack_from(">II", source_data, 8)
    packet_size = 2048
    end = min(len(source_data), 4096 + 50 * packet_size)
    packets = [source_data[i : i + packet_size] for i in range(4096, end, packet_size)]
    # XMA1 uses its own format record. It has one 20-byte stream descriptor
    # after the 8-byte configuration and gives the channel count per stream.
    description = pack("<HH4xH6xI9xB2x", 0x0165, 16, 1, rate, channels)
    if muxer in ("wav", "w64"):
        return wave_container(muxer, description, 0, b"".join(packets))

    avi = audio_avi(rate, 3072, 0x0165, packets, description=description)
    if muxer == "avi":
        return avi
    assert muxer == "asf"
    with TemporaryDirectory() as directory:
        intermediate = Path(directory) / "timestamped.avi"
        intermediate.write_bytes(avi)
        media = bytearray(remux(intermediate, stream="0:a:0", muxer=muxer))

    # FFmpeg's ASF muxer writes generic WAVEFORMATEX. Replace its type
    # data with the XMA1 layout and update the enclosing ASF object sizes.
    stream_properties = media.index(bytes.fromhex("9107dcb7b7a9cf118ee600c00c205365"))
    file_properties = media.index(bytes.fromhex("a1dcab8c47a9cf118ee400c00c205365"))
    format_data = stream_properties + 78
    old_size = unpack_from("<I", media, stream_properties + 64)[0]
    assert unpack_from("<H", media, format_data)[0] == 0x0165
    shift = len(description) - old_size
    for offset in (16, stream_properties + 16):
        pack_into("<Q", media, offset, unpack_from("<Q", media, offset)[0] + shift)
    pack_into("<Q", media, file_properties + 40, len(media) + shift)
    pack_into("<I", media, stream_properties + 64, len(description))
    media[format_data : format_data + old_size] = description
    return media


def ivf(source: Path, *, fourcc, forced_format=""):
    stream, packets = reference_stream(source, "v:0", forced_format=forced_format, max_packets=36)
    fps = Fraction(stream["r_frame_rate"]).limit_denominator(1001)
    if len(fourcc) != 4 or not fps or not packets:
        raise ValueError(f"Invalid IVF inputs for {source.name}")

    # IVF stores presentation timestamps in frame units, including reordered pictures.
    pts = [int(packet["pts"]) for packet in packets if "pts" in packet]
    positions = {stamp: frame for frame, stamp in enumerate(sorted(pts))}
    use_source_order = len(positions) == len(packets)
    result = bytearray(
        pack(
            "<4sHH4sHHIIII",
            b"DKIF",
            0,
            32,
            fourcc.encode("ascii"),
            stream["width"],
            stream["height"],
            fps.numerator,
            fps.denominator,
            len(packets),
            0,
        )
    )
    for frame, packet in enumerate(packets):
        data = packet_bytes(packet["data"])
        if len(data) != int(packet["size"]):
            raise ValueError(f"Unexpected IVF packet size in {source.name}")
        position = positions[int(packet["pts"])] if use_source_order else frame
        result.extend(pack("<IQ", len(data), position))
        result.extend(data)
    return bytes(result)


def rtp_telephone_audio(source: Path, *, codec):
    if codec == "g728":
        payload_type = 15
        encoded = source.read_bytes()
        assert len(encoded) % 40 == 0
        # Each five-byte block contains 20 samples at 8 kHz.
        frames = [encoded[offset : offset + 40] for offset in range(0, len(encoded), 40)]
    elif codec == "qcelp":
        payload_type = 12
        _, packets = reference_stream(source, "a:0", max_packets=150)
        rate_codes = {0: 0, 3: 1, 7: 2, 16: 3, 34: 4}
        # QCP strips the frame rate byte. RTP carries it after the
        # zero interleave header so each datagram contains one complete frame.
        frames = [bytes((0, rate_codes[int(packet["size"])])) + packet_bytes(packet["data"]) for packet in packets]
    else:
        raise ValueError(f"Unsupported telephone RTP codec: {codec}")
    packets = [pack(">BBHII", 0x80, payload_type, index, index * 160, 0x4D505655) + frame for index, frame in enumerate(frames)]
    data, _ = encode_recording(packets, payload_type, 8000)
    return data


def rtp_theora(source: Path):
    with TemporaryDirectory() as temporary:
        _, payload, _, packets = capture(
            Path(temporary),
            [
                "-i",
                str(source.resolve()),
                "-map",
                "0:v:0",
                "-t",
                "2.3",
                "-c",
                "copy",
            ],
        )
    data, _ = encode_recording(packets, payload, 90000)
    return data


def realmedia_track(data, kind):
    if not data.startswith(b".RMF"):
        raise ValueError("Expected a RealMedia file")
    offset = 0
    track = None
    while offset + 10 <= len(data):
        tag, size, version = unpack_from(">4sIH", data, offset)
        end = offset + size
        if size < 10:
            raise ValueError("Invalid RealMedia object size")
        if tag == b"DATA":
            if version != 0 or track is None:
                raise ValueError("Expected a selected track and version zero RealMedia data")
            return data[offset + 18 : end], track
        if tag == b"MDPR":
            stream = unpack_from(">H", data, offset + 10)[0]
            name = offset + 40
            mime = name + 1 + data[name]
            header = mime + 1 + data[mime]
            if data[mime + 1 : header].startswith(kind + b"/"):
                length = unpack_from(">I", data, header)[0]
                track = stream, data[header + 4 : header + 4 + length]
        offset = end
    raise ValueError("Missing RealMedia tracks or packets")


def realmedia_matroska(source: Path, *, codec):
    audio_codecs = {"cook": b"cook", "sipr": b"sipr", "ra_288": b"28_8"}
    audio = codec in audio_codecs
    payload, (stream, private) = realmedia_track(source.read_bytes(), b"audio" if audio else b"video")
    if audio:
        tag = audio_codecs[codec]
        header = {
            b".ra\xfd\0\x04": (62, 48, 54),
            b".ra\xfd\0\x05": (66, 54, 60),
        }.get(private[:6])
        if not header or private[header[0] : header[0] + 4] != tag:
            raise ValueError(f"Expected a RealAudio {codec} track in {source.name}")
        group_rows, frame_bytes = unpack_from(">HH", private, 40)
        sample_rate, channels = (unpack_from(">H", private, offset)[0] for offset in header[1:])
        if not group_rows or not frame_bytes:
            raise ValueError(f"Invalid RealAudio packet dimensions in {source.name}")
        settings = element("E1", element("B5", pack(">d", sample_rate)) + unsigned("9F", channels))
        track_codec = b"A_REAL/" + tag.upper()
        blocks = []
        offset = 0
        while offset + 12 <= len(payload):
            version, size, index, stamp, _, flags = unpack_from(">HHHIBB", payload, offset)
            if version != 0 or size < 12:
                raise ValueError(f"Invalid RealMedia packet in {source.name}")
            if index != stream:
                offset += size
                continue
            if stamp >= 3600 and len(blocks) % group_rows == 0:
                duration = stamp
                break
            if size != 12 + frame_bytes or offset + size > len(payload):
                raise ValueError(f"Unexpected RealAudio packet in {source.name}")
            blocks.append((stamp, flags & 2 != 0, payload[offset + 12 : offset + size]))
            offset += size
        else:
            raise ValueError(f"Expected several RealAudio interleave groups in {source.name}")
        if not blocks or len(blocks) % group_rows:
            raise ValueError(f"Incomplete RealAudio interleave group in {source.name}")
        # RealMedia timestamps the group. Give each Matroska block its own
        # playback time so both Matroska readers can assign monotonic PCM PTS.
        for start in range(0, len(blocks), group_rows):
            first = blocks[start][0]
            end = blocks[start + group_rows][0] if start + group_rows < len(blocks) else duration
            for row in range(group_rows):
                _, key, packet = blocks[start + row]
                blocks[start + row] = (first + round((end - first) * row / group_rows), key, packet)
    else:
        if private[4:12] != b"VIDO" + codec.upper().encode("ascii"):
            raise ValueError(f"Expected a {codec} track in {source.name}")
        details, packets = reference_stream(source, "v:0", max_packets=72)
        width, height = details["width"], details["height"]
        fps = Fraction(details["r_frame_rate"])
        settings = element("E0", unsigned("B0", width) + unsigned("BA", height))
        settings += unsigned("23E383", round(1000000000 / fps))
        track_codec = ("V_REAL/" + codec.upper()).encode("ascii")
        start = min(int(packet["pts"]) for packet in packets)
        blocks = [(int(packet["pts"]) - start, "K" in packet["flags"], packet_bytes(packet["data"])) for packet in packets]
        duration = max(stamp for stamp, _, _ in blocks) + round(1000 / fps)

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
        + element("4489", pack(">d", duration))
        + element("4D80", b"Local media tests")
        + element("5741", b"Local media tests"),
    )
    track = element(
        "AE",
        unsigned("D7", 1)
        + unsigned("73C5", 1)
        + unsigned("83", 2 if audio else 1)
        + unsigned("9C", 0)
        + element("86", track_codec)
        + element("63A2", private)
        + settings,
    )
    cluster = element(
        "1F43B675",
        unsigned("E7", 0)
        + b"".join(element("A3", vint(1) + pack(">hB", stamp, 0x80 if key else 0) + packet) for stamp, key, packet in blocks),
    )
    return header + element("18538067", info + element("1654AE6B", track) + cluster)


def mods(source: Path):
    stream, packets = reference_packets(source, "v:0", 66)
    numerator, denominator = map(int, stream["r_frame_rate"].split("/"))
    rate = round(numerator * (1 << 24) / denominator)
    header_bytes = 48
    payload, keyframes = bytearray(), bytearray()
    for frame, (data, key) in enumerate(packets):
        if frame == 0 or key:
            keyframes.extend(pack("<II", frame, header_bytes + len(payload)))
        payload.extend(pack("<I", len(data) << 14) + data)
    header = pack(
        "<8s4I16xII",
        b"MODSN3\x0a\x00",
        len(packets),
        stream["width"],
        stream["height"],
        rate,
        header_bytes + len(payload),
        len(keyframes) // 8,
    )
    return header + payload + keyframes


def sdns(source: Path):
    stream, _ = reference_packets(source, "a:0", 0)
    riff = source.read_bytes()
    offset = 12
    while offset + 8 <= len(riff):
        chunk, size = unpack_from("<4sI", riff, offset)
        offset += 8
        if chunk == b"data" and offset + size <= len(riff) and size % 2048 == 0:
            header = pack(">4sIII", b"SDNS", 0, int(stream["sample_rate"]), stream["channels"])
            return header.ljust(4096, b"\0") + riff[offset : offset + size]
        offset += size + size % 2
    raise ValueError(f"No complete XMA packets in {source.name}")


def vividas_varint(value):
    digits = [value & 127]
    while value >= 128:
        value >>= 7
        digits.append(128 | (value & 127))
    return bytes(reversed(digits))


def vividas_block(payload, *, prefix=b"", alignment=1):
    length_bytes = 1
    while True:
        size = len(prefix) + length_bytes + len(payload)
        size += (-size) % alignment
        length = vividas_varint(size)
        if len(length) == length_bytes:
            return (prefix + length + payload).ljust(size, b"\0")
        length_bytes = len(length)


def vividas_vorbis_headers(extradata):
    if extradata[0] != 2:
        raise ValueError("Expected three Vorbis headers")
    offset = 1
    lengths = []
    for _ in range(2):
        size = 0
        while extradata[offset] == 255:
            size += 255
            offset += 1
        lengths.append(size + extradata[offset])
        offset += 1
    lengths.append(len(extradata) - offset - sum(lengths))
    return b"\x13\0\x03" + b"".join(map(vividas_varint, lengths)) + extradata[offset:]


def vividas_superblock(records):
    descriptors = b"".join(vividas_varint(len(data)) + bytes([flag]) for flag, data in records)
    payload = b"\0\0" + descriptors + b"\0\0" + b"".join(data for _, data in records)
    return vividas_block(payload, prefix=b"SB")


def vividas(source: Path, audio: Path):
    video, packets = reference_packets(source, "v:0", 90)
    sound, audio_packets = reference_stream(audio, "a:0")
    fps, rate, channels = 30, int(sound["sample_rate"]), sound["channels"]
    video_header = vividas_block(
        b"\x03\0" + pack("<IIIHHBI", 1, fps, len(packets), video["width"], video["height"], 0, 0),
    )
    audio_header = vividas_block(
        b"\x05\0" + pack("<HHI", 0, channels, rate) + bytes(12) + vividas_block(vividas_vorbis_headers(packet_bytes(sound["extradata"]))),
    )
    tracks = vividas_block(
        b"\x01\x00\x02" + vividas_block(b"\x02\x01") + video_header + vividas_block(b"\x04\x01") + audio_header,
        alignment=4,
    )

    # Start each indexed superblock with an intra frame. Each record may carry audio
    # for its video interval, with byte offsets and decoded lengths for each Vorbis packet.
    groups = []
    pending = []
    samples = iter(audio_packets)
    sample = next(samples, None)
    for frame, (picture, is_keyframe) in enumerate(packets):
        if frame and is_keyframe:
            groups.append(pending)
            pending = []
        audio_data = []
        sample_counts = []
        while sample and sample["pts"] < (frame + 1) * rate // fps:
            audio_data.append(packet_bytes(sample["data"]))
            sample_counts.append(0 if sample["pts"] < 0 else sample["duration"])
            sample = next(samples, None)
        video_size = vividas_varint(len(picture))
        if not audio_data:
            pending.append((1, video_size + picture))
            continue
        offsets = accumulate(map(len, audio_data[:-1]), initial=0)
        audio_index = b"".join(
            vividas_varint(offset) + vividas_varint(count * 2 * channels) for offset, count in zip(offsets, sample_counts, strict=True)
        )
        pending.append((0, video_size + b"\0" + picture + audio_index + b"\0\0" + b"".join(audio_data)))
    groups.append(pending)
    blocks = [vividas_superblock(group) for group in groups]
    index = vividas_block(
        b"c"
        + vividas_varint(len(blocks))
        + b"".join(vividas_varint(len(block)) + vividas_varint(len(group)) for block, group in zip(blocks, groups, strict=True)),
        alignment=4,
    )

    key = 0x10203041
    key_offsets = (
        20,
        52,
        111,
        10,
        27,
        71,
        142,
        53,
        82,
        138,
        1,
        78,
        86,
        121,
        183,
        85,
        105,
        152,
        39,
        140,
        172,
        11,
        64,
        144,
        155,
        6,
        71,
        163,
        186,
        49,
        126,
        43,
    )
    key_buffer = bytearray(187)
    for bit, offset in enumerate(key_offsets):
        key_buffer[offset] |= ((key >> bit) & 1) << ((bit * 5 + 3) & 7)

    def keyed(data):
        words = range(1, (len(data) + 3) // 4 + 1)
        mask = b"".join(pack("<I", (key * word) & 0xFFFFFFFF) for word in words)
        return bytes(byte ^ key_byte for byte, key_byte in zip(data, mask))

    header = vividas_block(b"\x01\0" + key_buffer + bytes(4))
    return b"vividas03" + header + keyed(tracks + index) + b"".join(map(keyed, blocks))


def remux(source: Path, *, stream, muxer, input_format="", start=0, intermediate_muxer=""):
    # Disable generated identifiers and source metadata so the resulting wrapper has a fixed digest.
    source_options = []
    if input_format:
        source_options.extend(("-f", input_format))
    if start:
        source_options.extend(("-ss", str(start)))
    with TemporaryDirectory() as directory:
        if intermediate_muxer:
            # This reader needs packet timestamps that the elementary input does not carry.
            intermediate = Path(directory) / "timestamped.media"
            intermediate.write_bytes(remux(source, stream=stream, muxer=intermediate_muxer, input_format=input_format, start=start))
            source, stream, source_options = intermediate, "0:0", []
        target = Path(directory) / "input.media"
        check_output(
            [
                "ffmpeg",
                "-v",
                "error",
                "-nostdin",
                "-fflags",
                "+genpts",
                *source_options,
                "-i",
                str(source),
                "-map",
                stream,
                "-t",
                "3.3",
                "-c",
                "copy",
                "-map_metadata",
                "-1",
                "-fflags",
                "+bitexact",
                "-strict",
                "experimental",
                "-f",
                muxer,
                str(target),
            ]
        )
        return target.read_bytes()


def remux_sdns(source: Path, *, muxer):
    with TemporaryDirectory() as directory:
        wrapped = Path(directory) / "input.sdns"
        wrapped.write_bytes(sdns(source))
        return remux(wrapped, stream="0:a:0", muxer=muxer, input_format="sdns")


PREPARATIONS = {
    "ace": ace,
    "aifc_reference": aifc_reference,
    "binka": binka,
    "ivf": ivf,
    "legacy_video_container": legacy_video_container,
    "legacy_wave": legacy_wave,
    "matroska_atrac3": matroska_atrac3,
    "mods": mods,
    "msf_atrac3": msf_atrac3,
    "remux": remux,
    "remux_sdns": remux_sdns,
    "realmedia_matroska": realmedia_matroska,
    "rtp_telephone_audio": rtp_telephone_audio,
    "rtp_theora": rtp_theora,
    "sdns": sdns,
    "smacker_bink": smacker_bink,
    "vividas": vividas,
    "xma1_container": xma1_container,
}
