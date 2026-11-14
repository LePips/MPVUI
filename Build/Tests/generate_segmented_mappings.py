"""Author independently verifiable pictures and tones in HLS and DASH segments."""

from pathlib import Path
from struct import pack


VIDEO_ENCODERS = {
    "av1": ("libsvtav1", "libdav1d", "-preset", "10", "-svtav1-params", "lp=1"),
    "hevc": ("libx265", "hevc", "-preset", "ultrafast", "-x265-params", "pools=1:frame-threads=1:log-level=error"),
    "vp8": ("libvpx", "vp8", "-deadline", "realtime"),
    "vp9": ("libvpx-vp9", "vp9", "-deadline", "realtime"),
}
AUDIO_ENCODERS = {"mp2": ("mp2", "mp2float"), "mp3": ("libmp3lame", "mp3float"), "opus": ("libopus", "opus")}
SEGMENTED_MAPPINGS = (
    ("hls-ts", "hls / MPEG-TS", "hevc ac3 eac3 mp2 mp3"),
    ("hls-fmp4", "hls / fMP4", "av1 hevc ac3 alac eac3 flac"),
    ("dash-mp4", "dash / ISO BMFF", "av1 hevc vp9 ac3 eac3 flac opus"),
    ("dash-webm", "dash / WebM", "av1 vp8 vp9 opus vorbis"),
)
PACKED_AUDIO = {"aac": "adts", "mp3": "mp3", "ac3": "ac3", "eac3": "eac3"}
COLORS = ("red", "lime", "blue")
TONES = (440, 660, 880)


def sources():
    for route, mapping, codecs in SEGMENTED_MAPPINGS:
        for codec in codecs.split():
            stem = f"codecs-segments-{route}-{codec}"
            if route.startswith("dash-"):
                playlist, init = f"{stem}.mpd", (f"{stem}-init.m4s",)
                parts = tuple(f"{stem}-{index:02}.m4s" for index in (1, 2, 3))
            else:
                playlist = f"{stem}.m3u8"
                init = (f"{stem}-init.mp4",) if route == "hls-fmp4" else ()
                extension = "m4s" if init else "ts"
                parts = tuple(f"{stem}-{index:02}.{extension}" for index in range(3))
            yield route, mapping, codec, playlist, init, parts

    for codec in PACKED_AUDIO:
        stem = f"codecs-segments-hls-packed-{codec}"
        extension = "aac" if codec == "aac" else codec
        parts = tuple(f"{stem}-{index:02}.{extension}" for index in range(3))
        description = {"aac": "ADTS", "mp3": "MP3", "ac3": "AC-3", "eac3": "E-AC-3"}[codec]
        yield "hls-packed", f"hls / packed {description}", codec, f"{stem}.m3u8", (), parts


def output_names():
    return tuple(name for _, _, _, playlist, initialization, parts in sources() for name in (playlist, *initialization, *parts))


def audio_source(tone, duration):
    return ("-f", "lavfi", "-i", f"sine=frequency={tone}:sample_rate=48000:duration={duration}")


def packed_timestamp(ticks):
    owner = b"com.apple.streaming.transportStreamTimestamp\0"
    value = owner + pack(">Q", ticks)
    private = b"PRIV" + bytes((0, 0, 0, len(value))) + bytes(2) + value
    # The PRIV frame and enclosing tag are short enough for one synchsafe size byte.
    return b"ID3\x04\0\0" + bytes((0, 0, 0, len(private))) + private


def packed_audio(output, encode, codec, encoder, options, playlist, parts):
    lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:1", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"]
    for index, (tone, name) in enumerate(zip(TONES, parts)):
        encode(output, *audio_source(tone, 1), "-c:a", encoder, *options, "-f", PACKED_AUDIO[codec], name)
        target = output / name
        target.write_bytes(packed_timestamp(index * 90000) + target.read_bytes())
        lines.extend(("#EXTINF:1.000,", name))
    (output / playlist).write_text("\n".join([*lines, "#EXT-X-ENDLIST", ""]))


def generate(output, encode):
    catalog = {"video": [], "audio": []}
    for route, mapping, codec, playlist, init, parts in sources():
        video = codec in VIDEO_ENCODERS
        kind = "video" if video else "audio"
        stem = Path(playlist).stem
        if video:
            encoder, decoder, *options = VIDEO_ENCODERS[codec]
            inputs = [
                arg
                for color, duration in zip(COLORS, (1, 1, 0.8))
                for arg in ("-f", "lavfi", "-i", f"color={color}:size=176x144:rate=24:duration={duration}")
            ]
            coding = ("-c:v", encoder, "-threads:v", "1", "-g", "24", *options)
        else:
            encoder, decoder = AUDIO_ENCODERS.get(codec, (codec, codec))
            options = ("-strict", "experimental", "-threads:a", "1")
            if codec == "mp3":
                options += ("-write_xing", "0", "-id3v2_version", "0")
            if codec == "vorbis":
                options += ("-ac", "2")
            inputs = [arg for tone, duration in zip(TONES, (1, 1, 0.8)) for arg in audio_source(tone, duration)]
            coding = ("-c:a", encoder, *options)

        if route == "hls-packed":
            packed_audio(output, encode, codec, encoder, options, playlist, parts)
        else:
            if route.startswith("dash-"):
                muxer = (
                    "-f",
                    "dash",
                    "-seg_duration",
                    "1",
                    "-use_template",
                    "1",
                    "-use_timeline",
                    "1",
                    "-dash_segment_type",
                    "webm" if route == "dash-webm" else "mp4",
                    "-init_seg_name",
                    init[0],
                    "-media_seg_name",
                    f"{stem}-$Number%02d$.m4s",
                )
            else:
                muxer = (
                    "-f",
                    "hls",
                    "-hls_time",
                    "1",
                    "-hls_playlist_type",
                    "vod",
                    "-hls_segment_filename",
                    f"{stem}-%02d.{Path(parts[0]).suffix[1:]}",
                )
                if init:
                    muxer += ("-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", init[0])
            encode(output, *inputs, "-filter_complex", f"concat=n=3:v={int(video)}:a={int(not video)}", *coding, *muxer, playlist)
        for part in (*init, *parts):
            if not (output / part).is_file():
                raise ValueError(f"{playlist} is missing segment {part}")
        catalog[kind].append(
            {
                "file": playlist,
                "format": mapping.split(" / ", 1)[0],
                "mapping": mapping,
                "codec": codec,
                "decoder": decoder,
                "parts": [*init, *parts],
            }
        )
    return catalog
