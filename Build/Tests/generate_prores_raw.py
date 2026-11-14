"""Author 16-bit Bayer playback fixtures for both ProRes RAW profiles."""

from io import BytesIO
from struct import pack, unpack_from


def frame(width, height, size, dc):
    camera_to_xyz = (
        0.4123908,
        0.3575843,
        0.1804808,
        0.2126390,
        0.7151687,
        0.0721923,
        0.0193308,
        0.1191948,
        0.9505322,
    )
    header = pack(
        ">BB4sHH4BHH12fHH",
        0,
        0,
        b"test",
        width,
        height,
        0,
        0,
        0,
        0,
        0,
        3839,
        1.0,
        1.0,
        *camera_to_xyz,
        1.0,
        6504,
        16,
    )
    header += pack(">8H", 0, 8192, 16384, 24576, 32768, 40960, 49152, 57344)

    # One 8x8 DC-only block for each Bayer phase in a 16x16 tile. The first
    # coefficient uses a Rice prefix and 12-bit signed magnitude mapping.
    code = 2 * dc if dc >= 0 else -2 * dc - 1
    component = pack(">H", ((1 << 12) | code) << 3)
    tile = pack(">BBHHH", 8 << 3, 8, 2, 2, 2) + component * 4
    tile_count = (width // 16) * (height // 16)
    data = BytesIO()
    data.write(pack(">I4sH", size, b"prrf", len(header) + 2))
    data.write(header)
    data.write(pack(">H", len(tile)) * tile_count)
    data.write(tile * tile_count)
    data.write(pack(">I4s", 8, b"eomd"))
    return data.getvalue().ljust(size, b"\0")


def generate(output, fixture, tag, ffmpeg):
    width, height = fixture.width, fixture.height
    frame_count = 24
    sample_size = width * height * 3
    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        f"color=black:size={width}x{height}:rate=24",
        "-frames:v",
        str(frame_count),
        "-c:v",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "-f",
        "mov",
        fixture.filename,
    )
    path = output / fixture.filename
    movie = bytearray(path.read_bytes())
    samples = movie.index(b"mdat") + 4
    codec_tag = movie.index(b"stsd") + 16
    if movie[codec_tag : codec_tag + 4] != b"raw " or unpack_from(">I", movie, samples - 8)[0] != 8 + frame_count * sample_size:
        raise ValueError("The MOV template must use fixed-size, uncompressed RGB samples")

    # Preserve the MOV sample table by padding each RAW sample to the same size.
    count = frame_count // 2
    movie[samples : samples + frame_count * sample_size] = (
        frame(width, height, sample_size, -700) * count + frame(width, height, sample_size, 700) * count
    )
    movie[codec_tag : codec_tag + 4] = tag
    path.write_bytes(movie)
