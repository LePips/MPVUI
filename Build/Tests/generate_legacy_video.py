"""Author short, two-color clips for video decoders without local encoders."""

from pathlib import Path
import struct
import subprocess
from tempfile import TemporaryDirectory
import zlib

from derive_reference_media import packet_bytes, reference_packets, reference_stream
from generate_legacy_wrappers import elementary_packets, siff_video, video_avi


RATE = 24
COLORS = ((b"\0\0\xff", (81, 90, 240)), (b"\xff\0\0", (41, 240, 110)))
AVI_CODECS = {
    "012v": (b"012v", 20),
    "aasc": (b"AASC", 24),
    "agm": (b"AGM4", 24),
    "aura": (b"AURA", 16),
    "cyuv": (b"CYUV", 12),
    "dxtory": (b"xtor", 24),
    "fraps": (b"FPS1", 24),
    "mscc": (b"MSCC", 24),
    "mszh": (b"MSZH", 24),
    "mvha": (b"MVHA", 16),
    "notchlc": (b"nlc1", 32),
    "prosumer": (b"BT20", 12),
    "rasc": (b"RASC", 32),
    "rtv1": (b"RTV1", 32),
    "srgc": (b"SRGC", 24),
    "vble": (b"VBLE", 12),
    "vmix": (b"VMX1", 16),
    "wcmv": (b"WCMV", 24),
    "wnv1": (b"WNV1", 16),
    "zerocodec": (b"ZECO", 16),
}


def little_endian_bits(fields):
    output = bytearray()
    pending = length = 0
    for value, width in fields:
        pending |= value << length
        length += width
        while length >= 8:
            output.append(pending & 255)
            pending >>= 8
            length -= 8
    if length:
        output.append(pending)
    return bytes(output)


def wnv1(width, height, y, u, v):
    # Four absolute six-bit components start the frame. Zero residuals fill the remaining pairs.
    fields = [field for value in (y, u, y, v) for field in ((255, 8), (value // 4, 6))]
    fields.extend([(0, 1)] * (width * height * 2 - 4))
    return b"\0\0\x60" + bytes(5) + little_endian_bits(fields)


def vble(width, height, y, u, v):
    # Store reverse unary lengths before the signed residuals. Each row restarts its left predictor.
    lengths, residuals = [], []
    dimensions = ((width, height), (width // 2, height // 2), (width // 2, height // 2))
    for (columns, rows), level in zip(dimensions, (y, u, v)):
        code = 2 * level if level < 128 else 2 * (256 - level) - 1
        length = (code + 1).bit_length() - 1
        lengths.extend(([(1 << length, length + 1)] + [(1, 1)] * (columns - 1)) * rows)
        residuals.extend([(code + 1 - (1 << length), length)] * rows)
    return b"\1\0\0\0" + little_endian_bits(lengths + residuals)


def mszh(pixel, pixels):
    # Three four-byte literals seed the BGR pattern. The rest copies groups from 12 bytes back.
    tokens = [(False, (pixel * 4)[offset : offset + 4]) for offset in range(0, 12, 4)]
    for offset in range(12, pixels * 3, 128):
        groups = min(32, (pixels * 3 - offset) // 4)
        tokens.append((True, struct.pack("<H", 12 | ((groups - 1) << 11))))
    data = bytearray()
    for offset in range(0, len(tokens), 8):
        block = tokens[offset : offset + 8]
        data.append(sum(copy << (7 - index) for index, (copy, _) in enumerate(block)))
        for _, value in block:
            data.extend(value)
    return data


def vmix_frame(width, height, yuv):
    def golomb(value):
        code = f"{value + 1:b}"
        return "0" * (len(code) - 1) + code

    def packed(bits):
        bits += "0" * (-len(bits) % 8)
        return int(bits, 2).to_bytes(len(bits) // 8, "big")

    # Each 16-line slice has a DC difference and runs of zero differences and AC coefficients.
    block_counts = (width // 4, width // 8, width // 8)
    dc = []
    for blocks, level, bias in zip(block_counts, yuv, (128, 0, 0)):
        delta = level - bias
        signed = 2 * delta if delta >= 0 else -2 * delta - 1
        bits = golomb(signed) + (golomb(0) if delta else "")
        dc.append(packed(bits + golomb(blocks - 1 - bool(delta))))
    ac = packed(golomb(0) + golomb(sum(block_counts) * 64 - 1))
    slices = height // 16
    groups = [b"".join(dc)] * slices + [ac] * slices
    return b"\x03\x03\0\0\0" + b"".join(struct.pack("<I", len(group)) + group for group in groups)


def prosumer_frame(width, height, yuv):
    # A literal sets the first row. Zero residuals copy it into every subsequent row.
    y, u, v = ((level // 8 - 16) % 32 for level in yuv)
    row = bytes((u, y, v, y, u, y, v, y, y, y, y, y)) * (width // 8)
    residuals = row + bytes(len(row) * (height - 1))
    codes = "".join(f"00{high:02x}{low:02x}" for low, high in zip(residuals[::2], residuals[1::2]))
    codes += "0" * (-len(codes) % 8 + 8)
    return bytes(32) + b"".join(struct.pack("<I", int(codes[i : i + 8], 16)) for i in range(0, len(codes), 8))


def notchlc_frame(width, height, yuv):
    # Format 2 stores uncompressed blocks. Equal endpoints make luma and chroma blocks constant.
    y, u, v = yuv
    luma = y << 4
    y_rows = b"".join(struct.pack("<I", row * (width // 2)) for row in range(height // 4))
    y_control = struct.pack("<I", luma | (luma << 12)) * (width * height // 16)
    uv_offsets = bytes(4 * (width * height // 256))
    uv = struct.pack("<I4BI", 0, u, v, u, v, 0)
    y_control_start = 16 + 40 + len(y_rows)
    uv_index = y_control_start + len(y_control)
    uv_start = uv_index + len(uv_offsets)
    y_start = uv_start + len(uv)
    y_data = bytes(width * height // 8)
    end = y_start + len(y_data)
    # An alpha-control offset equal to the luma data offset denotes an opaque picture.
    layout = struct.pack("<10I", width, height, uv_index // 4, y_control_start // 4, y_start // 4, uv_start // 4, len(y_data), 0, 0, end)
    return b"1CLN" + struct.pack("<3I", end, end, 2) + layout + y_rows + y_control + uv_offsets + uv + y_data


def color_packet(codec, width, height, bgr, yuv):
    y, u, v = yuv
    pixels = width * height
    if codec == "012v":
        words = ((u, y, v), (y, u, y), (v, y, u), (y, v, y))
        packed = struct.pack("<4I", *(a << 2 | b << 12 | c << 22 for a, b, c in words))
        return packed * (pixels // 6)
    if codec == "cyuv":
        # Zero prediction tables and one absolute YUV predictor at the start of every row.
        row = bytes(((u & 0xF0) | (y >> 4), v & 0xF0, 0)) + bytes((width // 4 - 1) * 3)
        return bytes(48) + row * height
    if codec == "aura":
        return bytes((u, y, v, y)) * (pixels // 2)
    if codec == "agm":
        # AGM4 stores the first BGR pixel followed by deltas from the preceding pixel.
        return bytes(12) + bgr + bytes(3 * (pixels - 1))
    if codec == "mvha":
        planes = b"".join(bytes((level,)) + bytes(count - 1) for level, count in ((y, pixels), (u, pixels // 2), (v, pixels // 2)))
        compressed = zlib.compress(planes)
        return b"VYZL" + struct.pack("<I", len(compressed)) + compressed
    if codec == "vmix":
        return vmix_frame(width, height, yuv)
    if codec == "prosumer":
        return prosumer_frame(width, height, yuv)
    if codec == "notchlc":
        return notchlc_frame(width, height, yuv)
    if codec == "zerocodec":
        return zlib.compress(bytes((u, y, v, y)) * (pixels // 2))
    if codec == "vble":
        return vble(width, height, y, u, v)
    if codec == "wnv1":
        return wnv1(width, height, y, u, v)
    if codec == "mszh":
        return mszh(bgr, pixels)
    if codec in ("mscc", "srgc"):
        # One run fills each bottom-up scanline. MSCC disguises the first zlib byte.
        row = bytes((width,)) + bgr + b"\0\0"
        compressed = zlib.compress(row * height + b"\0\1")
        if codec == "mscc":
            mask = 0x43
            return bytes((mask, 0, compressed[0] ^ mask)) + compressed[1:]
        return compressed
    if codec == "wcmv":
        compressed = zlib.compress(bgr * pixels)
        return struct.pack("<6H", 1, 0, 0, width, height, len(compressed)) + compressed
    if codec == "rasc":
        # Frame initialization precedes the compressed current and comparison surfaces.
        init = struct.pack("<I4xII30xH24x", 0x65, width, height, 32)
        compressed = zlib.compress((bgr + b"\0") * (2 * pixels))
        return b"KBND" + b"FINT" + struct.pack("<I", len(init)) + init + b"KFRM" + struct.pack("<I", len(compressed)) + compressed
    if codec == "rtv1":
        blue, green, red = bgr
        endpoint = (blue >> 3) << 11 | (green >> 2) << 5 | (red >> 3)
        blocks = struct.pack("<HH", endpoint, endpoint) * (pixels // 16)
        return struct.pack("<4sIII", b"DXT1", 1, width, height) + blocks
    headers = {"aasc": bytes(4), "fraps": struct.pack("<I", 1), "dxtory": struct.pack(">I12x", 0x01000001)}
    return headers[codec] + bgr * pixels


def cpia_frame(width, height, yuv):
    y, u, v = yuv
    # 4:2:0 webcam packets have one YUYV line followed by a luma-only line.
    chroma_line = bytes((y, u, y, v)) * (width // 2) + b"\xfd"
    luma_line = bytes((y,)) * width + b"\xfd"
    rows = struct.pack("<H", len(chroma_line)) + chroma_line + struct.pack("<H", len(luma_line)) + luma_line
    return b"\x19\x68" + bytes(62) + rows * (height // 2)


def nut_crc(data):
    checksum = 0
    for byte in data:
        checksum ^= byte << 24
        for _ in range(8):
            polynomial = 0x04C11DB7 if checksum & 0x80000000 else 0
            checksum = ((checksum << 1) ^ polynomial) & 0xFFFFFFFF
    return struct.pack(">I", checksum)


def cpia_nut(folder, width, height, ffmpeg):
    # The NUT muxer supplies packet timestamps and indexes. Retag its single video stream
    # and update the CRC of each stream header because the AVI reader lacks a CPIA tag.
    packets = [(cpia_frame(width, height, yuv), True) for _, yuv in COLORS for _ in range(RATE // 2)]
    (folder / "packets.avi").write_bytes(video_avi(width, height, b"CLJR", 16, packets))
    ffmpeg(folder, "-i", "packets.avi", "-map", "0:v:0", "-c:v", "copy", "source.nut")
    media = bytearray((folder / "source.nut").read_bytes())
    start_code = bytes.fromhex("4e5311405bf2f9db")
    position = 0
    found = False
    while (position := media.find(start_code, position)) >= 0:
        offset = position + len(start_code)
        size = 0
        while media[offset] & 0x80:
            size = (size << 7) | (media[offset] & 0x7F)
            offset += 1
        size = (size << 7) | media[offset]
        offset += 1
        crc_start = offset + size - 4
        if (
            size > 4096
            or media[offset : offset + 7] != b"\0\0\x04CLJR"
            or nut_crc(media[offset:crc_start]) != media[crc_start : crc_start + 4]
        ):
            raise ValueError("Unexpected CPIA fixture stream header")
        media[offset + 3 : offset + 7] = b"CPiA"
        media[crc_start : crc_start + 4] = nut_crc(media[offset:crc_start])
        position = offset + size
        found = True
    if not found:
        raise ValueError("Missing CPIA fixture stream header")
    return media


def hymt_avi(folder, width, height, ffmpeg):
    slice_height = height // 2
    (folder / "slices.rgb").write_bytes(b"".join(bgr[::-1] * (width * slice_height) for bgr, _ in COLORS))
    ffmpeg(
        folder,
        "-f",
        "rawvideo",
        "-pixel_format",
        "rgb24",
        "-video_size",
        f"{width}x{slice_height}",
        "-framerate",
        str(RATE),
        "-i",
        "slices.rgb",
        "-threads",
        "1",
        "-c:v",
        "huffyuv",
        "-pix_fmt",
        "yuv422p",
        "slices.avi",
    )
    stream, slices = reference_stream(folder / "slices.avi", "v:0")
    frames = []
    for source in slices:
        data = packet_bytes(source["data"])
        size = len(data)
        if size % 4:
            raise ValueError("Expected word-aligned HuffYUV slices")
        slice_index = struct.pack("<4I", 0, size, size, size)
        footer = struct.pack("<4I", 0, 2, slice_height, 2 * size)
        frames.extend([(data * 2 + slice_index + footer, True)] * (RATE // 2))
    return video_avi(width, height, b"HYMT", 16, frames, packet_bytes(stream["extradata"]))


def atoms(data, start, end):
    while start < end:
        size, kind = struct.unpack_from(">I4s", data, start)
        assert 8 <= size <= end - start
        yield start, size, kind
        start += size


def quicktime_samples(template, tag, packets):
    # The single-track MOV template has one chunk before moov. Its offset stays constant.
    data = bytearray(template.read_bytes())
    start, end = 0, len(data)
    media, media_size = next((p, n) for p, n, kind in atoms(data, start, end) if kind == b"mdat")
    parents = []
    for child in (b"moov", b"trak", b"mdia", b"minf", b"stbl"):
        begin, size = next((p, n) for p, n, kind in atoms(data, start, end) if kind == child)
        parents.append((begin, size))
        start, end = begin + 8, begin + size
    tables = {kind: (p, n) for p, n, kind in atoms(data, start, end)}
    description, _ = tables[b"stsd"]
    offsets, _ = tables[b"stco"]
    sizes, old_size = tables[b"stsz"]
    assert struct.unpack_from(">I", data, description + 12) == (1,)
    assert struct.unpack_from(">II", data, offsets + 12) == (1, media + 8)
    assert struct.unpack_from(">I", data, sizes + 16) == (len(packets),)
    data[description + 20 : description + 24] = tag
    new_sizes = struct.pack(f">I4sIII{len(packets)}I", 20 + 4 * len(packets), b"stsz", 0, 0, len(packets), *map(len, packets))
    for position, length in parents:
        struct.pack_into(">I", data, position, length + len(new_sizes) - old_size)
    data[sizes : sizes + old_size] = new_sizes
    payload = b"".join(packets)
    data[media : media + media_size] = struct.pack(">I4s", 8 + len(payload), b"mdat") + payload
    return data


def cdtoons_frame(frame_id, bgr):
    # The scene clears to palette entry 1. Each keyframe defines its own palette.
    palette = bytes(6) + b"".join(bytes((value, 0)) for value in bgr[::-1]) + bytes(254 * 6)
    header = bytearray(44)
    struct.pack_into(">HH", header, 0, 9, frame_id)
    header[7] = 1
    struct.pack_into(">HHHBBH", header, 28, 1, len(header) + 10, frame_id, 1, 0, frame_id)
    sprite = struct.pack(">HHIHHH", frame_id, 0, 14 + len(palette), frame_id, frame_id, 0)
    return header + bytes(10) + sprite + palette


def mjpeg_b(jpeg):
    # Motion JPEG-B stores field-relative offsets to the JPEG table, frame and scan sections.
    sections = {}
    cursor = 2
    while cursor < len(jpeg):
        assert jpeg[cursor] == 255
        marker = jpeg[cursor + 1]
        length = struct.unpack_from(">H", jpeg, cursor + 2)[0]
        sections[marker] = cursor + 2
        if marker == 0xDA:
            break
        cursor += 2 + length
    offsets = tuple(40 + sections[kind] for kind in (0xDB, 0xC4, 0xC0, 0xDA))
    size = len(jpeg) + 40
    return struct.pack(">I4s8I", 0, b"mjpg", size, size, 0, *offsets, offsets[-1] + length) + jpeg


def intel_h263(packet):
    # Substitute Intel's extended picture type and preserve the QCIF macroblocks.
    bits = "".join(f"{byte:08b}" for byte in packet)
    assert bits[35:38] == "010"
    header = "111" + bits[38:43] + "010" + "0000000000" + "00001"
    result = bits[:35] + header + bits[43:]
    result += "0" * (-len(result) % 8)
    return int(result, 2).to_bytes(len(result) // 8, "big")


def msmpeg4v1_dc(delta, chroma=False):
    if delta == 0:
        return "00" if chroma else "100"
    size = abs(delta).bit_length()
    assert 4 <= size <= 7
    # Microsoft inverts the MPEG-4 DC size prefix. A negative residual uses one's complement.
    prefix = "1" * (size - (1 if chroma else 2)) + "0"
    level = delta if delta > 0 else delta + (1 << size) - 1
    return prefix + f"{level:0{size}b}"


def msmpeg4v1_frames(width, height):
    columns, rows = width // 16, height // 16
    packets = []
    for index in range(RATE):
        key = index % (RATE // 2) == 0
        # Picture start code, frame number, picture type and quantizer.
        bits = f"{0x100:032b}{index:05b}{int(not key):02b}{4:05b}"
        if key:
            y, u, v = COLORS[index // (RATE // 2)][1]
            # Each row resets DC prediction to 128. The coded block pattern is zero.
            empty = "10011" + msmpeg4v1_dc(0) * 4 + msmpeg4v1_dc(0, chroma=True) * 2
            first = "10011" + msmpeg4v1_dc(y - 128) + msmpeg4v1_dc(0) * 3
            first += msmpeg4v1_dc(u - 128, chroma=True) + msmpeg4v1_dc(v - 128, chroma=True)
            bits += f"{rows:05b}" + (first + empty * (columns - 1)) * rows
            bits += f"{RATE:05b}{64:011b}"  # Frame rate and bitrate in the extended header.
        else:
            bits += "1" * (columns * rows)  # Skip each macroblock in the predicted picture.
        bits += "0" * (-len(bits) % 8)
        packets.append((int(bits, 2).to_bytes(len(bits) // 8, "big"), key))
    return packets


def nuppel_video(width, height, compressed):
    rate = 12
    frame_count = 2 * rate
    luma = width * height
    header = b"NuppelVideo\0" + b"0.05\0" + bytes(3)
    header += struct.pack("<4I4sdd4I", width, height, width, height, b"P\0\0\0", width / height, rate, frame_count, 0, 0, rate)

    def packet(kind, storage, timestamp, payload):
        repeat = int(storage == b"L")
        return struct.pack("<ccBBII", kind, storage, repeat, 0, timestamp, len(payload)) + payload

    frames = [header, packet(b"D", b"R", 0, struct.pack("<I", 8) * 128)]
    for index in range(frame_count):
        if index % rate:
            storage, payload = b"L", b""
        else:
            y, u, v = COLORS[index // rate][1]
            if compressed:
                # Four luma and two chroma blocks, each with DC and no AC.
                storage = b"1"
                payload = (bytes((y, 0)) * 4 + bytes((u, 0, v, 0))) * (luma // 256)
            else:
                storage = b"0"
                payload = bytes([y]) * luma + bytes([u]) * (luma // 4) + bytes([v]) * (luma // 4)
        frames.append(packet(b"V", storage, index * 1000 // rate, payload))
    return b"".join(frames)


def generate(output, fixture, ffmpeg):
    width, height, codec = fixture.width, fixture.height, fixture.codec
    if codec == "vb":
        data = siff_video(width, height)
    elif codec == "nuv":
        data = nuppel_video(width, height, "rtjpeg" in fixture.name)
    elif codec == "msmpeg4v1":
        data = video_avi(width, height, b"MPG4", 24, msmpeg4v1_frames(width, height))
    elif codec in ("cpia", "hymt"):
        with TemporaryDirectory(dir=output) as directory:
            wrap = cpia_nut if codec == "cpia" else hymt_avi
            data = wrap(Path(directory), width, height, ffmpeg)
    elif codec == "m101":
        depth = 10 if "10bit" in fixture.name else 8
        rows = []
        for _, (y, u, v) in COLORS:
            pair = bytes((y, u, y, v))
            # At 10 bits, each sixteen-pixel group stores eight bytes of low bits.
            rows.append((pair * 8 + b"\x55" * 8) * (width // 16) if depth == 10 else pair * (width // 2))
        extra = struct.pack("<6I", 0, 0, depth, 3, 0, len(rows[0]))
        packets = [(row * height, True) for row in rows for _ in range(RATE // 2)]
        data = video_avi(width, height, b"M101", 16, packets, extra)
    elif codec in AVI_CODECS:
        tag, bits = AVI_CODECS[codec]
        keyframes = [color_packet(codec, width, height, bgr, yuv) for bgr, yuv in COLORS]
        if codec == "zerocodec":
            previous = zlib.compress(bytes(width * height * 2))
            packets = [packet for key in keyframes for packet in [(key, True)] + [(previous, False)] * (RATE // 2 - 1)]
        else:
            packets = [(key, True) for key in keyframes for _ in range(RATE // 2)]
        extra = b"\4\0\0\0\2\0\0\1" if codec == "mszh" else b""
        data = video_avi(width, height, tag, bits, packets, extra)
    else:
        with TemporaryDirectory(dir=output) as directory:
            directory = Path(directory)
            raw = b"".join(bgr[::-1] * (width * height * (RATE // 2)) for bgr, _ in COLORS)
            (directory / "colors.rgb").write_bytes(raw)
            source = (
                "-f",
                "rawvideo",
                "-pixel_format",
                "rgb24",
                "-video_size",
                f"{width}x{height}",
                "-framerate",
                str(RATE),
                "-i",
                "colors.rgb",
            )
            if codec == "h263i":
                ffmpeg(directory, *source, "-c:v", "h263", "-g", "1", "-q:v", "3", "source.avi")
                frames = [(intel_h263(packet), True) for packet, _ in elementary_packets(directory / "source.avi")]
                data = video_avi(width, height, b"I263", 24, frames)
            else:
                ffmpeg(directory, *source, "-c:v", "rawvideo", "source.mov")
                if codec == "mjpegb":
                    ffmpeg(directory, *source, "-threads", "1", "-c:v", "mjpeg", "-huffman", "default", "-pix_fmt", "yuvj422p", "jpeg.mov")
                    packets = [mjpeg_b(packet) for packet, _ in elementary_packets(directory / "jpeg.mov")]
                    data = quicktime_samples(directory / "source.mov", b"mjpb", packets)
                elif codec == "cdtoons":
                    packets = [cdtoons_frame(index + 1, COLORS[index // (RATE // 2)][0]) for index in range(RATE)]
                    data = quicktime_samples(directory / "source.mov", b"QkBk", packets)
                elif codec == "vp8":
                    # The MOV reader accepts vp08, even though FFmpeg's MOV muxer does not write it.
                    ffmpeg(directory, *source, "-threads", "1", "-c:v", "libvpx", "-g", "1", "-pix_fmt", "yuv420p", "vp8.webm")
                    _, wrapped = reference_packets(directory / "vp8.webm", "v:0")
                    packets = [packet for packet, _ in wrapped]
                    data = quicktime_samples(directory / "source.mov", b"vp08", packets)
                elif codec == "targa_y216":
                    frames = [struct.pack("<4H", u << 6, y << 6, v << 6, y << 6) * (width * height // 2) for _, (y, u, v) in COLORS]
                    packets = [frame for frame in frames for _ in range(RATE // 2)]
                    data = quicktime_samples(directory / "source.mov", b"Y216", packets)
                else:
                    # Each planar row uses a two-byte PackBits repeat code.
                    sizes = struct.pack(">H", 2) * (3 * height)
                    frames = [sizes + b"".join(bytes((257 - width, value)) * height for value in bgr[::-1]) for bgr, _ in COLORS]
                    packets = [frame for frame in frames for _ in range(RATE // 2)]
                    data = quicktime_samples(directory / "source.mov", b"8BPS", packets)
    (output / fixture.filename).write_bytes(data)
