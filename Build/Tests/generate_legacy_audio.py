"""Generate synthetic tones for legacy audio readers and decoders."""

import math
import struct
from bisect import bisect_left
from functools import lru_cache, reduce
from operator import xor


PCM_RATE = 48000
PSX_RATE = 22050
PCM_FRAMES = PCM_RATE * 5 // 4
SDS_RATE = 16000
DSD_BIT_RATE = 2822400

PCM_FORMATS = (
    ("audio-visual.avr", "avr", "pcm_s16be", PCM_RATE),
    ("paris.fap", "epaf", "pcm_s16le", PCM_RATE),
    ("paris-signed-8.paf", "epaf", "pcm_s8", PCM_RATE),
    ("4xm-unsigned-8.4xm", "4xm", "pcm_u8", PCM_RATE),
    ("cinematic-unsigned-8.cin", "idcin", "pcm_u8", 22400),
    ("stream-unsigned-8.nsv", "nsv", "pcm_u8", 12000),
    ("vqa-unsigned-8.vqa", "wsvqa", "pcm_u8", 22050),
    ("vqa-signed-16.vqa", "wsvqa", "pcm_s16le", 22050),
    ("smacker-unsigned-8.smk", "smk", "pcm_u8", 22050),
    ("smacker-signed-16.smk", "smk", "pcm_s16le", 22050),
    ("voice.pvf", "pvf", "pcm_s32be", PCM_RATE),
    ("spectrum.sph", "nistsphere", "pcm_s16le", PCM_RATE),
    ("speech.nsp", "nsp", "pcm_s16le", PCM_RATE),
    ("radical.rsd", "rsd", "pcm_s16le", PCM_RATE),
    ("psion.wve", "wve", "pcm_alaw", 8000),
)


def tone(rate, frames):
    return (math.sin(math.tau * 440 * frame / rate) for frame in range(frames))


def signed_nibbles(samples):
    """Keep the waveform sign at four-bit precision so zero plateaus cannot ring."""
    for sample in samples:
        level = round(7 * sample)
        yield (max(1, level) if sample >= 0 else min(-1, level)) & 15


def dv_wave(pal):
    # PCM is scattered across the audio DIF blocks of each Ulead DV packet.
    block_count = 54 if pal else 45
    block_size = 160 * block_count
    samples_per_frame = 1920 if pal else 1600
    frame_count = round(PCM_FRAMES / samples_per_frame)
    minimum = 1896 if pal else 1580
    shuffle = [
        80 * ((21 * (i % 3) + 9 * (i // 3) + (i // (block_count // 3)) % 3) % block_count) + 2 * (i // block_count) + 8
        for i in range(samples_per_frame)
    ]
    signal = iter(tone(PCM_RATE, frame_count * samples_per_frame))
    payload = bytearray()
    for _ in range(frame_count):
        frame = bytearray(block_size)
        frame[244] = samples_per_frame - minimum
        for offset in shuffle:
            value = round(next(signal) * 6000)
            struct.pack_into(">h", frame, offset, value)
            struct.pack_into(">h", frame, offset + block_size // 2, value)
        payload.extend(frame)
    parameters = struct.pack("<HHIIHH", 0x0216 if pal else 0x0215, 2, PCM_RATE, PCM_RATE * block_size // samples_per_frame, block_size, 16)
    wave = b"WAVEfmt " + struct.pack("<I", len(parameters)) + parameters + b"data" + struct.pack("<I", len(payload)) + payload
    return b"RIFF" + struct.pack("<I", len(wave)) + wave


def mpeg_layer1(output):
    # MPEG-1 Layer I, 128 kb/s, 48 kHz mono, without CRC. One frame has
    # 12 slots of 32 output samples. Only the lowest subband carries a tone.
    header = b"\xff\xff\x44\xc0"
    slots = 12
    frames = math.ceil(PCM_FRAMES / (32 * slots))
    signal = [round(127 + 96 * sample) for sample in tone(PCM_RATE // 32, frames * slots)]
    with output.open("wb") as stream:
        for start in range(0, len(signal), slots):
            # Allocation 7 selects 8-bit samples. The other 31 allocations
            # are zero, followed by the active subband's 6-bit scale factor.
            payload = (7 << (31 * 4 + 6)) | 8
            for sample in signal[start : start + slots]:
                payload = (payload << 8) | sample
            stream.write((header + (payload << 2).to_bytes(29, "big")).ljust(128, b"\0"))


def nistsphere(data, rate, coding, sample_bytes):
    header = (
        f"NIST_1A\n   1024\nchannel_count -i 1\nsample_rate -i {rate}\nsample_count -i {rate * 5 // 4}\n"
        f"sample_n_bytes -i {sample_bytes}\nsample_byte_format -s2 01\n"
        f"sample_coding -s{len(coding)} {coding}\nend_head\n"
    )
    return header.encode("ascii").ljust(1024, b" ") + data


def pcm_fixture(fmt, codec, alaw):
    signed = [round(6000 * sample) for sample in tone(PCM_RATE, PCM_FRAMES)]
    pcm_le = struct.pack(f"<{PCM_FRAMES}h", *signed)
    if fmt == "avr":
        header = (
            b"2BITfixture\0"
            + struct.pack(">HHHHH", 0, 16, 0xFFFF, 0, 0xFFFF)
            + PCM_RATE.to_bytes(4, "big")
            + struct.pack(">III", PCM_FRAMES, 0, PCM_FRAMES)
        )
        return header.ljust(128, b"\0") + struct.pack(f">{PCM_FRAMES}h", *signed)
    if fmt == "epaf":
        eight_bit = codec == "pcm_s8"
        data = bytes(round(value / 256) & 0xFF for value in signed) if eight_bit else pcm_le
        return (b"fap " + struct.pack("<5I", 0, 1, PCM_RATE, 2 if eight_bit else 0, 1)).ljust(2048, b"\0") + data
    if fmt == "4xm":
        return fourxm_pcm()
    if fmt == "idcin":
        return idcin_pcm()
    if fmt == "nsv":
        return nsv_pcm()
    if fmt == "wsvqa":
        return vqa_pcm(codec == "pcm_s16le")
    if fmt == "smk":
        return smacker_pcm(codec == "pcm_s16le")
    if fmt == "pvf":
        return f"PVF1\n1 {PCM_RATE} 32\n".encode("ascii") + struct.pack(f">{PCM_FRAMES}i", *(sample << 16 for sample in signed))
    if fmt == "nistsphere":
        return nistsphere(pcm_le, PCM_RATE, "pcm", 2)
    if fmt == "nsp":
        header = struct.pack("<I20xI8x", 32, PCM_RATE)
        return b"FORMDS16" + struct.pack("<I", len(pcm_le) + 48) + b"HEDR" + header + b"SDA_" + struct.pack("<I", len(pcm_le)) + pcm_le
    if fmt == "rsd":
        return (b"RSD4PCM " + struct.pack("<4I", 1, 16, PCM_RATE, 0)).ljust(2048, b"\0") + pcm_le
    if fmt == "wve":
        return b"ALawSoundFile**\0\x0f\x10" + struct.pack(">I", len(alaw)) + b"\0\0\0\1" + bytes(6) + alaw
    raise ValueError(f"Unknown legacy PCM format: {fmt}")


def mono_wave_header(rate, frames):
    return struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + frames * 2,
        b"WAVE",
        b"fmt ",
        16,
        1,
        1,
        rate,
        rate * 2,
        2,
        16,
        b"data",
        frames * 2,
    )


def rice(value, width):
    quotient, remainder = divmod(value, 1 << width)
    suffix = f"{remainder:0{width}b}" if width else ""
    return "0" * quotient + "1" + suffix


def rice_deltas(samples, previous):
    for sample in samples:
        delta = sample - previous
        yield rice(2 * delta if delta >= 0 else -2 * delta - 1, 11)
        previous = sample


def pack_bit_strings(bits):
    payload = "".join(bits)
    length = (len(payload) + 7) // 8
    return int(payload.ljust(length * 8, "0"), 2).to_bytes(length, "big")


def interplay_acm():
    rate, block_samples = 22050, 576
    blocks = round(rate * 1.25 / block_samples)
    frame_count = blocks * block_samples
    level = 0  # One untransformed column.
    header = b"\x97\x28\x03\x01" + struct.pack("<IHHH", frame_count, 1, rate, block_samples << 4 | level)
    samples = list(round(30 * sample) + 32 for sample in tone(rate, frame_count))
    prefix = [(6, 4), (300, 16), (6, 5)]  # Six-bit linear codes at 300 PCM units per step.
    bits = []
    for start in range(0, frame_count, block_samples):
        fields = (*prefix, *((sample, 6) for sample in samples[start : start + block_samples]))
        bits.extend(f"{value:0{width}b}"[::-1] for value, width in fields)
    reverse_bits = bytes(int(f"{value:08b}"[::-1], 2) for value in range(256))
    return header + pack_bit_strings(bits).translate(reverse_bits)


def apac(depth):
    rate, frames, block_size = 16000, 20000, 8
    offset, amplitude = (-128, 40) if depth == 8 else (0, 6000)
    samples = [offset + round(amplitude * sample) for sample in tone(rate, frames)]
    width = 10 if depth == 8 else 16
    bits = []
    previous, previous_delta = 0, 0
    for start in range(0, frames, block_size):
        # APAC codes each eight-sample group as zigzagged second differences.
        bits.append(f"110{width:05b}" if start == 0 and width != depth else "0")
        for sample in samples[start : start + block_size]:
            delta = sample - previous
            residual = delta - previous_delta
            coded = 2 * residual if residual >= 0 else -2 * residual - 1
            bits.append(f"{coded:0{width}b}")
            previous, previous_delta = sample, delta
    format_chunk = struct.pack("<HHIHH", 0, 1, rate, 0, depth)
    payload = pack_bit_strings(bits)
    return (
        b"APAC"
        + struct.pack("<I", 36 + len(payload))
        + b"PROFNAD \0\0\0\0PFMT"
        + struct.pack("<I", len(format_chunk))
        + format_chunk
        + b"PAD \0\0\0\0"
        + payload
    )


def mtaf():
    block_frames = 256
    block_count = round(PCM_FRAMES / block_frames)
    header = bytearray(0x800)
    header[:4], header[0x40:0x44] = b"MTAF", b"HEAD"
    struct.pack_into("<I", header, 0x5C, block_count * block_frames)
    header[0x61] = 1  # One stereo pair.

    # At the largest step, codes 7 and 15 move the predictor by +/-6365
    # and keep the step index saturated. Follow a 440 Hz square wave.
    predictor = 0
    signal = iter(tone(PCM_RATE, block_count * block_frames))
    for _ in range(block_count):
        header.extend(struct.pack("<4xHHh2xh2x", 31, 31, predictor, predictor))
        codes = []
        for _ in range(block_frames):
            target = 9500 if next(signal) >= 0 else -9500
            code = 7 if predictor < target else 15
            codes.append(code)
            predictor += 6365 if code == 7 else -6365
        channel = bytes(low | high << 4 for low, high in zip(codes[::2], codes[1::2]))
        header.extend(channel * 2)
    return bytes(header)


def shorten():
    rate, frames, block_size = 16000, 20000, 256
    samples = [round(6000 * sample) for sample in tone(rate, frames)]
    wave_header = mono_wave_header(rate, frames)

    def variable_uint(value):
        width = value.bit_length()
        return rice(width, 2) + rice(value, width)

    # Version 2 stream with signed little-endian samples, one channel,
    # no LPC coefficients, no running mean and no skipped leading bytes.
    bits = [variable_uint(value) for value in (5, 1, block_size, 0, 0, 0)]
    bits.extend((rice(9, 2), rice(len(wave_header), 5)))  # Verbatim WAVE header.
    bits.extend(rice(byte, 8) for byte in wave_header)
    for start in range(0, frames, block_size):
        block = samples[start : start + block_size]
        if len(block) != block_size:
            bits.extend((rice(5, 2), variable_uint(len(block))))  # Short final block.
        bits.extend((rice(1, 2), rice(10, 3)))  # First-order prediction.
        bits.extend(rice_deltas(block, samples[start - 1] if start else 0))
    bits.append(rice(4, 2))  # End of stream.
    return b"ajkg\x02" + pack_bit_strings(bits) + bytes(4)


WAVARC_PREDICTORS = {
    # Frames per block, first-order predictor command and end-of-stream command.
    "1dif": (256, 1, 8),
    "2slp": (570, 1, 9),
    "3nlp": (570, 1, 9),
    "4alp": (570, 1, 9),
    "5elp": (570, 3, 12),
}


def wavarc(mode):
    rate = PSX_RATE
    if mode == "0cpy":
        frames = round(rate * 1.25)
        data = struct.pack(f"<{frames}h", *(round(6000 * sample) for sample in tone(rate, frames)))
    else:
        block_frames, predictor, end = WAVARC_PREDICTORS[mode]
        frames = round(rate * 1.25 / block_frames) * block_frames
        samples = [round(6000 * sample) for sample in tone(rate, frames)]
        bits = []
        for start in range(0, frames, block_frames):
            bits.extend((rice(predictor, 1), rice(10, 2)))
            bits.extend(rice_deltas(samples[start : start + block_frames], samples[start - 1] if start else 0))
        bits.append(rice(end, 1))
        data = pack_bit_strings(bits)
    filename = b"tone.wav"
    header = mono_wave_header(rate, frames)
    return (
        bytes([len(filename)])
        + filename
        + b"\0"
        + mode.upper().encode("ascii")
        + struct.pack(
            "<4I",
            0,
            len(header) + len(data),
            0,
            0,
        )
        + header
        + data
    )


def hcom(differential):
    frames = 4 * round(PSX_RATE * 1.25 / 4)
    samples = [round(128 + 35 * sample) for sample in tone(PSX_RATE, frames)]
    if differential:
        signal = bytes((sample - prior) & 255 for sample, prior in zip(samples, [128, *samples[:-1]]))
    else:
        signal = bytes(samples)

    # A balanced eight-bit Huffman tree. Leaves carry a literal or a delta.
    branches = b"".join(struct.pack(">2h", 2 * i + 1, 2 * i + 2) for i in range(255))
    leaves = b"".join(struct.pack(">2h", -1, sample) for sample in range(256))
    fork = b"HCOM" + struct.pack(">4IH", frames, 0, differential, 1, 511) + branches + leaves + b"\0\x80" + signal
    macbinary = bytearray(128)
    macbinary[:6] = b"\0\x04Tone"
    macbinary[65:69] = b"FSSD"
    struct.pack_into(">I", macbinary, 83, len(fork))
    return macbinary + fork


def wady():
    # WADY supports absolute samples and nonuniform differential steps.
    # This subset spans the range needed for the authored tone.
    steps = (0, 2, 4, 8, 15, 32, 49, 70, 95, 124, 160, 200, 240, 300, 380, 475, 580, 700, 800, 900, 1000)
    codes = (0, 1, 2, 4, 7, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 59, 61, 62, 63)
    frames = round(PSX_RATE * 1.25)
    data = bytearray()
    value = 0
    for index, sample in enumerate(tone(PSX_RATE, frames)):
        target = round(6000 * sample)
        if index % 1024 == 0:
            value = round(target / 512) * 512
            data.append(0x80 | ((value // 512) & 127))
        else:
            error = target - value
            code = min(range(len(steps)), key=lambda i: abs(abs(error) - steps[i]))
            step = steps[code]
            value += step if error >= 0 else -step
            data.append(codes[code] | (0x40 if error < 0 else 0))
    return b"WADY" + struct.pack("<BBHIII28x", 0, 1, 1, PSX_RATE, 0, frames) + data


def dpcm_signal(cubic, rate, frames):
    # Even codes reset the predictor, and odd codes add to the previous sample.
    values = range(-126, 128)
    quantized = [int(code**3 / 64) if cubic else abs(code) * code * 2 for code in values]
    tables = (quantized[::2], quantized[1::2])
    previous = 0
    data = bytearray()
    for sample in tone(rate, frames):
        target = round(6000 * sample)
        choices = []
        for delta, table in enumerate(tables):
            baseline = previous if delta else 0
            upper = min(bisect_left(table, target - baseline), len(table) - 1)
            for index in (max(0, upper - 1), upper):
                choices.append((values[2 * index + delta], baseline + table[index]))
        code, previous = min(choices, key=lambda item: abs(target - item[1]))
        data.append(code & 255)
    return data


def aiff_dpcm(cubic):
    frames = round(PSX_RATE * 1.25)
    tag = b"CBD2" if cubic else b"SDX2"
    return aifc(PSX_RATE, tag, tag, frames, dpcm_signal(cubic, PSX_RATE, frames))


def sga():
    clock = 1387
    rate = round(clock * 12500000 / 786432)
    frames = round(rate * 1.25)
    samples = [round(45 * sample) for sample in tone(rate, frames)]
    data = bytearray()
    for start in range(0, frames, 1536):
        block = samples[start : start + 1536]
        data.extend(struct.pack(">BBH4xHBx", 0xAA, 0, 8 + len(block), clock, 1))
        data.extend(abs(sample) | (0x80 if sample < 0 else 0) for sample in block)
    return data


def psx_frames(rate=PSX_RATE, blocks_per_chunk=1):
    samples_per_block = 28
    blocks = round(rate * 1.25 / (samples_per_block * blocks_per_chunk)) * blocks_per_chunk
    samples = list(signed_nibbles(tone(rate, blocks * samples_per_block)))
    # Predictor zero is a signed 4-bit sample scaled by 2^(12-shift). A shift of 2
    # makes the decoded amplitude comparable to the other generated audio.
    packets = []
    for offset in range(0, len(samples), samples_per_block):
        decoded = samples[offset : offset + samples_per_block]
        packets.append(b"\x02\x00" + bytes(a | (b << 4) for a, b in zip(decoded[::2], decoded[1::2])))
    return b"".join(packets), len(samples)


def psx_header(fmt, size, samples):
    if fmt == "vag":
        return (b"VAGp" + struct.pack(">4I", 0x20, 0, size, PSX_RATE)).ljust(48, b"\0")
    if fmt == "svag":
        return (b"Svag" + struct.pack("<4I", size, PSX_RATE, 1, 16)).ljust(2048, b"\0")
    if fmt == "msf":
        return (b"MSF\0" + struct.pack(">4I", 3, 1, size, PSX_RATE)).ljust(64, b"\0")
    if fmt == "ads":
        return b"SShd" + struct.pack("<7I", 24, 0x10, PSX_RATE, 1, 16, 0, 0) + b"SSbd" + struct.pack("<I", size + 0x40)
    if fmt == "xvag":
        return (b"XVAG" + struct.pack("<I24x", 80) + b"fmat" + struct.pack("<4I8xI", 0x1C, 1, 0, samples, PSX_RATE)).ljust(80, b"\0")
    if fmt == "genh":
        return b"GENH" + struct.pack("<14I", 1, 16, PSX_RATE, 0, samples, 0, 64, 64, 0, 0, 0, 0, 0, 0) + bytes(4)
    if fmt == "svs":
        pitch = round(4096 * PSX_RATE / 48000)
        return b"SVS\0" + struct.pack("<12xI12x", pitch)
    if fmt == "vpk":
        return b" KPV" + struct.pack("<5I8x", size, 32, 16, PSX_RATE, 1)
    raise ValueError(f"Unknown PlayStation ADPCM format: {fmt}")


def sdx(depth):
    title = b"440 Hz tone"
    header = b"SDX:Sample Dump\x1a\x01" + bytes((len(title),)) + title
    header += struct.pack("<4xBI16x", depth, PCM_RATE)
    midpoint = 1 << (depth - 1)
    signal = (round(midpoint + midpoint * 0.18 * sample) for sample in tone(PCM_RATE, PCM_FRAMES))
    return header + b"".join(sample.to_bytes(depth // 8, "little") for sample in signal)


def sds(depth):
    def sysex_int(value):
        return bytes((value & 127, (value >> 7) & 127, (value >> 14) & 127))

    # 1.2 seconds gives complete packets for all three widths.
    frames = SDS_RATE * 6 // 5
    midpoint = 1 << (depth - 1)
    bits = ((depth + 6) // 7) * 7
    sample_shifts = tuple(range(bits - 7, -1, -7))
    samples = bytearray()
    for signal in tone(SDS_RATE, frames):
        value = round(midpoint + midpoint * 0.18 * signal) << (bits - depth)
        samples.extend((value >> shift) & 127 for shift in sample_shifts)
    header = b"\xf0\x7e\x00\x01\0\0" + bytes((depth,))
    header += sysex_int(1_000_000_000 // SDS_RATE) + sysex_int(frames) + bytes(6) + b"\x7f\xf7"
    packets = []
    for index, start in enumerate(range(0, len(samples), 120)):
        data = b"\x7e\x00\x02" + bytes((index % 128,)) + samples[start : start + 120]
        packets.append(b"\xf0" + data + bytes((reduce(xor, data), 0xF7)))
    return header + b"".join(packets)


def sol(compressed):
    samples = [round(6000 * sample) for sample in tone(PCM_RATE, PCM_FRAMES)]
    if compressed:
        # Only the small deltas are needed for adjacent samples of this tone.
        steps = (0, 8, *range(16, 0x181, 16))
        reconstructed = 0
        packed = bytearray()
        for sample in samples:
            error = sample - reconstructed
            upper = bisect_left(steps, abs(error))
            lower = max(0, upper - 1)
            index = min((lower, upper), key=lambda index: abs(abs(error) - steps[index]))
            if error < 0:
                reconstructed -= steps[index]
                packed.append(index | 128)
            else:
                reconstructed += steps[index]
                packed.append(index)
    else:
        packed = struct.pack(f"<{PCM_FRAMES}h", *samples)
    return b"\x8d\x0cSOL\0" + struct.pack("<HBIx", PCM_RATE, 5 if compressed else 4, len(packed)) + packed


def chunk(tag, contents, size_format=">I"):
    return tag + struct.pack(size_format, len(contents)) + contents + bytes(len(contents) % 2)


def pcm_tone(rate, frames, signed_16):
    samples = tone(rate, frames)
    if signed_16:
        return struct.pack(f"<{frames}h", *(round(value * 6200) for value in samples))
    return bytes(128 + round(value * 26) for value in samples)


def fourxm_pcm():
    track = chunk(b"strk", struct.pack("<II20xIII", 0, 0, 1, PCM_RATE, 8), "<I")
    pcm = pcm_tone(PCM_RATE, PCM_FRAMES, False)
    frames = []
    for offset in range(0, len(pcm), 2000):
        payload = pcm[offset : offset + 2000]
        packet = chunk(b"snd_", struct.pack("<II", 0, len(payload)) + payload, "<I")
        frames.append(chunk(b"LIST", b"FRAM" + packet, "<I"))
    header = chunk(b"LIST", b"HEAD" + track, "<I")
    return chunk(b"RIFF", b"4XMV" + header + chunk(b"LIST", b"MOVI" + b"".join(frames), "<I"), "<I")


def nsv_pcm():
    rate, fps = 12000, 24
    samples = rate // fps
    pcm = pcm_tone(rate, 30 * samples, False)
    sync = struct.pack("<4s4s4sHHBh", b"NSVs", b"NONE", b"PCM ", 0, 0, fps, 0)
    # Raw-audio records carry rate in quarter-sample units.
    packet = struct.pack("<BHHBBH", 0, 0, samples + 4, 8, 1, rate * 4)
    return sync + b"\xef\xbe".join(packet + pcm[start : start + samples] for start in range(0, len(pcm), samples))


def idcin_pcm():
    rate, frames, width, height = 22400, 18, 32, 32
    samples = rate // 14
    pcm = pcm_tone(rate, frames * samples, False)
    # Every previous-color context has the same two one-bit leaf codes.
    huffman = (b"\x01\x01" + bytes(254)) * 256
    palette = bytes((235, 40, 30, 32, 70, 218)) + bytes(762)
    encoded = b"\x00\xff" * (width * height // 16)
    picture = struct.pack("<II", len(encoded) + 4, width * height) + encoded
    media = bytearray(struct.pack("<5I", width, height, rate, 1, 1) + huffman)
    for frame in range(frames):
        media.extend(struct.pack("<I", int(frame == 0)))
        if frame == 0:
            media.extend(palette)
        start = frame * samples
        media.extend(picture + pcm[start : start + samples])
    return media + struct.pack("<I", 2)


def vqa_pcm(signed_16):
    rate, fps, frames = 22050, 15, 19
    samples = rate // fps
    pcm = pcm_tone(rate, frames * samples, signed_16)
    size = samples * (2 if signed_16 else 1)
    header = bytearray(42)
    struct.pack_into("<5H4BH", header, 0, 2, 0, frames, 16, 16, 4, 4, fps, 0, 256)
    struct.pack_into("<HBB", header, 24, rate, 1, 16 if signed_16 else 8)
    form = b"WVQA" + chunk(b"VQHD", header)
    # Each 4x4 cell uses a solid-color vector. Store the frame map as a literal run.
    palette = chunk(b"CPL0", bytes((59, 13, 10, 10, 18, 53)))
    cells = b"\0\1\0\1" * 4 + b"\xff" * 16
    picture = chunk(b"VQFR", palette + chunk(b"VPTZ", bytes((0x80 | len(cells),)) + cells + b"\x80"))
    packets = [chunk(b"SND0", pcm[i : i + size]) + picture for i in range(0, len(pcm), size)]
    position = 8 + len(form) + 8 + frames * 4
    index = bytearray()
    for packet in packets:
        index.extend(struct.pack("<I", position // 2))
        position += len(packet)
    return chunk(b"FORM", form + chunk(b"FINF", index) + b"".join(packets))


def smacker(packets, rate, audio_flags):
    # Three unused picture trees and a single TYPE leaf encode a 4x4 fill in palette entry one.
    fields = (
        (0, 3),
        (1, 1),
        (1, 1),
        (0, 1),
        (3, 8),
        (0, 1),
        (1, 1),
        (0, 1),
        (1, 8),
        (0, 1),
        (0x4000, 16),
        (0x4001, 16),
        (0x4002, 16),
        (0, 1),
        (0, 1),
    )
    value, position = 0, 0
    for bits, count in fields:
        value |= bits << position
        position += count
    tree = value.to_bytes((position + 7) // 8, "little")
    palette = bytes((3, 0, 0, 0, 6, 37, 55, 0xFF, 0xFD, 0, 0, 0))
    bodies = []
    for index, audio in enumerate(packets):
        frame = (palette if index == 0 else b"") + struct.pack("<I", len(audio) + 4) + audio + b"\0"
        bodies.append(frame + bytes(-len(frame) % 4))
    header = struct.pack("<4s5I28xI12xII28x", b"SMK2", 4, 4, len(bodies), 50, 0, len(tree), 16, rate | (audio_flags << 24))
    sizes = struct.pack(f"<{len(bodies)}I", *(len(body) for body in bodies))
    flags = b"\x03" + b"\x02" * (len(bodies) - 1)
    return header + sizes + flags + tree + b"".join(bodies)


def smacker_pcm(signed_16):
    rate, frames, samples = 22050, 25, 1102
    pcm = pcm_tone(rate, frames * samples, signed_16)
    size = samples * (2 if signed_16 else 1)
    packets = [pcm[offset : offset + size] for offset in range(0, len(pcm), size)]
    if not signed_16:
        # This reader takes the first four bytes as the duration for 8-bit PCM.
        packets = [struct.pack("<I", size) + packet[4:] for packet in packets]
    return smacker(packets, rate, 0x20 if signed_16 else 0)


def extended_sample_rate(rate):
    bits = rate.bit_length()
    return struct.pack(">HQ", 16382 + bits, rate << (64 - bits))


def aifc(rate, tag, name, blocks, data, extra_chunks=b"", *, channels=1):
    compression_name = bytes((len(name),)) + name
    compression_name += bytes(len(compression_name) % 2)
    common = struct.pack(">HIH", channels, blocks, 16) + extended_sample_rate(rate) + tag + compression_name
    return chunk(
        b"FORM",
        b"AIFC" + chunk(b"FVER", struct.pack(">I", 0xA2805140)) + chunk(b"COMM", common) + extra_chunks + chunk(b"SSND", bytes(8) + data),
    )


def big_endian_pcm_caf(rate):
    frames = rate * 5 // 4
    samples = (round((1 << 60) * sample) for sample in tone(rate, frames))
    pcm = struct.pack(f">{frames}q", *samples)
    # Nonfloating, big-endian LPCM, one frame per packet and one channel.
    description = struct.pack(">d4s5I", rate, b"lpcm", 0, 8, 1, 1, 64)
    return b"caff" + struct.pack(">2H", 1, 0) + chunk(b"desc", description, ">Q") + chunk(b"data", bytes(4) + pcm, ">Q")


def telephone_gsm(microsoft):
    # The second 100 ms of an 8 kHz, 440 Hz sine encoded with libsndfile's GSM 06.10
    # encoder. Repeat the stationary part so fixture generation needs no GSM encoder.
    period = bytes.fromhex(
        "d238ec29a26ea0325db626dcbac048dc91c6e5e08038db91b923e08039236e4ad2"
        "d236ec6de28d40491a7634edd54042a6d0a7b46d40252d694b1a6d4029224a5ad2"
        "d236ec6da2d90039634e588a9540569db5a72d6d6034a5ad2923912034e588bb63"
        "d237ec29a2db2037236a4b6392c04b636e5894daa0491376c6a5da805893b634e5"
        "d235ec6de2912044e684cd996dc03de12b58d16d606ac99ac25d93405654b5a735"
    )
    if not microsoft:
        return period * 12

    # WAV49 packs two GSM frames without the initial magic nibbles. Each codec
    # field keeps its value but is written into the block's little-endian bit order.
    widths = (6, 6, 5, 5, 4, 4, 3, 3) + ((7, 2, 2, 6) + (3,) * 13) * 4
    packets = period * 2
    blocks = bytearray()
    for start in range(0, len(packets), 66):
        block, destination = 0, 0
        for offset in (start, start + 33):
            value = int.from_bytes(packets[offset : offset + 33], "big")
            source = 260
            for width in widths:
                source -= width
                block |= ((value >> source) & ((1 << width) - 1)) << destination
                destination += width
        blocks.extend(block.to_bytes(65, "little"))

    wav_format = struct.pack("<HHIIHHHH", 49, 1, 8000, 1625, 65, 0, 2, 320)
    return chunk(
        b"RIFF",
        b"WAVE" + chunk(b"fmt ", wav_format, "<I") + chunk(b"fact", struct.pack("<I", 9600), "<I") + chunk(b"data", blocks * 6, "<I"),
        "<I",
    )


def vidc(rate):
    # VIDC stores the sign in bit zero, with four quantizer bits and three segment bits.
    levels = [((132 + 8 * code) << segment) - 132 for segment in range(8) for code in range(16)]
    midpoints = [(a + b) // 2 for a, b in zip(levels, levels[1:])]
    samples = (round(6000 * sample) for sample in tone(rate, round(rate * 1.25)))
    return bytes((bisect_left(midpoints, abs(sample)) << 1) | (sample < 0) for sample in samples)


def iff_audio(codec):
    rate = PSX_RATE
    frames = 2 * (rate * 5 // 8)
    if codec == "pcm_s16be_planar":
        form, compression = b"16SV", 0
        data = struct.pack(f">{frames}h", *(round(6000 * sample) for sample in tone(rate, frames)))
    elif codec == "pcm_s8_planar":
        form, compression = b"8SVX", 0
        data = bytes(round(24 * sample) & 255 for sample in tone(rate, frames))
    else:
        form = b"8SVX"
        if codec == "8svx_fib":
            compression = 1
            steps = (-34, -21, -13, -8, -5, -3, -2, -1, 0, 1, 2, 3, 5, 8, 13, 21)
        else:
            compression = 2
            steps = (-128, -64, -32, -16, -8, -4, -2, -1, 0, 1, 2, 4, 8, 16, 32, 64)
        reconstructed = 0
        nibbles = []
        for sample in tone(rate, frames):
            error = round(24 * sample) - reconstructed
            index = min(range(16), key=lambda index: abs(error - steps[index]))
            reconstructed += steps[index]
            nibbles.append(index)
        data = bytes(2) + bytes(low | (high << 4) for low, high in zip(nibbles[::2], nibbles[1::2]))
    header = struct.pack(">IIIHBBI", frames, 0, 0, rate, 1, compression, 65536)
    return chunk(b"FORM", form + chunk(b"VHDR", header) + chunk(b"BODY", data))


@lru_cache(maxsize=1)
def dsd_signal():
    # First-order sigma-delta modulation of the 440 Hz input into MSB-first bytes.
    error = 0.0
    packed = bytearray(DSD_BIT_RATE * 5 // 32)
    samples = tone(DSD_BIT_RATE, len(packed) * 8)
    for index in range(len(packed)):
        value = 0
        for _ in range(8):
            error += 0.2 * next(samples)
            bit = error >= 0.0
            error -= 1 if bit else -1
            value = (value << 1) | bit
        packed[index] = value
    return bytes(packed)


def dsd_fixture(fmt, codec):
    signal = dsd_signal()
    if fmt == "dsf":
        lsb_first = codec == "dsd_lsbf_planar"
        if lsb_first:
            bit_reverse = bytes(int(f"{value:08b}"[::-1], 2) for value in range(256))
            signal = signal.translate(bit_reverse)
        block_size = 4096
        data = signal + bytes(-len(signal) % block_size)
        description = b"fmt " + struct.pack("<Q6IQ2I", 52, 1, 0, 1, 1, DSD_BIT_RATE, 1 if lsb_first else 8, len(signal) * 8, block_size, 0)
        header = b"DSD " + struct.pack("<3Q", 28, 28 + len(description) + 12 + len(data), 0)
        return header + description + b"data" + struct.pack("<Q", len(data) + 12) + data
    if fmt == "wsd":
        header = bytearray(128)
        header[:4] = b"1bit"
        header[8] = 0x10
        struct.pack_into(">II", header, 20, 128, 2048)
        struct.pack_into(">I", header, 36, DSD_BIT_RATE)
        header[44] = 1
        struct.pack_into(">I", header, 48, 1 << 28)
        return header + b" " * (2048 - len(header)) + signal
    properties = b"SND " + b"".join(
        chunk(tag, content, ">Q")
        for tag, content in (
            (b"FS  ", struct.pack(">I", DSD_BIT_RATE)),
            (b"CHNL", b"\0\1C   "),
            (b"CMPR", b"DSD \x03DSD"),
        )
    )
    version = chunk(b"FVER", b"\x01\x05\0\0", ">Q")
    return chunk(b"FRM8", b"DSD " + version + chunk(b"PROP", properties, ">Q") + chunk(b"DSD ", signal, ">Q"), ">Q")


PSX_FORMATS = tuple(
    (f"playstation.{fmt}", fmt, "adpcm_psx", PSX_RATE) for fmt in ("vag", "svag", "msf", "ads", "xvag", "genh", "svs", "vpk")
)
FORMATS = (
    *PCM_FORMATS,
    *PSX_FORMATS,
    *((f"sample-dump-u{depth}.sdx", "sdx", f"pcm_u{depth}{'le' if depth > 8 else ''}", PCM_RATE) for depth in (8, 16, 24, 32)),
    *((f"midi-dump-{depth}.sds", "sds", "pcm_u32le", SDS_RATE) for depth in (12, 16, 24)),
    ("sierra-pcm.sol", "sol", "pcm_s16le", PCM_RATE),
    ("sierra-dpcm.sol", "sol", "sol_dpcm", PCM_RATE),
    ("8svx-pcm.8svx", "iff", "pcm_s8_planar", PSX_RATE),
    ("8svx-fibonacci.8svx", "iff", "8svx_fib", PSX_RATE),
    ("8svx-exponential.8svx", "iff", "8svx_exp", PSX_RATE),
    ("16sv-pcm.16sv", "iff", "pcm_s16be_planar", PSX_RATE),
    ("shorten.shn", "shn", "shorten", 16000),
    ("interplay.acm", "acm", "interplayacm", PSX_RATE),
    ("apac-8bit.apc", "apac", "apac", 16000),
    ("apac-16bit.apc", "apac", "apac", 16000),
    ("konami.mtaf", "mtaf", "adpcm_mtaf", PCM_RATE),
    *((f"waveform-archive-{mode}.wa", "wavarc", "wavarc", PSX_RATE) for mode in ("0cpy", *WAVARC_PREDICTORS)),
    ("macintosh-literal.hcom", "hcom", "hcom", PSX_RATE),
    ("macintosh-differential.hcom", "hcom", "hcom", PSX_RATE),
    ("marble.way", "wady", "wady_dpcm", PSX_RATE),
    ("sega-cd.sga", "sga", "pcm_sga", 22046),
    ("square-delta.aifc", "aiff", "sdx2_dpcm", PSX_RATE),
    ("cube-delta.aifc", "aiff", "cbd2_dpcm", PSX_RATE),
    ("dsd-lsb.dsf", "dsf", "dsd_lsbf_planar", DSD_BIT_RATE),
    ("dsd-msb.dsf", "dsf", "dsd_msbf_planar", DSD_BIT_RATE),
    ("dsd-msb.wsd", "wsd", "dsd_msbf", DSD_BIT_RATE),
    ("dsd-msb.dff", "iff", "dsd_msbf", DSD_BIT_RATE),
)


def generate(output, fmt, codec, alaw=b""):
    if any(fmt == clip[1] for clip in PSX_FORMATS):
        signal, frames = psx_frames()
        if fmt == "svs":
            # SVS stores left and right 16-byte PlayStation blocks together.
            signal = b"".join(signal[i : i + 16] * 2 for i in range(0, len(signal), 16))
        data = psx_header(fmt, len(signal), frames) + signal
    elif fmt == "sdx":
        depth = int(output.stem.rsplit("-u", 1)[1])
        data = sdx(depth)
    elif fmt == "sds":
        data = sds(int(output.stem.rsplit("-", 1)[1]))
    elif fmt == "sol":
        data = sol(codec == "sol_dpcm")
    elif fmt == "shn":
        data = shorten()
    elif fmt == "acm":
        data = interplay_acm()
    elif fmt == "apac":
        depth = 8 if output.stem.endswith("8bit") else 16
        data = apac(depth)
    elif fmt == "mtaf":
        data = mtaf()
    elif fmt == "wavarc":
        data = wavarc(output.stem.rsplit("-", 1)[1])
    elif fmt == "hcom":
        data = hcom(output.stem.endswith("-differential"))
    elif fmt == "wady":
        data = wady()
    elif fmt == "sga":
        data = sga()
    elif fmt == "aiff":
        data = aiff_dpcm(codec == "cbd2_dpcm")
    elif fmt in ("dsf", "wsd") or codec == "dsd_msbf":
        data = dsd_fixture(fmt, codec)
    elif fmt == "iff":
        data = iff_audio(codec)
    else:
        data = pcm_fixture(fmt, codec, alaw)
    output.write_bytes(data)
