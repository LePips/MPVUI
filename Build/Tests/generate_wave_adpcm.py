"""Author valid WAVE blocks for ADPCM codecs without FFmpeg encoders."""

import struct
from bisect import bisect_left

from generate_legacy_audio import PCM_FRAMES, PCM_RATE, tone


# WAVE format tag, channels, bits per code, bytes per block, decoded frames per block.
PROFILES = {
    "adpcm_ima_dk4": (0x0061, 1, 4, 64, 121),
    "adpcm_ima_dk3": (0x0062, 2, 4, 64, 64),
    "adpcm_ima_xbox": (0x0069, 1, 4, 36, 64),
    "adpcm_ima_oki": (0x0010, 1, 4, 1, 2),
    "adpcm_ct": (0x0200, 1, 4, 1, 2),
    "adpcm_zork": (0x0011, 1, 8, 1, 1),
    "adpcm_sanyo": (0x0125, 1, 4, 64, 120),
    "adpcm_agm": (0xFFFE, 1, 4, 3754, 7500),
}

IMA_STEPS = (
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    16,
    17,
    19,
    21,
    23,
    25,
    28,
    31,
    34,
    37,
    41,
    45,
    50,
    55,
    60,
    66,
    73,
    80,
    88,
    97,
    107,
    118,
    130,
    143,
    157,
    173,
    190,
    209,
    230,
    253,
    279,
    307,
    337,
    371,
    408,
    449,
    494,
    544,
    598,
    658,
    724,
    796,
    876,
    963,
    1060,
    1166,
    1282,
    1411,
    1552,
    1707,
    1878,
    2066,
    2272,
    2499,
    2749,
    3024,
    3327,
    3660,
    4026,
    4428,
    4871,
    5358,
    5894,
    6484,
    7132,
    7845,
    8630,
    9493,
    10442,
    11487,
    12635,
    13899,
    15289,
    16818,
    18500,
    20350,
    22385,
    24623,
    27086,
    29794,
    32767,
)
IMA_INDEX = (-1, -1, -1, -1, 2, 4, 6, 8)


def clamp(value, low, high):
    return max(low, min(high, value))


def closest(deltas, error):
    target = abs(error)
    upper = min(bisect_left(deltas, target), len(deltas) - 1)
    lower = max(0, upper - 1)
    index = lower if target - deltas[lower] <= deltas[upper] - target else upper
    return index, -deltas[index] if error < 0 else deltas[index]


def ima_codes(samples, predictor, index, *, oki=False, escape=False):
    steps = IMA_STEPS[8:57] if oki else IMA_STEPS
    limit = 2048 if oki else 32768
    scale, bias, shift = (1, 0, 2) if escape else (2, 1, 3)
    for target in samples:
        error = target - predictor
        step = steps[index]
        deltas = tuple(((scale * code + bias) * step) >> shift for code in range(8))
        code, delta = closest(deltas, error)
        predictor = clamp(predictor + delta, -limit, limit - 1)
        index = clamp(index + IMA_INDEX[code], 0, len(steps) - 1)
        yield code | (8 if error < 0 else 0)


def creative_codes(samples):
    adapt = (230, 230, 230, 230, 307, 409, 512, 614)
    predictor, step = 0, 511
    for target in samples:
        predictor = (predictor * 254) >> 8
        error = target - predictor
        code, delta = closest(tuple(((2 * code + 1) * step) >> 3 for code in range(8)), error)
        predictor = clamp(predictor + delta, -32768, 32767)
        step = clamp((step * adapt[code]) >> 8, 511, 32767)
        yield code | (8 if error < 0 else 0)


def zork_codes(samples):
    index_adjustment = (-1, -1, -1, 1, 4, 7, 10, 12)
    tables = tuple(tuple(sum(step >> bit for bit in range(7) if code & (64 >> bit)) for code in range(128)) for step in IMA_STEPS)
    predictor, index = 0, 0
    for target in samples:
        error = target - predictor
        code, delta = closest(tables[index], error)
        predictor = clamp(predictor + delta, -32768, 32767)
        index = clamp(index + index_adjustment[code >> 4], 0, 88)
        yield code | (128 if error < 0 else 0)


def sanyo_codes(samples, predictor, step):
    for target in samples:
        error = target - predictor
        deltas = (0, step, 2 * step, 3 * step, 4 * step, 11 * step // 2, 15 * step // 2)
        deltas += (19 * step // 2, 25 * step // 2) if error < 0 else (21 * step // 2,)
        code, delta = closest(deltas, error)
        predictor = clamp(predictor + delta, -32768, 32767)
        next_steps = (3 * step // 4, 3 * step // 4, step, step, step, step + step // 4, 2 * step, 5 * step // 2, 5 * step)
        step = clamp(next_steps[code], 1, 2621)
        yield (-code if error < 0 else code) & 15


def agm_codes(samples, predictor, step):
    adaptation = (57, 57, 57, 57, 77, 102, 128, 153)
    for target in samples:
        error = target - predictor
        deltas = tuple(((2 * code + 1) * step) >> 3 for code in range(8))
        code, delta = closest(deltas, error)
        predictor = clamp(predictor + delta, -32767, 32767)
        step = clamp((step * adaptation[code]) >> 6, 127, 24576)
        yield code | (8 if error < 0 else 0)


def pack_nibbles(codes, *, low_first=False):
    pairs = zip(codes, codes, strict=True)
    if low_first:
        return bytes(a | (b << 4) for a, b in pairs)
    return bytes((a << 4) | b for a, b in pairs)


def block(codec, samples, start, length):
    if codec in ("adpcm_sanyo", "adpcm_agm"):
        predictor = samples[max(0, start - 1)]
        step, encode = (90, sanyo_codes) if codec == "adpcm_sanyo" else (127, agm_codes)
        codes = encode(samples[start : start + length], predictor, step)
        return struct.pack("<hh", predictor, step) + pack_nibbles(codes, low_first=True)
    index = 24
    if codec == "adpcm_ima_dk3":
        # Encode the tone in the sum channel. Zero difference gives balanced stereo.
        predictor = samples[max(0, start - 1)]
        summed = ima_codes(samples[start : start + length], predictor, index)
        codes = (code for a, b in zip(summed, summed, strict=True) for code in (a, 0, b))
        return struct.pack("<10xhhBB", predictor, 0, index, 0) + pack_nibbles(codes, low_first=True)
    predictor = samples[start]
    xbox = codec == "adpcm_ima_xbox"
    # An Xbox block contains one extra code. The decoder returns 64 frames.
    codes = ima_codes(samples[start + 1 : start + length + xbox], predictor, index)
    return struct.pack("<hh", predictor, index) + pack_nibbles(codes, low_first=xbox)


def riff(tag, payload):
    return tag + struct.pack("<I", len(payload)) + payload + bytes(len(payload) % 2)


def generate(output, codec):
    tag, channels, depth, alignment, frames_per_block = PROFILES[codec]
    frames = PCM_FRAMES // frames_per_block * frames_per_block
    samples = [round(6000 * sample) for sample in tone(PCM_RATE, frames + 1)]
    if codec == "adpcm_ima_oki":
        data = pack_nibbles(ima_codes((sample >> 4 for sample in samples[:frames]), 0, 0, oki=True))
    elif codec == "adpcm_ct":
        data = pack_nibbles(creative_codes(samples[:frames]))
    elif codec == "adpcm_zork":
        data = bytes(zork_codes(samples[:frames]))
    else:
        data = b"".join(block(codec, samples, start, frames_per_block) for start in range(0, frames, frames_per_block))
    if len(data) != frames // frames_per_block * alignment:
        raise ValueError(f"{codec} data does not contain the expected WAVE blocks")
    header = struct.pack("<HHIIHH", tag, channels, PCM_RATE, PCM_RATE * alignment // frames_per_block, alignment, depth)
    if codec == "adpcm_agm":
        # WAVEFORMATEXTENSIBLE uses the AmuseGraphics subformat GUID and front-center channel.
        guid = bytes.fromhex("82ec1f6acadb1945bde756d3b3ef981d")
        header += struct.pack("<HHI16s", 22, frames_per_block, 4, guid)
    else:
        header += struct.pack("<HH", 2, frames_per_block)
    content = riff(b"fmt ", header) + riff(b"fact", struct.pack("<I", frames)) + riff(b"data", data)
    output.write_bytes(riff(b"RIFF", b"WAVE" + content))
