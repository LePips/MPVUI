"""Record small RTP streams and their SDP parameters for loopback playback tests."""

from pathlib import Path
import socket
import struct
import subprocess
from tempfile import TemporaryDirectory, TemporaryFile
import time


VIDEO = (
    ("h261", "h261", ("-c:v", "h261", "-f_strict", "experimental"), True, True),
    ("h263", "h263", ("-c:v", "h263", "-rtpflags", "rfc2190"), False, True),
    ("h264", "h264", ("-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency"), False, False),
    # VC-2 needs enough bytes per slice to retain the authored chroma at this frame size.
    ("dirac", "dirac", ("-c:v", "vc2", "-pix_fmt", "yuv420p", "-b:v", "2M", "-strict", "experimental"), True, False),
    ("hevc", "hevc", ("-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error:pools=none"), False, False),
    ("mjpeg", "mjpeg", ("-c:v", "mjpeg", "-pix_fmt", "yuvj420p", "-huffman", "default"), False, True),
    ("mpeg1video", "mpeg1video", ("-c:v", "mpeg1video"), False, True),
    ("mpeg2video", "mpeg2video", ("-c:v", "mpeg2video"), False, True),
    ("mpeg4", "mpeg4", ("-c:v", "mpeg4"), False, False),
    ("vp8", "vp8", ("-c:v", "libvpx", "-deadline", "realtime"), False, False),
    ("vp9", "vp9", ("-c:v", "libvpx-vp9", "-deadline", "realtime", "-strict", "experimental"), False, False),
    (
        "av1",
        "libdav1d",
        ("-c:v", "libsvtav1", "-preset", "10", "-svtav1-params", "lp=1:pred-struct=1", "-strict", "experimental"),
        False,
        False,
    ),
)

AUDIO = (
    ("aac", "aac", "aac-lc.m4a", 48000, False, False),
    ("amr_nb", "amrnb", "amr-nb.amr", 8000, False, False),
    ("amr_wb", "amrwb", "amr-wb.amr", 16000, False, False),
    ("ilbc", "ilbc", "narrowband.ilbc", 8000, True, False),
    ("mp2", "mp2float", "mp2.mp2", 90000, False, True),
    ("mp3", "mp3", "reservoir-free.mp3", 90000, False, True),
    ("opus", "opus", "opus.ogg", 48000, False, False),
    ("pcm_s24be", "pcm_s24be", "pcm-s24be.aiff", 48000, False, False),
    ("speex", "speex", "speex-nb.spx", 8000, True, False),
    ("vorbis", "vorbis", "vorbis.ogg", 48000, False, False),
)

# Each record carries one authored fixed-size audio frame. AC-3 alternates
# complete and two-fragment frames to also exercise the reader's reassembly.
FIXED_AUDIO = (
    ("ac3", "ac3.ac3", "AC3", 48000, 1536, 384, False),
    ("gsm", "telephone.gsm", "GSM", 8000, 160, 33, True),
    ("mp3adu", "reservoir-free.mp3", "mpa-robust", 90000, 2160, 384, False),
)

SRTP_SUITE = "AES_CM_128_HMAC_SHA1_80"
SRTP_FIXTURE_KEY = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwd"


def filename(codec):
    return f"codecs-rtp-packetized-{codec}.bin"


def output_names():
    codecs = [codec for codec, *_ in (*VIDEO, *AUDIO, *FIXED_AUDIO)]
    return tuple(filename(codec) for codec in (*codecs, "dvvideo", "srtp-pcm_mulaw", "srtp-h264"))


def capture(output, options, *, secure=False, transport_stream=False):
    with (
        TemporaryDirectory(dir=output) as temporary,
        TemporaryFile() as errors,
        socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver,
    ):
        description = Path(temporary).resolve() / "transport.sdp"
        receiver.bind(("127.0.0.1", 0))
        receiver.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024 * 1024)
        receiver.settimeout(0.05)
        port = receiver.getsockname()[1]
        encryption = ("-srtp_out_suite", SRTP_SUITE, "-srtp_out_params", SRTP_FIXTURE_KEY) if secure else ()
        scheme = "srtp" if secure else "rtp"
        if transport_stream:
            muxer = ("-f", "rtp_mpegts", "-rtp_muxer_options", "ssrc=1297110613:seq=0")
            packet_size = 1328
        else:
            muxer = ("-f", "rtp", "-ssrc", "1297110613", "-seq", "0", "-sdp_file", str(description))
            packet_size = 200 if secure else 1300
        command = [
            "ffmpeg",
            "-nostdin",
            "-v",
            "error",
            "-y",
            *options,
            "-max_delay",
            "20000",
            *muxer,
            *encryption,
            f"{scheme}://127.0.0.1:{port}?pkt_size={packet_size}",
        ]
        datagrams = []
        with subprocess.Popen(command, cwd=output, stderr=errors) as encoder:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                try:
                    datagrams.append(receiver.recv(1500))
                except TimeoutError:
                    if encoder.poll() is not None:
                        break
            else:
                encoder.kill()
                raise TimeoutError("Recording loopback RTP packets timed out")
            if encoder.wait() != 0:
                errors.seek(0)
                raise RuntimeError(errors.read().decode())

        if transport_stream:
            return "video", 33, [], datagrams

        lines = description.read_text().splitlines()
        media_line = next(line for line in lines if line.startswith("m="))
        media, _, profile, payload = media_line[2:].split()
        assert profile == "RTP/AVP"
        attributes = [line for line in lines if line.startswith(("a=rtpmap:", "a=fmtp:", "a=framesize:", "a=crypto:"))]
        return media, int(payload), attributes, datagrams


def encode_recording(packets, payload, clock, *, preserve_headers=False):
    assert len(packets) > 1
    timestamps_origin = struct.unpack_from(">I", packets[0], 4)[0]
    timestamps = []
    for sequence, packet in enumerate(packets):
        header, kind, actual_sequence, timestamp = struct.unpack_from(">BBHI", packet)
        assert header == 0x80 and kind & 0x7F == payload and actual_sequence == sequence % 65536
        timestamps.append((timestamp - timestamps_origin) & 0xFFFFFFFF)
    deltas = [end - start for start, end in zip(timestamps, timestamps[1:])]
    assert min(deltas) >= 0 and max(deltas) > 0
    # Repeat the exact timestamps and preserve zero delay between packet fragments.
    closing_ticks = min(delta for delta in deltas if delta > 0)
    loop_ticks = timestamps[-1] + closing_ticks
    data = bytearray()
    for packet, timestamp, ticks in zip(packets, timestamps, (*deltas, closing_ticks)):
        delay = round(ticks * 1_000_000 / clock)
        data.extend(struct.pack(">HI", len(packet), delay))
        data.extend(packet if preserve_headers else packet[:4] + struct.pack(">I", timestamp) + packet[8:])

    return bytes(data), 0 if preserve_headers else loop_ticks


def store_clip(output, recording, codec, decoder, clock, android, direct, *, authenticated=False):
    media, payload, attributes, packets = recording
    data, loop_ticks = encode_recording(packets, payload, clock, preserve_headers=authenticated)
    file = filename(f"srtp-{codec}" if authenticated else codec)
    (output / file).write_bytes(data)
    return {
        "file": file,
        "media": media,
        "codec": codec,
        "decoder": decoder,
        "payloadType": payload,
        "sdpAttributes": attributes,
        "loopTicks": loop_ticks,
        "androidOnly": android,
        "direct": direct,
    }


def time_vc2_frames(recording, frame_count):
    # The host packetizer leaves VC-2 timestamps at zero. Each marker
    # completes a picture. An end-of-sequence unit follows that picture.
    media, payload, attributes, packets = recording
    frame = 0
    timed = []
    for packet in packets:
        picture = frame - 1 if packet[15] == 0x10 else frame
        timed.append(packet[:4] + struct.pack(">I", picture * 3750) + packet[8:])
        if packet[1] & 0x80:
            frame += 1
    assert frame == frame_count
    return media, payload, attributes, timed


def packetize_dv():
    # NTSC DV uses 120,000-byte frames made up of 80-byte DIF blocks.
    width, height = 720, 480
    data = subprocess.check_output(
        [
            "ffmpeg",
            "-nostdin",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            f"color=red:size={width}x{height}:rate=30000/1001:duration=1",
            "-f",
            "lavfi",
            "-i",
            f"color=blue:size={width}x{height}:rate=30000/1001:duration=1",
            "-filter_complex",
            "[0:v][1:v]concat=n=2:v=1:a=0",
            "-an",
            "-c:v",
            "dvvideo",
            "-pix_fmt",
            "yuv411p",
            "-threads:v",
            "1",
            "-f",
            "dv",
            "-",
        ]
    )
    payload_type = 96
    frame_bytes, fragment_bytes = 120000, 1280
    assert len(data) == 60 * frame_bytes
    packets = []
    for frame, offset in enumerate(range(0, len(data), frame_bytes)):
        picture = data[offset : offset + frame_bytes]
        for start in range(0, frame_bytes, fragment_bytes):
            fragment = picture[start : start + fragment_bytes]
            marker = 0x80 if start + len(fragment) == frame_bytes else 0
            header = struct.pack(">BBHII", 0x80, payload_type | marker, len(packets), frame * 3003, 0x4D505655)
            packets.append(header + fragment)
    attributes = ["a=rtpmap:96 DV/90000", "a=fmtp:96 encode=SD-VCR/525-60"]
    return ("video", payload_type, attributes, packets), width, height


def packetize_fixed_audio(output, codec, source, encoding, clock, ticks, frame_bytes):
    data = (output / f"codecs-{source}").read_bytes()
    assert data and len(data) % frame_bytes == 0, source
    payload_type = 96
    packets = []
    for frame, offset in enumerate(range(0, len(data), frame_bytes)):
        body = data[offset : offset + frame_bytes]
        if codec == "ac3":
            assert body.startswith(b"\x0b\x77")
            if frame % 2:
                fragments = (b"\x01\x02" + body[: frame_bytes // 2], b"\x03\x02" + body[frame_bytes // 2 :])
            else:
                fragments = (b"\x00\x01" + body,)
        elif codec == "mp3adu":
            fragments = (struct.pack(">H", 0x4000 | frame_bytes) + body,)
        else:
            fragments = (body,)
        for index, fragment in enumerate(fragments):
            marker = 0x80 if index == len(fragments) - 1 else 0
            header = struct.pack(">BBHII", 0x80, payload_type | marker, len(packets), frame * ticks, 0x4D505655)
            packets.append(header + fragment)
    return "audio", payload_type, [f"a=rtpmap:{payload_type} {encoding}/{clock}"], packets


def generate(output):
    video = []
    for codec, decoder, options, android, direct in VIDEO:
        # The first two authored pictures repeat with a keyframe at each transition.
        seconds = 2 if codec == "dirac" else 1
        inputs = (
            "-f",
            "lavfi",
            "-i",
            f"color=red:size=176x144:rate=24:duration={seconds}",
            "-f",
            "lavfi",
            "-i",
            f"color=blue:size=176x144:rate=24:duration={seconds}",
            "-filter_complex",
            "[0:v][1:v]concat=n=2:v=1:a=0",
            "-an",
            "-threads:v",
            "1",
            "-g",
            "12",
            "-bf",
            "0",
            *options,
        )
        recording = capture(output, inputs)
        if codec == "dirac":
            recording = time_vc2_frames(recording, 2 * seconds * 24)
        video.append(dict(store_clip(output, recording, codec, decoder, 90000, android, direct), width=176, height=144))
    recording, width, height = packetize_dv()
    video.append(dict(store_clip(output, recording, "dvvideo", "dvvideo", 90000, True, False), width=width, height=height))

    audio = []
    for codec, decoder, source, clock, android, direct in AUDIO:
        inputs = ("-i", f"codecs-{source}", "-map", "0:a:0", "-c", "copy")
        audio.append(store_clip(output, capture(output, inputs), codec, decoder, clock, android, direct))
    for codec, source, encoding, clock, ticks, frame_bytes, android in FIXED_AUDIO:
        packets = packetize_fixed_audio(output, codec, source, encoding, clock, ticks, frame_bytes)
        audio.append(store_clip(output, packets, codec, codec, clock, android, False))

    encrypted = capture(output, ("-f", "lavfi", "-i", "sine=440:sample_rate=8000:duration=6", "-c:a", "pcm_mulaw"), secure=True)
    assert encrypted[1] == 0 and f"a=crypto:1 {SRTP_SUITE} inline:{SRTP_FIXTURE_KEY}" in encrypted[2]
    secure_audio = store_clip(output, encrypted, "pcm_mulaw", "pcm_mulaw", 8000, False, False, authenticated=True)
    encrypted_transport = capture(output, ("-i", "codecs-datagrams.ts", "-map", "0", "-c", "copy"), secure=True, transport_stream=True)
    secure_video = store_clip(output, encrypted_transport, "h264", "h264", 90000, False, False, authenticated=True)
    secure_video["inputOptions"] = f"srtp_in_suite={SRTP_SUITE},srtp_in_params={SRTP_FIXTURE_KEY}"
    return video, audio, [secure_audio], secure_video
