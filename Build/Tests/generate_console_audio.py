"""Write short synthetic recordings in legacy game audio formats."""

import math
import struct

from generate_legacy_audio import aifc, chunk, dpcm_signal, extended_sample_rate, psx_frames, signed_nibbles, tone
from generate_wave_adpcm import IMA_STEPS, clamp, closest, ima_codes, pack_nibbles


NINTENDO_STREAMS = (
    ("brstm", "brstm", b"RSTM", ">", "pcm_s16be_planar", "adpcm_thp"),
    ("bfstm", "bfstm", b"FSTM", ">", "pcm_s16be_planar", "adpcm_thp"),
    ("bcstm", "bfstm", b"CSTM", "<", "pcm_s16le_planar", "adpcm_thp_le"),
)
GENH_AUDIO = {
    "adpcm_ima_wav": (1, 36, 65),
    "adpcm_dtk": (2, 16, 28),
    "pcm_s16be_planar": (3, 2048, 1024),
    "pcm_s16le_planar": (4, 2048, 1024),
    "pcm_s8_planar": (5, 1024, 1024),
    "sdx2_dpcm": (6, 1024, 1024),
    "adpcm_ima_ws": (7, 512, 1024),
    "adpcm_aica": (10, 512, 1024),
    "adpcm_thp": (12, 8, 14),
    "pcm_u8": (13, 1024, 1024),
    "adpcm_ima_qt": (17, 34, 64),
}
RSD_AUDIO = {
    "adpcm_ima_wav": (3, b"XADP"),
    "adpcm_psx": (4, b"VAG "),
    "adpcm_thp": (6, b"WADP"),
    "adpcm_thp_le": (3, b"GADP"),
    "pcm_s16be": (4, b"PCMB"),
}

FORMATS = (
    ("gamecube.dtk", "adp", "adpcm_dtk", 48000),
    ("gamecube.afc", "afc", "adpcm_afc", 32000),
    ("dreamcast-adpcm.str", "dcstr", "adpcm_aica", 22050),
    ("dreamcast-pcm.str", "dcstr", "pcm_s16le_planar", 22050),
    ("xilam.adp", "derf", "derf_dpcm", 22050),
    ("mt-framework.fwse", "fwse", "adpcm_ima_mtf", 22050),
    ("sony-pcm.ads", "ads", "pcm_s16le_planar", 22050),
    ("nintendo-afc.ast", "ast", "adpcm_afc", 32000),
    ("sony-pcm-s16be.msf", "msf", "pcm_s16be", 22050),
    ("sony-pcm-s16le.msf", "msf", "pcm_s16le", 22050),
    ("sony-mpeg-audio.msf", "msf", "mp3", 48000),
    ("sony-mpeg-audio.xvag", "xvag", "mp3", 48000),
    ("cryo.apc", "apc", "adpcm_ima_apc", 22050),
    ("funcom.iss", "iss", "adpcm_ima_iss", 22050),
    ("capcom.mca", "mca", "adpcm_thp_le", 22050),
    ("konami.xmd", "xmd", "adpcm_xmd", 22050),
    *((f"game-audio-{codec}.genh", "genh", codec, 22050) for codec in GENH_AUDIO),
    *((f"radical-{codec}.rsd", "rsd", codec, 22050) for codec in RSD_AUDIO),
    *(
        (f"nintendo-{profile}.{extension}", reader, codec, 22050)
        for extension, reader, _, _, pcm16, dsp in NINTENDO_STREAMS
        for profile, codec in (("pcm8", "pcm_s8_planar"), ("pcm16", pcm16), ("dsp", dsp))
    ),
)


def dtk(rate):
    block_frames = 28
    frames = round(rate * 1.25 / block_frames) * block_frames
    codes = [round(sample * 7) & 15 for sample in tone(rate, frames)]
    data = bytearray()
    for index, start in enumerate(range(0, frames, block_frames)):
        # DTK repeats the per-channel shift header, then interleaves the nibbles.
        shift = 2 + index % 2
        data.extend(bytes([shift]) * 4)
        data.extend(code | (code << 4) for code in codes[start : start + block_frames])
    return data


def afc_frames(rate, channels):
    block_frames = 16
    frames = round(rate * 1.25 / block_frames) * block_frames
    codes = list(signed_nibbles(tone(rate, frames)))
    data = bytearray()
    for start in range(0, frames, block_frames):
        # Predictor zero and scale 1024 produce signed four-bit samples.
        channel = b"\xa0" + pack_nibbles(iter(codes[start : start + block_frames]))
        data.extend(channel * channels)
    return data, frames


def afc(rate):
    data, frames = afc_frames(rate, 2)
    return struct.pack(">IIH22x", len(data), frames, rate) + data


def aica_codes(samples):
    scales = (230, 230, 230, 230, 307, 409, 512, 614)
    predictor, step = 0, 127
    for target in samples:
        error = target - predictor
        code, delta = closest(tuple((2 * index + 1) * step // 8 for index in range(8)), error)
        predictor = clamp(predictor + delta, -32768, 32767)
        step = clamp((step * scales[code]) >> 8, 127, 24576)
        yield code | (8 if error < 0 else 0)


def dreamcast(rate, compressed):
    alignment = 512
    block_frames = alignment * 2 if compressed else alignment // 2
    frames = round(rate * 1.25 / block_frames) * block_frames
    samples = [round(6000 * sample) for sample in tone(rate, frames)]
    header = bytearray(2048)
    struct.pack_into("<7I", header, 0, 1, rate, 4 if compressed else 16, alignment, 0, frames, 1)
    header[213:224] = b"Sega Stream"
    data = pack_nibbles(aica_codes(samples), low_first=True) if compressed else struct.pack(f"<{frames}h", *samples)
    return header + data


def derf(rate):
    steps = tuple(range(15)) + IMA_STEPS[8:]
    predictor = 0
    data = bytearray()
    for sample in tone(rate, round(rate * 1.25)):
        error = round(6000 * sample) - predictor
        code, delta = closest(steps, error)
        predictor = clamp(predictor + delta, -32768, 32767)
        data.append(code | (128 if error < 0 else 0))
    return b"DERF" + struct.pack("<II", 1, len(data)) + data


def mtf_codes(samples):
    adapt = (8, 6, 4, 2, -1, -1, -1, -1, -1, -1, -1, -1, 2, 4, 6, 8)
    predictor, index = 0, 0
    for sample in samples:
        target = round(6000 * sample)
        step = IMA_STEPS[index]
        code = clamp(round((16 * target - predictor + 15 * step) / (2 * step)), 0, 15)
        predictor = clamp((predictor + step * (2 * code - 15)) >> 4, -32768, 32767)
        index = clamp(index + adapt[code], 0, 88)
        yield code


def fwse(rate):
    frames = round(rate * 1.25 / 2) * 2
    return b"FWSE" + struct.pack("<6I", 2, 0, 28, 1, frames, rate) + pack_nibbles(mtf_codes(tone(rate, frames)))


def apc(rate):
    frames = round(rate * 1.25 / 2) * 2
    samples = (round(6000 * sample) for sample in tone(rate, frames))
    header = b"CRYO_APC1.20" + struct.pack("<5I", frames, rate, 0, 0, 0)
    return header + pack_nibbles(ima_codes(samples, 0, 0))


def iss(rate):
    packet_size = 512
    block_frames = 2 * (packet_size - 4)
    frames = round(rate * 1.25 / block_frames) * block_frames
    samples = [round(6000 * sample) for sample in tone(rate, frames)]
    packets = bytearray()
    for start in range(0, frames, block_frames):
        predictor = samples[max(0, start - 1)]
        packets.extend(struct.pack("<hH", predictor, 24))
        packets.extend(pack_nibbles(ima_codes(samples[start : start + block_frames], predictor, 24), low_first=True))
    return f"IMA_ADPCM_Sound {packet_size} 0 {2 * frames} 0 0 {44100 // rate} 0 1 {len(packets)} ".encode("ascii") + packets


def mca(rate):
    block_size = 512
    block_frames = block_size * 14 // 8
    frames = round(rate * 1.25 / block_frames) * block_frames
    samples = [code if code < 8 else code - 16 for code in signed_nibbles(tone(rate, frames))]
    data = bytearray()
    for start in range(0, frames, 14):
        channel = samples[start : start + 14]
        if start % block_frames == 0:
            # Each block starts with an absolute frame so it also decodes after a seek.
            data.append(0x0A)
            residuals = channel
        else:
            data.append(0x1A)
            residuals = [sample - previous for previous, sample in zip(samples[start - 1 : start + 13], channel)]
        data.extend(pack_nibbles((sample & 15 for sample in residuals)))
    header = b"MADP" + struct.pack("<H2xBxH6I12x", 3, 1, block_size, frames, rate, 0, frames, 96, len(data))
    # Predictor one copies the previous sample. The residual is scaled by 1024.
    coefficients = struct.pack("<4xh42x", 2048)
    return header + coefficients + data


def xmd(rate):
    block_frames = 32
    scale = 32
    frames = round(rate * 1.25 / block_frames) * block_frames
    samples = [round(6000 * sample) for sample in tone(rate, frames)]
    data = bytearray()
    for start in range(0, frames, block_frames):
        previous, current = samples[start : start + 2]
        data.extend(struct.pack("<hhH", previous, current, scale))
        codes = []
        for sample in samples[start + 2 : start + block_frames]:
            prediction = (current * 3667 - previous * 1642) >> 11
            residual = clamp(round((sample - prediction) / scale), -8, 7)
            previous, current = current, clamp(prediction + residual * scale, -32768, 32767)
            codes.append(residual & 15)
        data.extend(pack_nibbles(iter(codes), low_first=True))
    return b"xmd\x01" + struct.pack("<HI7x", rate, len(data)) + data


def dsp_frames(rate, frames):
    codes = list(signed_nibbles(tone(rate, frames)))
    # Predictor zero and shift 10. Each 8-byte frame expands to 14 samples.
    return b"".join(b"\x0a" + pack_nibbles(iter(codes[i : i + 14])) for i in range(0, frames, 14))


def ima_blocks(rate, frames, quicktime=False):
    block_frames = 64 if quicktime else 65
    samples = [round(6000 * sample) for sample in tone(rate, frames)]
    packets = bytearray()
    step_index = 47
    for start in range(0, frames, block_frames):
        block = samples[start : start + block_frames]
        predictor = block[0]
        if quicktime:
            predictor &= ~0x7F
            packets.extend(struct.pack(">h", predictor | step_index))
        else:
            packets.extend(struct.pack("<hBx", predictor, step_index))
            block = block[1:]
        packets.extend(pack_nibbles(ima_codes(block, predictor, step_index), low_first=True))
    return packets


def genh(rate, codec):
    codec_tag, block_bytes, block_frames = GENH_AUDIO[codec]
    frames = round(rate * 1.25 / block_frames) * block_frames
    channels = 1
    if codec == "adpcm_dtk":
        channels = 2
        data = dtk(rate)
    elif codec in ("adpcm_ima_wav", "adpcm_ima_qt"):
        data = ima_blocks(rate, frames, quicktime=codec == "adpcm_ima_qt")
    elif codec == "adpcm_thp":
        data = dsp_frames(rate, frames)
    elif codec == "sdx2_dpcm":
        data = dpcm_signal(False, rate, frames)
    elif codec == "pcm_u8":
        data = bytes(round(128 + 26 * sample) for sample in tone(rate, frames))
    elif codec == "pcm_s8_planar":
        data = bytes(round(26 * sample) & 255 for sample in tone(rate, frames))
    elif codec in ("pcm_s16be_planar", "pcm_s16le_planar"):
        endian = ">" if codec == "pcm_s16be_planar" else "<"
        data = struct.pack(f"{endian}{frames}h", *(round(6000 * sample) for sample in tone(rate, frames)))
    else:
        samples = [round(6000 * sample) for sample in tone(rate, frames)]
        codes = aica_codes(samples) if codec == "adpcm_aica" else ima_codes(samples, 0, 0)
        data = pack_nibbles(codes, low_first=True)
    # The DSP decoder loads a 32-byte coefficient table immediately before the audio.
    offset = 96 if codec == "adpcm_thp" else 64
    header = b"GENH" + struct.pack("<14I", channels, block_bytes, rate, 0, frames, codec_tag, offset, 64, 64, 0, 0, 0, 0, 0)
    return header.ljust(offset, b"\0") + data


def rsd(rate, codec):
    version, tag = RSD_AUDIO[codec]
    header = b"RSD" + bytes((48 + version,)) + struct.pack("<4s5I", tag, 1, 16, rate, 0, 0x800)
    if codec == "adpcm_psx":
        data, _ = psx_frames(rate)
    elif codec == "adpcm_ima_wav":
        data = ima_blocks(rate, round(rate * 1.25 / 65) * 65)
    elif codec in ("adpcm_thp", "adpcm_thp_le"):
        # Zero coefficients make the same predictor-zero frames valid in either byte order.
        data = dsp_frames(rate, round(rate * 1.25 / 14) * 14)
    else:
        samples = [round(6000 * sample) for sample in tone(rate, round(rate * 1.25))]
        data = struct.pack(f">{len(samples)}h", *samples)
    return header.ljust(0x800, b"\0") + data


def ast_afc(rate):
    data, frames = afc_frames(rate, 1)
    blocks = bytearray()
    block_size = 9 * 64
    for start in range(0, len(data), block_size):
        block = data[start : start + block_size]
        blocks.extend(struct.pack(">4sI24x", b"BLCK", len(block)))
        blocks.extend(block)
    return struct.pack(">4sI4HII40x", b"STRM", len(blocks), 0, 16, 1, 0, rate, frames) + blocks


def pcm16(rate, *, little_endian):
    frames = round(rate * 1.25)
    byte_order = "<" if little_endian else ">"
    return struct.pack(f"{byte_order}{frames}h", *(round(6000 * sample) for sample in tone(rate, frames)))


def ads_pcm(rate):
    data = pcm16(rate, little_endian=True)
    header = b"SShd" + struct.pack("<7I", 24, 1, rate, 1, 1024, 0, 0) + b"SSbd" + struct.pack("<I", len(data))
    return header + data


def sony_audio(path, fmt, codec, rate):
    if codec == "mp3":
        mp3 = path.with_name("codecs-mp3-fixed.mp3").read_bytes()
        data = mp3[mp3.index(b"\xff\xfb") :]
        tag = 7
    else:
        tag = int(codec == "pcm_s16le")
        data = pcm16(rate, little_endian=bool(tag))
    if fmt == "xvag":
        header = b"XVAG" + struct.pack("<I24x", 80)
        header += b"fmat" + struct.pack("<4I8xI", 0x1C, 1, 0, round(rate * 1.25), rate)
        return header.ljust(80, b"\0") + data
    return struct.pack(">4s4I44x", b"MSF\0", tag, 1, len(data), rate) + data


def nintendo_stream(rate, tag, endian, encoding):
    modern = tag != b"RSTM"
    compressed = encoding == 2
    block_frames = 14 * 32 if compressed else 512
    frames = round(rate * 1.25 / block_frames) * block_frames
    if compressed:
        payload = dsp_frames(rate, frames)
        block_bytes = block_frames * 8 // 14
        last_frames, last_bytes = block_frames, block_bytes
    else:
        last_frames = 14
        frames += last_frames
        samples = tone(rate, frames)
        if encoding == 1:
            payload = struct.pack(f"{endian}{frames}h", *(round(6000 * sample) for sample in samples))
        else:
            payload = struct.pack(f"{frames}b", *(round(32 * sample) for sample in samples))
        block_bytes = block_frames * (encoding + 1)
        last_bytes = last_frames * (encoding + 1)
    blocks = math.ceil(frames / block_frames)

    def section(tag, data):
        return tag + struct.pack(endian + "I", len(data) + 8) + data

    header_size, info_size = 64, 128
    info = bytearray(info_size - 8)
    struct.pack_into(endian + "I", info, 4, 24)  # Stream info offset relative to the section's body.
    seek_table = b""
    if compressed:
        if modern:
            struct.pack_into(endian + "I", info, 20, 56)
            struct.pack_into(endian + "I", info, 64, 8)
        else:
            struct.pack_into(endian + "I", info, 20, 64)
            struct.pack_into(endian + "II", info, 72, 80, 80)
        # Zero predictor coefficients and zero previous samples for each block.
        seek_table = section(b"SEEK" if modern else b"ADPC", bytes(blocks * 4))

    data_offset = header_size + info_size + len(seek_table)
    stream = bytes((encoding, 0, 1, 0))
    stream += struct.pack(endian + ("III" if modern else "H2xII"), rate, 0, frames)
    if not modern:
        stream += struct.pack(endian + "I", data_offset + 8)
    stream += struct.pack(endian + "6I", blocks, block_bytes, block_frames, last_bytes, last_frames, last_bytes)
    info[24 : 24 + len(stream)] = stream
    info_section = section(b"INFO" if modern else b"HEAD", info)
    data = section(b"DATA", (bytes(24) if modern and compressed else b"") + payload)
    size = data_offset + len(data)
    header = tag + struct.pack(endian + "H", 0xFEFF)
    if modern:
        header += struct.pack(endian + "HIIH2x", header_size, 0x30000, size, 3 if compressed else 2)
        header += struct.pack(endian + "H2xII", 0x4000, header_size, info_size)
        if compressed:
            header += struct.pack(endian + "H2xII", 0x4001, header_size + info_size, len(seek_table))
        header += struct.pack(endian + "H2xII", 0x4002, data_offset, len(data))
    else:
        header += b"\x01\0" + struct.pack(endian + "IH", size, header_size)
    return header.ljust(header_size, b"\0") + info_section + seek_table + data


def n64_aifc(rate):
    frames_per_block = 16
    blocks = round(rate * 1.25 / frames_per_block)
    samples = list(signed_nibbles(tone(rate, blocks * frames_per_block)))
    data = bytearray()
    for start in range(0, len(samples), frames_per_block):
        # Predictor zero and scale 1024 store the tone as signed four-bit samples.
        data.append(0xA0)
        data.extend(pack_nibbles(iter(samples[start : start + frames_per_block])))
    codebook = chunk(b"APPL", b"stoc\x0bVADPCMCODES" + struct.pack(">3H", 1, 2, 1) + bytes(32))
    return aifc(rate, b"VAPC", b"VADPCM", blocks, data, codebook)


def westwood_aifc(rate):
    frames = 2 * round(rate * 1.25 / 2)
    samples = (round(6000 * sample) for sample in tone(rate, frames))
    data = pack_nibbles(ima_codes(samples, 0, 0), low_first=True)
    return aifc(rate, b"ADP4", b"IMA ADPCM", len(data), data)


def xa_aiff(rate):
    units, unit_frames = 8, 28
    group_frames = units * unit_frames
    frames = round(rate * 1.25 / group_frames) * group_frames
    codes = list(signed_nibbles(tone(rate, frames)))
    data = bytearray()
    for start in range(0, frames, group_frames):
        # Predictor zero and shift two. Four bytes per row pair eight units of samples.
        data.extend(b"\x02" * 16)
        for frame in range(unit_frames):
            for unit in range(0, units, 2):
                offset = start + unit * unit_frames + frame
                data.append(codes[offset] | (codes[offset + unit_frames] << 4))
    common = struct.pack(">HIH", 1, frames, 16) + extended_sample_rate(rate)
    return chunk(b"FORM", b"AIFF" + chunk(b"COMM", common) + chunk(b"APCM", struct.pack(">II", 0, 128) + data))


def qoa(rate):
    frame_samples = 400
    slice_samples = 20
    samples = [round(6000 * sample) for sample in tone(rate, round(rate * 1.25))]
    data = bytearray(struct.pack(">4sI", b"qoaf", len(samples)))
    # Scale factor seven has eight signed residuals. Choose the nearest one
    # to each target and feed the reconstructed sample back into the predictor.
    residuals = (228, -228, 760, -760, 1368, -1368, 2128, -2128)
    for start in range(0, len(samples), frame_samples):
        frame = samples[start : start + frame_samples]
        size = 24 + 8 * math.ceil(len(frame) / slice_samples)
        data.extend(struct.pack(">IHH", (1 << 24) | rate, len(frame), size))
        history, weights = [0] * 4, [0] * 4
        data.extend(struct.pack(">8h", *history, *weights))
        for offset in range(0, len(frame), slice_samples):
            encoded = 7 << 60
            for index, sample in enumerate(frame[offset : offset + slice_samples]):
                prediction = sum(weight * prior for weight, prior in zip(weights, history)) >> 13
                code = min(range(len(residuals)), key=lambda i: abs(sample - prediction - residuals[i]))
                residual = residuals[code]
                delta = residual >> 4
                weights = [weight + (-delta if prior < 0 else delta) for weight, prior in zip(weights, history)]
                history = history[1:] + [clamp(prediction + residual, -32768, 32767)]
                encoded |= code << (57 - 3 * index)
            data.extend(encoded.to_bytes(8, "big"))
    return data


def generate(output, fmt, codec, rate):
    if fmt == "genh":
        output.write_bytes(genh(rate, codec))
        return
    if fmt == "rsd":
        output.write_bytes(rsd(rate, codec))
        return
    if fmt in ("msf", "xvag"):
        output.write_bytes(sony_audio(output, fmt, codec, rate))
        return
    if fmt in {"brstm", "bfstm"}:
        _, _, tag, endian, pcm16, _ = next(spec for spec in NINTENDO_STREAMS if output.suffix == "." + spec[0])
        encoding = ("pcm_s8_planar", pcm16).index(codec) if codec.startswith("pcm_") else 2
        output.write_bytes(nintendo_stream(rate, tag, endian, encoding))
        return
    generators = {
        "adp": dtk,
        "ads": ads_pcm,
        "afc": afc,
        "ast": ast_afc,
        "derf": derf,
        "fwse": fwse,
        "apc": apc,
        "iss": iss,
        "mca": mca,
        "xmd": xmd,
    }
    data = dreamcast(rate, codec == "adpcm_aica") if fmt == "dcstr" else generators[fmt](rate)
    output.write_bytes(data)
