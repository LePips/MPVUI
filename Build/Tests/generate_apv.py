"""Write APV access units with DC-only blocks for all defined profiles."""

import struct


# Profile indicator, chroma indicator, bit depth and decoded pixel format.
PROFILES = {
    "422-10": (33, 2, 10, "yuv422p10le"),
    "422-12": (44, 2, 12, "yuv422p12le"),
    "444-10": (55, 3, 10, "yuv444p10le"),
    "444-12": (66, 3, 12, "yuv444p12le"),
    "4444-10": (77, 4, 10, "yuva444p10le"),
    "4444-12": (88, 4, 12, "yuva444p12le"),
    "400-10": (99, 0, 10, "gray10le"),
}


def pack_bits(bits):
    bits += "0" * (-len(bits) % 8)
    return int(bits, 2).to_bytes(len(bits) // 8, "big")


def fields_bytes(fields):
    return pack_bits("".join(f"{value:0{width}b}" for value, width in fields))


def rice_code(value, order):
    group = 1 << order
    if value < group:
        return "1" + (f"{value:0{order}b}" if order else "")
    if value < 2 * group:
        return "00" + (f"{value - group:0{order}b}" if order else "")
    zeros = ((value >> order) - 1).bit_length() - 1
    remainder = value - ((1 << zeros) + 1) * group
    return "01" + "0" * zeros + "1" + f"{remainder:0{zeros + order}b}"


def component(value, depth, blocks):
    # With default quantization and QP 4 a constant block reconstructs as midpoint + DC / 8.
    dc = ((value << (depth - 8)) - (1 << (depth - 1))) * 8
    end_of_block = rice_code(63, 0)
    sign = str(int(dc < 0)) if dc else ""
    first = rice_code(abs(dc), 5) + sign + end_of_block
    second = rice_code(0, min(abs(dc) // 2, 5)) + end_of_block
    return pack_bits(first + second + ("1" + end_of_block) * (blocks - 2))


def access_unit(width, height, profile, chroma, depth, values):
    frame = fields_bytes(
        [
            (profile, 8),
            (30, 8),
            (0, 8),
            (width, 24),
            (height, 24),
            (chroma, 4),
            (depth - 8, 4),
            (0, 8),
            (0, 8),
        ]
    )
    # Use default color and quantization metadata. One tile covers the whole frame.
    tile_info = fields_bytes([(0, 8), (0, 1), (0, 1), (16, 20), (8, 20), (0, 1), (0, 8)])
    macroblocks = width // 16 * (height // 16)
    per_macroblock = {0: (4,), 2: (4, 2, 2), 3: (4, 4, 4), 4: (4, 4, 4, 4)}[chroma]
    planes = [component(value, depth, blocks * macroblocks) for value, blocks in zip(values, per_macroblock, strict=True)]
    channels = len(planes)
    tile = struct.pack(f">HH{channels}I{channels}Bx", 5 + 5 * channels, 0, *map(len, planes), *([4] * channels))
    tile += b"".join(planes)

    primary_frame = b"\x01\0\0\0" + frame + tile_info + struct.pack(">I", len(tile)) + tile
    access = b"aPv1" + struct.pack(">I", len(primary_frame)) + primary_frame
    return struct.pack(">I", len(access)) + access


def generate(destination, variant, width, height):
    profile, chroma, depth, _ = PROFILES[variant]
    if chroma == 0:
        values = ((72,), (180,))
    elif chroma == 4:
        values = ((81, 90, 240, 255), (41, 240, 110, 255))
    else:
        values = ((81, 90, 240), (41, 240, 110))
    destination.write_bytes(b"".join(access_unit(width, height, profile, chroma, depth, frame) * 12 for frame in values))
