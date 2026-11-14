"""Generate short playable fixtures for readers without an FFmpeg muxer."""

from math import trunc
import struct
import subprocess
from zlib import compress

from derive_reference_media import packet_bytes, reference_packets
from generate_legacy_audio import pack_bit_strings, tone
from generate_legacy_wrappers import audio_avi, elementary_packets, g711, pes_timestamp, riff, wave_container
from generate_wave_adpcm import clamp, ima_codes, pack_nibbles


AA_TEST_KEY = b"MPVUI test audio"


def aa_mp3(mp3):
    def encrypt(data, key):
        k0, k1, k2, k3 = struct.unpack(">4I", key)
        mask = 0xFFFFFFFF
        blocks = bytearray()
        limit = len(data) // 8 * 8
        for start in range(0, limit, 8):
            left, right = struct.unpack_from(">2I", data, start)
            total = 0
            for _ in range(8):
                total = (total + 0x9E3779B9) & mask
                left = (left + (((right << 4) + k0) ^ (right + total) ^ ((right >> 5) + k1))) & mask
                right = (right + (((left << 4) + k2) ^ (left + total) ^ ((left >> 5) + k3))) & mask
            blocks.extend(struct.pack(">2I", left, right))
        return blocks + data[limit:]

    seed = 4096
    file_key = b"Fixture MP3 tone"
    derived = encrypt(struct.pack(">6I", *range(seed, seed + 6)), AA_TEST_KEY)[2:18]
    header_key = bytes(a ^ b for a, b in zip(file_key, derived, strict=True))
    key_values = " ".join(map(str, struct.unpack(">4I", header_key))).encode()
    fields = ((b"codec", b"mp332"), (b"HeaderSeed", str(seed).encode()), (b"HeaderKey", key_values))
    dictionary = struct.pack(">I", len(fields))
    dictionary += b"".join(struct.pack(">BII", 0, len(key), len(value)) + key + value for key, value in fields)
    chapter_header = struct.pack(">II", len(mp3), 0)
    chapter = chapter_header + b"".join(encrypt(mp3[i : i + 3982], file_key) for i in range(0, len(mp3), 3982))
    start = 64 + len(dictionary)
    file_header = struct.pack(">4I", start + len(chapter), 1469084982, 2, 0)
    directory = struct.pack(">6I24x", 0, 64, len(dictionary), 1, start, len(chapter))
    return file_header + directory + dictionary + chapter


def cintel_raw(width, height, bright_on_left):
    levels = (63000, 100) if bright_on_left else (100, 63000)
    rows = b"".join(struct.pack("<H", level) * (width // 2) for level in levels) * height
    fields = ((1, b"DVCC"), (100, struct.pack("<4I", width, height, 90, 1)), (103, rows))
    return b"".join(struct.pack("<II", key, len(value)) + value for key, value in fields)


def ipu(width, height, colors):
    luma_dc = ("100", "00", "01", "101", "110", "1110", "11110", "111110", "1111110")
    chroma_dc = ("00", "01", "10", "110", "1110", "11110", "111110", "1111110", "11111110")
    frames = []
    for _, color in colors:
        predictors = [128, 128, 128]
        # Intra-only 4:2:0 with MPEG-1 DC differences and no AC coefficients.
        bits = ["10000000"]
        for macroblock in range(width * height // 256):
            bits.append("11" if macroblock else "1")
            for channel in (0, 0, 0, 0, 1, 2):
                delta = color[channel] - predictors[channel]
                predictors[channel] = color[channel]
                size = abs(delta).bit_length()
                bits.append((chroma_dc if channel else luma_dc)[size])
                if size:
                    complement = delta if delta >= 0 else delta + (1 << size) - 1
                    bits.append(f"{complement:0{size}b}")
                bits.append("10")
        coded = "".join(bits)
        coded += "0" * (-len(coded) % 8)
        frame = int(coded, 2).to_bytes(len(coded) // 8, "big") + b"\0\0\x01\xb0"
        frames.extend([frame] * 12)
    payload = b"".join(frames)
    return struct.pack("<4sIHHI", b"ipum", len(payload) + 16, width, height, len(frames)) + payload


def color_stills(width, height, codec, *options):
    return [
        subprocess.check_output(
            [
                "ffmpeg",
                "-v",
                "error",
                "-nostdin",
                "-f",
                "lavfi",
                "-i",
                f"color={color}:size={width}x{height}",
                "-frames:v",
                "1",
                "-c:v",
                codec,
                *options,
                "-f",
                "image2pipe",
                "-",
            ]
        )
        for color in ("red", "blue")
    ]


def mxg(width, height):
    def marker(code, data):
        return struct.pack(">BBH", 255, code, len(data) + 2) + data

    pictures = color_stills(width, height, "mjpeg")
    audio = g711("pcm_alaw")
    data = bytearray()
    for index in range(30):
        start, end = (round(frame * 8000 / 24) for frame in (index, index + 1))
        timestamp = round(index * 1000000 / 24)
        picture = pictures[index // 15]
        data.extend(marker(0xED, b"MXA\0" + struct.pack("<Q", timestamp) + audio[start:end]))
        data.extend(picture[:2] + marker(0xFE, b"MXF\0" + struct.pack("<IQ", 0, timestamp)) + picture[2:])
    return bytes(data)


def bonk():
    rate, frames, block_size = 8000, 10000, 125
    encoded = bytearray(b"\0BONK" + struct.pack("<BIIBBBHBH", 0, frames, rate, 1, 1, 0, 1, 1, block_size))
    bits, used = 0, 0

    def write(value, width):
        nonlocal bits, used
        bits |= value << used
        used += width
        while used >= 8:
            encoded.append(bits & 255)
            bits >>= 8
            used -= 8

    # One zero prediction tap leaves the signed sample magnitudes as the residuals.
    # All magnitudes fit in the 15 raw low bits, leaving an all-zero high-bit run.
    residuals = [round(1800 * level) * 16 for level in tone(rate, frames)]
    for start in range(0, frames, block_size):
        block = residuals[start : start + block_size]
        write(0, 1)
        write(15, 4)
        for sample in block:
            write(abs(sample), 15)
        step, remaining = 256, block_size
        while remaining > 0:
            write(0, 1)
            remaining -= step >> 8
            step += step // 8
        for sample in block:
            if sample:
                write(int(sample < 0), 1)
    if used:
        encoded.append(bits)
    return bytes(encoded)


def with_hca_crc(data):
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ (0x8005 if crc & 0x8000 else 0)) & 0xFFFF
    return data + struct.pack(">H", crc)


def hca():
    rate, frames, block_size = 45056, 55, 32
    header = (
        struct.pack(">4sHH4sIIHH", b"HCA\0", 0x200, 64, b"fmt\0", (1 << 24) | rate, frames, 0, 0)
        + struct.pack(">4sH8B2x", b"comp", block_size, 1, 15, 1, 0, 3, 3, 0, 0)
        + b"pad\0"
    )
    # At 45056 Hz, MDCT band 2 is centered at 440 Hz. Its phase advances
    # by 2.5π between subframes, giving two positive and two negative values.
    bits = "1" * 16 + "0" * 16 + "110" + "0" * 12 + f"{60:06b}"
    bits += "".join(f"{2 * 1470 + sign:012b}" for sign in (0, 0, 1, 1) * 2)
    bits = bits.ljust((len(bits) + 7) // 8 * 8, "0")
    block = int(bits, 2).to_bytes(len(bits) // 8, "big")
    return with_hca_crc(header.ljust(62, b"\0")) + with_hca_crc(block.ljust(block_size - 2, b"\0")) * frames


def westwood_snd1():
    rate, count, block_size = 8000, 10000, 250
    samples = bytes(round(128 + 80 * level) for level in tone(rate, count))
    chunks = []
    for offset in range(0, len(samples), block_size):
        block = samples[offset : offset + block_size]
        # SND1 literal runs carry up to 32 samples at a time.
        runs = [block[start : start + 25] for start in range(0, len(block), 25)]
        compressed = b"".join(bytes((0x80 | (len(run) - 1),)) + run for run in runs)
        chunks.append(struct.pack("<HHI", len(compressed), len(block), 0xDEAF) + compressed)
    body = b"".join(chunks)
    return struct.pack("<HIIBB", rate, len(body), len(samples), 0, 1) + body


def swf(width, height):
    def tag(kind, body=b""):
        header = struct.pack("<H", kind << 6 | min(63, len(body)))
        if len(body) >= 63:
            header += struct.pack("<I", len(body))
        return header + body

    fps, rate, frames = 25, 22050, 30
    samples_per_frame = rate // fps
    coord_bits = max(width, height).bit_length() + 6
    rect = pack_bit_strings(
        (
            f"{coord_bits:05b}",
            f"{0:0{coord_bits}b}",
            f"{width * 20:0{coord_bits}b}",
            f"{0:0{coord_bits}b}",
            f"{height * 20:0{coord_bits}b}",
        )
    )
    # DefineBitsLossless format 5 is zlib-compressed 0RGB. The streaming
    # soundtrack is uncompressed little-endian, 8-bit mono at 22.05 kHz.
    pictures = [compress(pixel * (width * height)) for pixel in (b"\0\xff\0\0", b"\0\0\0\xff")]
    samples = bytes(round(128 + sample * 28) for sample in tone(rate, frames * samples_per_frame))
    body = bytearray(rect + struct.pack("<HH", fps << 8, frames))
    body.extend(tag(45, struct.pack("<BBH", 0x08, 0x38, samples_per_frame)))
    for index in range(frames):
        body.extend(tag(20, struct.pack("<HBHH", index + 1, 5, width, height) + pictures[index // (frames // 2)]))
        start = index * samples_per_frame
        body.extend(tag(19, samples[start : start + samples_per_frame]))
        body.extend(tag(1))
    body.extend(tag(0))
    return struct.pack("<3sBI", b"FWS", 8, 8 + len(body)) + body


def lossless_bayer_jpeg(width, height, difference):
    def marker(code, payload):
        return struct.pack(">BBH", 0xFF, code, 2 + len(payload)) + payload

    # A single CFA component with lossless horizontal prediction. The first
    # sample differs from the midpoint, then each remaining residual is zero.
    category = abs(difference).bit_length()
    huffman = bytes((0, 1, 1)) + bytes(14) + bytes((0, category))
    frame = struct.pack(">BHHBBBB", 12, height, width, 1, 1, 0x11, 0)
    scan = bytes((1, 1, 0, 1, 0, 0))
    magnitude = difference if difference > 0 else (1 << category) - 1 + difference
    bits = f"10{magnitude:0{category}b}" + "0" * (width * height - 1)
    entropy = pack_bit_strings((bits, "1" * (-len(bits) % 8))).replace(b"\xff", b"\xff\0")
    return b"\xff\xd8" + marker(0xC3, frame) + marker(0xC4, huffman) + marker(0xDA, scan) + entropy + b"\xff\xd9"


def mlv_video(codec, width, height, source=None):
    classes = {"mjpeg": 3, "h264": 4, "tiff": 0x21}
    fps = 24
    if codec == "tiff":
        bits = 12
        packets = [lossless_bayer_jpeg(width, height, delta) for delta in (-1024, 1024) for _ in range(fps // 2)]
    else:
        bits = 8
        packet_bytes = width * height * bits // 8
        packets = []
        for data, _ in elementary_packets(source, "v:0"):
            assert len(data) <= packet_bytes
            packets.append(data.ljust(packet_bytes, b"\0"))
    header = struct.pack("<4sI8sQHHIHHIIII", b"MLVI", 52, b"v2.0", 0x4D50565549, 0, 1, 0, classes[codec], 0, len(packets), 0, fps, 1)
    matrix = tuple(value for index in range(9) for value in (int(index % 4 == 0), 1))
    sensor = struct.pack("<HHI20xIII40xII18i4x", width, height, 1, bits, 0, (1 << bits) - 1, 0x02010100, 21, *matrix)
    result = bytearray(header + struct.pack("<4sIQ", b"RAWI", 16 + len(sensor), 0) + sensor)
    for index, packet in enumerate(packets):
        timestamp = round(index * 1000000 / fps)
        result.extend(struct.pack("<4sIQI12x", b"VIDF", 32 + len(packet), timestamp, index) + packet)
    result.extend(struct.pack("<4sIQ", b"NULL", 16, 0))
    return result


def sgi_movie(width, height, *, jpeg=False):
    rate, fps, frames = 48000, 24, 30
    if jpeg:

        def table(fields):
            entries = bytearray(struct.pack(">4xI4x", len(fields)))
            for name, value in fields:
                field = str(value).encode() + b"\0"
                entries.extend(struct.pack(">16sI", name, len(field)) + field)
            return entries

        header = struct.pack(">4sHHI", b"MOVI", 0, 3, 0)
        header += table(((b"__NUM_A_TRACKS", 0), (b"__NUM_I_TRACKS", 1)))
        header += table(((b"__DIR_COUNT", frames), (b"COMPRESSION", 10), (b"FPS", fps), (b"WIDTH", width), (b"HEIGHT", height)))
        pictures = color_stills(width, height, "mjpeg")
        cursor = len(header) + frames * 16
        index = bytearray()
        payload = bytearray()
        for number in range(frames):
            frame = pictures[number // (frames // 2)]
            index.extend(struct.pack(">II8x", cursor + len(payload), len(frame)))
            payload.extend(frame)
        return header + index + payload

    # The fixed SGI movie header carries an index to interleaved signed
    # audio and ARGB pictures, with one audio packet per video frame.
    pixels = (b"\xff\xff\0\0", b"\xff\0\0\xff")
    pictures = [pixel * (width * height) for pixel in pixels]
    samples_per_frame = rate // fps
    audio = struct.pack(f">{frames * samples_per_frame}b", *(round(sample * 28) for sample in tone(rate, frames * samples_per_frame)))
    header = struct.pack(">4sH10xdH2x4I12x4I8x512x", b"MOVI", 2, fps, 1, frames, 2, width, height, rate, 1, 401, 1)
    cursor = len(header) + frames * 20
    index = bytearray()
    payload = bytearray()
    for number in range(frames):
        start = number * samples_per_frame
        picture = pictures[number // (frames // 2)]
        index.extend(struct.pack(">III8x", cursor + len(payload), samples_per_frame, len(picture)))
        payload.extend(audio[start : start + samples_per_frame] + picture)
    return header + index + payload


def moflex(codec):
    rate, frames, packet_count = 48000, 1024, 59
    samples = [round(10000 * sample) for sample in tone(rate, frames * packet_count)]
    adpcm = codec == "adpcm_ima_moflex"
    descriptor = bytes((2, 6, 0, 1 if adpcm else 2)) + (rate - 1).to_bytes(3, "big") + bytes(4)
    output = bytearray()
    for start in range(0, len(samples), frames):
        block = samples[start : start + frames]
        if adpcm:
            index, predictor = 47, block[0]
            codes = pack_nibbles(ima_codes(block, predictor, index), low_first=True)
            packet = struct.pack("<hh", index, predictor) + codes
        else:
            packet = struct.pack(f"<{frames}h", *block)
        # Stream zero, end of frame, no timestamp delta, and a 13-bit payload length.
        packet_header = ((0b1011001 << 41) | (len(packet) - 1)).to_bytes(6, "big")
        payload = descriptor + packet_header + packet + b"\0"
        output.extend(struct.pack(">HHQH", 0x4C32, 0, start, len(payload) + 13))
        output.extend(payload)
    return output


def ftr_voice(source):
    _, frames = reference_packets(source, "a:0")
    packets = []
    for frame, (data, _) in enumerate(frames):
        packet = bytearray(data)
        if frame % 2:
            # Exercise FTR's ADTS flag and byte transform on alternating AAC frames.
            packet[3] |= 0x20
            packet[8], packet[10] = packet[10] ^ 255, packet[8] ^ 255
            for offset in (9, 11, 12):
                packet[offset] ^= 255
        packets.append(packet)
    return audio_avi(48000, 1024, 0x0180, packets)


def ahx(source):
    # AHX uses the same MPEG-2 Layer II header for every shortened packet.
    _, frames = reference_packets(source, "a:0")
    packets = []
    for data, _ in frames:
        if len(data) not in (1044, 1045):
            raise ValueError("Expected 160 kb/s 22.05 kHz Layer II packets for AHX")
        packet = bytearray(data[:1044])
        packet[2] &= ~2  # Remove the MPEG padding bit along with the padding byte.
        packets.append(packet.rstrip(b"\0"))
    header = struct.pack(">HH4BIIH", 0x8000, 20, 16, 0, 0, 1, 22050, 1152 * len(packets), 0)
    return header + b"(c)CRI" + b"".join(packets)


def acelp_kelvin(g729, container):
    # Sipro Kelvin prefixes each mono G.729 speech frame with its channel byte.
    if not g729 or len(g729) % 10:
        raise ValueError("Expected complete G.729 speech frames for ACELP Kelvin")
    packets = [b"\x02" + g729[start : start + 10] for start in range(0, len(g729), 10)]
    tag, rate, samples = 0x0135, 8000, 80
    if container == "avi":
        return audio_avi(rate, samples, tag, packets)
    params = struct.pack("<HHIIHHH", tag, 1, rate, 1100, 11, 0, 0)
    count = struct.pack("<I", len(packets) * samples)
    return riff(b"RIFF", b"WAVE" + riff(b"fmt ", params) + riff(b"fact", count) + riff(b"data", b"".join(packets)))


SC4_STEPS = (4084, 18, 41, 64, 112, 198, 355, 1122, 1122, 355, 198, 112, 64, 41, 18, 4084)
SC4_DIFFERENCES = (2048, 4, 135, 213, 273, 323, 373, 425, 425, 373, 323, 273, 213, 135, 4, 2048)


def sc4_deltas(step):
    for nibble, difference in enumerate(SC4_DIFFERENCES):
        value = (difference + (step >> 2)) & 0xFFF
        magnitude = 0 if value & 0x800 else ((value & 127) + 128) * 128 >> (14 - (value >> 7))
        yield -magnitude if nibble & 8 else magnitude


def sc4_codes(samples):
    # Quantize against the current decoder predictor, then advance its six-tap filter.
    step, prediction = 0, 0
    weights, history = [0] * 6, [0] * 6
    for sample in samples:
        deltas = tuple(sc4_deltas(step))
        nibble = min(range(16), key=lambda code: abs(sample - ((prediction + (deltas[code] << 12)) >> 9)))
        yield nibble
        delta = deltas[nibble]
        gain = ((delta > 0) - (delta < 0)) << 27
        weights = [trunc(weight * 255 / 256) + (gain if past > 0 else -gain) for weight, past in zip(weights, history, strict=True)]
        history = [-16 * delta, *history[:-1]]
        prediction += (delta << 12) + sum((past * weight) >> 26 for past, weight in zip(history, weights, strict=True))
        prediction = trunc(clamp(prediction, -16383 << 12, 16383 << 12) * 9 / 10)
        change = (SC4_STEPS[nibble] * 32 - step) & 0x1FFFF
        step = clamp(((change >> 5) + (0x1000 if change & 0x10000 else 0) + step) & 0x1FFF, 544, 5120)


def micronas_sc4(container):
    rate, decoded_frames, packet_count, tag = 16000, 58, 345, 0x0350
    samples = (round(12000 * sample) for sample in tone(rate, decoded_frames * packet_count))
    coded = pack_nibbles(sc4_codes(samples))
    packet_bytes = decoded_frames // 2
    packets = [coded[start : start + packet_bytes] + b"\x55" for start in range(0, len(coded), packet_bytes)]
    if container == "avi":
        return audio_avi(rate, decoded_frames, tag, packets)
    block_align = packet_bytes + 1
    params = struct.pack("<HHIIHHH", tag, 1, rate, block_align * rate // decoded_frames, block_align, 0, 0)
    return wave_container(container, params, decoded_frames * packet_count, b"".join(packets))


def usm_chunk(tag, payload, payload_type=0):
    return struct.pack(">4sIBBHBBBBII8x", tag, 24 + len(payload), 0, 24, 0, 0, 0, 0, payload_type, 0, 2400) + payload


def usm_metadata(fields):
    keys, items = bytearray(), bytearray()
    for key, value in fields.items():
        items.extend(struct.pack(">BII", 0x34, len(keys), value))
        keys.extend(key.encode("ascii") + b"\0")
    offset = 24 + len(items)
    table = struct.pack(">4IHHI", offset, offset, 0, 0, len(fields), 0, 1) + items + keys
    return b"@UTF" + struct.pack(">I", len(table)) + table


def usm_adx(adx):
    header_bytes = struct.unpack_from(">H", adx, 2)[0] + 4
    block_bytes, channels, rate, frames = struct.unpack_from(">BxBII", adx, 5)
    block_frames = (block_bytes - 2) * 2
    step = block_bytes * channels * 32
    end = header_bytes + (frames + block_frames - 1) // block_frames * block_bytes * channels
    metadata = usm_metadata(dict(sampling_rate=rate, num_channels=channels, total_samples=frames, audio_codec=2))
    payload = (
        usm_chunk(b"@SFA", metadata, payload_type=1),
        usm_chunk(b"@SFA", adx[:header_bytes]),
        *(usm_chunk(b"@SFA", adx[offset : min(offset + step, end)]) for offset in range(header_bytes, end, step)),
    )
    return usm_chunk(b"CRID", b"") + b"".join(payload)


def usm_hca(audio):
    header_bytes = struct.unpack_from(">H", audio, 6)[0]
    channels_and_rate, blocks = struct.unpack_from(">II", audio, 12)
    block_bytes = struct.unpack_from(">H", audio, 28)[0]
    metadata = usm_metadata(
        dict(
            sampling_rate=channels_and_rate & 0xFFFFFF,
            num_channels=channels_and_rate >> 24,
            total_samples=blocks * 1024,
            audio_codec=4,
        )
    )
    payload = (
        usm_chunk(b"@SFA", metadata, payload_type=1),
        usm_chunk(b"@SFA", audio[:header_bytes]),
        *(usm_chunk(b"@SFA", audio[offset : offset + block_bytes]) for offset in range(header_bytes, len(audio), block_bytes)),
    )
    return usm_chunk(b"CRID", b"") + b"".join(payload)


def usm_video(source, codec, width, height):
    codec_tag = {"mpeg1video": 1, "h264": 5, "vp9": 9}[codec]
    _, packets = reference_packets(source, "v:0")
    metadata = usm_metadata(
        dict(width=width, height=height, total_frames=len(packets), framerate_n=24, framerate_d=1, mpeg_codec=codec_tag)
    )
    return (
        usm_chunk(b"CRID", b"")
        + usm_chunk(b"@SFV", metadata, payload_type=1)
        + b"".join(usm_chunk(b"@SFV", packet) for packet, _ in packets)
    )


def flv_tag(kind, timestamp, body):
    return (
        bytes((kind,))
        + len(body).to_bytes(3, "big")
        + (timestamp & 0xFFFFFF).to_bytes(3, "big")
        + bytes((timestamp >> 24,))
        + bytes(3)
        + body
        + struct.pack(">I", 11 + len(body))
    )


def flv_video(source, codec):
    # FFmpeg's reader recognizes Real H.263 and MPEG-4 Part 2 tags in FLV.
    # Write the video tags directly because the standard muxer may reject these tags.
    codec_tag = {"h263": 8, "mpeg4": 9}[codec]
    _, packets = reference_packets(source, "v:0")
    data = bytearray(b"FLV\x01\x01\x00\x00\x00\x09\x00\x00\x00\x00")
    for index, (packet, keyframe) in enumerate(packets):
        timestamp = index * 1000 // 24
        body = bytes([(0x10 if keyframe else 0x20) | codec_tag])
        if codec == "mpeg4":
            # Packet type 1 and a zero composition offset for the fixture's IP frames.
            body += b"\x01\x00\x00\x00"
        data.extend(flv_tag(9, timestamp, body + packet))
    return bytes(data)


def flv_captions(source, events):
    def amf_string(value):
        data = value.encode("utf-8")
        return struct.pack(">H", len(data)) + data

    data = source.read_bytes()
    offset = struct.unpack_from(">I", data, 5)[0] + 4
    output = bytearray(data[:offset])
    events = iter(events)
    event = next(events, None)
    while offset < len(data):
        size = int.from_bytes(data[offset + 1 : offset + 4], "big")
        timestamp = int.from_bytes(data[offset + 4 : offset + 7], "big") | (data[offset + 7] << 24)
        while event is not None and event[0] <= timestamp:
            time, text = event
            body = b"\x02" + amf_string("onCaption") + b"\x03" + amf_string("text") + b"\x02" + amf_string(text) + b"\0\0\x09"
            output.extend(flv_tag(18, time, body))
            event = next(events, None)
        end = offset + 11 + size + 4
        output.extend(data[offset:end])
        offset = end
    if event is not None:
        raise ValueError("The FLV video ends before the final caption.")
    return bytes(output)


def caf_with_packet_table(source, codec):
    stream, packets = reference_packets(source, "a:0")
    data = source.read_bytes()
    if codec == "aac":
        tag = data.index(b"esds")
        size = struct.unpack_from(">I", data, tag - 4)[0]
        cookie = data[tag + 4 : tag - 4 + size]
        fourcc, packet_frames, priming = b"aac ", 1024, 1024
    else:
        tag = data.index(b"OpusHead")
        cookie = data[tag : tag + 19]
        fourcc, packet_frames = b"opus", 960
        priming = struct.unpack_from("<H", cookie, 10)[0]

    def chunk(tag, body):
        return struct.pack(">4sQ", tag, len(body)) + body

    def packet_size(size):
        # CAF stores variable packet sizes as big-endian groups of seven bits.
        encoded = bytearray((size & 0x7F,))
        while size >= 128:
            size >>= 7
            encoded.insert(0, 0x80 | (size & 0x7F))
        return encoded

    rate, channels = int(stream["sample_rate"]), stream["channels"]
    valid_frames = rate * 5 // 4
    remainder = len(packets) * packet_frames - priming - valid_frames
    description = struct.pack(">d4s5I", rate, fourcc, 0, 0, packet_frames, channels, 0)
    table = struct.pack(">QQII", len(packets), valid_frames, priming, remainder)
    table += b"".join(packet_size(len(packet)) for packet, _ in packets)
    payload = bytes(4) + b"".join(packet for packet, _ in packets)
    return b"caff\x00\x01\x00\x00" + chunk(b"desc", description) + chunk(b"kuki", cookie) + chunk(b"pakt", table) + chunk(b"data", payload)


def vorbis_wave(source, format_name):
    stream, packets = reference_packets(source, "a:0")
    rate, channels = int(stream["sample_rate"]), stream["channels"]
    block_bytes = 256
    frames = rate * 5 // 4
    extra = packet_bytes(stream["extradata"])
    assert all(len(data) <= block_bytes for data, _ in packets)
    # WAV has no packet table. Read one block per packet and keep the
    # compressed Vorbis frame intact, with trailing zero padding.
    payload = b"".join(data.ljust(block_bytes, b"\0") for data, _ in packets)
    byte_rate = round(len(payload) * rate / frames)
    description = struct.pack("<HHIIHHH", 0x566F, channels, rate, byte_rate, block_bytes, 0, len(extra)) + extra
    return wave_container(format_name, description, frames, payload)


def r3d(width, height):
    rate, fps, frame_count = 48000, 24, 30
    samples_per_frame = rate // fps
    pictures = color_stills(width, height, "jpeg2000", "-pix_fmt", "yuv422p", "-format", "j2k")

    def atom(kind, payload):
        return struct.pack(">I4s", 8 + len(payload), kind) + payload

    title = b"Authored red and blue camera frames"
    header = struct.pack(">BBHII32xIIHHHB", 1, 0, 0, rate, 1, width, height, 0, fps, 1, 1)
    data = bytearray(atom(b"RED1", header + title.ljust(257, b"\0")))
    waveform = [round(1200000000 * sample) for sample in tone(rate, frame_count * samples_per_frame)]
    offsets = []
    for frame in range(frame_count):
        timestamp = frame * samples_per_frame
        offsets.append(len(data))
        video = struct.pack(">IIBBH", timestamp, frame, 1, 0, 0)
        data.extend(atom(b"REDV", video + pictures[frame // (frame_count // 2)]))
        audio = struct.pack(">IIIIHBBI", timestamp, rate, samples_per_frame, frame, 0, 1, 0, 0)
        block = struct.pack(f">{samples_per_frame}i", *waveform[timestamp : timestamp + samples_per_frame])
        data.extend(atom(b"REDA", audio + block))
    index = len(data)
    data.extend(atom(b"RDVO", struct.pack(f">{len(offsets)}I", *offsets)))
    data.extend(atom(b"REOF", struct.pack(">6I24x", index, 0, 0, 0, frame_count, frame_count)))
    return bytes(data)


def tivo_ty(video, audio, *, ac3):
    chunk_size = 128 * 1024

    def pes(code, pts, frame, header_bytes):
        optional = bytes((0x80, 0x80, header_bytes - 9)) + pes_timestamp(pts) + bytes(header_bytes - 14)
        return b"\0\0\x01" + bytes((code,)) + struct.pack(">H", len(frame) + len(optional)) + optional + frame

    def chunk(records):
        headers, payload = bytearray(), bytearray()
        for kind, subtype, pts, frame in records:
            header = (len(frame) << 12) | (subtype << 8) | kind
            headers.extend(struct.pack(">IIQ", header, 0, pts))
            payload.extend(frame)
        return (bytes((len(records), 0, 0, 0)) + headers + payload).ljust(chunk_size, b"\0")

    _, video_packets = reference_packets(video, "v:0")
    _, audio_packets = reference_packets(audio, "a:0")
    records = []
    for index, (frame, _) in enumerate(video_packets):
        pts = index * 3750  # 24 fps in a 90 kHz clock.
        records.append((pts, 0xE0, 0xB, pes(0xE0, pts, frame, 16)))
    step, subtype, packet_id, header_bytes = (2880, 9, 0xBD, 14) if ac3 else (2160, 3, 0xC0, 16)
    for index, (frame, _) in enumerate(audio_packets):
        pts = index * step
        records.append((pts, 0xC0, subtype, pes(packet_id, pts, frame, header_bytes)))
    records.sort(key=lambda record: record[0])

    header = struct.pack(">3I", 0xF5467ABD, 2, chunk_size)
    output = bytearray(header.ljust(chunk_size, b"\0"))
    current, length = [], 4
    for pts, kind, subtype, frame in records:
        record_size = 16 + len(frame)
        if length + record_size > chunk_size or len(current) == 255:
            output.extend(chunk(current))
            current, length = [], 4
        current.append((kind, subtype, round(pts * 1000000000 / 90000), frame))
        length += record_size
    output.extend(chunk(current))
    return bytes(output)
