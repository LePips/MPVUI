#!/usr/bin/env python3
"""Generate short, synthetic inputs for software decoder and demuxer playback tests."""

import argparse
import base64
import ctypes
import ctypes.util
from dataclasses import dataclass, replace
import hashlib
import json
import math
import re
from pathlib import Path
import struct
import subprocess
import sys
from tempfile import TemporaryDirectory
import wave
from xml.etree import ElementTree
import zlib

from derive_reference_media import ivf, realmedia_matroska
from generate_apv import PROFILES as APV_PROFILES, generate as generate_apv
from generate_authored_formats import (
    acelp_kelvin,
    ahx,
    bonk,
    caf_with_packet_table,
    cintel_raw,
    flv_captions,
    flv_video,
    ftr_voice,
    hca,
    ipu,
    micronas_sc4,
    moflex,
    mxg,
    r3d,
    tivo_ty,
)
from generate_authored_formats import (
    AA_TEST_KEY,
    aa_mp3,
    color_stills,
    mlv_video,
    sgi_movie,
    swf,
    usm_adx,
    usm_hca,
    usm_video,
    vorbis_wave,
    westwood_snd1,
)
from generate_avs3 import matroska as avs3_matroska
from generate_broadcast_formats import (
    GXF_AUDIO,
    GXF_VIDEO,
    MXF_PCM,
    dss_g723,
    flic,
    gxf,
    jpeg2000_program_map,
    maud,
    mxf_pcm,
    ogg_dirac,
    wtv_mjpeg,
    wtv_mp1,
)
from generate_console_audio import FORMATS as CONSOLE_AUDIO_FORMATS, generate as generate_console_audio
from generate_console_audio import n64_aifc, qoa, westwood_aifc, xa_aiff
from generate_legacy_audio import FORMATS as LEGACY_AUDIO_FORMATS, generate as generate_legacy_audio
from generate_legacy_audio import aifc, big_endian_pcm_caf, dv_wave, mpeg_layer1, nistsphere, shorten, telephone_gsm, vidc
from generate_legacy_video import AVI_CODECS as LEGACY_AVI_CODECS, generate as generate_legacy_video
from generate_legacy_video import COLORS
from generate_legacy_wrappers import WRAPPERS as LEGACY_WRAPPERS, generate as generate_legacy_wrapper
from generate_legacy_wrappers import FRM_MODES, elementary_packets, frm, g711, msp, riff, sofdec_adx, video_avi
from generate_packetized_rtp import generate as generate_packetized_rtp
from generate_packetized_rtp import output_names as packetized_rtp_names
from generate_prores_raw import generate as generate_prores_raw
from generate_rtmp import FILENAME as RTMP_REPLIES, write_rtmp_replies
from generate_segmented_mappings import generate as generate_segmented_mappings
from generate_segmented_mappings import output_names as segmented_mapping_names
from generate_speex import tone as speex_tone
from generate_wave_adpcm import PROFILES as WAVE_ADPCM_PROFILES, generate as generate_wave_adpcm
from remux_mappings import ADDITIONAL_REMUX_SOURCES, IVF_PACKET_TAGS, REMUX_MAPPINGS, REMUX_SOURCES


@dataclass(frozen=True)
class Fixture:
    name: str
    encoder: str
    muxer: str
    codec: str
    decoder: str
    source: str
    options: tuple[str, ...]
    android_only: bool
    width: int = 0
    height: int = 0
    forced_format: str = ""
    mpv_options: tuple[tuple[str, str], ...] = ()
    pipe_input: bool = False

    @property
    def filename(self):
        return f"codecs-{self.name}"

    @property
    def format(self):
        demuxer = dict(self.mpv_options).get("demuxer")
        if demuxer and demuxer != "lavf":
            return demuxer
        name = self.forced_format or self.muxer
        return {
            "adts": "aac",
            "amv": "avi",
            "3gp": "mov",
            "dvd": "mpeg",
            "latm": "loas",
            "matroska": "matroska" if demuxer == "lavf" else "mkv",
            "mp4": "mov",
            "mp2": "mp3",
            "mpeg1video": "mpegvideo",
            "mpeg2video": "mpegvideo",
            "vob": "mpeg",
            "webm": "mkv",
        }.get(name, name)

    def expectation(self):
        mpv_options = dict(self.mpv_options)
        if self.forced_format and not mpv_options:
            mpv_options["demuxer-lavf-format"] = self.forced_format
        return {
            "file": self.filename,
            "format": self.format,
            "codec": self.codec,
            "decoder": self.decoder,
            "androidOnly": self.android_only,
            "width": self.width,
            "height": self.height,
            "forcedFormat": self.forced_format,
            "mpvOptions": mpv_options,
            "pipeInput": self.pipe_input,
        }


def video(
    name, muxer, codec, *options, encoder=None, decoder=None, android=False, size=(176, 144), rate="24", duration=0.75, force="", mpv=()
):
    width, height = size
    source = f"testsrc2=size={width}x{height}:rate={rate}:duration={duration}"
    return Fixture(name, encoder or codec, muxer, codec, decoder or codec, source, options, android, width, height, force, mpv)


def audio(name, muxer, codec, *options, encoder=None, decoder=None, android=False, rate=48000, duration=1.25, force="", mpv=(), pipe=False):
    source = f"sine=frequency=440:sample_rate={rate}:duration={duration}"
    return Fixture(
        name,
        encoder or codec,
        muxer,
        codec,
        decoder or codec,
        source,
        options,
        android,
        forced_format=force,
        mpv_options=mpv,
        pipe_input=pipe,
    )


def packed_video(name, fmt, muxer, *options, size=(96, 64), pixel_format=None):
    width, height = size
    parameters = f"video_size={width}x{height},framerate=12"
    if pixel_format:
        parameters += f",pixel_format={pixel_format}"
    return video(
        name,
        muxer,
        fmt,
        *options,
        android=True,
        size=size,
        rate="12",
        force=fmt,
        mpv=(("demuxer-lavf-format", fmt), ("demuxer-lavf-o", parameters)),
    )


def raw_audio(sample_format):
    mpv_format = {"f32le": "floatle", "f32be": "floatbe", "f64le": "doublele", "f64be": "doublebe"}.get(sample_format, sample_format)
    return audio(
        f"raw-{sample_format}.pcm",
        sample_format,
        f"pcm_{sample_format}",
        force=sample_format,
        mpv=(
            ("demuxer", "rawaudio"),
            ("demuxer-rawaudio-format", mpv_format),
            ("demuxer-rawaudio-rate", "48000"),
            ("demuxer-rawaudio-channels", "mono"),
        ),
    )


def ffmpeg_raw_audio(sample_format, rate=48000):
    return audio(
        f"ffmpeg-raw-{sample_format}.pcm",
        sample_format,
        f"pcm_{sample_format}",
        android=True,
        rate=rate,
        force=sample_format,
        mpv=(("demuxer-lavf-format", sample_format), ("demuxer-lavf-o", f"sample_rate={rate},ch_layout=mono")),
    )


def still(name, codec, demuxer, pixel_format, muxer="image2"):
    image_options = ("-update", "1") if muxer == "image2" else ()
    return video(name, muxer, codec, "-pix_fmt", pixel_format, "-frames:v", "1", *image_options, android=True, force=demuxer)


IMAGES = (
    still("alias.pix", "alias_pix", "alias_pix", "bgr24"),
    still("bmp.bmp", "bmp", "bmp_pipe", "bgr24"),
    still("hdr.hdr", "hdr", "hdr_pipe", "gbrpf32le"),
    still("pam.pam", "pam", "pam_pipe", "rgb24"),
    still("pbm.pbm", "pbm", "pbm_pipe", "monow"),
    still("pcx.pcx", "pcx", "pcx_pipe", "rgb24"),
    still("pfm.pfm", "pfm", "pfm_pipe", "gbrpf32le"),
    still("pgm.pgm", "pgm", "pgm_pipe", "gray"),
    still("pgmyuv.pgm", "pgmyuv", "pgmyuv_pipe", "yuv420p"),
    still("phm.phm", "phm", "phm_pipe", "gbrpf32le"),
    still("ppm.ppm", "ppm", "ppm_pipe", "rgb24"),
    still("qoi.qoi", "qoi", "qoi_pipe", "rgb24"),
    still("sunrast.ras", "sunrast", "sunrast_pipe", "bgr24"),
    still("vbn.vbn", "vbn", "vbn_pipe", "rgba"),
    still("xbm.xbm", "xbm", "xbm_pipe", "monow"),
    still("xwd.xwd", "xwd", "xwd_pipe", "bgra"),
    still("fits.fits", "fits", "fits", "gbrp16le", "fits"),
    still("windows.ico", "bmp", "ico", "bgra", "ico"),
    still("windows-png.ico", "png", "ico", "rgba", "ico"),
    video("graphics-raw.msp", "msp", "rawvideo", android=True, size=(96, 64)),
    video("graphics-rle.msp", "msp", "msp2", android=True, size=(96, 64)),
    *(video(f"megalux-{mode}.frm", "frm", "rawvideo", android=True, size=(96, 64)) for mode in FRM_MODES),
    video("cintel-bayer.cri", "cri_pipe", "cri", android=True, size=(96, 64)),
    video("screen.bin", "bin", "bintext", android=True, size=(640, 400), force="bin"),
    video("screen.xbin", "xbin", "xbin", android=True, size=(96, 64), force="xbin"),
    video("screen.adf", "adf", "bintext", android=True, size=(640, 400), force="adf"),
    video("screen.idf", "idf", "idf", android=True, size=(640, 352), force="idf"),
    video(
        "screen.ans",
        "tty",
        "ansi",
        android=True,
        size=(640, 400),
        force="tty",
        mpv=(("demuxer-lavf-format", "tty"), ("demuxer-lavf-o", "chars_per_frame=1000000")),
    ),
    still("wbmp.wbmp", "wbmp", "image2", "monow"),
    still("pipe.dpx", "dpx", "dpx_pipe", "rgb24"),
    still("pipe.exr", "exr", "exr_pipe", "gbrpf32le"),
    still("pipe.gif", "gif", "gif_pipe", "rgb8"),
    still("pipe.j2k", "jpeg2000", "j2k_pipe", "rgb24"),
    still("pipe.jpg", "mjpeg", "jpeg_pipe", "yuvj420p"),
    still("pipe.jls", "jpegls", "jpegls_pipe", "rgb24"),
    still("pipe.png", "png", "png_pipe", "rgb24"),
    still("pipe.sgi", "sgi", "sgi_pipe", "rgb24"),
    still("pipe.tiff", "tiff", "tiff_pipe", "rgb24"),
    still("pipe.dds", "dds", "dds_pipe", "bgra"),
    still("pipe.pgx", "pgx", "pgx_pipe", "gray"),
    still("pipe.psd", "psd", "psd_pipe", "gbrp"),
    still("pipe.xpm", "xpm", "xpm_pipe", "pal8"),
    still("pipe.webp", "webp", "webp_pipe", "yuv420p"),
    still("brender.pix", "brender_pix", "brender_pix", "rgb24"),
    still("gem.img", "gem", "gem_pipe", "pal8"),
    still("pictor.pic", "pictor", "pictor_pipe", "pal8"),
    video("contact-sheet.pcd", "image2", "photocd", android=True, size=(192, 128), force="photocd_pipe"),
)

MF_ONLY_IMAGES = (
    still("targa.tga", "targa", "", "bgr24"),
    replace(still("portrait.xface", "xface", "", "monow"), width=48, height=48),
)

MF_IMAGE_TYPES = {
    "bmp": "bmp",
    "brender_pix": "pix",
    "exr": "exr",
    "gif": "gif",
    "hdr": "hdr",
    "jpeg2000": "j2k",
    "mjpeg": "jpg",
    "pam": "pam",
    "pbm": "pbm",
    "pcx": "pcx",
    "pfm": "pfm",
    "pgm": "pgm",
    "pgmyuv": "pgmyuv",
    "phm": "phm",
    "photocd": "pcd",
    "pictor": "pic",
    "png": "png",
    "ppm": "ppm",
    "qoi": "qoi",
    "sgi": "sgi",
    "sunrast": "ras",
    "targa": "tga",
    "tiff": "tiff",
    "webp": "webp",
    "xbm": "xbm",
    "xface": "xface",
    "xwd": "xwd",
}


COLOR_VIDEO = (
    *(video(f"{codec}.avi", "avi", codec, android=True, size=(96, 64), duration=1) for codec in LEGACY_AVI_CODECS),
    video("m101-8bit.avi", "avi", "m101", android=True, size=(96, 64), duration=1),
    video("m101-10bit.avi", "avi", "m101", android=True, size=(96, 64), duration=1),
    video("hymt.avi", "avi", "hymt", android=True, size=(96, 64), duration=1),
    video("cpia.nut", "nut", "cpia", android=True, size=(96, 64), duration=1),
    video("ps2-intra.ipu", "ipu", "ipu", android=True, size=(96, 64), rate="25", duration=0.96),
    video("camera-motion.mxg", "mxg", "mxpeg", android=True, size=(96, 64), duration=1.25, force="mxg"),
    video("red-camera-motion.r3d", "r3d", "jpeg2000", android=True, size=(192, 108), duration=1.25),
    video("msmpeg4v1.avi", "avi", "msmpeg4v1", size=(64, 64), duration=1),
    video("palette.vb", "siff", "vb", android=True, size=(96, 64), rate="12", duration=1),
    video("8bps.mov", "mov", "8bps", android=True, size=(96, 64), duration=1),
    video("cdtoons.mov", "mov", "cdtoons", android=True, size=(96, 64), duration=1),
    video("motion-jpeg-b.mov", "mov", "mjpegb", size=(96, 64), duration=1),
    video("targa-y216.mov", "mov", "targa_y216", android=True, size=(96, 64), duration=1),
    video("vp8.mov", "mov", "vp8", size=(96, 64), duration=1),
    video("intel-h263.avi", "avi", "h263i", duration=1),
    video("nuppel-raw.nuv", "nuv", "nuv", android=True, size=(128, 96), rate="12", duration=2),
    video("nuppel-rtjpeg.nuv", "nuv", "nuv", android=True, size=(128, 96), rate="12", duration=2),
)

AVS3_VIDEO = (
    video("avs3.mkv", "matroska", "avs3", decoder="libuavs3d", size=(128, 128), duration=1),
    video("avs3-lavf.mkv", "matroska", "avs3", decoder="libuavs3d", size=(128, 128), duration=1, mpv=(("demuxer", "lavf"),)),
    video("avs3.mov", "mov", "avs3", decoder="libuavs3d", size=(128, 128), duration=1),
    video("avs3.ts", "mpegts", "avs3", decoder="libuavs3d", size=(128, 128), duration=1),
)

PRORES_RAW_VIDEO = (
    (video("prores-raw.mov", "mov", "prores_raw", size=(96, 64), duration=1), b"aprn", "RAW"),
    (video("prores-raw-hq.mov", "mov", "prores_raw", size=(96, 64), duration=1), b"aprh", "RAW HQ"),
)

APV_VIDEO = tuple(
    (fixture, profile)
    for profile in APV_PROFILES
    for fixture in (
        video(
            f"apv-{profile}.apv",
            "apv",
            "apv",
            android=True,
            size=(96, 64),
            duration=1,
            force="apv",
            mpv=(("demuxer-lavf-format", "apv"), ("demuxer-lavf-o", "framerate=24")),
        ),
        video(f"apv-{profile}.mp4", "mp4", "apv", size=(96, 64), duration=1),
    )
)

CHROMA_ENCODERS = (
    (
        "h264",
        "libx264",
        "mp4",
        ("-preset", "ultrafast"),
        (
            ("high10", "yuv420p10le", "High 10"),
            ("high422", "yuv422p10le", "High 4:2:2"),
            ("high444", "yuv444p10le", "High 4:4:4 Predictive"),
        ),
    ),
    (
        "hevc",
        "libx265",
        "mp4",
        ("-preset", "ultrafast", "-x265-params", "pools=none:frame-threads=1:log-level=error"),
        (
            ("main12", "yuv420p12le", "Rext"),
            ("main422-10", "yuv422p10le", "Rext"),
            ("main422-12", "yuv422p12le", "Rext"),
            ("main444-10", "yuv444p10le", "Rext"),
            ("main444-12", "yuv444p12le", "Rext"),
        ),
    ),
    (
        "vp9",
        "libvpx-vp9",
        "webm",
        ("-cpu-used", "5"),
        (
            ("1", "yuv422p", "Profile 1"),
            ("1", "yuv444p", "Profile 1"),
            ("2", "yuv420p12le", "Profile 2"),
            ("3", "yuv422p12le", "Profile 3"),
            ("3", "yuv444p12le", "Profile 3"),
        ),
    ),
)
CHROMA_VIDEO = tuple(
    (
        video(
            f"{codec}-{pixel_format}.{container}",
            container,
            codec,
            *options,
            "-pix_fmt",
            pixel_format,
            "-profile:v",
            encode_profile,
            encoder=encoder,
            size=(96, 64),
            duration=1,
        ),
        pixel_format,
        decoded_profile,
    )
    for codec, encoder, container, options, profiles in CHROMA_ENCODERS
    for encode_profile, pixel_format, decoded_profile in profiles
)

LMLM4_AV = video("mpeg4-capture-av.lmlm4", "lmlm4", "mpeg4", android=True)
FLIC_INPUT = video("palette-animation.flc", "flic", "flic", android=True, size=(96, 64))
FLIC_MOV = video("palette-animation.mov", "mov", "flic", android=True, size=(96, 64))
FLIC_AUDIO = audio("palette-sound.flc", "flic", "pcm_u8", android=True, rate=22050)
DIRAC_OGG = video("dirac.ogv", "ogg", "dirac", android=True)
JPEG2000_TS = video("jpeg2000.ts", "mpegts", "jpeg2000", android=True)
DSS_AUDIO = audio("long-play.dss", "dss", "g723_1", android=True, rate=8000)
MAUD_AUDIO = tuple(audio(f"studio-{codec}.maud", "iff", codec, android=True) for codec in ("pcm_u8", "pcm_s16be", "pcm_alaw", "pcm_mulaw"))
GXF_PICTURES = tuple(
    video(f"exchange-{codec}.gxf", "gxf", codec, android=True, size=(256, 144) if codec == "dnxhd" else (176, 144)) for codec in GXF_VIDEO
)
GXF_TONES = tuple(audio(f"exchange-{codec}.gxf", "gxf", codec, android=True) for codec in GXF_AUDIO)
MXF_TONES = tuple(audio(f"exchange-{codec}.mxf", "mxf", codec, android=True, duration=1.2) for codec in MXF_PCM)
SWF_BITMAP = video("flash-bitmap.swf", "swf", "rawvideo", android=True, size=(96, 64))
SWF_PCM = audio("flash-sound.swf", "swf", "pcm_u8", android=True, rate=22050, duration=1.2)
MLV_VIDEO = tuple(
    video(f"camera-{codec}.mlv", "mlv", codec, android=True, size=(96, 64) if codec == "tiff" else (176, 144))
    for codec in ("mjpeg", "h264", "tiff")
)
MV_RAW = video("sgi-raw.mv", "mv", "rawvideo", android=True, size=(96, 64))
MV_JPEG = video("sgi-jpeg.mv", "mv", "mjpeg", android=True, size=(96, 64))
MV_PCM = audio("sgi-signed-8.mv", "mv", "pcm_s8", android=True)
AA_MP3 = audio("authored-mp3.aa", "aa", "mp3", android=True, rate=22050, mpv=(("demuxer-lavf-o", f"aa_fixed_key={AA_TEST_KEY.hex()}"),))
WTV_MJPEG = video("broadcast-mjpeg.wtv", "wtv", "mjpeg", android=True, size=(96, 64), duration=1.25)
WTV_MP1 = audio("broadcast-mp1.wtv", "wtv", "mp1", android=True)
DERIVED_VIDEO = (LMLM4_AV, FLIC_INPUT, FLIC_MOV, DIRAC_OGG, JPEG2000_TS, SWF_BITMAP, MV_RAW, MV_JPEG, WTV_MJPEG, *GXF_PICTURES, *MLV_VIDEO)
DERIVED_AUDIO = (FLIC_AUDIO, DSS_AUDIO, SWF_PCM, MV_PCM, AA_MP3, WTV_MP1, *MAUD_AUDIO, *GXF_TONES, *MXF_TONES)

VIDEO = (
    video("mpeg4.avi", "avi", "mpeg4"),
    video("mp42.avi", "avi", "msmpeg4v2"),
    video("mpeg4.m4v", "m4v", "mpeg4"),
    video("mp43.avi", "avi", "msmpeg4v3", encoder="msmpeg4", decoder="msmpeg4"),
    video("wmv1.asf", "asf", "wmv1"),
    video("wmv2.asf", "asf", "wmv2"),
    video("h263.avi", "avi", "h263"),
    video("h263.3gp", "3gp", "h263"),
    video("h263-plus.avi", "avi", "h263", encoder="h263p"),
    video("h263-plus.asf", "asf", "h263", encoder="h263p"),
    video("spark.flv", "flv", "flv1", encoder="flv", decoder="flv"),
    video("spark-live.flv", "flv", "flv1", encoder="flv", decoder="flv", force="live_flv"),
    video("rv10.rm", "rm", "rv10"),
    video("rv20.rm", "rm", "rv20"),
    *(
        video(f"{codec}-{reader}.mkv", "matroska", codec, mpv=(("demuxer", reader),))
        for codec in ("rv10", "rv20")
        for reader in ("mkv", "lavf")
    ),
    video("ffv1.mkv", "matroska", "ffv1"),
    video("ffv1-level1.mkv", "matroska", "ffv1", "-level", "1", android=True),
    video("raw-i420.avi", "avi", "rawvideo", "-pix_fmt", "yuv420p", "-tag:v", "I420", android=True),
    video("ffvhuff.avi", "avi", "ffvhuff"),
    video("huffyuv.avi", "avi", "huffyuv", "-pix_fmt", "yuv422p"),
    video("snow.avi", "avi", "snow", "-strict", "experimental"),
    video("mjpeg.avi", "avi", "mjpeg", "-pix_fmt", "yuvj420p"),
    video("prores.mov", "mov", "prores", "-pix_fmt", "yuv422p10le"),
    video("hap.mov", "mov", "hap", size=(96, 64), rate="8", duration=3),
    video("dxv.mov", "mov", "dxv"),
    video("dpx.mov", "mov", "dpx", "-pix_fmt", "rgb24"),
    video("tscc.avi", "avi", "tscc", decoder="camtasia"),
    video("mpeg1.mpg", "mpeg", "mpeg1video"),
    video("mpeg2.mpg", "vob", "mpeg2video"),
    video("mpeg1.m1v", "mpeg1video", "mpeg1video"),
    video("mpeg2.m2v", "mpeg2video", "mpeg2video", decoder="mpegvideo"),
    video("h264.h264", "h264", "h264", "-preset", "ultrafast", "-tune", "zerolatency", encoder="libx264"),
    video("camera-h264.dat", "luodat", "h264", android=True),
    video("camera-h264.lvf", "lvf", "h264", android=True),
    video("h264-high10.mp4", "mp4", "h264", "-pix_fmt", "yuv420p10le", "-preset", "ultrafast", encoder="libx264"),
    video("hevc.hevc", "hevc", "hevc", "-preset", "ultrafast", "-tune", "zerolatency", encoder="libx265"),
    video("hevc.asf", "asf", "hevc"),
    video("hevc-main10.hevc", "hevc", "hevc", "-pix_fmt", "yuv420p10le", "-preset", "ultrafast", "-tune", "zerolatency", encoder="libx265"),
    video("vp8.webm", "webm", "vp8", "-deadline", "realtime", encoder="libvpx"),
    video("vp9.webm", "webm", "vp9", "-deadline", "realtime", encoder="libvpx-vp9"),
    video("vp9-profile2.webm", "webm", "vp9", "-pix_fmt", "yuv420p10le", "-deadline", "realtime", encoder="libvpx-vp9"),
    video("av1.mkv", "matroska", "av1", "-preset", "12", encoder="libsvtav1", decoder="libdav1d"),
    video("av1-annex-b.av1", "av1", "av1", "-preset", "12", "-g", "1", encoder="libsvtav1", decoder="libdav1d", force="av1"),
    # Android's FFmpeg build also exposes the upstream decoders and demuxers below.
    video("dnxhr.mxf", "mxf", "dnxhd", "-profile:v", "dnxhr_lb", android=True, size=(256, 144), rate="25"),
    video("dnxhr.dnxhd", "dnxhd", "dnxhd", "-profile:v", "dnxhr_lb", android=True, size=(256, 144), rate="25"),
    video("dv.dv", "dv", "dvvideo", "-pix_fmt", "yuv411p", android=True, size=(720, 480), rate="30000/1001"),
    video("av1.ivf", "ivf", "av1", "-preset", "12", encoder="libsvtav1", decoder="libdav1d", android=True),
    video("av1.obu", "obu", "av1", "-preset", "12", "-g", "1", encoder="libsvtav1", decoder="libdav1d", android=True, force="obu"),
    video("mjpeg.mjpeg", "mjpeg", "mjpeg", "-pix_fmt", "yuvj420p", android=True, force="mjpeg"),
    video("mjpeg-ingenient.cgi", "ingenient", "mjpeg", android=True),
    video("mjpeg-loki.mjpg", "smjpeg", "mjpeg", "-pix_fmt", "yuvj420p", android=True, force="smjpeg"),
    video("filmstrip.flm", "filmstrip", "rawvideo", "-pix_fmt", "rgba", android=True, force="filmstrip"),
    video("cinepak-film.cpk", "film_cpk", "cinepak", "-pix_fmt", "rgb24", android=True),
    video(
        "mpeg2.gxf", "gxf", "mpeg2video", "-pix_fmt", "yuv422p", "-b:v", "10M", "-g", "12", android=True, size=(720, 480), rate="30000/1001"
    ),
    video("jpeg2000.j2c", "image2pipe", "jpeg2000", "-format", "j2k", android=True, force="mjpeg_2000"),
    video("png-sequence.png", "image2pipe", "png", "-pix_fmt", "rgb24", android=True, force="image2pipe"),
    packed_video("raw.v210", "v210", "rawvideo", "-pix_fmt", "yuv422p10le"),
    packed_video("raw.yuv10", "v210x", "v210x"),
    packed_video("raw.bitpacked", "bitpacked", "bitpacked", pixel_format="yuv422p10le"),
    video("rawvideo.y4m", "yuv4mpegpipe", "rawvideo", encoder="wrapped_avframe", android=True),
    video("rawvideo.nut", "nut", "rawvideo", android=True),
    video("h261.h261", "h261", "h261", android=True),
    video("h263.h263", "h263", "h263", android=True),
    video("cinepak.avi", "avi", "cinepak", "-pix_fmt", "rgb24", android=True),
    video("msvideo1.avi", "avi", "msvideo1", android=True),
    video("msrle.avi", "avi", "msrle", "-pix_fmt", "pal8", "-strict", "experimental", android=True),
    video("asv1.avi", "avi", "asv1", android=True),
    video("asv2.avi", "avi", "asv2", android=True),
    video("zmbv.avi", "avi", "zmbv", android=True),
    video("flashsv.flv", "flv", "flashsv", android=True),
    video("flashsv2.flv", "flv", "flashsv2", "-strict", "experimental", android=True),
    video("qtrle.mov", "mov", "qtrle", android=True),
    video("svq1.mov", "mov", "svq1", "-pix_fmt", "yuv410p", android=True),
    video("rpza.mov", "mov", "rpza", "-pix_fmt", "rgb555le", android=True),
    video("cfhd.mov", "mov", "cfhd", "-pix_fmt", "yuv422p10le", android=True),
    video("utvideo.avi", "avi", "utvideo", android=True),
    video("magicyuv.avi", "avi", "magicyuv", android=True),
    video("jpeg2000.mov", "mov", "jpeg2000", "-tag:v", "mjp2", android=True),
    video("png.mov", "mov", "png", "-pix_fmt", "rgb24", android=True),
    video("tiff.mov", "mov", "tiff", "-pix_fmt", "rgb24", android=True),
    video("v210.mov", "mov", "v210", android=True),
    video("r210.mov", "mov", "r210", android=True),
    video("avrp.mov", "mov", "avrp", android=True),
    video("yuv4.mov", "mov", "yuv4", android=True),
    video("amv.avi", "avi", "amv", "-pix_fmt", "yuvj420p", android=True),
    video("animated.apng", "apng", "apng", "-plays", "0", android=True, force="apng"),
    video(
        "avui.mov",
        "mov",
        "avui",
        "-pix_fmt",
        "uyvy422",
        "-strict",
        "experimental",
        android=True,
        size=(720, 486),
        rate="30000/1001",
        duration=0.35,
    ),
    video("cljr.avi", "avi", "cljr", android=True),
    video("dirac.ts", "mpegts", "dirac", encoder="vc2", android=True),
    video("dirac-24.drc", "dirac", "dirac", encoder="vc2", android=True),
    video("dirac-2997.drc", "dirac", "dirac", encoder="vc2", android=True, rate="30000/1001"),
    video("gif.gif", "gif", "gif", "-loop", "-1", android=True),
    video("jpegls.avi", "avi", "jpegls", "-pix_fmt", "rgb24", android=True),
    video("r10k.mov", "mov", "r10k", "-pix_fmt", "gbrp10le", android=True),
    video("sgi.mov", "mov", "sgi", "-pix_fmt", "rgb24", android=True),
    video("smc.mov", "mov", "smc", "-pix_fmt", "pal8", android=True),
    video("speedhq.avi", "avi", "speedhq", "-pix_fmt", "yuv420p", android=True),
    video("targa.mov", "mov", "targa", "-pix_fmt", "bgr24", android=True),
    video("y41p.avi", "avi", "y41p", "-pix_fmt", "yuv411p", android=True),
    video("zlib.avi", "avi", "zlib", "-pix_fmt", "bgr24", android=True),
    video("roq.roq", "roq", "roq", encoder="roqvideo", decoder="roqvideo", android=True, size=(128, 128), rate="30"),
    video("xface.nut", "nut", "xface", "-pix_fmt", "monow", android=True, size=(48, 48)),
    video("exr.mov", "mov", "exr", "-pix_fmt", "gbrpf32le", android=True),
    video("flash.swf", "swf", "flv1", encoder="flv", decoder="flv", android=True),
    video("multipart.mjpg", "mpjpeg", "mjpeg", android=True, rate="25", force="mpjpeg"),
    video("pipe.mjpeg", "image2pipe", "mjpeg", android=True, rate="25", force="image2pipe"),
    video("asf-active.asf", "asf", "wmv2", android=True, force="asf_o"),
    video("playdate.pdv", "pdv", "pdv", "-pix_fmt", "monob", "-strict", "-2", "-max_frames", "18", android=True),
    video("broadcast.wtv", "wtv", "mpeg2video", android=True),
    video("broadcast-avc.wtv", "wtv", "h264", "-preset", "ultrafast", "-tune", "zerolatency", encoder="libx264", android=True),
    video("mpeg2-broadcast.pva", "pva", "mpeg2video", android=True, force="pva"),
    video("mpeg4-capture.lmlm4", "lmlm4", "mpeg4", android=True, force="lmlm4"),
    video("mpeg2-broadcast.lxf", "lxf", "mpeg2video", android=True),
    *(
        video(f"broadcast-{codec}.lxf", "lxf", codec, android=True, size=(720, 480) if codec == "dvvideo" else (176, 144))
        for codec in ("mpeg1video", "mjpeg", "dvvideo")
    ),
    *(video(f"camera-{codec}.dav", "dhav", codec, android=True) for codec in ("h264", "hevc", "mpeg4", "mjpeg")),
    video("camera-hxvs.264", "hxvs", "h264", android=True),
    video("camera-hxvs.265", "hxvs", "hevc", android=True),
    video("camera-indigo.iv8", "iv8", "mpeg4", android=True),
    video("camera-network.v", "nc", "mpeg4", android=True),
    video("camera-sdr2.sdr2", "sdr2", "h264", android=True, force="sdr2"),
    video("handheld-mpeg4.pmp", "pmp", "mpeg4", android=True),
    video("handheld-avc.pmp", "pmp", "h264", android=True, force="pmp"),
    video("mpeg2-capture.mgsts", "mgsts", "mpeg2video", android=True),
    video("handheld-picture.mtv", "mtv", "rawvideo", android=True, size=(96, 64)),
    video("camera-avc.ifv", "ifv", "h264", android=True, force="ifv"),
    video("palette-video.imx", "simbiosis_imx", "simbiosis_imx", android=True, size=(320, 160)),
    video("flash-video.kux", "kux", "flv1", decoder="flv", android=True),
    video("rgb8-astronomy.ser", "ser", "rawvideo", size=(96, 64), rate="25", duration=1, android=True, force="ser"),
    video("bgr16-astronomy.ser", "ser", "rawvideo", size=(96, 64), rate="25", duration=1, android=True, force="ser"),
    video("color-cues.cdg", "cdg", "cdgraphics", size=(300, 216), rate="300", duration=1, android=True),
    *(video(f"sofdec-{codec}.usm", "usm", codec, android=True, force="usm") for codec in ("h264", "mpeg1video", "vp9")),
    *(video(f"tivo-picture-{codec}.ty", "ty", "mpeg2video", android=True) for codec in ("mp2", "ac3")),
    *DERIVED_VIDEO,
)

AUDIO = (
    audio("mpeg-layer1.mp1", "mp3", "mp1"),
    audio("amr-nb.amr", "amr", "amr_nb", decoder="amrnb", rate=8000),
    audio("amr-wb.amr", "amr", "amr_wb", decoder="amrwb", rate=16000),
    audio("aac-lc.aac", "adts", "aac"),
    audio("aac-lc.m4a", "mp4", "aac"),
    audio("aac.loas", "latm", "aac_latm", encoder="aac"),
    audio("aac-fixed.aac", "adts", "aac", decoder="aac_fixed"),
    audio("ac3.ac3", "ac3", "ac3"),
    audio("ac3-fixed.ac3", "ac3", "ac3", decoder="ac3_fixed"),
    audio("eac3.eac3", "eac3", "eac3"),
    audio("truehd.mka", "matroska", "truehd", "-strict", "experimental"),
    audio("mp2.mp2", "mp2", "mp2", decoder="mp2float"),
    audio("mp2-fixed.mp2", "mp2", "mp2", decoder="mp2"),
    audio("mp3-fixed.mp3", "mp3", "mp3", encoder="libmp3lame"),
    audio("mp3-float.mp3", "mp3", "mp3", encoder="libmp3lame", decoder="mp3float"),
    audio("mp3-vbr.mp3", "mp3", "mp3", "-q:a", "2", encoder="libmp3lame"),
    audio("mpeg-audio-in-mp4.mp4", "mp4", "mp3on4"),
    audio("flac.flac", "flac", "flac"),
    audio("opus.ogg", "ogg", "opus", encoder="libopus"),
    audio(
        "opus.iamf",
        "iamf",
        "opus",
        "-b:a",
        "48k",
        "-stream_group",
        "type=iamf_audio_element:id=1:st=0,layer=ch_layout=mono",
        "-stream_group",
        "type=iamf_mix_presentation:id=2:stg=0:annotations=en-us=Tone,"
        "submix=parameter_id=100:parameter_rate=48000|element=stg=0:parameter_id=100:annotations=en-us=Mono|layout=sound_system=mono",
        "-streamid",
        "0:0",
        encoder="libopus",
        android=True,
    ),
    audio("tone.sbg", "sbg", "wavesynth", android=True, rate=44100),
    audio("vorbis.ogg", "ogg", "vorbis", "-ac", "2", "-strict", "experimental"),
    *(
        audio(
            f"vorbis-blocks.{format_name}", format_name, "vorbis", android=format_name == "w64", mpv=(("demuxer-lavf-o", "max_size=256"),)
        )
        for format_name in ("wav", "w64")
    ),
    audio("tta.mka", "matroska", "tta"),
    audio("alac.caf", "caf", "alac"),
    audio("aac-packet-table.caf", "caf", "aac"),
    audio("opus-packet-table.caf", "caf", "opus"),
    audio("wma1.asf", "asf", "wmav1", rate=44100),
    audio("wma2.asf", "asf", "wmav2", rate=44100),
    audio("pcm-s8.aiff", "aiff", "pcm_s8"),
    audio("pcm-s16be.aiff", "aiff", "pcm_s16be"),
    audio("pcm-s24be.aiff", "aiff", "pcm_s24be"),
    audio("pcm-s32be.aiff", "aiff", "pcm_s32be"),
    audio("pcm-f32be.aifc", "aiff", "pcm_f32be"),
    audio("pcm-f64be.aifc", "aiff", "pcm_f64be"),
    audio("n64-adpcm.aifc", "aiff", "adpcm_n64", rate=22050),
    audio("ima-ws.aifc", "aiff", "adpcm_ima_ws", rate=22050),
    audio("cdrom-xa.aiff", "aiff", "adpcm_xa", rate=37800),
    audio("g726le.aifc", "aiff", "adpcm_g726le", encoder="g726le", decoder="g726le", rate=8000),
    audio("tone.qoa", "qoa", "qoa", android=True, rate=22050),
    audio("telephone.gsm", "gsm", "gsm", android=True, rate=8000),
    audio("telephone.aifc", "aiff", "gsm", android=True, rate=8000, duration=1.2),
    audio("telephone-ms.wav", "wav", "gsm_ms", android=True, rate=8000),
    audio("openmg-aac.oma", "oma", "aac", "-b:a", "128k", android=True),
    audio(
        "openmg-mp3.oma",
        "oma",
        "mp3",
        "-b:a",
        "128k",
        "-write_xing",
        "0",
        "-id3v2_version",
        "0",
        encoder="libmp3lame",
        android=True,
        duration=1.128,
    ),
    audio("openmg-pcm.oma", "oma", "pcm_s16be", "-ac", "2", android=True, rate=44100, duration=55040 / 44100),
    audio("asterisk.sln", "s16le", "pcm_s16le", android=True, rate=8000, force="sln"),
    audio("pcm-s16le.caf", "caf", "pcm_s16le"),
    audio("pcm-f32le.caf", "caf", "pcm_f32le"),
    audio("pcm-s64be.caf", "caf", "pcm_s64be"),
    audio("pcm-u8.wav", "wav", "pcm_u8"),
    audio("pcm-s24le.wav", "wav", "pcm_s24le"),
    audio("pcm-s32le.wav", "wav", "pcm_s32le"),
    audio("pcm-s64le.wav", "wav", "pcm_s64le"),
    audio("pcm-f64le.wav", "wav", "pcm_f64le"),
    audio("audition-f16le.wav", "wav", "pcm_f16le"),
    audio("audition-f24le.wav", "wav", "pcm_f24le"),
    *(
        raw_audio(sample_format)
        for sample_format in (
            "u8",
            "s8",
            "u16le",
            "u16be",
            "s16le",
            "s16be",
            "u24le",
            "u24be",
            "s24le",
            "s24be",
            "u32le",
            "u32be",
            "s32le",
            "s32be",
            "f32le",
            "f32be",
            "f64le",
            "f64be",
        )
    ),
    audio("alaw.wav", "wav", "pcm_alaw", rate=8000),
    audio("mulaw.wav", "wav", "pcm_mulaw", rate=8000),
    audio("dvd.vob", "vob", "pcm_dvd"),
    audio("bluray.m2ts", "mpegts", "pcm_bluray", "-mpegts_m2ts_mode", "1"),
    audio("dts-core.m2ts", "mpegts", "dts", "-strict", "experimental", "-mpegts_m2ts_mode", "1", encoder="dca", decoder="dca"),
    audio("truehd.m2ts", "mpegts", "truehd", "-strict", "experimental", "-mpegts_m2ts_mode", "1"),
    audio("hdmv-bluray.ts", "mpegts", "pcm_bluray"),
    audio("hdmv-dts-core.ts", "mpegts", "dts", decoder="dca"),
    audio("hdmv-truehd.ts", "mpegts", "truehd"),
    # DV audio alone is playable on builds with no DV video decoder.
    audio("dv-audio.dv", "dv", "pcm_s16le", "-ac", "2", duration=1.25125, mpv=(("vid", "no"),)),
    audio("ima-wav.wav", "wav", "adpcm_ima_wav"),
    audio("ima-qt.mov", "mov", "adpcm_ima_qt"),
    audio("ima-qt.aiff", "aiff", "adpcm_ima_qt"),
    audio("ima-amv.amv", "amv", "adpcm_ima_amv", "-ac", "1", "-block_size", "1470", rate=22050, duration=20 / 15, mpv=(("vid", "no"),)),
    audio("adpcm-ms.wav", "wav", "adpcm_ms"),
    audio("adpcm-yamaha.wav", "wav", "adpcm_yamaha"),
    *(audio(f"{codec.replace('_', '-')}.wav", "wav", codec) for codec in WAVE_ADPCM_PROFILES),
    audio("adpcm-swf.flv", "flv", "adpcm_swf", rate=44100),
    *(audio(f"adpcm-swf.{muxer}", muxer, "adpcm_swf", rate=44100, android=muxer == "w64") for muxer in ("avi", "asf", "wav", "w64")),
    audio("pcm-s16le.flv", "flv", "pcm_s16le", rate=44100),
    audio("pcm-u8.flv", "flv", "pcm_u8", rate=44100),
    audio("g722.wav", "wav", "adpcm_g722", encoder="g722", decoder="g722", rate=16000),
    audio("g726.wav", "wav", "adpcm_g726", encoder="g726", decoder="g726", rate=8000),
    audio("truehd.thd", "truehd", "truehd", "-strict", "experimental", android=True),
    audio("dts-core.dts", "dts", "dts", "-strict", "experimental", encoder="dca", decoder="dca", android=True, force="dts"),
    audio("dts-hd-container.dtshd", "dtshd", "dts", decoder="dca", android=True),
    audio("mlp.mlp", "mlp", "mlp", "-strict", "experimental", android=True, force="mlp"),
    audio("tta.tta", "tta", "tta", android=True),
    audio("wavpack.wv", "wv", "wavpack", android=True),
    audio("alaw.au", "au", "pcm_alaw", android=True, rate=8000),
    audio("ra144.rm", "rm", "ra_144", encoder="real_144", decoder="real_144", android=True, rate=8000),
    audio("nellymoser.flv", "flv", "nellymoser", android=True, rate=22050),
    # Five complete 1020-byte reads at 32 kbps. Exercise both pipe and file startup.
    audio(
        "g726.g726", "g726", "adpcm_g726", encoder="g726", decoder="g726", android=True, rate=8000, duration=1.275, force="g726", pipe=True
    ),
    audio(
        "g726le.g726",
        "g726le",
        "adpcm_g726le",
        encoder="g726le",
        decoder="g726le",
        android=True,
        rate=8000,
        duration=1.275,
        force="g726le",
        pipe=True,
    ),
    audio("sbc.sbc", "sbc", "sbc", android=True),
    audio("adpcm-adx.adx", "adx", "adpcm_adx", android=True, rate=44100),
    audio("voice-ahx.adx", "adx", "ahx", android=True, rate=22050),
    audio("sofdec-adx.mpg", "mpeg", "adpcm_adx", rate=44100),
    audio("adpcm-adx.aix", "aix", "adpcm_adx", android=True, rate=44100),
    audio("adpcm-adx.aax", "aax", "adpcm_adx", android=True, rate=44100),
    audio("sofdec-adx.usm", "usm", "adpcm_adx", android=True, rate=44100),
    audio("tonal-mdct.hca", "hca", "hca", android=True, rate=45056),
    audio("sofdec-hca.usm", "usm", "hca", android=True, rate=45056),
    audio("tonal-lossless.bonk", "bonk", "bonk", android=True, rate=8000),
    audio("westwood-literal.aud", "wsaud", "westwood_snd1", decoder="ws_snd1", android=True, rate=8000),
    audio("ftr-voice.avi", "avi", "ftr", android=True),
    *(audio(f"sc4.{fmt}", fmt, "misc4", android=True, rate=16000) for fmt in ("avi", "wav", "w64")),
    audio("moflex-ima.moflex", "moflex", "adpcm_ima_moflex", android=True),
    audio("moflex-pcm.moflex", "moflex", "pcm_s16le", android=True),
    audio("camera-sound.mxg", "mxg", "pcm_alaw", android=True, rate=8000, force="mxg"),
    audio("red-camera-sound.r3d", "r3d", "pcm_s32be", android=True),
    *(audio(f"tivo-sound-{codec}.ty", "ty", codec, android=True) for codec in ("mp2", "ac3")),
    audio("adpcm-ms.boa", "boa", "adpcm_ms", android=True),
    audio("big-endian.scd", "scd", "pcm_s16be", android=True, rate=8000, mpv=(("demuxer-lavf-o", "strict=-2"),)),
    audio("mpeg-audio.scd", "scd", "mp3", android=True, mpv=(("demuxer-lavf-o", "strict=-2"),)),
    audio("camera-pcm.sdr2", "sdr2", "pcm_s16le", android=True, rate=8000, force="sdr2"),
    audio("beam-audio.son", "siff", "pcm_u8", android=True, rate=8000),
    audio("3do-audio.str", "3dostr", "sdx2_dpcm", android=True, rate=22050),
    audio("camera-pcm.lvf", "lvf", "pcm_s16le", android=True, rate=8000),
    *(
        audio(f"limitless-{codec.removeprefix('pcm_')}.laf", "laf", codec, android=True, mpv=(("length", "1.25"),))
        for codec in ("pcm_u8", "pcm_s16le", "pcm_f32le", "pcm_s24le")
    ),
    audio("dv-audio-pal.wav", "wav", "dvaudio", android=True),
    audio("dv-audio-ntsc.wav", "wav", "dvaudio", android=True),
    audio("handheld-sound.mtv", "mtv", "mp3", android=True, rate=44100),
    audio("camera-pcm.ifv", "ifv", "pcm_s16le", android=True, rate=8000),
    audio("palette-audio.imx", "simbiosis_imx", "pcm_u8", android=True, rate=22050),
    *(
        audio(f"sample-bank-{codec}.fsb", "fsb", codec, android=True, rate=22050)
        for codec in ("pcm_s16le", "adpcm_ima_wav", "adpcm_psx", "adpcm_thp")
    ),
    *(audio(f"eurocom-{codec}.musx", "musx", codec, android=True, rate=32000) for codec in ("adpcm_psx", "adpcm_ima_dat4")),
    *(
        audio(f"armovie-{codec}.rpl", "rpl", codec, android=True, rate=8000)
        for codec in ("pcm_s16le", "pcm_u8", "pcm_s8", "pcm_vidc", "adpcm_ima_acorn", "adpcm_ima_escape")
    ),
    audio("adpcm-argo.asf", "argo_asf", "adpcm_argo", android=True, rate=22050),
    audio("ima-alp.alp", "alp", "adpcm_ima_alp", android=True, rate=22050),
    audio("ima-apm.apm", "apm", "adpcm_ima_apm", android=True, rate=22050, pipe=True),
    audio("aptx.aptx", "aptx", "aptx", "-ac", "2", android=True, force="aptx"),
    audio("aptx-hd.aptx", "aptx_hd", "aptx_hd", "-ac", "2", android=True, force="aptx_hd"),
    audio("dfpwm.wav", "wav", "dfpwm", android=True),
    *(audio(f"dfpwm.{format_name}", format_name, "dfpwm", android=True) for format_name in ("asf", "avi", "nut", "w64")),
    *(audio(f"nut-pcm-u{bits}be.nut", "nut", f"pcm_u{bits}be", android=True) for bits in (16, 24, 32)),
    audio("spectrum-alaw.sph", "nistsphere", "pcm_alaw", android=True, rate=8000),
    audio("spectrum-mulaw.sph", "nistsphere", "pcm_mulaw", android=True, rate=8000),
    audio("spectrum-shorten.sph", "nistsphere", "shorten", android=True, rate=16000),
    audio("daud.302", "daud", "pcm_s24daud", "-ac", "6", android=True, rate=96000, force="daud"),
    audio("ima-ssi.kvag", "kvag", "adpcm_ima_ssi", android=True, rate=22050),
    audio("ima-ws.wsaud", "wsaud", "adpcm_ima_ws", android=True, rate=22050),
    audio("g723.g723_1", "g723_1", "g723_1", android=True, rate=8000),
    audio("speech-tone.g729", "g729", "g729", force="g729", android=True, rate=8000),
    audio("g729.bit", "bit", "g729", android=True, rate=8000),
    audio("g729.wav", "wav", "g729", android=True, rate=8000),
    audio("g729.w64", "w64", "g729", android=True, rate=8000),
    audio("g729.nut", "nut", "g729", android=True, rate=8000),
    *(audio(f"kelvin.{fmt}", fmt, "acelp.kelvin", android=True, rate=8000) for fmt in ("avi", "wav")),
    *(
        audio(f"speex-{band}.{extension}", format, "speex", android=True, rate=rate)
        for band, rate in (("nb", 8000), ("wb", 16000), ("uwb", 32000))
        for extension, format in (("spx", "ogg"), ("nut", "nut"))
    ),
    audio("s302m.ts", "mpegts", "s302m", "-ac", "2", "-strict", "experimental", android=True),
    audio("roq-audio.roq", "roq", "roq_dpcm", android=True, rate=22050),
    audio("s16be-planar.ast", "ast", "pcm_s16be_planar", "-ac", "2", android=True, rate=32000),
    audio("s16le-planar.nut", "nut", "pcm_s16le_planar", "-ac", "2", android=True),
    audio("s24le-planar.nut", "nut", "pcm_s24le_planar", "-ac", "2", android=True),
    audio("s32le-planar.nut", "nut", "pcm_s32le_planar", "-ac", "2", android=True),
    audio("s64be.nut", "nut", "pcm_s64be", android=True),
    audio("s8-planar.nut", "nut", "pcm_s8_planar", "-ac", "2", android=True),
    audio("g726le.au", "au", "adpcm_g726le", encoder="g726le", decoder="g726le", rate=8000, android=True),
    *(
        ffmpeg_raw_audio(fmt)
        for fmt in (
            "s8",
            "u8",
            "s16be",
            "s16le",
            "s24be",
            "s24le",
            "s32be",
            "s32le",
            "u16be",
            "u16le",
            "u24be",
            "u24le",
            "u32be",
            "u32le",
            "f32be",
            "f32le",
            "f64be",
            "f64le",
        )
    ),
    *(ffmpeg_raw_audio(fmt, rate=8000) for fmt in ("alaw", "mulaw")),
    ffmpeg_raw_audio("vidc", rate=22050),
    audio("ffmpeg-raw.sln", "s16le", "pcm_s16le", android=True, rate=8000, force="sln"),
    audio("raw-narrowband.amrnb", "amrnb", "amr_nb", decoder="amrnb", android=True, rate=8000, force="amrnb"),
    audio("raw-wideband.amrwb", "amrwb", "amr_wb", decoder="amrwb", android=True, rate=16000, force="amrwb"),
    audio("tone.sox", "sox", "pcm_s32le", android=True),
    audio("ircamsound.sf", "ircam", "pcm_f32le", android=True),
    audio("mindstorms.rso", "rso", "pcm_u8", android=True, rate=8000),
    audio("wave64.w64", "w64", "pcm_f32le", android=True),
    audio("creative.voc", "voc", "pcm_s16le", android=True),
    audio("raw.dfpwm", "dfpwm", "dfpwm", android=True),
    audio("raw.g722", "g722", "adpcm_g722", encoder="g722", decoder="g722", android=True, rate=16000),
    audio("narrowband.ilbc", "ilbc", "ilbc", encoder="ilbc_at", android=True, rate=8000),
    audio("iec61937.spdif", "spdif", "ac3", android=True),
    audio("smaf.mmf", "mmf", "adpcm_yamaha", android=True, rate=22050),
    *(
        audio(name, demuxer, codec, android=True, rate=rate, force="avr" if demuxer == "avr" else None)
        for name, demuxer, codec, rate in LEGACY_AUDIO_FORMATS
    ),
    *(
        audio(name, demuxer, codec, android=True, rate=rate, force=demuxer if demuxer in ("adp", "afc") else "")
        for name, demuxer, codec, rate in CONSOLE_AUDIO_FORMATS
    ),
    audio("argonaut.cvg", "argo_cvg", "adpcm_psx", android=True, rate=22050),
    audio("xbox.xwma", "xwma", "wmav2", "-b:a", "48k", android=True, rate=44100),
    audio("broadcast-ac3.wtv", "wtv", "ac3", android=True),
    audio("broadcast-eac3.wtv", "wtv", "eac3", android=True),
    audio("broadcast-mp2.wtv", "wtv", "mp2", decoder="mp2float", android=True),
    audio("mpeg-audio-broadcast.pva", "pva", "mp2", decoder="mp2float", android=True, force="pva"),
    audio("mpeg-audio-capture.lmlm4", "lmlm4", "mp2", decoder="mp2float", android=True),
    audio("camera-alaw.dav", "dhav", "pcm_alaw", rate=8000, android=True),
    audio("camera-mulaw.dav", "dhav", "pcm_mulaw", rate=8000, android=True),
    *(
        audio(
            f"camera-{codec}.dav",
            "dhav",
            codec,
            decoder="mp2float" if codec == "mp2" else None,
            rate=8000 if codec in ("pcm_s8", "pcm_s16le") else 48000,
            android=True,
        )
        for codec in ("pcm_s8", "pcm_s16le", "aac", "mp2", "mp3", "adpcm_ms")
    ),
    audio("camera-hxvs-audio.264", "hxvs", "pcm_alaw", rate=8000, android=True, mpv=(("vid", "no"),)),
    *(
        audio(f"planar-{depth}.lxf", "lxf", codec, android=True, mpv=(("vid", "no"),))
        for depth, codec in ((16, "pcm_s16le_planar"), (20, "pcm_lxf"), (24, "pcm_s24le_planar"), (32, "pcm_s32le_planar"))
    ),
    *DERIVED_AUDIO,
)

HIGH_EFFICIENCY_AAC = tuple(
    (
        replace(
            audio(f"{name}.{suffix}", muxer, "aac", "-profile:a", str(profile_id), "-b:a", "48k", "-ac", "2", encoder="aac_at"),
            # Keep the first half pure, then add a tone above the 24 kHz core's
            # Nyquist frequency so the decoded high band depends on SBR.
            source=r"aevalsrc=0.25*sin(2*PI*440*t)+0.16*sin(2*PI*13300*t)*gte(t\,0.65):s=48000:d=1.15",
        ),
        profile,
    )
    for name, profile_id, profile in (("he-aac", 4, "HE-AAC"), ("he-aac-v2", 28, "HE-AACv2"))
    for suffix, muxer in (("m4a", "mp4"), ("aac", "adts"))
)


TS_PARTS = tuple(f"codecs-hls-{index:02}.ts" for index in range(3))
MP4_PARTS = tuple(f"codecs-part-{index:02}.mp4" for index in range(3))
SEGMENTED = (
    ("codecs-hls.m3u8", "hls", TS_PARTS),
    ("codecs-hls-fmp4.m3u8", "hls", ("codecs-hls-init.mp4", *(f"codecs-hls-{index:02}.m4s" for index in range(3)))),
    ("codecs-dash.mpd", "dash", ("codecs-dash-init.m4s", *(f"codecs-dash-{index:02}.m4s" for index in range(1, 4)))),
    ("codecs-concat.ffconcat", "concat", MP4_PARTS),
    ("codecs-timeline.edl", "edl/mov", MP4_PARTS),
)
HTTP_TS_PARTS = tuple(f"codecs-http-hls-{index:02}.ts" for index in range(3))
LIVE_PLAYLIST = "codecs-http-hls-live.m3u8"
LIVE_UPDATE = "codecs-http-hls-live-update.m3u8"
HLS_DISCONTINUITIES = "codecs-http-hls-discontinuities.m3u8"
HLS_DISCONTINUITY_PARTS = tuple(f"codecs-http-hls-discontinuities-{index:02}.ts" for index in range(9))
HLS_TIMESTAMP_RESETS = "codecs-http-hls-timestamp-resets.m3u8"
HLS_MASTER = "codecs-http-hls-master.m3u8"
HLS_HIGH = "codecs-http-hls-high.m3u8"
HLS_HIGH_PARTS = tuple(f"codecs-http-hls-high-{index:02}.ts" for index in range(3))
HLS_RENDITIONS = ("codecs-http-hls.m3u8", *HTTP_TS_PARTS, HLS_HIGH, *HLS_HIGH_PARTS)
DATAGRAM_TS = "codecs-datagrams.ts"
WINDOWS_MEDIA_HTTP = "codecs-windows-media.wmsp"
MP3_ADU = "codecs-reservoir-free.mp3"
RTP_AUDIO = (
    # Codec, encoder, packet storage, RTP payload type, RTP encoding, decoded rate,
    # byte and timestamp increments per packet, packet interval in milliseconds.
    ("pcm_mulaw", "pcm_mulaw", "mulaw", 0, "PCMU/8000", 8000, 160, 160, 20),
    ("g723_1", "g723_1", "g723_1", 4, "G723/8000", 8000, 24, 240, 30),
    ("pcm_alaw", "pcm_alaw", "alaw", 8, "PCMA/8000", 8000, 160, 160, 20),
    ("adpcm_g722", "g722", "g722", 9, "G722/8000", 16000, 160, 160, 20),
    ("pcm_s16be", "pcm_s16be", "s16be", 11, "L16/44100", 44100, 882, 441, 10),
)


def rtp_audio_name(codec, storage):
    return f"codecs-rtp-{codec}.{storage}"


COMFORT_NOISE = "codecs-comfort-noise.nut"
MPEG_TS_PROGRAMS = "codecs-two-programs.ts"
MPEG_TS_PROGRAM_CHANGES = "codecs-changing-programs.ts"
MPEG_TS_WRAP = "codecs-pts-wrap.ts"
VFR_ANAMORPHIC = "codecs-avc-vfr-anamorphic.mp4"
DISPLAY_ROTATION = "codecs-avc-display-rotation.mp4"
AVC_CROP = "codecs-avc-explicit-crop.mp4"
HEVC_UHD = "codecs-hevc-main10-uhd.mp4"
AV1_FILM_GRAIN = "codecs-av1-main10-film-grain.mkv"
INTERLACED_AVC = {"top": "codecs-avc-mbaff-top.mp4", "bottom": "codecs-avc-mbaff-bottom.mp4"}
TELECINE_MPEG2 = "codecs-mpeg2-telecine.mkv"
DASH_HTTP_PLAYLIST = "codecs-http-dash.mpd"
DASH_HTTP_PARTS = tuple(
    name
    for track, count in enumerate((3, 4))
    for name in (
        f"codecs-http-dash-{track}-init.m4s",
        *(f"codecs-http-dash-{track}-{index:02}.m4s" for index in range(1, count + 1)),
    )
)
NETWORK_STREAMS = (
    ("codecs-http-hls.m3u8", "hls", HTTP_TS_PARTS),
    ("codecs-http-hls-fmp4.m3u8", "hls", ("codecs-http-hls-init.mp4", *(f"codecs-http-hls-{index:02}.m4s" for index in range(3)))),
    (DASH_HTTP_PLAYLIST, "dash", DASH_HTTP_PARTS),
)
DASH_RENDITIONS = "codecs-dash-renditions.mpd"
DASH_ADAPTATION_SETS = "codecs-dash-adaptation-sets.mpd"
DASH_AUDIO_ADAPTATION_SETS = "codecs-dash-audio-adaptation-sets.mpd"
DASH_ALTERNATE_AUDIO_INIT = "codecs-dash-audio-alt-init.m4s"
DASH_ALTERNATE_AUDIO_MEDIA = "codecs-dash-audio-alt-$Number%02d$.m4s"
DASH_ALTERNATE_AUDIO_PARTS = (
    DASH_ALTERNATE_AUDIO_INIT,
    *(DASH_ALTERNATE_AUDIO_MEDIA.replace("$Number%02d$", f"{index:02}") for index in range(1, 5)),
)
DASH_RENDITION_PARTS = tuple(
    name
    for track, count in enumerate((3, 3, 4))
    for name in (
        f"codecs-dash-renditions-{track}-init.m4s",
        *(f"codecs-dash-renditions-{track}-{index:02}.m4s" for index in range(1, count + 1)),
    )
)
DASH_LIVE = "codecs-dash-live.mpd"
DASH_LIVE_UPDATE = "codecs-dash-live-update.mpd"
DASH_LIVE_SLIDE = "codecs-dash-live-slide.mpd"
DASH_LIVE_PARTS = DASH_RENDITION_PARTS[:4]
DASH_ROLLOVER_MANIFESTS = tuple(f"codecs-dash-rollover-{index}.mpd" for index in range(3))
DASH_ROLLOVER_WINDOWS = ((0, 2), (1, 4), (3, 6))
DASH_ROLLOVER_FIRST_SEQUENCE = 31
DASH_ROLLOVER_PARTS = {
    kind: (f"codecs-dash-rollover-{track}-init.m4s", *(f"codecs-dash-rollover-{track}-{index:02}.m4s" for index in range(1, 7)))
    for track, kind in enumerate(("video", "audio"))
}
SUBTITLE_VIDEO = "codecs-mov-text.mp4"
SUBTITLE_VTT = "codecs-cues.vtt"
SUBTITLE_WEBM = "codecs-webvtt.webm"
SUBTITLE_MATROSKA = "codecs-webvtt.mkv"
CEA608_TS = "codecs-cea608.ts"
CEA608_MOV = "codecs-cea608.mov"
CEA608_MXF = "codecs-cea608.mxf"
# Android's asset packager reserves the .scc extension for source control metadata.
CEA608_SCC = "codecs-cea608.scenarist"
CEA608_MCC = "codecs-cea608.mcc"
CEA608_RCWT = "codecs-cea608.rcwt"
FLV_CAPTIONS = "codecs-flv-captions.flv"
SURROUND_FLAC = "codecs-24bit-surround.flac"
PCM_RATE_CASES = (
    (44100, "alac", "codecs-alac-44100-24bit.m4a", "mov"),
    (96000, "pcm_s24le", "codecs-pcm-96000-24bit.wav", "wav"),
)
MONKEYS_AUDIO = "codecs-lossless.ape"
VC1_STREAM = "codecs-vc1.vc1"
VC1_CONTAINERS = (
    ("codecs-vc1.asf", "asf"),
    ("codecs-vc1.avi", "avi"),
    ("codecs-vc1.mov", "mov"),
    ("codecs-vc1.ts", "mpegts"),
    ("codecs-vc1.mkv", "matroska"),
    ("codecs-vc1.nut", "nut"),
)
WMV3_STREAM = "codecs-wmv3.rcv"
WMV3_CONTAINERS = tuple(
    (f"codecs-wmv3.{extension}", muxer) for extension, muxer in (("asf", "asf"), ("avi", "avi"), ("mkv", "matroska"), ("nut", "nut"))
)
CUE_AUDIO = "codecs-album.flac"
M4A_ALBUM = "codecs-album.m4a"
CUE_SHEET = "codecs-album.cue"
CUE_FILES = ("codecs-album-disc-1.flac", "codecs-album-disc-2.flac")
CUE_MULTI = "codecs-album-multi.cue"
PLAYLIST_M3U = "codecs-playlist.m3u"
PLAYLIST_PLS = "codecs-playlist.pls"
WEBM_DASH_INDEX = "codecs-webm-dash-index.webm"
WEBM_TRUNCATED_CLUSTER = "codecs-webm-truncated-cluster.webm"
VIDEO_ALPHA = (
    ("codecs-alpha-prores.mov", "prores_ks", "yuva444p10le", ("-profile:v", "4", "-alpha_bits", "16")),
    ("codecs-alpha-vp8.webm", "libvpx", "yuva420p", ("-auto-alt-ref", "0")),
    ("codecs-alpha-vp9.webm", "libvpx-vp9", "yuva420p", ("-auto-alt-ref", "0")),
)
RAW_VIDEO = "codecs-raw-frames.i420"
RAW_MJPEG = "codecs-raw-frames.mjpg"
RAW_H263P = "codecs-raw-frames.h263p"
STILLS = tuple(f"codecs-still-{index:02}.dpx" for index in range(3))
MANIFEST = "codecs.json"

# Each file changes its picture and tone at 1 s. Reuse the codec settings from
# the single-stream inputs so the added variable is A/V muxing and playback.
PAIRED = (
    ("avi", "mpeg4.avi", "mp3-float.mp3"),
    ("asf", "wmv2.asf", "wma2.asf"),
    ("mov", "prores.mov", "pcm-s16le.caf"),
    ("webm", "vp8.webm", "vorbis.ogg"),
    ("webm", "vp9.webm", "opus.ogg"),
)


def paired_inputs():
    video_fixtures = {fixture.name: fixture for fixture in VIDEO}
    audio_fixtures = {fixture.name: fixture for fixture in AUDIO}
    for muxer, picture, sound in PAIRED:
        picture, sound = video_fixtures[picture], audio_fixtures[sound]
        filename = f"codecs-paired-{picture.codec}-{sound.codec}.{muxer}"
        yield filename, muxer, picture, sound


def remuxed_inputs():
    fixtures = {
        fixture.name: (fixture, kind)
        for kind, clips in (
            ("video", VIDEO),
            ("audio", AUDIO),
            ("colorVideo", COLOR_VIDEO + tuple(fixture for fixture, _, _ in CHROMA_VIDEO)),
        )
        for fixture in clips
    }
    mappings = [
        (destination, lane, REMUX_SOURCES[codec][0])
        for destination, lanes in REMUX_MAPPINGS.items()
        for lane, codecs in lanes.items()
        for codec in codecs.split()
    ]
    mappings.extend(
        (destination, lane, name)
        for destination, lanes in ADDITIONAL_REMUX_SOURCES.items()
        for lane, files in lanes.items()
        for name in files.split()
    )
    for (reader, muxer, suffix), lane, name in mappings:
        source, kind = fixtures[name]
        target = replace(
            source,
            name=f"mapping-{reader}-{source.codec}.{suffix}",
            muxer=muxer,
            android_only=lane == "android",
            forced_format="live_flv" if reader == "live_flv" else "",
            # mpv's Matroska reader has no A_REAL/14_4 mapping. FFmpeg does.
            mpv_options=(("demuxer", "lavf"),) if reader == "matroska" and source.codec == "ra_144" else (),
            pipe_input=False,
        )
        yield source, target, kind, reader


def output_names():
    return (
        MANIFEST,
        SUBTITLE_VIDEO,
        SUBTITLE_VTT,
        SUBTITLE_WEBM,
        SUBTITLE_MATROSKA,
        CEA608_TS,
        CEA608_MOV,
        CEA608_MXF,
        CEA608_SCC,
        CEA608_MCC,
        CEA608_RCWT,
        FLV_CAPTIONS,
        SURROUND_FLAC,
        *(name for _, _, name, _ in PCM_RATE_CASES),
        MONKEYS_AUDIO,
        VC1_STREAM,
        *(name for name, _ in VC1_CONTAINERS),
        WMV3_STREAM,
        *(name for name, _ in WMV3_CONTAINERS),
        CUE_AUDIO,
        M4A_ALBUM,
        CUE_SHEET,
        *CUE_FILES,
        CUE_MULTI,
        PLAYLIST_M3U,
        PLAYLIST_PLS,
        WEBM_DASH_INDEX,
        WEBM_TRUNCATED_CLUSTER,
        *(name for name, *_ in VIDEO_ALPHA),
        RAW_VIDEO,
        RAW_MJPEG,
        RAW_H263P,
        LIVE_PLAYLIST,
        LIVE_UPDATE,
        HLS_DISCONTINUITIES,
        *HLS_DISCONTINUITY_PARTS,
        HLS_TIMESTAMP_RESETS,
        HLS_MASTER,
        HLS_HIGH,
        DATAGRAM_TS,
        WINDOWS_MEDIA_HTTP,
        RTMP_REPLIES,
        MP3_ADU,
        *(rtp_audio_name(codec, storage) for codec, _, storage, *_ in RTP_AUDIO),
        *packetized_rtp_names(),
        COMFORT_NOISE,
        MPEG_TS_PROGRAMS,
        MPEG_TS_PROGRAM_CHANGES,
        MPEG_TS_WRAP,
        VFR_ANAMORPHIC,
        DISPLAY_ROTATION,
        AVC_CROP,
        HEVC_UHD,
        AV1_FILM_GRAIN,
        *INTERLACED_AVC.values(),
        TELECINE_MPEG2,
        *HLS_HIGH_PARTS,
        DASH_RENDITIONS,
        DASH_ADAPTATION_SETS,
        *DASH_RENDITION_PARTS,
        DASH_AUDIO_ADAPTATION_SETS,
        *DASH_ALTERNATE_AUDIO_PARTS,
        DASH_LIVE,
        DASH_LIVE_UPDATE,
        DASH_LIVE_SLIDE,
        *DASH_ROLLOVER_MANIFESTS,
        *DASH_ROLLOVER_PARTS["video"],
        *DASH_ROLLOVER_PARTS["audio"],
        *STILLS,
        *(fixture.filename for fixture in VIDEO + COLOR_VIDEO + AUDIO + IMAGES + MF_ONLY_IMAGES),
        *(fixture.filename for fixture in AVS3_VIDEO),
        *(fixture.filename for fixture, _, _ in PRORES_RAW_VIDEO),
        *(fixture.filename for fixture, _ in APV_VIDEO),
        *(fixture.filename for fixture, _, _ in CHROMA_VIDEO),
        *(fixture.filename for fixture, _ in HIGH_EFFICIENCY_AAC),
        *(filename for filename, _, _, _ in paired_inputs()),
        *(target.filename for _, target, _, _ in remuxed_inputs()),
        *segmented_mapping_names(),
        *dict.fromkeys(name for filename, _, files in SEGMENTED + NETWORK_STREAMS for name in (filename, *files)),
    )


def ffmpeg(output, *args):
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", *args], cwd=output, check=True)


def amr_library(name):
    package = subprocess.run(["pkg-config", "--variable=libdir", name], capture_output=True, text=True)
    directory = package.stdout.strip()
    if not package.returncode and directory:
        suffix = ".dylib" if sys.platform == "darwin" else ".so"
        return ctypes.CDLL(str(Path(directory) / f"lib{name}{suffix}"))

    # The release tool's pkg-config only knows its own installation prefix.
    library = ctypes.util.find_library(name)
    if library is None:
        raise RuntimeError(f"Install {name} to generate AMR test media (Homebrew: brew bundle).")
    return ctypes.CDLL(library)


def generate_amr(output, filename, wideband, *, storage_header):
    # Drive the encoders directly when the host FFmpeg lacks the optional wrappers.
    if wideband:
        encoder = amr_library("vo-amrwbenc")
        initialize, encode, close = encoder.E_IF_init, encoder.E_IF_encode, encoder.E_IF_exit
        initialize.argtypes = []
        rate, mode, frame_bytes, magic = 16000, 8, 61, b"#!AMR-WB\n"  # 23.85 kbps
    else:
        encoder = amr_library("opencore-amrnb")
        initialize, encode, close = encoder.Encoder_Interface_init, encoder.Encoder_Interface_Encode, encoder.Encoder_Interface_exit
        initialize.argtypes = [ctypes.c_int]
        rate, mode, frame_bytes, magic = 8000, 7, 32, b"#!AMR\n"  # MR122, 12.2 kbps
    initialize.restype = ctypes.c_void_p
    encode.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_int16), ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int]
    encode.restype = ctypes.c_int
    close.argtypes = [ctypes.c_void_p]
    close.restype = None

    samples_per_frame = rate // 50
    speech = ctypes.c_int16 * samples_per_frame
    frame = (ctypes.c_ubyte * frame_bytes)()
    state = initialize() if wideband else initialize(0)
    if not state:
        raise RuntimeError(f"AMR encoder initialization failed for {filename}")
    try:
        with (output / filename).open("wb") as fixture:
            if storage_header:
                fixture.write(magic)
            for offset in range(0, rate * 5 // 4, samples_per_frame):
                samples = speech(
                    *(round(6000 * math.sin(math.tau * 440 * index / rate)) for index in range(offset, offset + samples_per_frame))
                )
                size = encode(state, mode, samples, frame, 0)  # Disable DTX.
                if size != len(frame):
                    raise RuntimeError(f"{filename} mode {mode} produced {size} bytes, expected {frame_bytes}")
                fixture.write(bytes(frame))
    finally:
        close(state)


def audition_wave(output, fixture):
    # Adobe Audition stores IEEE floats scaled by the nominal sample's integer range.
    rate, frames = 48000, 60000
    bits = 16 if fixture.codec == "pcm_f16le" else 24
    header = struct.pack("<HHIIHH", 1, 1, rate, rate * 4, 4, 32 if bits == 16 else 24)
    if bits == 16:
        header += struct.pack("<HH", 2, 1)
    scale = (1 << (bits - 1)) / 8
    signal = struct.pack(
        f"<{frames}f",
        *(scale * math.sin(math.tau * 440 * frame / rate) for frame in range(frames)),
    )
    (output / fixture.filename).write_bytes(riff(b"RIFF", b"WAVE" + riff(b"fmt ", header) + riff(b"data", signal)))


def tscc_avi(output, fixture):
    """Write a 24-bit TSCC AVI. Each frame contains lossless BGR runs compressed with zlib."""

    width, height = fixture.width, fixture.height
    colors = (b"\0\0\xff", b"\0\xff\0", b"\xff\0\0")
    runs = (width // 3, width // 3, width - 2 * (width // 3))
    frames = []
    for index in range(18):
        row = b"".join(bytes([length]) + colors[(index + band) % len(colors)] for band, length in enumerate(runs))
        frames.append((zlib.compress((row + b"\0\0") * height + b"\0\1"), True))
    (output / fixture.filename).write_bytes(video_avi(width, height, b"tscc", 24, frames))


def av1_annex_b(output, fixture):
    """Wrap intra-only AV1 OBUs in Annex B temporal and frame units."""
    with TemporaryDirectory(dir=output) as temp:
        ffmpeg(
            Path(temp),
            "-f",
            "lavfi",
            "-i",
            fixture.source,
            "-c:v",
            fixture.encoder,
            "-threads",
            "1",
            *fixture.options,
            "-bsf:v",
            "av1_metadata=td=insert",
            "-f",
            "obu",
            "source.obu",
        )
        source = (Path(temp) / "source.obu").read_bytes()

    def sized(data):
        size = len(data)
        prefix = bytearray()
        while size > 127:
            prefix.append((size & 127) | 128)
            size >>= 7
        prefix.append(size)
        return bytes(prefix) + data

    def temporal_unit(obus):
        # The source uses intra-only encoding so there is one frame unit per delimiter.
        if sum((obu[0] >> 3) & 15 == 6 for obu in obus) != 1:
            raise ValueError("Expected one AV1 frame per temporal unit")
        return sized(sized(b"".join(sized(obu) for obu in obus)))

    units = []
    obus = []
    offset = 0
    while offset < len(source):
        header = source[offset]
        if not header & 2:
            raise ValueError("AV1 OBU is missing its size")
        header_end = offset + 1 + bool(header & 4)
        cursor = header_end
        size = 0
        for shift in range(0, 56, 7):
            digit = source[cursor]
            cursor += 1
            size |= (digit & 127) << shift
            if digit < 128:
                break
        else:
            raise ValueError("Invalid AV1 OBU size")
        if cursor + size > len(source):
            raise ValueError("Truncated AV1 OBU payload")
        if (header >> 3) & 15 == 2 and obus:
            units.append(temporal_unit(obus))
            obus.clear()
        # The Annex B envelope supplies the size, so clear obu_has_size_field.
        obus.append(bytes([header & ~2]) + source[offset + 1 : header_end] + source[cursor : cursor + size])
        offset = cursor + size
    units.append(temporal_unit(obus))
    (output / fixture.filename).write_bytes(b"".join(units))


def generate_paired(output, filename, muxer, picture, sound):
    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        "color=red:size=176x144:rate=24:duration=1",
        "-f",
        "lavfi",
        "-i",
        "color=lime:size=176x144:rate=24:duration=1",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:sample_rate=44100:duration=1",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=660:sample_rate=44100:duration=1",
        "-filter_complex",
        "[0:v][1:v]concat=n=2:v=1:a=0[v];[2:a][3:a]concat=n=2:v=0:a=1[a]",
        "-map",
        "[v]",
        "-map",
        "[a]",
        "-c:v",
        picture.encoder,
        "-threads:v",
        "1",
        "-g",
        "24",
        *picture.options,
        "-c:a",
        sound.encoder,
        *sound.options,
        "-f",
        muxer,
        filename,
    )


def generate_video_alpha(output):
    def picture(red, blue):
        row = b"".join(bytes((red, 0, blue, alpha)) * 32 for alpha in (0, 128, 255))
        return row * 64

    with TemporaryDirectory(dir=output) as directory:
        source = Path(directory) / "stripes.rgba"
        source.write_bytes(picture(255, 0) * 12 + picture(0, 255) * 12)
        for name, encoder, pixel_format, options in VIDEO_ALPHA:
            ffmpeg(
                output,
                "-f",
                "rawvideo",
                "-pixel_format",
                "rgba",
                "-video_size",
                "96x64",
                "-framerate",
                "12",
                "-i",
                str(source.resolve()),
                "-c:v",
                encoder,
                "-pix_fmt",
                pixel_format,
                "-threads:v",
                "1",
                *options,
                name,
            )


def generate_transport_cases(output):
    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        "color=red:size=176x144:rate=24:duration=3",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:sample_rate=48000:duration=3",
        "-f",
        "lavfi",
        "-i",
        "color=blue:size=352x288:rate=24:duration=3",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=880:sample_rate=48000:duration=3",
        "-map",
        "0:v",
        "-map",
        "1:a",
        "-map",
        "2:v",
        "-map",
        "3:a",
        "-c:v:0",
        "libx264",
        "-threads:v:0",
        "1",
        "-preset:v:0",
        "ultrafast",
        "-g:v:0",
        "12",
        "-bf:v:0",
        "0",
        "-c:v:1",
        "mpeg2video",
        "-threads:v:1",
        "1",
        "-g:v:1",
        "12",
        "-bf:v:1",
        "2",
        "-c:a:0",
        "aac",
        "-c:a:1",
        "mp2",
        "-program",
        "program_num=101:st=0:st=1",
        "-program",
        "program_num=202:st=2:st=3",
        "-streamid",
        "0:256",
        "-streamid",
        "1:257",
        "-streamid",
        "2:512",
        "-streamid",
        "3:513",
        "-f",
        "mpegts",
        MPEG_TS_PROGRAMS,
    )
    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        "color=red:size=176x144:rate=24:duration=1.5",
        "-f",
        "lavfi",
        "-i",
        "color=blue:size=176x144:rate=24:duration=1.5",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:sample_rate=48000:duration=3",
        "-filter_complex",
        "[0:v][1:v]concat=n=2:v=1:a=0[v]",
        "-map",
        "[v]",
        "-map",
        "2:a",
        "-c:v",
        "libx264",
        "-threads:v",
        "1",
        "-preset",
        "ultrafast",
        "-g",
        "12",
        "-c:a",
        "aac",
        # PTS is 33 bits at 90 kHz. Start one second before it rolls over.
        "-muxdelay",
        "0",
        "-mpegts_copyts",
        "1",
        "-output_ts_offset",
        f"{(1 << 33) / 90000 - 1:.9f}",
        "-f",
        "mpegts",
        MPEG_TS_WRAP,
    )


def generate_mpegts_program_changes(output):
    parts = []
    with TemporaryDirectory(dir=output) as temporary:
        for version, (color, tone) in enumerate((("red", 440), ("lime", 550), ("blue", 660))):
            secondary = (
                (
                    "-f",
                    "lavfi",
                    "-i",
                    "color=white:s=352x288:r=24:d=3",
                    "-f",
                    "lavfi",
                    "-i",
                    "sine=frequency=880:sample_rate=48000:duration=3",
                )
                if version == 1
                else ()
            )
            secondary_streams = (
                (
                    "-map",
                    "2:v",
                    "-map",
                    "3:a",
                    "-c:v:1",
                    "mpeg2video",
                    "-threads:v:1",
                    "1",
                    "-g:v:1",
                    "12",
                    "-c:a:1",
                    "mp2",
                    "-program",
                    "program_num=202:st=2:st=3",
                    "-streamid",
                    "2:512",
                    "-streamid",
                    "3:513",
                )
                if secondary
                else ()
            )
            phase = Path(temporary).resolve() / f"version-{version}.ts"
            ffmpeg(
                output,
                "-f",
                "lavfi",
                "-i",
                f"color={color}:s=176x144:r=24:d=3",
                "-f",
                "lavfi",
                "-i",
                f"sine=frequency={tone}:sample_rate=48000:duration=3",
                *secondary,
                "-map",
                "0:v",
                "-map",
                "1:a",
                "-c:v:0",
                "libx264",
                "-threads:v:0",
                "1",
                "-preset:v:0",
                "ultrafast",
                "-g:v:0",
                "12",
                "-c:a:0",
                "aac",
                "-program",
                "program_num=101:st=0:st=1",
                "-streamid",
                "0:256",
                "-streamid",
                "1:257",
                *secondary_streams,
                "-tables_version",
                str(version),
                "-mpegts_flags",
                "+initial_discontinuity",
                "-mpegts_copyts",
                "1",
                "-muxdelay",
                "0",
                "-muxrate",
                "400000",
                "-output_ts_offset",
                str(0.25 + version * 3),
                "-f",
                "mpegts",
                str(phase),
            )
            parts.append(phase.read_bytes())
    (output / MPEG_TS_PROGRAM_CHANGES).write_bytes(b"".join(parts))


def generate_video_timing_cases(output):
    keep = "+".join(f"eq(n,{frame})" for frame in (0, 6, 18, 24, 27, 42, 48, 54, 66))
    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        "color=red:size=192x108:rate=24:duration=1",
        "-f",
        "lavfi",
        "-i",
        "color=lime:size=192x108:rate=24:duration=1",
        "-f",
        "lavfi",
        "-i",
        "color=blue:size=192x108:rate=24:duration=1",
        "-filter_complex",
        f"[0:v][1:v][2:v]concat=n=3:v=1:a=0,select='{keep}',setsar=3/2",
        "-fps_mode",
        "vfr",
        "-c:v",
        "libx264",
        "-threads:v",
        "1",
        "-preset",
        "ultrafast",
        "-g",
        "1",
        "-pix_fmt",
        "yuv420p",
        VFR_ANAMORPHIC,
    )
    with TemporaryDirectory(dir=output) as temporary:
        source = str(Path(temporary).resolve() / "unrotated.mp4")
        ffmpeg(
            output,
            "-f",
            "lavfi",
            "-i",
            "color=red:size=192x108:rate=24:duration=1",
            "-vf",
            "drawbox=x=96:y=0:w=96:h=108:color=blue:t=fill",
            "-c:v",
            "libx264",
            "-threads:v",
            "1",
            "-preset",
            "ultrafast",
            "-pix_fmt",
            "yuv420p",
            source,
        )
        ffmpeg(output, "-display_rotation", "90", "-i", source, "-c:v", "copy", DISPLAY_ROTATION)

    for order, filename in INTERLACED_AVC.items():
        parity = "tff" if order == "top" else "bff"
        ffmpeg(
            output,
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=192x128:rate=48:duration=1",
            "-vf",
            f"tinterlace=interleave_{order}",
            "-c:v",
            "libx264",
            "-threads:v",
            "1",
            "-flags",
            "+ilme+ildct",
            "-x264-params",
            f"{parity}=1:interlaced=1",
            "-bf",
            "0",
            "-pix_fmt",
            "yuv420p",
            filename,
        )
    # Distinct luma values identify the eight film frames in each half of the clip.
    levels = (46, 100, 158, 213, 66, 121, 176, 228)
    luma = str(levels[-1])
    for index, level in reversed(list(enumerate(levels[:-1]))):
        luma = f"if(eq(N,{index}),{level},{luma})"
    with TemporaryDirectory(dir=output) as temporary:
        directory = Path(temporary).resolve()
        for first_field, parity in (("top", "tff"), ("bottom", "bff")):
            ffmpeg(
                output,
                "-f",
                "lavfi",
                "-i",
                f"nullsrc=size=176x144:rate=24,geq=lum='{luma}':cb=128:cr=128",
                "-frames:v",
                "10",
                "-vf",
                f"telecine=first_field={first_field}:pattern=23,setfield={parity}",
                "-c:v",
                "mpeg2video",
                "-flags",
                "+ilme+ildct",
                "-bf",
                "0",
                "-q:v",
                "2",
                "-pix_fmt",
                "yuv420p",
                "-color_range",
                "tv",
                str(directory / f"{parity}.mkv"),
            )
        playlist = directory / "segments.ffconcat"
        playlist.write_text("file tff.mkv\nfile bff.mkv\n")
        ffmpeg(output, "-f", "concat", "-i", str(playlist), "-c", "copy", TELECINE_MPEG2)


def generate_video_geometry_cases(output):
    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        "color=black:size=192x144:rate=12:duration=1",
        "-vf",
        "drawbox=x=16:y=8:w=80:h=128:color=red:t=fill,drawbox=x=96:y=8:w=80:h=128:color=blue:t=fill",
        "-c:v",
        "libx264",
        "-threads:v",
        "1",
        "-preset",
        "ultrafast",
        "-bsf:v",
        "h264_metadata=crop_left=16:crop_right=16:crop_top=8:crop_bottom=8",
        AVC_CROP,
    )
    # Preserve a clean color target while the surrounding moving texture uses a real UHD bitrate.
    boxes = [
        f"drawbox=x=1520:y=810:w=800:h=540:color={color}:t=fill:enable='{when}'"
        for color, when in (
            ("red", "lt(t,0.5)"),
            ("lime", "between(t,0.5,0.999)"),
            ("blue", "gte(t,1)"),
        )
    ]
    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        "testsrc2=s=3840x2160:r=12:d=1.5",
        "-vf",
        ",".join(["noise=alls=8:allf=t+u", *boxes]),
        "-c:v",
        "libx265",
        "-preset",
        "ultrafast",
        "-crf",
        "20",
        "-pix_fmt",
        "yuv420p10le",
        "-threads",
        "4",
        "-x265-params",
        "pools=4:frame-threads=2:bframes=2:b-adapt=0:keyint=24:min-keyint=24:scenecut=0:log-level=error",
        "-tag:v",
        "hvc1",
        HEVC_UHD,
    )


def generate_av1_film_grain(output):
    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        "color=c=gray:size=160x96:rate=12:duration=1.5,noise=c0s=48:c0f=t+u",
        "-an",
        "-c:v",
        "libsvtav1",
        "-pix_fmt",
        "yuv420p10le",
        "-preset",
        "6",
        "-svtav1-params",
        "lp=2:film-grain=40:film-grain-denoise=1",
        "-g",
        "12",
        AV1_FILM_GRAIN,
    )


def generate_surround_audio(output):
    rate = 48000
    frames = rate * 5 // 4
    channels = 6
    frame_format = struct.Struct("<6i")
    source = bytearray(frames * frame_format.size)
    # Distinct, repeating signed 24-bit samples in WAVE channel order, aligned
    # to the high 24 bits of each 32-bit PCM word.
    for frame in range(frames):
        samples = [(((frame * step) % 10_000_019) - 5_000_009) << 8 for step in (31337, 40177, 48017, 12919, 57803, 65357)]
        frame_format.pack_into(source, frame * frame_format.size, *samples)
    with TemporaryDirectory(dir=output) as temporary:
        raw = Path(temporary) / "source.pcm"
        raw.write_bytes(source)
        ffmpeg(
            output,
            "-f",
            "s32le",
            "-ar",
            str(rate),
            "-ac",
            str(channels),
            "-channel_layout",
            "5.1",
            "-i",
            str(raw),
            "-c:a",
            "flac",
            "-sample_fmt",
            "s32",
            "-bits_per_raw_sample",
            "24",
            SURROUND_FLAC,
        )

    start = rate // 2
    return {
        "file": SURROUND_FLAC,
        "sampleRate": rate,
        "channels": channels,
        "frames": frames,
        "sha256": hashlib.sha256(source).hexdigest(),
        "seekStartFrame": start,
        "seekSha256": hashlib.sha256(source[start * frame_format.size :]).hexdigest(),
    }


def generate_audio_rate_cases(output):
    cases = []
    frame_format = struct.Struct("<2i")
    with TemporaryDirectory(dir=output) as temporary:
        raw = Path(temporary) / "rates.pcm"
        for rate, codec, name, demuxer in PCM_RATE_CASES:
            frames = rate * 5 // 4 + 13
            source = bytearray(frames * frame_format.size)
            for frame in range(frames):
                left = ((frame * 31337) % 10_000_019 - 5_000_009) << 8
                right = ((frame * 40177) % 10_000_079 - 5_000_039) << 8
                frame_format.pack_into(source, frame * frame_format.size, left, right)
            raw.write_bytes(source)
            ffmpeg(
                output,
                "-f",
                "s32le",
                "-ar",
                str(rate),
                "-ac",
                "2",
                "-i",
                str(raw),
                "-c:a",
                codec,
                "-bits_per_raw_sample",
                "24",
                name,
            )
            start = rate // 2
            cases.append(
                {
                    "codec": codec,
                    "format": demuxer,
                    "pcm": {
                        "file": name,
                        "sampleRate": rate,
                        "channels": 2,
                        "frames": frames,
                        "sha256": hashlib.sha256(source).hexdigest(),
                        "seekStartFrame": start,
                        "seekSha256": hashlib.sha256(source[start * frame_format.size :]).hexdigest(),
                        "seekEarlySha256": hashlib.sha256(source[(start - 1) * frame_format.size :]).hexdigest(),
                    },
                }
            )
    return cases


def generate_monkeys_audio(output):
    rate = 48000
    with TemporaryDirectory(dir=output) as temporary:
        wav = Path(temporary).resolve() / "source.wav"
        ffmpeg(output, "-f", "lavfi", "-i", f"sine=frequency=440:sample_rate={rate}:duration=4", "-c:a", "pcm_s16le", str(wav))
        with wave.open(str(wav), "rb") as reference:
            frames = reference.getnframes()
            source = reference.readframes(frames)
        subprocess.run(["mac", str(wav), MONKEYS_AUDIO, "-c2000", "-threads=1"], cwd=output, capture_output=True, check=True)

    # Start inside the second compressed frame and play through the third.
    start = rate * 9 // 4
    return {
        "file": MONKEYS_AUDIO,
        "sampleRate": rate,
        "channels": 1,
        "frames": frames,
        "sha256": hashlib.sha256(source).hexdigest(),
        "seekStartFrame": start,
        "seekSha256": hashlib.sha256(source[start * 2 :]).hexdigest(),
        "seekEarlySha256": hashlib.sha256(source[(start - 1) * 2 :]).hexdigest(),
    }


def vc1_bits(fields):
    bits = "".join(f"{value:0{width}b}" for value, width in fields)
    padded = bits.ljust((len(bits) + 7) // 8 * 8, "0")
    return int(padded, 2).to_bytes(len(padded) // 8, "big")


def vc1_intra_blocks(y, cb, cr):
    def dc(value, *, chroma=False):
        if value == 0:
            return [(0, 2)] if chroma else [(1, 1)]
        escape = (0x60888F, 23) if chroma else (0x6078F, 24)
        return [escape, (abs(value), 8), (int(value < 0), 1)]

    fields = []
    for index in range(4):  # Four macroblocks in a 32×32 picture.
        fields.extend([(1, 1), (0, 1)])  # No coded AC coefficients or AC prediction.
        fields.extend(dc(0 if index else y) + dc(0) * 3)
        fields.extend(dc(0 if index else cb, chroma=True) + dc(0 if index else cr, chroma=True))
    return fields


def generate_vc1(output):
    # SMPTE 421M Advanced Profile with one sequence and two closed entry
    # points. DC-only intra pictures give each half a distinct solid color.
    def unit(code, fields):
        payload = bytearray()
        for byte in vc1_bits(fields):
            if payload[-2:] == b"\x00\x00" and byte <= 3:
                payload.append(3)
            payload.append(byte)
        return b"\x00\x00\x01" + bytes([code]) + payload

    size = 32
    sequence = unit(
        0x0F,
        [
            (3, 2),
            (0, 3),
            (1, 2),  # Advanced Profile, level 0, 4:2:0.
            (0, 3),
            (0, 5),
            (0, 1),  # No postprocessing.
            (size // 2 - 1, 12),
            (size // 2 - 1, 12),
            (0, 1),
            (0, 1),
            (0, 1),
            (0, 1),
            (1, 1),
            (0, 1),  # Progressive pictures.
            (1, 1),
            (size - 1, 14),
            (size - 1, 14),
            (1, 1),
            (1, 4),  # Square pixels.
            (1, 1),
            (1, 1),
            (12 * 32 - 1, 16),
            (0, 1),
            (0, 1),
        ],
    )
    entry = unit(
        0x0E,
        [
            (0, 1),
            (1, 1),
            (0, 1),
            (0, 1),
            (0, 1),
            (0, 1),
            (0, 1),  # Closed entry point.
            (0, 2),
            (0, 1),
            (0, 1),
            (3, 2),  # Uniform quantization.
            (0, 1),
            (0, 1),
            (0, 1),  # Keep the sequence dimensions and sample range.
        ],
    )

    def intra(y, cb, cr):
        # I picture, RNDCTRL=0, quantizer 20, raw ACPRED, default AC/DC tables.
        fields = [(0b110, 3), (0, 1), (20, 5), (0, 5), (0, 3)]
        return unit(0x0D, fields + vc1_intra_blocks(y, cb, cr))

    red = intra(-26, -22, 61)
    blue = intra(-42, 54, -11)
    (output / VC1_STREAM).write_bytes(sequence + entry + 12 * red + entry + 12 * blue + b"\x00\x00\x01\x0a")

    for name, muxer in VC1_CONTAINERS:
        # NUT needs packet timestamps. MOV has them after copying the raw units.
        source = ("-i", "codecs-vc1.mov") if muxer == "nut" else ("-r", "25", "-i", VC1_STREAM)
        ffmpeg(output, *source, "-c:v", "copy", "-f", muxer, name)


def generate_wmv3(output):
    # Main Profile, FASTTX and FASTUVMC, uniform quantization, no B frames.
    sequence = bytes.fromhex("44 41 80 0d")
    # An I picture has two frame-count bits, one type bit and seven buffer bits.
    picture_header = [(0, 10), (20, 5), (0, 3)]
    red = vc1_bits(picture_header + vc1_intra_blocks(-26, -22, 61))
    blue = vc1_bits(picture_header + vc1_intra_blocks(-42, 54, -11))
    frames = [red] * 12 + [blue] * 12
    # RCV version 2 uses millisecond timestamps when its rate field is all ones.
    header = len(frames).to_bytes(3, "little") + b"\xc5" + struct.pack("<I", len(sequence))
    header += sequence + struct.pack("<6I", 32, 32, 12, 0, 0, 0xFFFFFFFF)
    packets = (
        len(frame).to_bytes(3, "little") + b"\x80" + struct.pack("<I", round(index * 1000 / 12)) + frame
        for index, frame in enumerate(frames)
    )
    (output / WMV3_STREAM).write_bytes(header + b"".join(packets))
    for name, muxer in WMV3_CONTAINERS:
        ffmpeg(output, "-i", WMV3_STREAM, "-c:v", "copy", "-f", muxer, name)


def vc1_cases(codec, containers):
    return [
        {
            "file": name,
            "format": "mkv" if muxer == "matroska" else muxer,
            "codec": codec,
            "decoder": codec,
            "width": 32,
            "height": 32,
            "androidOnly": muxer in {"nut", "vc1test"},
            "mpvOptions": {},
        }
        for name, muxer in containers
    ]


def generate_cue_album(output):
    tones = [arg for hz in (440, 660, 880) for arg in ("-f", "lavfi", "-i", f"sine=frequency={hz}:sample_rate=48000:duration=1")]
    ffmpeg(output, *tones, "-filter_complex", "[0:a][1:a][2:a]concat=n=3:v=0:a=1", "-c:a", "flac", CUE_AUDIO)
    entries = ['TITLE "Local audio album"', f'FILE "{CUE_AUDIO}" WAVE']
    for index, title in enumerate(("Opening", "Middle", "Ending")):
        entries.extend((f"  TRACK {index + 1:02} AUDIO", f'    TITLE "{title}"', f"    INDEX 01 00:{index:02}:00"))
    (output / CUE_SHEET).write_text("\n".join(entries) + "\n", encoding="ascii")

    first, second = CUE_FILES
    ffmpeg(output, "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1", "-c:a", "flac", first)
    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=660:sample_rate=48000:duration=0.4",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=880:sample_rate=48000:duration=1",
        "-filter_complex",
        "[0:a][1:a]concat=n=2:v=0:a=1",
        "-c:a",
        "flac",
        "-frame_size",
        "960",
        second,
    )
    (output / CUE_MULTI).write_text(
        f'TITLE "Local multi-file audio album"\n'
        f'FILE "{first}" WAVE\n'
        '  TRACK 01 AUDIO\n    TITLE "First file"\n    INDEX 01 00:00:00\n'
        f'FILE "{second}" WAVE\n'
        '  TRACK 02 AUDIO\n    TITLE "Second file"\n    INDEX 00 00:00:00\n    INDEX 01 00:00:30\n',
        encoding="ascii",
    )


def generate_m4a_album(output):
    tones = [
        argument for hz in (440, 660, 880) for argument in ("-f", "lavfi", "-i", f"sine=frequency={hz}:sample_rate=48000:duration=1.024")
    ]
    # A whole number of AAC frames gives the priming edit a sample-exact endpoint.
    metadata = [";FFMETADATA1", "title=Three tone album", "artist=Test ensemble"]
    for index, title in enumerate(("Opening", "Middle", "Ending")):
        metadata.extend(("[CHAPTER]", "TIMEBASE=1/1000", f"START={1024 * index}", f"END={1024 * (index + 1)}", f"title={title}"))

    with TemporaryDirectory() as directory:
        chapters = Path(directory) / "album.ffmetadata"
        chapters.write_text("\n".join(metadata) + "\n", encoding="ascii")
        ffmpeg(
            output,
            *tones,
            "-f",
            "lavfi",
            "-i",
            "color=blue:size=96x64:rate=1:duration=1",
            "-f",
            "ffmetadata",
            "-i",
            str(chapters),
            "-filter_complex",
            "[0:a][1:a][2:a]concat=n=3:v=0:a=1[album]",
            "-map",
            "[album]",
            "-map",
            "3:v",
            "-map_metadata",
            "4",
            "-map_chapters",
            "4",
            "-c:a",
            "aac",
            "-b:a",
            "96k",
            "-c:v",
            "mjpeg",
            "-pix_fmt",
            "yuvj420p",
            "-disposition:v",
            "attached_pic",
            "-f",
            "ipod",
            M4A_ALBUM,
        )


def generate_playlists(output):
    files = (HTTP_TS_PARTS[0], "codecs-missing-playlist-entry.ts", HTTP_TS_PARTS[2])
    titles = ("Opening", "Unavailable", "Ending")
    m3u = "".join(f"#EXTINF:1,{title}\n{name}\n" for name, title in zip(files, titles))
    (output / PLAYLIST_M3U).write_text("#EXTM3U\n" + m3u, encoding="ascii")
    pls = "".join(
        f'File{index}="{name}"\nTitle{index}={title}\nLength{index}=1\n' for index, (name, title) in enumerate(zip(files, titles), start=1)
    )
    (output / PLAYLIST_PLS).write_text("[playlist]\nNumberOfEntries=3\n" + pls + "Version=2\n", encoding="ascii")


def generate_http_streams(output):
    # All three manifests carry the same picture and audio changes at each
    # segment boundary. Only the packaging and HTTP requests differ.
    colors = ("red", "lime", "blue")
    frequencies = (440, 660, 880)
    video = [arg for color in colors for arg in ("-f", "lavfi", "-i", f"color={color}:size=176x144:rate=12:duration=1")]
    audio = [arg for hz in frequencies for arg in ("-f", "lavfi", "-i", f"sine=frequency={hz}:sample_rate=48000:duration=1")]
    dash_namespace = "urn:mpeg:dash:schema:mpd:2011"
    namespace = f"{{{dash_namespace}}}"
    ElementTree.register_namespace("", dash_namespace)
    ElementTree.register_namespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
    with TemporaryDirectory(dir=output) as temporary:
        source = str((Path(temporary) / "source.mp4").resolve())
        ffmpeg(
            output,
            *video,
            *audio,
            "-filter_complex",
            "[0:v][1:v][2:v]concat=n=3:v=1:a=0[v];[3:a][4:a][5:a]concat=n=3:v=0:a=1[a]",
            "-map",
            "[v]",
            "-map",
            "[a]",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-g",
            "12",
            "-sc_threshold",
            "0",
            "-threads:v",
            "1",
            "-c:a",
            "aac",
            source,
        )
        generate_dash_rollovers(output, source)
        ffmpeg(output, "-stream_loop", "3", "-i", source, "-c", "copy", "-muxrate", "256k", "-f", "mpegts", DATAGRAM_TS)
        ffmpeg(output, "-i", source, "-c", "copy", "-f", "asf_stream", WINDOWS_MEDIA_HTTP)
        flv = Path(temporary).resolve() / "source.flv"
        ffmpeg(output, "-i", source, "-c", "copy", "-f", "flv", str(flv))
        write_rtmp_replies(output, flv.read_bytes())
        hls = ("-f", "hls", "-hls_time", "1", "-hls_playlist_type", "vod")
        ffmpeg(output, "-i", source, "-c", "copy", *hls, "-hls_segment_filename", "codecs-http-hls-%02d.ts", "codecs-http-hls.m3u8")
        ffmpeg(
            output,
            "-stream_loop",
            "2",
            "-i",
            source,
            "-c",
            "copy",
            *hls,
            "-hls_segment_filename",
            "codecs-http-hls-discontinuities-%02d.ts",
            HLS_DISCONTINUITIES,
        )
        ffmpeg(
            output,
            "-i",
            source,
            "-vf",
            "scale=352:288",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-g",
            "12",
            "-sc_threshold",
            "0",
            "-threads:v",
            "1",
            "-c:a",
            "copy",
            *hls,
            "-hls_segment_filename",
            "codecs-http-hls-high-%02d.ts",
            HLS_HIGH,
        )
        ffmpeg(
            output,
            "-i",
            source,
            "-c",
            "copy",
            *hls,
            "-hls_segment_type",
            "fmp4",
            "-hls_fmp4_init_filename",
            "codecs-http-hls-init.mp4",
            "-hls_segment_filename",
            "codecs-http-hls-%02d.m4s",
            "codecs-http-hls-fmp4.m3u8",
        )
        ffmpeg(
            output,
            "-i",
            source,
            "-c",
            "copy",
            "-f",
            "dash",
            "-seg_duration",
            "1",
            "-use_timeline",
            "1",
            "-init_seg_name",
            "codecs-http-dash-$RepresentationID$-init.m4s",
            "-media_seg_name",
            "codecs-http-dash-$RepresentationID$-$Number%02d$.m4s",
            DASH_HTTP_PLAYLIST,
        )
        ffmpeg(
            output,
            "-i",
            source,
            "-filter_complex",
            "[0:v]scale=352:288[high]",
            "-map",
            "0:v:0",
            "-map",
            "[high]",
            "-map",
            "0:a:0",
            "-c:v:0",
            "copy",
            "-c:v:1",
            "libx264",
            "-preset",
            "ultrafast",
            "-b:v:1",
            "250k",
            "-g",
            "12",
            "-sc_threshold",
            "0",
            "-threads:v",
            "1",
            "-c:a",
            "copy",
            "-f",
            "dash",
            "-seg_duration",
            "1",
            "-use_timeline",
            "1",
            "-adaptation_sets",
            "id=0,streams=v id=1,streams=a",
            "-init_seg_name",
            "codecs-dash-renditions-$RepresentationID$-init.m4s",
            "-media_seg_name",
            "codecs-dash-renditions-$RepresentationID$-$Number%02d$.m4s",
            DASH_RENDITIONS,
        )

    manifest = ElementTree.parse(output / DASH_RENDITIONS)
    period = manifest.getroot().find(f"{namespace}Period")
    video, audio = period.findall(f"{namespace}AdaptationSet")
    _, high = video.findall(f"{namespace}Representation")
    video.remove(high)
    alternate = ElementTree.Element(video.tag, {**video.attrib, "id": "2"})
    alternate.append(high)
    period.insert(list(period).index(audio), alternate)
    manifest.write(output / DASH_ADAPTATION_SETS, encoding="utf-8", xml_declaration=True)

    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=990:sample_rate=48000:duration=3",
        "-c:a",
        "aac",
        "-b:a",
        "96k",
        "-f",
        "dash",
        "-seg_duration",
        "1",
        "-use_timeline",
        "1",
        "-init_seg_name",
        DASH_ALTERNATE_AUDIO_INIT,
        "-media_seg_name",
        DASH_ALTERNATE_AUDIO_MEDIA,
        DASH_AUDIO_ADAPTATION_SETS,
    )
    alternate = ElementTree.parse(output / DASH_AUDIO_ADAPTATION_SETS).getroot().find(f"{namespace}Period/{namespace}AdaptationSet")
    alternate.set("id", "2")
    alternate.set("lang", "es")
    alternate.find(f"{namespace}Representation").set("id", "2")
    manifest = ElementTree.parse(output / DASH_HTTP_PLAYLIST)
    period = manifest.getroot().find(f"{namespace}Period")
    _, audio = period.findall(f"{namespace}AdaptationSet")
    audio.set("lang", "en")
    period.append(alternate)
    manifest.write(output / DASH_AUDIO_ADAPTATION_SETS, encoding="utf-8", xml_declaration=True)

    first, second, third = HTTP_TS_PARTS
    header = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n"
    (output / LIVE_PLAYLIST).write_text(header + f"#EXT-X-MEDIA-SEQUENCE:101\n#EXTINF:1,\n{first}\n#EXTINF:1,\n{second}\n")
    (output / LIVE_UPDATE).write_text(
        header + f"#EXT-X-MEDIA-SEQUENCE:102\n#EXTINF:1,\n{second}\n#EXT-X-DISCONTINUITY\n#EXTINF:1,\n{third}\n#EXT-X-ENDLIST\n"
    )
    for filename, parts in ((HLS_DISCONTINUITIES, HLS_DISCONTINUITY_PARTS), (HLS_TIMESTAMP_RESETS, HTTP_TS_PARTS * 3)):
        # The second playlist reuses three segments, restarting their MPEG-TS timestamps twice.
        cycles = ["".join(f"#EXTINF:1,\n{name}\n" for name in parts[start : start + 3]) for start in (0, 3, 6)]
        (output / filename).write_text(
            header + "#EXT-X-PLAYLIST-TYPE:VOD\n" + "#EXT-X-DISCONTINUITY\n".join(cycles) + "#EXT-X-ENDLIST\n",
            encoding="ascii",
        )
    (output / HLS_MASTER).write_text(
        "#EXTM3U\n#EXT-X-VERSION:3\n"
        "#EXT-X-STREAM-INF:BANDWIDTH=150000,RESOLUTION=176x144\ncodecs-http-hls.m3u8\n"
        f"#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=352x288\n{HLS_HIGH}\n"
    )
    init, *segments = DASH_LIVE_PARTS
    for manifest, start_number, parts in (
        (DASH_LIVE, 0, segments[:2]),
        (DASH_LIVE_UPDATE, 0, segments),
        (DASH_LIVE_SLIDE, 1, segments[1:]),
    ):
        urls = "".join(f'          <SegmentURL media="{name}"/>\n' for name in parts)
        (output / manifest).write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-live:2011"\n'
            '     type="dynamic" availabilityStartTime="1970-01-01T00:00:00Z" minimumUpdatePeriod="PT1S" minBufferTime="PT1S">\n'
            '  <Period id="0" start="PT0S">\n'
            '    <AdaptationSet contentType="video" mimeType="video/mp4" segmentAlignment="true">\n'
            '      <Representation id="0" bandwidth="50000" width="176" height="144" frameRate="12">\n'
            f'        <SegmentList timescale="1" duration="1" startNumber="{start_number}">\n'
            f'          <Initialization sourceURL="{init}"/>\n'
            f"{urls}"
            "        </SegmentList>\n"
            "      </Representation>\n"
            "    </AdaptationSet>\n"
            "  </Period>\n"
            "</MPD>\n"
        )


def generate_dash_rollovers(output, source):
    ffmpeg(
        output,
        "-stream_loop",
        "1",
        "-i",
        source,
        "-t",
        "6",
        "-c",
        "copy",
        "-f",
        "dash",
        "-seg_duration",
        "1",
        "-init_seg_name",
        "codecs-dash-rollover-$RepresentationID$-init.m4s",
        "-media_seg_name",
        "codecs-dash-rollover-$RepresentationID$-$Number%02d$.m4s",
        DASH_ROLLOVER_MANIFESTS[0],
    )
    namespace = "{urn:mpeg:dash:schema:mpd:2011}"
    manifest = ElementTree.parse(output / DASH_ROLLOVER_MANIFESTS[0])
    root = manifest.getroot()
    root.attrib.pop("mediaPresentationDuration")
    root.set("type", "dynamic")
    root.set("availabilityStartTime", "1970-01-01T00:00:00Z")
    root.set("minimumUpdatePeriod", "PT1S")
    lists = {}
    for adaptation in root.find(f"{namespace}Period").findall(f"{namespace}AdaptationSet"):
        kind = adaptation.get("contentType")
        representation = adaptation.find(f"{namespace}Representation")
        representation.remove(representation.find(f"{namespace}SegmentTemplate"))
        segment_list = ElementTree.SubElement(representation, f"{namespace}SegmentList", timescale="1", duration="1")
        ElementTree.SubElement(segment_list, f"{namespace}Initialization", sourceURL=DASH_ROLLOVER_PARTS[kind][0])
        lists[kind] = segment_list

    for (start, end), filename in zip(DASH_ROLLOVER_WINDOWS, DASH_ROLLOVER_MANIFESTS, strict=True):
        for kind, segment_list in lists.items():
            segment_list.set("startNumber", str(DASH_ROLLOVER_FIRST_SEQUENCE + start))
            for media in segment_list.findall(f"{namespace}SegmentURL"):
                segment_list.remove(media)
            for name in DASH_ROLLOVER_PARTS[kind][start + 1 : end + 1]:
                ElementTree.SubElement(segment_list, f"{namespace}SegmentURL", media=name)
        manifest.write(output / filename, encoding="utf-8", xml_declaration=True)


def generate_cea608(output):
    def odd_parity(byte):
        return byte if byte.bit_count() % 2 else byte | 0x80

    def caption_nal(pair):
        # ATSC A/53 carries one valid field-one 608 pair in a registered ITU-T T.35 SEI.
        header = b"\xb5\x00\x31GA94\x03\x41\xff\xfc"
        payload = header + bytes(map(odd_parity, pair)) + b"\xff"
        return b"\x00\x00\x00\x01\x06\x04" + bytes([len(payload)]) + payload + b"\x80"

    captions = {}
    for start_frame, text, preamble in ((28, b"FIRST CAPTION ", (0x14, 0x60)), (88, b"SECOND CAPTION", (0x11, 0x40))):
        # Resume caption loading, clear nondisplayed memory, set the row,
        # then swap caption memories once the whole line has arrived.
        pairs = [(0x14, 0x20), (0x14, 0x2E), preamble]
        pairs.extend(zip(text[::2], text[1::2], strict=True))
        pairs.append((0x14, 0x2F))
        captions.update(enumerate(pairs, start=start_frame))
        captions[start_frame + 42] = (0x14, 0x2C)  # Erase displayed memory.
    captions[144] = (0, 0)  # Give the last erase sample a finite duration in MOV.

    with TemporaryDirectory(dir=output) as temporary:
        source = (Path(temporary) / "source.h264").resolve()
        with_captions = source.with_name("captioned.h264")
        rate = "30000/1001"
        ffmpeg(
            output,
            "-f",
            "lavfi",
            "-i",
            f"color=black:size=320x180:rate={rate}:duration=5",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-threads:v",
            "1",
            "-x264-params",
            "aud=1:bframes=0:keyint=30:min-keyint=30:scenecut=0",
            "-f",
            "h264",
            str(source),
        )
        video = source.read_bytes()
        delimiters = list(re.finditer(rb"\x00\x00(?:\x00)?\x01\x09.", video))
        if len(delimiters) <= max(captions):
            raise ValueError("Missing H.264 access units for the CEA-608 timeline")
        offset = 0
        with with_captions.open("wb") as stream:
            for frame, pair in sorted(captions.items()):
                end = delimiters[frame].end()
                stream.write(video[offset:end])
                stream.write(caption_nal(pair))
                offset = end
            stream.write(video[offset:])
        ffmpeg(output, "-r", rate, "-i", str(with_captions), "-c", "copy", "-f", "mpegts", CEA608_TS)
        ffmpeg(
            output,
            "-r",
            rate,
            "-i",
            str(source),
            "-f",
            "lavfi",
            "-i",
            f"movie={CEA608_TS}[out+subcc]",
            "-map",
            "0:v:0",
            "-map",
            "1:s:0",
            "-c",
            "copy",
            CEA608_MOV,
        )
        ffmpeg(output, "-i", CEA608_MOV, "-map", "0:s:0", "-c:s", "copy", "-f", "scc", CEA608_SCC)
        ffmpeg(
            output,
            "-i",
            CEA608_MOV,
            "-map",
            "0:s:0",
            "-c:s",
            "copy",
            "-fflags",
            "+bitexact",
            "-override_time_code_rate",
            "30",
            "-creation_time",
            "2024-01-01 00:00:00",
            "-f",
            "mcc",
            CEA608_MCC,
        )
        ffmpeg(output, "-i", CEA608_MOV, "-map", "0:s:0", "-c:s", "copy", "-fflags", "+bitexact", "-f", "rcwt", CEA608_RCWT)
        # MXF frame-wraps captions. Fill the sparse track with no-op pairs so each cue
        # keeps the same video frame number on the SMPTE 436M ancillary track.
        frame_map = Path(temporary).resolve() / "frames.scc"
        rows = []
        for frame in range(len(delimiters)):
            seconds, index = divmod(frame, 30)
            word = bytes(map(odd_parity, captions.get(frame, (0, 0)))).hex()
            rows.append(f"00:00:{seconds:02}:{index:02}\t{word}\n\n")
        frame_map.write_text("Scenarist_SCC V1.0\n\n" + "".join(rows))
        ffmpeg(
            output,
            "-i",
            CEA608_MOV,
            "-i",
            frame_map,
            "-map",
            "0:v:0",
            "-map",
            "1:s:0",
            "-c:v",
            "mpeg2video",
            "-c:s",
            "copy",
            "-vf",
            "scale=720:480",
            "-r",
            rate,
            "-pix_fmt",
            "yuv422p",
            "-g",
            "12",
            "-threads",
            "1",
            CEA608_MXF,
        )


def text_screen(fmt, width, height, bright_on_left):
    columns, rows = width // 8, height // 16
    half = columns // 2
    attributes = (0xF0, 0) if bright_on_left else (0, 0xF0)
    left, right = (bytes((32, attribute)) for attribute in attributes)
    cells = (left * half + right * half) * rows
    palette = bytes(45) + bytes([63]) * 3
    blank_font = bytes(4096)
    if fmt == "tty":
        # Position each row explicitly so the terminal's last-column wrap cannot scroll the pattern.
        column = 1 if bright_on_left else half + 1
        return b"\x1b[47m" + b"".join(f"\x1b[{line};{column}H".encode("ascii") + b" " * (half - 1) for line in range(1, rows + 1))
    if fmt == "xbin":
        # Repeat each pair of character and attribute bits. Finish with literal cells.
        header = b"XBIN\x1a" + struct.pack("<HHBB", columns, rows, 16, 4)
        repeated = bytes((0xC0 | (half - 1),))
        return header + (repeated + left + repeated + right) * (rows - 1) + repeated + left + bytes((half - 1,)) + right * half
    if fmt == "adf":
        return b"\x01" + palette[:24] + bytes(144) + palette[24:] + blank_font + cells
    if fmt == "idf":
        header = b"\x041.4" + struct.pack("<4H", 0, 0, columns - 1, rows - 1)
        return header + cells + blank_font + palette
    return cells


def generate_still(output, fixture, bright_on_left):
    width, height = fixture.width, fixture.height
    path = output / fixture.filename
    bright, dark = bytes([255]) * (width // 2), bytes(width // 2)
    row = bright + dark if bright_on_left else dark + bright
    gray = row * height
    if fixture.muxer in ("bin", "xbin", "adf", "idf", "tty"):
        path.write_bytes(text_screen(fixture.muxer, width, height, bright_on_left))
    elif fixture.muxer == "msp":
        path.write_bytes(msp(width, height, fixture.codec == "msp2", bright_on_left))
    elif fixture.muxer == "frm":
        path.write_bytes(frm(width, height, fixture.name.removesuffix(".frm").removeprefix("megalux-"), bright_on_left))
    elif fixture.muxer == "cri_pipe":
        path.write_bytes(cintel_raw(width, height, bright_on_left))
    elif fixture.codec == "brender_pix":
        pixels = b"".join(bytes((value,)) * 3 for value in gray)
        start = struct.pack(">4I", 0x12, 8, 2, 2)
        header = struct.pack(">2IB3H4x", 3, 11, 6, width * 3, width, height)
        data = struct.pack(">4I", 0x21, len(pixels), width * height, 3)
        path.write_bytes(start + header + data + pixels)
    elif fixture.codec == "gem":
        # One bit plane. The GEM palette assigns index zero to white.
        header = struct.pack(">8H", 1, 8, 1, 1, 372, 372, width, height)
        run = width // 16
        line = bytes((run, 0x80 | run))
        path.write_bytes(header + (line if bright_on_left else line[::-1]) * height)
    elif fixture.codec == "pictor":
        # One eight-bit plane, two VGA palette entries and uncompressed scanlines.
        header = struct.pack("<3H4xB2s2H", 0x1234, width, height, 8, b"\xff\x00", 4, 6)
        palette = b"\x00\x00\x00\x3f\x3f\x3f"
        path.write_bytes(header + palette + bytes(2) + gray.translate(bytes.maketrans(b"\xff", b"\x01")))
    elif fixture.codec == "photocd":
        # A Photo CD contact sheet with a single neutral-chroma thumbnail.
        header = (b"PCD_OPA" + bytes(3) + struct.pack("<H", 1)).ljust(10240, b"\0")
        pair = row * 2 + b"\x9c" * (width // 2) + b"\x89" * (width // 2)
        path.write_bytes(header + pair * (height // 2))
    elif fixture.codec == "dds":
        # Uncompressed little-endian BGRA with an explicit alpha channel.
        dimensions = (124, 0x100F, height, width, 4 * width, 0, 0, *(0,) * 11)
        pixel_format = (32, 0x41, 0, 32, 0xFF0000, 0xFF00, 0xFF, 0xFF000000)
        caps = (0x1000, 0, 0, 0, 0)
        path.write_bytes(
            b"DDS " + struct.pack("<31I", *dimensions, *pixel_format, *caps) + b"".join(bytes((value, value, value, 255)) for value in gray)
        )
    elif fixture.codec == "pgx":
        path.write_bytes(f"PG ML + 8 {width} {height}\n".encode("ascii") + gray)
    elif fixture.codec == "psd":
        # Version 1, three 8-bit RGB planes, empty metadata sections, raw pixels.
        header = struct.pack(">4sH6xHIIHHIIIH", b"8BPS", 1, 3, height, width, 8, 3, 0, 0, 0, 0)
        path.write_bytes(header + gray * 3)
    elif fixture.codec == "xpm":
        pixels = row.translate(bytes.maketrans(b"\x00\xff", b".+")).decode("ascii")
        lines = [f'"{width} {height} 2 1"', '". c #000000"', '"+ c #ffffff"', *[f'"{pixels}"'] * height]
        path.write_text("/* XPM */\nstatic char *pattern[] = {\n" + ",\n".join(lines) + "\n};\n", encoding="ascii")
    elif fixture.codec == "webp":
        with TemporaryDirectory(prefix="webp-fixture-") as temporary:
            ppm = Path(temporary) / "pattern.ppm"
            ppm.write_bytes(f"P6\n{width} {height}\n255\n".encode("ascii") + b"".join(bytes((value,)) * 3 for value in gray))
            subprocess.run(["cwebp", "-quiet", "-lossless", str(ppm), "-o", str(path)], check=True)
    else:
        x = "0" if bright_on_left else "iw/2"
        pattern = f"color=black:size={width}x{height},drawbox=x={x}:w=iw/2:h=ih:color=white:t=fill"
        ffmpeg(
            output,
            "-f",
            "lavfi",
            "-i",
            pattern,
            "-c",
            fixture.encoder,
            "-threads",
            "1",
            *fixture.options,
            "-f",
            fixture.muxer,
            fixture.filename,
        )


def generate_raw_video(output):
    pixels = 96 * 64
    frames = []
    for y, cb, cr in ((81, 90, 240), (145, 54, 34), (41, 240, 110)):
        frame = bytes([y]) * pixels + bytes([cb]) * (pixels // 4) + bytes([cr]) * (pixels // 4)
        frames.append(frame * 8)
    (output / RAW_VIDEO).write_bytes(b"".join(frames))
    # Both compressed bitstreams accept padding after the encoded picture. The
    # native raw reader supplies a timestamp and one packet per picture.
    with TemporaryDirectory() as temporary:
        work = Path(temporary)
        for filename, codec, pixel_format, packet_size in (
            (RAW_MJPEG, "mjpeg", "yuvj420p", 2048),
            (RAW_H263P, "h263p", "yuv420p", 1024),
        ):
            with (output / filename).open("wb") as raw:
                for color in ("red", "lime", "blue"):
                    ffmpeg(
                        work,
                        "-f",
                        "lavfi",
                        "-i",
                        f"color={color}:size=96x64",
                        "-frames:v",
                        "1",
                        "-c:v",
                        codec,
                        "-pix_fmt",
                        pixel_format,
                        "-f",
                        "image2",
                        "-update",
                        "1",
                        "frame.bin",
                    )
                    frame = (work / "frame.bin").read_bytes()
                    if len(frame) > packet_size:
                        raise ValueError(f"{codec} frame exceeds the configured packet size")
                    raw.write(frame.ljust(packet_size, b"\0") * 8)


def generate_hap(output, fixture):
    width, height = fixture.width, fixture.height
    with TemporaryDirectory() as temporary:
        work = Path(temporary)
        for index, color in enumerate((0xF800, 0x07E0, 0x001F)):
            # Hap1 stores 4×4 DXT1 blocks. Every pixel selects the first RGB565
            # endpoint. The Hap section uses uncompressed texture data.
            block = struct.pack("<HHI", color, 0, 0)
            texture = block * (width // 4) * (height // 4)
            packet = len(texture).to_bytes(3, "little") + b"\xab" + texture
            for frame in range(index * 8, (index + 1) * 8):
                (work / f"frame-{frame:02}.bin").write_bytes(packet)
        ffmpeg(
            output,
            "-f",
            "image2",
            "-c:v",
            "hap",
            "-framerate",
            "8",
            "-video_size",
            f"{width}x{height}",
            "-i",
            str(work / "frame-%02d.bin"),
            "-c:v",
            "copy",
            "-tag:v",
            "Hap1",
            fixture.filename,
        )


def ingenient_mjpeg(output, fixture):
    with TemporaryDirectory() as temporary:
        work = Path(temporary)
        ffmpeg(work, "-f", "lavfi", "-i", fixture.source, "-c:v", "mjpeg", "-pix_fmt", "yuvj420p", "-threads", "1", "frame-%02d.jpg")
        with (output / fixture.filename).open("wb") as stream:
            for image in sorted(work.glob("frame-*.jpg")):
                packet = image.read_bytes()
                stream.write(struct.pack("<4sIHH36x", b"MJPG", len(packet), fixture.width, fixture.height))
                stream.write(packet)


def packed_yuv(output, fixture):
    width, height = fixture.width, fixture.height
    with (output / fixture.filename).open("wb") as stream:
        for y, u, v in ((324, 360, 960), (580, 216, 136), (164, 960, 440)):
            if fixture.muxer == "bitpacked":
                group = ((u << 30) | (y << 20) | (v << 10) | y).to_bytes(5, "big")
                line = group * (width // 2)
            else:
                groups = ((u, y, v), (y, u, y), (v, y, u), (y, v, y))
                line = b"".join(struct.pack(">I", (first << 22) | (second << 12) | (third << 2)) for first, second, third in groups) * (
                    width // 6
                )
            stream.write(line * height * 4)


def g729_audio(output, fixture):
    # 125 10 ms frames of a 440 Hz, 8 kHz mono sine encoded with bcg729 1.1.1.
    # Voice activity detection was disabled to retain all 10-byte speech frames.
    packets = zlib.decompress(
        base64.b64decode(
            b"eNod0n9ME2ccBnDsqBLljVy3UVY0otXC0Jl7z2UwFH/hosJ1o+1WZsuk69AYiRt3JsIwJPxY0ADNaEFoysIYE90k"
            b"ku4gF5zOlCLYQGEU2MQ2jlIZQUuAXhEzXJa9L//38z7P873WXHa0Rqw6qXX/mjjlW5uudbS2MyY73f3yVsipzzFx"
            b"9ELM7+z3r70CDmWMK0OdrW6R59Kl4zvIstle5cVa/5yFcomkYtbtv13P5nduk0/SX97oYP481gwcoCamSx1HesCv"
            b"9Jl+C8P3NClW6Hv7X6kaRTL0crDLKHx4pilqyv2fVULxlWbQ5Q5fHKTevE4AI/vQQEHugfkkSy/Mj4UbG4aAj37h"
            b"0Qnbq3KUl9zBiDbqlFYFlqL9T+rVp77RA04pc/mYU6Z4xayuaslIRkp6AUfPWjPhoc+kUS+HNdYvsn/wy8Bdt/2r"
            b"AJS1EOKwt+GNPrUnt0VuUMYZfIV9GTLxlLszageV2ke8w7mfU0aqfaMZdRlIt0DHhBnY6Zndavj1aZW8m57P3sfq"
            b"H+nRoiUyQ+ILtKAd//wSELoisHg4bYHvHSeAPXqufCPVf9Aj54W+T1i4v90sFkwxrmZVgcUHjPRv54RQ8edSwN+d"
            b"nEtdypuRos7zpSWUJlIlt7MTkbdgaZVKHB4+OXcx+5LKBwx0kPmRqTZJ5ffdF6rVsOysOSqslD2OZybW2+T8cGRP"
            b"5lLKFqn4lZvLc0BbKQH42mnKKBQdbkKtJpUl5J4rKtTKvtjGgCfE9mV6vrBG03fcC7hhYjQzVNDvA2ej7+zjKPsE"
            b"vl+PaZCq/VYK7NRkwtiS+6pHIdAdST62ZSu+VSBhNSQZ8STfZR8samGt7pp8Wde4Iy00XuYFvHvFIIS3FhxXXqb5"
            b"4jSoWd+E3puOOBoe628GM7LKvYNkm8Fs4lhH9znozEBNudHX1dBpike/W0yihLFGqWKZfj6vkWw7it4DkVZ5dmq0"
            b"DwTolc0V1A2lGfC2sto2kiVUgGOdLgk8mmxG4kVsFjueawN8dDjBK9wUPQIB3WjtRpiy4QgSdalqUnvYjIQrVgIb"
            b"9mDx04EhJitdhsTf+84LCQaUoeuVVsNDGwicURQgD0URSIxsFsEkBRYvK3Yz0jEsnrauCoWnsahjkkIKBW718ImR"
            b"pPOx6KtQU59mEEjwsbtZRQlutZrtFeh8JPRpzw4ybZU4o9wUIKvWdnhdNmj+7ggSHUkdjDYWZ/g7qsPXF7B4++dU"
            b"kvxAhYRVH4D1JN7hjBPBsgbc6tnH8WzjpjwkgglpQvpjLIqfpVzYewVnWDRqMrcO/cPYv05IyEYtFp11WYw0gFsF"
            b"rTrh3cPoVnrKdZ/cuSYG0o3krjgshj0iWLMN75jW1rCJJVNYLNuEj9auOxJ5Hu692YuEuZwlE61YOK0S2DyAxW0i"
            b"nikawDuCx5KFohx8K9eBEyGyFN+q/H2OTIzByx1DIlISwq34q12qO+vwDn/soNCzXo/ExGRPaNfa9/D2B8iCOZwx"
            b"uFNEbnmKM+75swrzjuCMFYmG3RKHW/3ht4RQq/8BXWc8rg=="
        )
    )
    target = output / fixture.filename
    if fixture.muxer == "g729":
        target.write_bytes(packets)
        return
    source = "codecs-speech-tone.g729"
    if fixture.muxer == "w64":
        # Whole G.729 frames must fill the Wave64 data chunk without an alignment tail.
        with TemporaryDirectory() as temporary:
            work = Path(temporary)
            (work / source).write_bytes(packets[:-10])
            ffmpeg(work, "-f", "g729", "-i", source, "-c", "copy", "-f", "w64", "tone.w64")
            target.write_bytes((work / "tone.w64").read_bytes())
    else:
        ffmpeg(output, "-f", "g729", "-i", source, "-c", "copy", "-f", fixture.muxer, fixture.filename)
    if fixture.muxer in ("wav", "w64"):
        data = bytearray(target.read_bytes())
        format_offset = data.index(b"fmt ") + (24 if fixture.muxer == "w64" else 8)
        struct.pack_into("<IH", data, format_offset + 8, 1000, 10)
        target.write_bytes(data)


def openmg_audio(output, fixture):
    # The OpenMG reader accepts these streams, while FFmpeg's OMA writer only emits ATRAC.
    codec_tag, payload_format = {"aac": (2, "adts"), "mp3": (3, "mp3"), "pcm_s16be": (4, "s16be")}[fixture.codec]
    with TemporaryDirectory() as temporary:
        work = Path(temporary)
        ffmpeg(work, "-f", "lavfi", "-i", fixture.source, "-c:a", fixture.encoder, *fixture.options, "-f", payload_format, "audio.raw")
        payload = (work / "audio.raw").read_bytes()
    header = b"EA3\0\0\x60\xff\xff" + bytes(24) + bytes([codec_tag]) + bytes(63)
    (output / fixture.filename).write_bytes(header + payload)


def dts_hd_container(output, fixture):
    source = output / "codecs-dts-core.dts"
    frame_count = int(
        subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-count_packets",
                "-select_streams",
                "a:0",
                "-show_entries",
                "stream=nb_read_packets",
                "-of",
                "csv=p=0",
                source,
            ]
        )
    )
    samples_per_frame, rate = 512, 48000
    profile = (
        bytes(3)
        + rate.to_bytes(3, "big")
        + struct.pack(">IH", frame_count, samples_per_frame)
        + (frame_count * samples_per_frame).to_bytes(5, "big")
        + struct.pack(">2H", 1, 0)
    )
    chunks = (
        (b"DTSHDHDR", bytes(12)),
        (b"AUPR-HDR", profile),
        (b"STRMDATA", source.read_bytes()),
        (b"FILEINFO", b"Authored tone\0"),
    )
    (output / fixture.filename).write_bytes(b"".join(tag + struct.pack(">Q", len(payload)) + payload for tag, payload in chunks))


def mpeg_audio_in_mp4(output, fixture):
    with TemporaryDirectory() as temporary:
        template = Path(temporary) / "tone.mp4"
        ffmpeg(output, "-i", MP3_ADU, "-t", "1.25", "-map", "0:a:0", "-c:a", "copy", "-tag:a", "mp4a", template)
        data = bytearray(template.read_bytes())
        packets = json.loads(
            subprocess.check_output(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_packets",
                    "-show_entries",
                    "packet=pos,size",
                    "-of",
                    "json",
                    template,
                ]
            )
        )["packets"]

    # MPEG-4 stores the packet length in the twelve bits normally occupied by the sync word.
    for packet in packets:
        position, size = int(packet["pos"]), int(packet["size"])
        assert size == 384 and data[position : position + 2] == b"\xff\xfb"
        struct.pack_into(">H", data, position, (size << 4) | (data[position + 1] & 15))

    start, end = 0, len(data)
    parents = []
    for tag, fields in ((b"moov", 0), (b"trak", 0), (b"mdia", 0), (b"minf", 0), (b"stbl", 0), (b"stsd", 8), (b"mp4a", 28)):
        while start < end:
            size, actual = struct.unpack_from(">I4s", data, start)
            assert 8 <= size <= end - start
            if actual == tag:
                parents.append((start, size))
                start, end = start + 8 + fields, start + size
                break
            start += size
        else:
            raise ValueError(f"{tag!r} missing from MPEG-4 audio template")
    size, tag = struct.unpack_from(">I4s", data, start)
    assert tag == b"esds"

    def descriptor(tag, payload):
        return bytes((tag, len(payload))) + payload

    # Audio object type 34 (Layer III), 48 kHz and one channel.
    config = ((31 << 19) | (2 << 13) | (3 << 9) | (1 << 5)).to_bytes(3, "big")
    decoder = descriptor(4, b"\x40\x15" + bytes(3) + struct.pack(">2I", 128000, 128000) + descriptor(5, config))
    entry = bytes(4) + descriptor(3, b"\x00\x01\x00" + decoder + descriptor(6, b"\x02"))
    replacement = struct.pack(">I4s", len(entry) + 8, b"esds") + entry
    for position, parent_size in parents:
        struct.pack_into(">I", data, position, parent_size + len(replacement) - size)
    data[start : start + size] = replacement
    (output / fixture.filename).write_bytes(data)


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    generate_raw_video(output)
    generate_transport_cases(output)
    generate_mpegts_program_changes(output)
    generate_video_timing_cases(output)
    generate_video_geometry_cases(output)
    generate_av1_film_grain(output)
    generate_video_alpha(output)
    for fixture in COLOR_VIDEO:
        if fixture.muxer == "ipu":
            (output / fixture.filename).write_bytes(ipu(fixture.width, fixture.height, COLORS))
        elif fixture.muxer == "mxg":
            (output / fixture.filename).write_bytes(mxg(fixture.width, fixture.height))
        elif fixture.muxer == "r3d":
            (output / fixture.filename).write_bytes(r3d(fixture.width, fixture.height))
        else:
            generate_legacy_video(output, fixture, ffmpeg)
    avs3 = avs3_matroska()
    for fixture in AVS3_VIDEO:
        if fixture.muxer == "matroska":
            (output / fixture.filename).write_bytes(avs3)
        else:
            ffmpeg(output, "-i", AVS3_VIDEO[0].filename, "-map", "0:v:0", "-c:v", "copy", "-f", fixture.muxer, fixture.filename)
    for fixture, tag, _ in PRORES_RAW_VIDEO:
        generate_prores_raw(output, fixture, tag, ffmpeg)
    for fixture, profile in APV_VIDEO:
        if fixture.muxer == "apv":
            generate_apv(output / fixture.filename, profile, fixture.width, fixture.height)
        else:
            ffmpeg(output, "-framerate", "24", "-i", f"codecs-apv-{profile}.apv", "-c:v", "copy", fixture.filename)
    for fixture, _, _ in CHROMA_VIDEO:
        size = f"{fixture.width}x{fixture.height}"
        ffmpeg(
            output,
            "-f",
            "lavfi",
            "-i",
            f"color=red:size={size}:rate=24:duration=0.5",
            "-f",
            "lavfi",
            "-i",
            f"color=blue:size={size}:rate=24:duration=0.5",
            "-filter_complex",
            "[0:v][1:v]concat=n=2:v=1:a=0",
            "-c:v",
            fixture.encoder,
            "-threads:v",
            "1",
            "-g",
            "12",
            *fixture.options,
            fixture.filename,
        )
    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:sample_rate=48000:duration=2.4",
        "-c:a",
        "libmp3lame",
        "-b:a",
        "128k",
        "-reservoir",
        "0",
        "-write_xing",
        "0",
        "-id3v2_version",
        "0",
        "-f",
        "mp3",
        MP3_ADU,
    )
    rtp_audio = []
    for codec, decoder, storage, payload, encoding, rate, packet_bytes, packet_ticks, packet_ms in RTP_AUDIO:
        name = rtp_audio_name(codec, storage)
        bitrate = ("-b:a", "6300") if codec == "g723_1" else ()
        ffmpeg(
            output,
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency=440:sample_rate={rate}:duration=1.2",
            "-c:a",
            decoder,
            *bitrate,
            "-f",
            storage,
            name,
        )
        assert (output / name).stat().st_size == 1200 // packet_ms * packet_bytes
        rtp_audio.append(
            {
                "file": name,
                "codec": codec,
                "decoder": decoder,
                "payloadType": payload,
                "encoding": encoding,
                "packetBytes": packet_bytes,
                "packetTicks": packet_ticks,
                "packetMs": packet_ms,
                "androidOnly": codec == "g723_1",
            }
        )

    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        "anoisesrc=amplitude=0.25:seed=117:sample_rate=8000:duration=3",
        "-af",
        "volume='if(lt(t,1.5),0.22,1)':eval=frame",
        "-c:a",
        "comfortnoise",
        "-f",
        "nut",
        COMFORT_NOISE,
    )

    # Alternate the bright half of successive images so a previously displayed
    # frame cannot satisfy the next fixture's readback.
    bright_on_left = {fixture.filename: index % 2 == 0 for index, fixture in enumerate(IMAGES + MF_ONLY_IMAGES)}
    audio_picture = {
        "dv-audio.dv": ("testsrc2=size=720x480:rate=30000/1001:duration=1.25125", "dvvideo", "yuv411p"),
        "ima-amv.amv": ("testsrc2=size=176x144:rate=15:duration=1.333333", "amv", "yuvj420p"),
    }
    legacy_formats = {name for name, _, _, _ in LEGACY_AUDIO_FORMATS}
    console_formats = {name: rate for name, _, _, rate in CONSOLE_AUDIO_FORMATS}
    audio_generators = {
        "n64-adpcm.aifc": (n64_aifc, 22050),
        "ima-ws.aifc": (westwood_aifc, 22050),
        "tone.qoa": (qoa, 22050),
        "ffmpeg-raw-vidc.pcm": (vidc, 22050),
        "cdrom-xa.aiff": (xa_aiff, 37800),
        "pcm-s64be.caf": (big_endian_pcm_caf, 48000),
    }
    for fixture in (*VIDEO, *AUDIO, *IMAGES, *MF_ONLY_IMAGES, *(fixture for fixture, _ in HIGH_EFFICIENCY_AAC)):
        if fixture in DERIVED_VIDEO or fixture in DERIVED_AUDIO:
            continue
        if fixture.muxer == "nistsphere" and fixture.codec != "pcm_s16le":
            if fixture.codec == "shorten":
                data = nistsphere(shorten(), 16000, "pcm,embedded-shorten-v2.00", 2)
            else:
                coding = "alaw" if fixture.codec == "pcm_alaw" else "ulaw"
                data = nistsphere(g711(fixture.codec), 8000, coding, 1)
            (output / fixture.filename).write_bytes(data)
            continue
        if fixture.name in ("h263-plus.asf", "hevc.asf"):
            source, fourcc = ("h263-plus.avi", "H263") if fixture.codec == "h263" else ("hevc.hevc", "HEVC")
            ffmpeg(
                output, "-fflags", "+genpts", "-i", f"codecs-{source}", "-map", "0:v:0", "-c", "copy", "-tag:v", fourcc, fixture.filename
            )
            continue
        if fixture.codec == "vorbis" and fixture.muxer in ("wav", "w64"):
            (output / fixture.filename).write_bytes(vorbis_wave(output / "codecs-vorbis.ogg", fixture.muxer))
            continue
        if fixture.muxer == "matroska" and fixture.codec in ("rv10", "rv20"):
            source = output / f"codecs-{fixture.codec}.rm"
            (output / fixture.filename).write_bytes(realmedia_matroska(source, codec=fixture.codec))
            continue
        if fixture.name in ("aac-packet-table.caf", "opus-packet-table.caf"):
            source = output / ("codecs-aac-lc.m4a" if fixture.codec == "aac" else "codecs-opus.ogg")
            (output / fixture.filename).write_bytes(caf_with_packet_table(source, fixture.codec))
            continue
        if fixture.muxer == "mpegts" and fixture.name.startswith("hdmv-"):
            stem = fixture.name.removeprefix("hdmv-").removesuffix(".ts")
            packets = (output / f"codecs-{stem}.m2ts").read_bytes()
            # Strip the Blu-ray arrival timestamps and retain the HDMV program registration.
            assert len(packets) % 192 == 0 and all(sync == 0x47 for sync in packets[4::192])
            (output / fixture.filename).write_bytes(b"".join(packets[i + 4 : i + 192] for i in range(0, len(packets), 192)))
            continue
        if fixture.codec in ("amr_nb", "amr_wb"):
            generate_amr(output, fixture.filename, wideband=fixture.codec == "amr_wb", storage_header=fixture.muxer == "amr")
            continue
        if fixture.codec == "tscc":
            tscc_avi(output, fixture)
            continue
        if fixture.codec == "hap":
            generate_hap(output, fixture)
            continue
        if fixture.codec in ("pcm_f16le", "pcm_f24le"):
            audition_wave(output, fixture)
            continue
        if fixture.codec in WAVE_ADPCM_PROFILES:
            generate_wave_adpcm(output / fixture.filename, fixture.codec)
            continue
        if fixture.codec == "mp1":
            mpeg_layer1(output / fixture.filename)
            continue
        if fixture.codec == "mp3on4":
            mpeg_audio_in_mp4(output, fixture)
            continue
        if fixture.name == "sofdec-adx.mpg":
            (output / fixture.filename).write_bytes(sofdec_adx((output / "codecs-adpcm-adx.adx").read_bytes()))
            continue
        if fixture.muxer == "usm":
            if fixture.codec == "adpcm_adx":
                payload = usm_adx((output / "codecs-adpcm-adx.adx").read_bytes())
            elif fixture.codec == "hca":
                payload = usm_hca((output / "codecs-tonal-mdct.hca").read_bytes())
            else:
                source = {"h264": "h264.h264", "mpeg1video": "mpeg1.m1v", "vp9": "vp9.webm"}[fixture.codec]
                payload = usm_video(output / f"codecs-{source}", fixture.codec, fixture.width, fixture.height)
            (output / fixture.filename).write_bytes(payload)
            continue
        if fixture.muxer == "bonk":
            (output / fixture.filename).write_bytes(bonk())
            continue
        if fixture.muxer == "hca":
            (output / fixture.filename).write_bytes(hca())
            continue
        if fixture.codec == "westwood_snd1":
            (output / fixture.filename).write_bytes(westwood_snd1())
            continue
        if fixture.codec == "ftr":
            (output / fixture.filename).write_bytes(ftr_voice(output / "codecs-aac-lc.aac"))
            continue
        if fixture.codec == "ahx":
            with TemporaryDirectory(dir=output) as directory:
                folder = Path(directory)
                ffmpeg(folder, "-f", "lavfi", "-i", fixture.source, "-c:a", "mp2", "-b:a", "160k", "source.mp2")
                (output / fixture.filename).write_bytes(ahx(folder / "source.mp2"))
            continue
        if fixture.codec == "misc4":
            (output / fixture.filename).write_bytes(micronas_sc4(fixture.muxer))
            continue
        if fixture.muxer == "moflex":
            (output / fixture.filename).write_bytes(moflex(fixture.codec))
            continue
        if fixture.muxer in ("mxg", "r3d"):
            picture = {"mxg": "codecs-camera-motion.mxg", "r3d": "codecs-red-camera-motion.r3d"}[fixture.muxer]
            (output / fixture.filename).write_bytes((output / picture).read_bytes())
            continue
        if fixture.muxer == "ty":
            continue
        if fixture.codec == "speex":
            stem = Path(fixture.filename).stem
            if fixture.muxer == "ogg":
                (output / fixture.filename).write_bytes(speex_tone(stem.rsplit("-", 1)[1]))
            else:
                ffmpeg(output, "-i", stem + ".spx", "-c", "copy", "-f", "nut", fixture.filename)
            continue
        if fixture.codec == "g729":
            g729_audio(output, fixture)
            continue
        if fixture.codec == "acelp.kelvin":
            packets = (output / "codecs-speech-tone.g729").read_bytes()
            (output / fixture.filename).write_bytes(acelp_kelvin(packets, fixture.muxer))
            continue
        if fixture.codec == "dvaudio":
            (output / fixture.filename).write_bytes(dv_wave("pal" in fixture.name))
            continue
        if fixture.codec in ("gsm", "gsm_ms"):
            signal = telephone_gsm(fixture.codec == "gsm_ms")
            if fixture.muxer == "aiff":
                signal = aifc(8000, b"GSM ", b"GSM", len(signal) // 33, signal)
            (output / fixture.filename).write_bytes(signal)
            continue
        if fixture.muxer == "oma":
            openmg_audio(output, fixture)
            continue
        if fixture.muxer == "sbg":
            (output / fixture.filename).write_bytes(b"-SE\ntone: 440/12\noff: -\nNOW == tone\n+0:00:01.25 == off\n")
            continue
        if fixture.muxer == "dtshd":
            dts_hd_container(output, fixture)
            continue
        if fixture.muxer in LEGACY_WRAPPERS:
            generate_legacy_wrapper(output, fixture)
            continue
        if generated := audio_generators.get(fixture.name):
            generator, rate = generated
            (output / fixture.filename).write_bytes(generator(rate))
            continue
        if fixture.muxer == "ingenient":
            ingenient_mjpeg(output, fixture)
            continue
        if fixture.muxer in ("v210x", "bitpacked"):
            packed_yuv(output, fixture)
            continue
        if fixture.name in legacy_formats:
            alaw = (output / "codecs-ffmpeg-raw-alaw.pcm").read_bytes() if fixture.muxer == "wve" else b""
            generate_legacy_audio(output / fixture.filename, fixture.muxer, fixture.codec, alaw)
            continue
        if fixture.name in console_formats:
            generate_console_audio(output / fixture.filename, fixture.muxer, fixture.codec, console_formats[fixture.name])
            continue
        if fixture.muxer == "argo_cvg":
            ffmpeg(output, "-i", "codecs-playstation.vag", "-c:a", "copy", "-skip_rate_check", "1", "-f", fixture.muxer, fixture.filename)
            continue
        if fixture.name == "g726le.aifc":
            with TemporaryDirectory() as temporary:
                work = Path(temporary)
                ffmpeg(
                    work,
                    "-f",
                    "lavfi",
                    "-i",
                    fixture.source,
                    "-c:a",
                    fixture.encoder,
                    "-code_size",
                    "5",
                    "-b:a",
                    "40k",
                    "-f",
                    "g726le",
                    "audio.raw",
                )
                payload = (work / "audio.raw").read_bytes()
            # Eight five-bit codewords occupy five bytes. Cross the reader's packet boundary.
            (output / fixture.filename).write_bytes(aifc(8000, b"G726", b"G.726 ADPCM", len(payload) // 5, payload))
            continue
        if fixture.muxer == "xwma":
            with TemporaryDirectory() as temporary:
                work = Path(temporary)
                ffmpeg(work, "-f", "lavfi", "-i", fixture.source, "-c:a", fixture.encoder, *fixture.options, "input.wav")
                wave_data = (work / "input.wav").read_bytes()
                # XWMA uses RIFF WMA format and data chunks with its own form type.
                (output / fixture.filename).write_bytes(wave_data[:8] + b"XWMA" + wave_data[12:])
            continue
        if fixture.muxer == "av1":
            av1_annex_b(output, fixture)
            continue
        if picture := audio_picture.get(fixture.name):
            video_source, video_encoder, pixel_format = picture
            ffmpeg(
                output,
                "-f",
                "lavfi",
                "-i",
                fixture.source,
                "-f",
                "lavfi",
                "-i",
                video_source,
                "-map",
                "1:v",
                "-map",
                "0:a",
                "-c:v",
                video_encoder,
                "-pix_fmt",
                pixel_format,
                "-threads:v",
                "1",
                "-c:a",
                fixture.encoder,
                *fixture.options,
                "-f",
                fixture.muxer,
                fixture.filename,
            )
            continue
        if fixture.filename in bright_on_left:
            generate_still(output, fixture, bright_on_left[fixture.filename])
            continue
        ffmpeg(
            output,
            "-f",
            "lavfi",
            "-i",
            fixture.source,
            "-c",
            fixture.encoder,
            "-threads",
            "1",
            *fixture.options,
            "-f",
            fixture.muxer,
            fixture.filename,
        )

    generate_legacy_wrapper(output, LMLM4_AV)
    palette_animation = flic(FLIC_INPUT.width, FLIC_INPUT.height)
    for fixture in (FLIC_INPUT, FLIC_AUDIO):
        (output / fixture.filename).write_bytes(palette_animation)
    ffmpeg(output, "-i", FLIC_INPUT.filename, "-map", "0:v:0", "-c", "copy", "-tag:v", "FLIC", FLIC_MOV.filename)
    dirac_packets = elementary_packets(output / "codecs-dirac-24.drc", "v:0")
    (output / DIRAC_OGG.filename).write_bytes(ogg_dirac(dirac_packets))
    with TemporaryDirectory(dir=output) as temporary:
        transport = Path(temporary).resolve() / "private-data.ts"
        ffmpeg(output, "-i", "codecs-jpeg2000.mov", "-map", "0:v:0", "-c", "copy", transport)
        (output / JPEG2000_TS.filename).write_bytes(jpeg2000_program_map(transport.read_bytes()))
    g723 = next(source["file"] for source in rtp_audio if source["codec"] == "g723_1")
    (output / DSS_AUDIO.filename).write_bytes(dss_g723((output / g723).read_bytes()))
    for fixture in MAUD_AUDIO:
        (output / fixture.filename).write_bytes(maud(fixture.codec))
    flash = swf(SWF_BITMAP.width, SWF_BITMAP.height)
    for fixture in (SWF_BITMAP, SWF_PCM):
        (output / fixture.filename).write_bytes(flash)
    mlv_sources = {"mjpeg": output / "codecs-mjpeg.avi", "h264": output / "codecs-h264.h264"}
    for fixture in MLV_VIDEO:
        data = mlv_video(fixture.codec, fixture.width, fixture.height, mlv_sources.get(fixture.codec))
        (output / fixture.filename).write_bytes(data)
    movie = sgi_movie(MV_RAW.width, MV_RAW.height)
    for fixture in (MV_RAW, MV_PCM):
        (output / fixture.filename).write_bytes(movie)
    (output / MV_JPEG.filename).write_bytes(sgi_movie(MV_JPEG.width, MV_JPEG.height, jpeg=True))
    with TemporaryDirectory(dir=output) as temporary:
        source = Path(temporary).resolve() / "tone.mp3"
        ffmpeg(
            output,
            "-f",
            "lavfi",
            "-i",
            AA_MP3.source,
            "-c:a",
            "libmp3lame",
            "-b:a",
            "32k",
            "-write_xing",
            "0",
            "-id3v2_version",
            "0",
            source,
        )
        (output / AA_MP3.filename).write_bytes(aa_mp3(source.read_bytes()))
    with TemporaryDirectory(dir=output) as temporary:
        work = Path(temporary).resolve()
        picture_carrier = work / "picture-carrier.wtv"
        ffmpeg(output, "-f", "lavfi", "-i", WTV_MJPEG.source, "-c:v", "mpeg2video", "-g", "1", "-q:v", "2", picture_carrier)
        pictures = color_stills(WTV_MJPEG.width, WTV_MJPEG.height, "mjpeg")
        (output / WTV_MJPEG.filename).write_bytes(wtv_mjpeg(picture_carrier.read_bytes(), pictures))

        frames = [packet for packet, _ in elementary_packets(output / "codecs-mpeg-layer1.mp1", "a:0")]
        temporary_audio = work / "carrier.mp2"
        audio_carrier = work / "audio-carrier.wtv"
        # Layer II carries 1152 samples per packet. Scale the timeline to the Layer I packet duration.
        duration = len(frames) * 1152 / 48000
        ffmpeg(output, "-f", "lavfi", "-i", f"anullsrc=r=48000:cl=mono:d={duration}", "-c:a", "mp2", "-b:a", "64k", temporary_audio)
        ffmpeg(output, "-itsscale", "0.3333333333333333", "-i", temporary_audio, "-c:a", "copy", audio_carrier)
        (output / WTV_MP1.filename).write_bytes(wtv_mp1(audio_carrier.read_bytes(), frames))
    for fixture in (*GXF_PICTURES, *GXF_TONES):
        (output / fixture.filename).write_bytes(gxf(output, fixture.codec))
    mxf_24bit = MXF_TONES[0]
    ffmpeg(output, "-f", "lavfi", "-i", mxf_24bit.source, "-c:a", mxf_24bit.codec, "-f", "mxf_opatom", mxf_24bit.filename)
    with TemporaryDirectory(dir=output) as temporary:
        template = Path(temporary).resolve() / "wide-pcm.mxf"
        ffmpeg(output, "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono:d=2.4", "-c:a", "pcm_s16le", "-f", "mxf_opatom", template)
        clip_24bit, clip_32bit = (output / mxf_24bit.filename).read_bytes(), template.read_bytes()
        for fixture in MXF_TONES[1:]:
            clip = clip_32bit if "32" in fixture.codec else clip_24bit
            (output / fixture.filename).write_bytes(mxf_pcm(clip, fixture.codec))
    paired = []
    for filename, muxer, picture, sound in paired_inputs():
        generate_paired(output, filename, muxer, picture, sound)
        paired.append(
            {
                "file": filename,
                "format": picture.format,
                "videoCodec": picture.codec,
                "videoDecoder": picture.decoder,
                "audioCodec": sound.codec,
                "audioDecoder": sound.decoder,
            }
        )
    webm = (output / "codecs-paired-vp9-opus.webm").read_bytes()
    cluster = bytes.fromhex("1f43b675")
    second_start = webm.index(cluster, webm.index(cluster) + len(cluster))
    (output / WEBM_TRUNCATED_CLUSTER).write_bytes(webm[: second_start + 16])
    for codec, source in (("mp2", "codecs-mp2-fixed.mp2"), ("ac3", "codecs-ac3.ac3")):
        clip = tivo_ty(output / "codecs-mpeg2.m2v", output / source, ac3=codec == "ac3")
        for track in ("picture", "sound"):
            (output / f"codecs-tivo-{track}-{codec}.ty").write_bytes(clip)
    mapped = {"audio": [], "video": [], "colorVideo": []}
    for source, target, kind, reader in remuxed_inputs():
        input_options = ("-fflags", "+genpts")
        if source.forced_format and source.forced_format not in {"mkv", "mf", "rawaudio", "rawvideo", "lavf"}:
            input_options += ("-f", source.forced_format)
        if reader == "ivf" and (fourcc := IVF_PACKET_TAGS.get(source.codec)):
            (output / target.filename).write_bytes(ivf(output / source.filename, fourcc=fourcc))
        elif target.muxer == "flv" and source.codec in {"h263", "mpeg4"}:
            (output / target.filename).write_bytes(flv_video(output / source.filename, source.codec))
        else:
            stream = "0:a:0" if kind == "audio" else "0:v:0"
            # WAVE stores self-framing ADTS with the MPEG HE-AAC WAVE tag.
            output_options = ("-tag:a", "0x1610") if target.muxer in ("wav", "w64") and source.codec == "aac" else ()
            if target.muxer == "mov" and source.codec == "dvvideo":
                output_options = ("-r", "30000/1001", "-write_tmcd", "0")
            ffmpeg(
                output,
                *input_options,
                "-i",
                source.filename,
                "-map",
                stream,
                "-c",
                "copy",
                *output_options,
                "-strict",
                "experimental",
                "-f",
                target.muxer,
                target.filename,
            )
        mapped[kind].append({**target.expectation(), "mapping": reader, "source": source.filename})
    generate_http_streams(output)
    rtp_video, rtp_packetized_audio, srtp_audio, srtp_transport = generate_packetized_rtp(output)
    segmented_mappings = generate_segmented_mappings(output, ffmpeg)
    generate_playlists(output)
    generate_cea608(output)
    with TemporaryDirectory(dir=output) as temporary:
        source = Path(temporary).resolve() / "caption-video.flv"
        ffmpeg(
            output,
            "-f",
            "lavfi",
            "-i",
            "color=red:size=176x144:rate=24:duration=2.75",
            "-c:v",
            "flv",
            "-g",
            "12",
            "-map_metadata",
            "-1",
            str(source),
        )
        (output / FLV_CAPTIONS).write_bytes(flv_captions(source, [(400, "First FLV cue"), (1400, "Second FLV cue")]))
    generate_vc1(output)
    generate_wmv3(output)
    generate_cue_album(output)
    generate_m4a_album(output)

    # Each segment carries a different primary. A seek must decode the new segment's pixels.
    def segment_video(*args):
        ffmpeg(
            output,
            "-f",
            "lavfi",
            "-i",
            "color=red:size=176x144:rate=12:duration=1",
            "-f",
            "lavfi",
            "-i",
            "color=lime:size=176x144:rate=12:duration=1",
            "-f",
            "lavfi",
            "-i",
            "color=blue:size=176x144:rate=12:duration=1",
            "-filter_complex",
            "[0:v][1:v][2:v]concat=n=3:v=1:a=0",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-g",
            "12",
            "-sc_threshold",
            "0",
            "-threads",
            "1",
            *args,
        )

    segment_video(
        "-f", "hls", "-hls_time", "1", "-hls_playlist_type", "vod", "-hls_segment_filename", "codecs-hls-%02d.ts", "codecs-hls.m3u8"
    )
    segment_video(
        "-f",
        "hls",
        "-hls_time",
        "1",
        "-hls_playlist_type",
        "vod",
        "-hls_segment_type",
        "fmp4",
        "-hls_fmp4_init_filename",
        "codecs-hls-init.mp4",
        "-hls_segment_filename",
        "codecs-hls-%02d.m4s",
        "codecs-hls-fmp4.m3u8",
    )
    segment_video(
        "-f",
        "dash",
        "-seg_duration",
        "1",
        "-use_timeline",
        "0",
        "-init_seg_name",
        "codecs-dash-init.m4s",
        "-media_seg_name",
        "codecs-dash-$Number%02d$.m4s",
        "codecs-dash.mpd",
    )
    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        "color=red:size=176x144:rate=12:duration=1",
        "-c:v",
        "libvpx-vp9",
        "-deadline",
        "realtime",
        "-threads",
        "1",
        "-g",
        "3",
        "-dash",
        "1",
        "-f",
        "webm",
        WEBM_DASH_INDEX,
    )
    for filename, color in zip(MP4_PARTS, ("red", "lime", "blue")):
        ffmpeg(
            output,
            "-f",
            "lavfi",
            "-i",
            f"color={color}:size=176x144:rate=12:duration=1",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-threads",
            "1",
            filename,
        )
    (output / "codecs-concat.ffconcat").write_text("ffconcat version 1.0\n" + "".join(f"file {name}\nduration 1.0\n" for name in MP4_PARTS))
    (output / "codecs-timeline.edl").write_text("# mpv EDL v0\n" + "".join(f"{name},0,1\n" for name in MP4_PARTS))

    for filename, color in zip(STILLS, ("red", "lime", "blue")):
        ffmpeg(
            output,
            "-f",
            "lavfi",
            "-i",
            f"color={color}:size=32x24",
            "-frames:v",
            "1",
            "-c:v",
            "dpx",
            "-pix_fmt",
            "rgb24",
            "-update",
            "1",
            filename,
        )

    cue = output / "cue.srt"
    cue.write_text("1\n00:00:01,000 --> 00:00:02,000\nFirst cue\n\n2\n00:00:02,500 --> 00:00:03,500\nSecond cue\n")
    ffmpeg(
        output,
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=176x144:rate=12:duration=4",
        "-i",
        cue.name,
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-threads",
        "1",
        "-c:s",
        "mov_text",
        SUBTITLE_VIDEO,
    )
    (output / SUBTITLE_VTT).write_text(
        "WEBVTT\n\n"
        "00:01.000 --> 00:02.000 position:25%,line-left line:80%,end size:40% align:start\nWebVTT first cue\n\n"
        "00:02.500 --> 00:03.500\nWebVTT second cue\n",
        encoding="utf-8",
    )
    cue.unlink()
    with TemporaryDirectory(dir=output) as temp:
        captions = Path(temp) / "captions.vtt"
        captions.write_text(
            "WEBVTT\n\n"
            "00:01.000 --> 00:02.000 position:75%,line-right line:20%,start size:30% align:start\nכתוביות בעברית\n\n"
            "00:02.500 --> 00:03.500\nCaptions second cue\n",
            encoding="utf-8",
        )
        ffmpeg(
            output,
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=176x144:rate=12:duration=4",
            "-i",
            SUBTITLE_VTT,
            "-i",
            str(captions.resolve()),
            "-map",
            "0:v:0",
            "-map",
            "1:s:0",
            "-map",
            "2:s:0",
            "-c:v",
            "libvpx-vp9",
            "-deadline",
            "realtime",
            "-g",
            "12",
            "-threads",
            "1",
            "-c:s",
            "copy",
            "-disposition:s:0",
            "default",
            "-disposition:s:1",
            "captions",
            SUBTITLE_WEBM,
        )
    ffmpeg(output, "-i", SUBTITLE_WEBM, "-map", "0", "-c", "copy", "-f", "matroska", SUBTITLE_MATROSKA)

    (output / MANIFEST).write_text(
        json.dumps(
            {
                "video": [fixture.expectation() for fixture in VIDEO],
                "colorVideo": [fixture.expectation() for fixture in COLOR_VIDEO],
                "avs3Video": [fixture.expectation() for fixture in AVS3_VIDEO],
                "proresRAWVideo": [
                    {**fixture.expectation(), "profile": profile, "mpvPixelFormat": "bayer_rggb16"}
                    for fixture, _, profile in PRORES_RAW_VIDEO
                ],
                "apv": [{**fixture.expectation(), "pixelFormat": APV_PROFILES[profile][3]} for fixture, profile in APV_VIDEO],
                "chromaVideo": [
                    {
                        **fixture.expectation(),
                        "pixelFormat": pixel_format,
                        "profile": profile,
                        "mpvPixelFormat": pixel_format.removesuffix("le"),
                    }
                    for fixture, pixel_format, profile in CHROMA_VIDEO
                ],
                "audio": [fixture.expectation() for fixture in AUDIO],
                "highEfficiencyAAC": [{**fixture.expectation(), "profile": profile} for fixture, profile in HIGH_EFFICIENCY_AAC],
                "images": [{**fixture.expectation(), "brightOnLeft": bright_on_left[fixture.filename]} for fixture in IMAGES],
                "mfImages": [
                    {
                        **fixture.expectation(),
                        "format": "mf",
                        "androidOnly": fixture.codec not in ("mjpeg", "webp"),
                        "mpvOptions": {"demuxer": "mf", "mf-type": MF_IMAGE_TYPES[fixture.codec]},
                        "brightOnLeft": bright_on_left[fixture.filename],
                    }
                    for fixture in IMAGES + MF_ONLY_IMAGES
                    if fixture.codec in MF_IMAGE_TYPES and fixture.muxer != "ico"
                ],
                "paired": paired,
                "dashRenditions": {"file": DASH_RENDITIONS, "format": "dash", "parts": DASH_RENDITION_PARTS},
                "dashAdaptationSets": {"file": DASH_ADAPTATION_SETS, "format": "dash", "parts": DASH_RENDITION_PARTS},
                "dashAudioAdaptationSets": {
                    "file": DASH_AUDIO_ADAPTATION_SETS,
                    "format": "dash",
                    "parts": (*DASH_HTTP_PARTS, *DASH_ALTERNATE_AUDIO_PARTS),
                },
                "liveDash": {"file": DASH_LIVE, "update": DASH_LIVE_UPDATE, "parts": DASH_LIVE_PARTS},
                "liveDashSliding": {"file": DASH_LIVE, "update": DASH_LIVE_SLIDE, "parts": DASH_LIVE_PARTS},
                "dashRollovers": {"manifests": DASH_ROLLOVER_MANIFESTS, **DASH_ROLLOVER_PARTS},
                "mappedVideo": mapped["video"],
                "mappedColorVideo": mapped["colorVideo"],
                "mappedAudio": mapped["audio"],
                "vc1": vc1_cases("vc1", ((VC1_STREAM, "vc1"), *VC1_CONTAINERS)),
                "wmv3": vc1_cases("wmv3", ((WMV3_STREAM, "vc1test"), *WMV3_CONTAINERS)),
                "surround": generate_surround_audio(output),
                "audioRates": generate_audio_rate_cases(output),
                "monkeysAudio": generate_monkeys_audio(output),
                "segmented": [{"file": name, "format": format_name, "parts": parts} for name, format_name, parts in SEGMENTED],
                "networkStreams": [{"file": name, "format": format_name, "parts": parts} for name, format_name, parts in NETWORK_STREAMS],
                "segmentedVideo": segmented_mappings["video"],
                "segmentedAudio": segmented_mappings["audio"],
                "rtpAudio": rtp_audio,
                "rtpVideo": rtp_video,
                "rtpPacketizedAudio": rtp_packetized_audio,
                "srtpAudio": srtp_audio,
                "srtpTransport": srtp_transport,
                "liveStream": {"file": LIVE_PLAYLIST, "update": LIVE_UPDATE, "parts": HTTP_TS_PARTS},
                "hlsRenditions": {"file": HLS_MASTER, "format": "hls", "parts": HLS_RENDITIONS},
                "hlsDiscontinuities": {"file": HLS_DISCONTINUITIES, "format": "hls", "parts": HLS_DISCONTINUITY_PARTS},
                "hlsTimestampResets": {"file": HLS_TIMESTAMP_RESETS, "format": "hls", "parts": HTTP_TS_PARTS},
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    generate(parser.parse_args().output)
